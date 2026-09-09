--- Go adapter. Identifies fmt and log output calls via Tree-sitter (or an
--- embedded scanner fallback) and routes them through a runtime helper that
--- records caller coordinates with runtime.Caller. Compiler diagnostics
--- and panic traces are parsed from native compiler output.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local utils = require("itchy.utils")

M.name = "go"

--- Callee rewrites. Keys are `package + "." + method`.
local REWRITES = {
	["fmt.Print"] = "__itchyFmtPrint",
	["fmt.Printf"] = "__itchyFmtPrintf",
	["fmt.Println"] = "__itchyFmtPrintln",
	["log.Print"] = "__itchyLogPrint",
	["log.Printf"] = "__itchyLogPrintf",
	["log.Println"] = "__itchyLogPrintln",
}

--- Whether Tree-sitter can parse Go in this Neovim (no hard requirement).
---@return boolean
function M._has_treesitter()
	local ok_lang = pcall(vim.treesitter.language.add, "go")
	if not ok_lang then
		return false
	end
	local ok_q = pcall(vim.treesitter.query.parse, "go", "(call_expression) @call")
	return ok_q
end

--- Instrument only relevant call selectors via Tree-sitter.
--- Returns nil + error when the parser is unavailable so the caller can
--- use the embedded scanner instead.
---@param source string
---@return string?, string? instrumented source or nil + error
local function instrument_ts(source)
	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, "go")
	if not ok_parser or parser == nil then
		return nil, "go treesitter parser unavailable"
	end
	local ok_tree, trees = pcall(function()
		return parser:parse(true)
	end)
	if not ok_tree or trees == nil or trees[1] == nil then
		return nil, "go treesitter parse failed"
	end
	local root = trees[1]:root()
	local ok_q, query = pcall(
		vim.treesitter.query.parse,
		"go",
		"(call_expression function: (selector_expression operand: (identifier) @obj field: (field_identifier) @fld))"
	)
	if not ok_q or query == nil then
		return nil, "go treesitter query failed"
	end

	---@type table<integer, table[]> per-TS-row replacements {start_col, end_col, text}; TS rows/cols are 0-based bytes
	local by_ts_row = {}
	for id, node, _ in query:iter_captures(root, source, 0, -1) do
		local capture = query.captures[id]
		if capture == "obj" then
			-- handled together with its sibling field below; skip here
		elseif capture == "fld" then
			-- find sibling operand via parent selector
			local parent = node:parent()
			if parent ~= nil and parent:type() == "selector_expression" then
				local obj_node = parent:field("operand")[1]
				if obj_node ~= nil then
					local obj_text = vim.treesitter.get_node_text(obj_node, source)
					local fld_text = vim.treesitter.get_node_text(node, source)
					local key = obj_text .. "." .. fld_text
					local replacement = REWRITES[key]
					if replacement ~= nil then
						local start_row, start_col, end_row, end_col = parent:range()
						-- Selectors never span lines; skip anything unexpected.
						if start_row == end_row then
							by_ts_row[start_row] = by_ts_row[start_row] or {}
							table.insert(by_ts_row[start_row], { start_col = start_col, end_col = end_col, text = replacement })
						end
					end
				end
			end
		end
	end

	if next(by_ts_row) == nil then
		return source, nil
	end

	-- Split keeping no trailing phantom line; rejoin with \n.
	local lines = vim.split(source, "\n", { plain = true })
	-- vim.split drops nothing; a trailing \n yields a final "" element which
	-- round-trips correctly on rejoin.
	for ts_row, reps in pairs(by_ts_row) do
		table.sort(reps, function(a, b)
			return a.start_col > b.start_col
		end)
		local idx = ts_row + 1 -- 0-based TS row -> 1-based lua index
		local line = lines[idx]
		if line ~= nil then
			for _, rep in ipairs(reps) do
				-- TS columns are 0-based byte offsets; Lua string ops are 1-based bytes.
				line = line:sub(1, rep.start_col) .. rep.text .. line:sub(rep.end_col + 1)
			end
			lines[idx] = line
		end
	end
	return table.concat(lines, "\n"), nil
