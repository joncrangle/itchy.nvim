--- Go adapter with syntax-aware targeted instrumentation (issue #13).
---
--- Output calls (`fmt.Print/Printf/Println`, `log.Print/Printf/Println`) are
--- identified with the Go Tree-sitter parser, so comments, strings and
--- similarly named methods never match. Only the callee selector is
--- rewritten (`fmt.Println` -> `__itchyFmtPrintln`); argument lists keep
--- their exact line breaks, so multiline calls work and native source lines
--- never shift. Locations come from `runtime.Caller(1)` inside the helper,
--- called directly by the instrumented call site (depth verified by the
--- exact-line e2e tests). Both `fmt.*` and `log.*` output report as
--- `stdout` events (log content is program output, not an error diagnostic);
--- compiler diagnostics and panic stacks keep their
--- native `path:line:col` coordinates; no generated-source offsets.
---
--- The user's (instrumented) source and the helper live in separate files in
--- one temp dir, executed as `go run user.go helper.go`. Bare fragments
--- without a `package` clause are wrapped in `package main`/`func main()`;
--- that explicit header offset is the only source mapping, stored in
--- metadata and applied on decode. Full files map 1:1.
---
--- If the Go Tree-sitter parser is unavailable, prepare/decode fall back
--- silently to the legacy compatibility adapter (CMD keeps working there).
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local legacy = require("itchy.adapters.legacy")
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
---@param source string
---@return string?, string? instrumented source or nil + error
local function instrument(source)
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
	local needs_fmt = source:find("fmt%.", 1, true) ~= nil
	local needs_log = source:find("log%.", 1, true) ~= nil
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

--- Go helper: framed emit + print/log wrappers using runtime.Caller(1)
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
	if not M._has_treesitter() then
		return legacy.prepare(ctx)
	end
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local nonce = framed.create_nonce()

	local full = has_package(source)
	local base = source
	local header_offset = 0
	if not full then
		base, header_offset = wrap_fragment(source)
	end

	local instrumented, ierr = instrument(base)
	if instrumented == nil then
		return legacy.prepare(ctx)
	end

	-- Keep explicit imports used: replacing every fmt/log call can leave the
	-- import unused (a per-file compile error). Appending a package-level
	-- blank reference after the user code preserves all existing line numbers.
	for _, keep in ipairs({ { '"fmt"', "fmt%.", "fmt.Sprint" }, { '"log"', "log%.", "log.Print" } }) do
		if base:find(keep[1], 1, true) ~= nil and instrumented:find(keep[2], 1, true) == nil then
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
	if metadata.nonce == nil then
		return legacy.decode(ctx, prepared, result)
	end
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
		if legacy.should_filter_line(line) then
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
				if t == "" or t:match("^#%s") or t:match("^exit%s+status") or legacy.should_filter_line(t) then
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