end

--- Shared lexical primitives for the comment/string-aware scans below
--- (`instrument_lexer` and `code_uses_package`). One definition of the span
--- rules so a fix in one scan cannot diverge from the other.
---@param b integer?
---@return boolean
local function is_ident_byte(b)
	return b ~= nil
		and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

---@param b integer?
---@return boolean
local function is_gap_byte(b)
	return b == 32 or b == 9
end

--- First byte after the non-code span starting at byte i, or nil when i is
--- ordinary code. Skips `//` line comments, `/* */` block comments,
--- interpreted strings/runes (backslash escapes) and raw strings.
---@param source string
---@param n integer #source
---@param i integer 1-based byte position
---@return integer?
local function span_end(source, n, i)
	local b = source:byte(i)
	if b == 47 then -- '/'
		local c = source:byte(i + 1)
		if c == 47 then
			return source:find("\n", i, true) or (n + 1)
		elseif c == 42 then -- '*'
			local e = source:find("*/", i + 2, true)
			return ((e and (e + 1)) or n) + 1
		end
		return nil
	elseif b == 34 or b == 39 then -- string / rune literal
		local j = i + 1
		while j <= n do
			local q = source:byte(j)
			if q == 92 then -- backslash escapes the next byte
				j = j + 2
			elseif q == b then
				return j + 1
			else
				j = j + 1
			end
		end
		return n + 1 -- unterminated: consume rest
	elseif b == 96 then -- raw string: no escapes
		local e = source:find("`", i + 1, true)
		return (e and (e + 1)) or (n + 1)
	end
	return nil
end

--- Pure-Lua fallback scanner: comment- and string-aware rewrite of the same
--- `fmt|log.Print*` call selectors. Used only when the Go Tree-sitter parser
--- is unavailable (Neovim ships no `go` parser on any version; it comes from
--- the user's own nvim-treesitter setup). It skips line/block comments,
--- interpreted strings, runes (with escapes) and raw strings, matches only
--- real `pkg.Method(` calls on single lines, and produces byte-identical
--- rewrites to the Tree-sitter path (verified by test). Never line-regexes.
---@param source string
---@return string
local function instrument_lexer(source)
	local n = #source
	local out = {}
	local i = 1
	local is_ident = is_ident_byte
	local is_gap = is_gap_byte
	-- Try to match `fmt|log . Method (` at byte pos (normal state only).
	-- Returns the REWRITES key and the selector end byte, or nil.
	local function try_selector(pos)
		local pkg = nil
		if source:sub(pos, pos + 2) == "fmt" then
			pkg = "fmt"
		elseif source:sub(pos, pos + 2) == "log" then
			pkg = "log"
		else
			return nil
		end
		if pos > 1 and is_ident(source:byte(pos - 1)) then
			return nil
		end
		local j = pos + 3
		while j <= n and is_gap(source:byte(j)) do
			j = j + 1
		end
		if source:byte(j) ~= 46 then -- '.'
			return nil
		end
		j = j + 1
		while j <= n and is_gap(source:byte(j)) do
			j = j + 1
		end
		for _, m in ipairs({ "Println", "Printf", "Print" }) do -- longest first
			if source:sub(j, j + #m - 1) == m then
				local k = j + #m
				if k <= n and is_ident(source:byte(k)) then
					return nil -- e.g. Printlnx: not one of ours
				end
				local l = k
				while l <= n and is_gap(source:byte(l)) do
					l = l + 1
				end
				if source:byte(l) == 40 then -- '('
					return pkg .. "." .. m, j + #m - 1
				end
				return nil
			end
		end
		return nil
	end
	while i <= n do
		local b = source:byte(i)
		local after = span_end(source, n, i)
		if after ~= nil then
			table.insert(out, source:sub(i, after - 1))
			i = after
		elseif (b == 102 or b == 108) and (i == 1 or not is_ident(source:byte(i - 1))) then -- 'f'/'l'
			local key, sel_end = try_selector(i)
			if key then
				table.insert(out, REWRITES[key])
				i = sel_end + 1
			else
				table.insert(out, source:sub(i, i))
				i = i + 1
			end
		else
			table.insert(out, source:sub(i, i))
			i = i + 1
		end
	end
	return table.concat(out)
end

M._instrument_lexer = instrument_lexer
M._instrument_ts = instrument_ts

--- Whether real code (outside comments/strings/runes/raw strings) references
--- `pkg.` as a selector (`fmt.Sprintf`, `log.New`, ...). A plain substring
--- search is wrong here: `"catalog."` contains `"log."` and a comment
--- mentioning `fmt.Println` is not a use. Either mistake adds (or withholds)
--- an import the fragment needs to compile, or defeats the keep-import check
--- below by seeing `fmt.` where only a comment does.
---@param source string
---@param pkg string "fmt" or "log"
---@return boolean
local function code_uses_package(source, pkg)
	local n = #source
	local plen = #pkg
	local is_ident = is_ident_byte
	local is_gap = is_gap_byte
	local i = 1
	while i <= n do
		local after = span_end(source, n, i)
		if after ~= nil then
			i = after
		elseif source:sub(i, i + plen - 1) == pkg then
			local prev = i > 1 and source:byte(i - 1) or nil
			if prev ~= nil and (is_ident(prev) or prev == 46) then
				i = i + 1 -- `xfmt.` / `x.fmt.`: not a package reference
			else
				local j = i + plen
				while j <= n and is_gap(source:byte(j)) do
					j = j + 1
				end
				if source:byte(j) == 46 then -- '.'
					return true
				end
				i = j
			end
		else
			i = i + 1
		end
	end
	return false
end

M._code_uses_package = code_uses_package

--- Instrument with Tree-sitter when available, else the embedded scanner.
---@param source string
---@return string instrumented source
local function instrument(source)
	local out = instrument_ts(source)
	if out ~= nil then
		return out
	end
	return instrument_lexer(source)
end

M._instrument = instrument

--- Whether the source already declares a package (full file vs fragment).
---@param source string
---@return boolean
local function has_package(source)
	return source:match("^%s*package%s+") ~= nil
end

--- Wrap a bare fragment in package main + func main. Returns wrapped source
--- and the header line count (user code starts at header + 1).
---@param source string
---@return string, integer
local function wrap_fragment(source)
	-- Code-aware package detection (see code_uses_package): a plain
	-- `"fmt."` substring search would fire on `"catalog."` or on comments,
	-- adding an unused import that fails the fragment build.
	local needs_fmt = code_uses_package(source, "fmt")
	local needs_log = code_uses_package(source, "log")
	local header = { "package main", "" }
	if needs_fmt then
		table.insert(header, 'import "fmt"')
	end
	if needs_log then
		table.insert(header, 'import "log"')
	end
	if needs_fmt or needs_log then
		table.insert(header, "")
	end
	table.insert(header, "func main() {")
	local wrapped = table.concat(header, "\n") .. "\n" .. source
	if not wrapped:match("\n$") then
		wrapped = wrapped .. "\n"
	end
	wrapped = wrapped .. "}\n"
	return wrapped, #header
end

--- Go helper: framed emit + print/log interceptors using runtime.Caller(1)
--- called directly at the instrumented site (no intermediate frames).
---@param nonce string
---@return string
local function helper_source(nonce)
	local template = [=[
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
)

const __itchyNonce = "__ITCHY_NONCE__"

type __itchyEvent struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Line    *int   `json:"line,omitempty"`
}

func __itchyEmit(kind, message string, line *int) {
	evt := __itchyEvent{Kind: kind, Message: message, Line: line}
	data, err := json.Marshal(evt)
	if err != nil {
		return
	}
	fmt.Fprintf(os.Stdout, "\x1eITCHY:%s:%s\n", __itchyNonce, string(data))
}

func __itchyFmtPrint(a ...any) (int, error) {
	msg := fmt.Sprint(a...)
	n := len(msg)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
	return n, nil
}

func __itchyFmtPrintf(format string, a ...any) (int, error) {
	msg := fmt.Sprintf(format, a...)
	n := len(msg)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
	return n, nil
}

func __itchyFmtPrintln(a ...any) (int, error) {
	msg := fmt.Sprintln(a...)
	n := len(msg)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
	return n, nil
}

func __itchyLogPrint(a ...any) {
	msg := fmt.Sprint(a...)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
}

func __itchyLogPrintf(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
}

func __itchyLogPrintln(a ...any) {
	msg := fmt.Sprintln(a...)
	__itchyEmit("stdout", strings.TrimSuffix(msg, "\n"), __itchyLineOffset(1))
}

func __itchyLineOffset(skip int) *int {
	// skip + 1: this helper frame; callers pass 1 for their own caller.
	_, _, line, ok := runtime.Caller(skip + 1)
	if !ok {
		return nil
	}
	return &line
}
]=]
	return (template:gsub("__ITCHY_NONCE__", function()
		return nonce
	end))
end

--- Normalize a path for user-file comparison (slashes + case on Windows).
--- Parse native Go compiler diagnostics: `path.go:LINE:COL: message`.
--- Returns events for frames belonging to the user file.
---@param stderr_text string
---@param user_file string
---@param header_offset integer
---@return itchy.Event[]
local function parse_compiler_errors(stderr_text, user_file, header_offset)
	local events = {}
	framed.each_line(stderr_text, function(line)
		local path, lnum, col, msg = line:match("^(.-%.go):(%d+):(%d+):?%s*(.*)$")
		if path ~= nil and utils.is_user_file(path, user_file, "itchy_helper.go") then
			local src_line = tonumber(lnum) - (header_offset or 0)
			local src_col = tonumber(col)
			msg = msg ~= "" and msg or line
			if src_line ~= nil and src_line >= 1 then
				table.insert(events, event.create("error", framed.sanitize_message(msg), src_line, src_col))
			else
				table.insert(events, event.create("error", framed.sanitize_message(msg), nil))
			end
		end
	end)
	return events
end

--- Parse a native panic: `panic: ...` message plus the first stack frame
--- belonging to the user file (`\tpath.go:LINE ...`).
---@param stderr_text string
---@param user_file string
---@param header_offset integer
---@return itchy.Event[]
local function parse_panic(stderr_text, user_file, header_offset)
	local panic_msg = nil
	framed.each_line(stderr_text, function(line)
		if panic_msg == nil then
			local m = line:match("^panic:%s*(.+)%s*$")
			if m then
				panic_msg = m
			elseif line:match("^panic:") then
				panic_msg = line
			end
		end
	end)
	if panic_msg == nil then
		return {}
	end
	local frame_line = nil
	framed.each_line(stderr_text, function(line)
		if frame_line ~= nil then
			return
		end
		local path, lnum = line:match("^%s*(.-%.go):(%d+)")
		if path ~= nil and utils.is_user_file(path, user_file, "itchy_helper.go") then
			frame_line = tonumber(lnum) - (header_offset or 0)
		end
	end)
	if frame_line ~= nil and frame_line >= 1 then
		return { event.create("error", framed.sanitize_message("panic: " .. panic_msg), frame_line) }
	end
	return { event.create("error", framed.sanitize_message("panic: " .. panic_msg), nil) }
end

--- Prepare execution: instrumented user file + separate helper file.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "go adapter requires a context")
	assert(ctx.runtime ~= nil, "go adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local nonce = framed.create_nonce()

	local full = has_package(source)
	local base = source
	local header_offset = 0
	if not full then
		base, header_offset = wrap_fragment(source)
	end

	-- Tree-sitter when available, else the embedded comment/string-aware
	-- scanner. Either way every output call is instrumented.
	local instrumented = instrument(base)

	-- Keep explicit imports used: replacing every fmt/log call can leave the
	-- import unused (a per-file compile error). Appending a package-level
	-- blank reference after the user code preserves all existing line numbers.
	-- Code-aware like wrap_fragment: a `fmt.` inside a comment or string
	-- must not count as a use, or the keep would be skipped and the build
	-- would fail on an unused import.
	for _, keep in ipairs({ { '"fmt"', "fmt", "fmt.Sprint" }, { '"log"', "log", "log.Print" } }) do
		if base:find(keep[1], 1, true) ~= nil and not code_uses_package(instrumented, keep[2]) then
			instrumented = instrumented .. "\nvar _ = " .. keep[3] .. " // itchy: keep import used\n"
		end
	end

	local tmpdir = utils.make_adapter_tmpdir(utils.project_dir(ctx), "itchy-go", nonce)

	local user_path = tmpdir .. "/itchy-user-" .. nonce .. ".go"
	local helper_path = tmpdir .. "/itchy_helper.go"
	local uf, uerr = io.open(user_path, "w")
	if not uf then
		error("go adapter: failed to create source file: " .. tostring(uerr))
	end
	uf:write(instrumented)
	uf:close()
	local hf, herr = io.open(helper_path, "w")
	if not hf then
		utils.remove_temp_file(user_path)
		error("go adapter: failed to create helper file: " .. tostring(herr))
	end
	hf:write(helper_source(nonce))
	hf:close()

	local cmd = { runtime.cmd }
	for _, arg in ipairs(runtime.args or {}) do
		table.insert(cmd, arg)
	end
	table.insert(cmd, user_path)
	table.insert(cmd, helper_path)

	local function cleanup()
		utils.remove_temp_file(user_path)
		utils.remove_temp_file(helper_path)
		pcall(vim.fn.delete, tmpdir, "d")
	end

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = cleanup,
		metadata = {
			nonce = nonce,
			user_file = user_path,
			helper_file = helper_path,
			header_offset = header_offset,
			filetype = ctx.filetype,
		},
	}
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	local metadata = (prepared and prepared.metadata) or {}
	local nonce = metadata.nonce
	local user_file = metadata.user_file or ""
	local header_offset = metadata.header_offset or 0
	---@type itchy.Event[]
	local events = {}

	framed.each_line(result.stdout, function(line)
		local record = framed.decode_line(line, nonce)
		if record then
			local loc = record.line ~= nil and (record.line - header_offset) or nil
			if loc ~= nil and loc < 1 then
				loc = nil
			end
			table.insert(events, event.create(record.kind, record.message, loc, record.column))
			return
		end
		if line ~= "" and line ~= nil then
			-- Uninstrumented stdout (os.Stdout writes, external commands) stays
			-- visible as locationless output; never attribute a fake line.
			-- Skip `go run` build headers; real diagnostics live on stderr.
			if not line:match("^#%s") then
				table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
			end
		end
	end)

	local stderr_text = type(result.stderr) == "string" and result.stderr or ""
	local compiler_events = parse_compiler_errors(stderr_text, user_file, header_offset)
	for _, e in ipairs(compiler_events) do
		table.insert(events, e)
	end
	if #compiler_events == 0 then
		for _, e in ipairs(parse_panic(stderr_text, user_file, header_offset)) do
			table.insert(events, e)
		end
	end
	-- Native `go run` failure footers without locations (e.g. `exit status 2`
	-- after a parsed panic) carry no new information; drop them. Anything
	-- else meaningful on stderr that we cannot locate becomes a locationless
	-- error rather than a guess.
	if #compiler_events == 0 then
		local saw_panic = stderr_text:match("panic:") ~= nil
		if not saw_panic then
			local meaningful = {}
			framed.each_line(stderr_text, function(line)
				local t = line:match("^%s*(.-)%s*$")
				if t == "" or t:match("^#%s") or t:match("^exit%s+status") then
					return
				end
				-- Already-consumed diagnostic frames; the message lives in events.
				if t:match("%.go:%d+") or t:match("^goroutine%s+%d+") or t:match("^main%.") then
					return
				end
				table.insert(meaningful, t)
			end)
			if #meaningful > 0 and #events == 0 then
				-- Only surface locationless stderr when nothing else explains the
				-- failure; framed output already visible must not gain noise.
				local joined = table.concat(meaningful, " ")
				if joined ~= "" then
					table.insert(events, event.create("error", framed.sanitize_message(joined), nil))
				end
			end
		end
	end

	return events
end

return M
