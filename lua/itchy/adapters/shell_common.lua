--- Shared helpers for shell adapters (bash, zsh, sh). Handles launcher
--- templating, sidecar event file decoding, and native shell error parsing.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local utils = require("itchy.utils")

-- A framed builtin writes the same bytes to stdout that the user would have
-- seen without itchy. The side-channel record alone cannot distinguish those
-- bytes from identical output produced by an external command. Shell
-- launchers therefore bracket intercepted output with nonce-authenticated
-- markers. A frame stays open across adjacent non-newline writes, so framing
-- never changes the byte sequence seen by a downstream command or by the
-- executor. The decoder removes the bracketed copy, leaving every unmarked
-- byte untouched. These markers are a shell transport detail, separate from
-- the JSON record protocol.
-- Use control-only sentinels for the transport framing. Text transforms such
-- as `tr a-z A-Z` must not be able to rewrite the marker itself; the nonce
-- remains the authentication component and is normalized to uppercase by the
-- shell preparation path.
local OUTPUT_START = "\30\31"
local OUTPUT_END = "\30\29"

--- Normalize shell-specific diagnostic envelopes while keeping the native
--- source coordinate and diagnostic text intact.
---@param ctx itchy.AdapterContext
---@param message string
---@return string
local function normalize_native_message(ctx, message)
	if ctx and ctx.filetype == "sh" then
		local command = message:match("^(.-): not found$")
		if command ~= nil then
			message = command .. ": command not found"
		end
		local _, expression = message:match('^(arithmetic expression: division by zero: ")%s*(.-)%s*"$')
		if expression ~= nil then
			message = 'arithmetic expression: division by zero: "' .. expression .. '"'
		end
	end
	-- Bash versions that include an arithmetic expansion token append this
	-- explanatory suffix. It is part of the shell's diagnostic envelope,
	-- not the error text, and is absent from the stable fixture wording.
	if ctx and (ctx.filetype == "bash" or ctx.filetype == "sh") then
		message = message:gsub('%s+%(error token is ".-"%)$', "")
	end
	return message
end

---@param nonce string
---@param sequence integer
---@return string
function M.output_start(nonce, sequence)
	return OUTPUT_START .. nonce .. ":" .. tostring(sequence) .. ":"
end

---@param nonce string
---@param sequence integer
---@return string
function M.output_end(nonce, sequence)
	return OUTPUT_END .. nonce .. ":" .. tostring(sequence) .. "\n"
end

--- Remove launcher output spans without interpreting their contents.
---
--- The markers are parsed as a set rather than as one outer span. A background
--- or nested shell can interleave two intercepted writes, so looking only for
--- the first matching end marker would leave the second marker (and possibly
--- its payload) in residual output.
---@param text string?
---@param marker_nonce string
---@return string
function M.strip_marked_output(text, marker_nonce)
	if type(text) ~= "string" or text == "" or marker_nonce == "" then
		return type(text) == "string" and text or ""
	end
	local start_prefix = OUTPUT_START .. marker_nonce .. ":"
	local end_prefix = OUTPUT_END .. marker_nonce .. ":"
	local cursor = 1
	local pieces = {}
	local active = {}
	local first_active = nil

	local function append_visible(value)
		if value ~= "" then
			table.insert(pieces, value)
		end
	end

	local function find_marker(from)
		local start_at = text:find(start_prefix, from, true)
		local end_at = text:find(end_prefix, from, true)
		if start_at == nil then
			return end_at, "end"
		end
		if end_at == nil or start_at < end_at then
			return start_at, "start"
		end
		return end_at, "end"
	end

	while cursor <= #text do
		local marker_start, marker_kind = find_marker(cursor)
		if marker_start == nil then
			if first_active ~= nil then
				-- An incomplete marker cannot be proven to be launcher output.
				-- Restore it verbatim rather than discarding user output.
				append_visible(text:sub(first_active))
			else
				append_visible(text:sub(cursor))
			end
			break
		end

		if next(active) == nil then
			append_visible(text:sub(cursor, marker_start - 1))
		end

		local marker_end
		local sequence
		if marker_kind == "start" then
			local sequence_start = marker_start + #start_prefix
			local sequence_end = text:find(":", sequence_start, true)
			sequence = sequence_end and text:sub(sequence_start, sequence_end - 1) or ""
			marker_end = sequence_end
		else
			local sequence_start = marker_start + #end_prefix
			local sequence_end = text:find("\n", sequence_start, true)
			sequence = sequence_end and text:sub(sequence_start, sequence_end - 1) or ""
			marker_end = sequence_end
		end

		if marker_end == nil or sequence == "" or not sequence:match("^%d+$") then
			-- A malformed marker is ordinary output. Advance one byte so a
			-- later valid marker can still be recognized.
			if next(active) ~= nil then
				-- Keep malformed bytes inside an incomplete launcher span out of
				-- the normal result; the active span will be restored if needed.
				cursor = marker_start + 1
			else
				append_visible(text:sub(marker_start, marker_start))
				cursor = marker_start + 1
			end
		else
			if marker_kind == "start" then
				if next(active) == nil then
					first_active = marker_start
				end
				active[sequence] = true
			elseif active[sequence] then
				active[sequence] = nil
				if next(active) == nil then
					first_active = nil
				end
			else
				-- An unmatched end marker is ordinary user output.
				if next(active) == nil then
					append_visible(text:sub(marker_start, marker_end))
				end
			end
			cursor = marker_end + 1
		end
	end
	return table.concat(pieces)
end

--- Escape a filesystem path for embedding in a double-quoted shell string.
---@param path string
---@return string
function M.shell_dquote(path)
	return (path:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`"))
end

--- Create a normalized temp file path with forward slashes for cross-platform shell compatibility.
---@param suffix? string
---@return string
function M.temp_path(suffix)
	return (vim.fn.tempname() .. (suffix or "")):gsub("\\", "/")
end

--- Render a shell launcher template by replacing standard placeholders.
---@param template string
---@param nonce string
---@param event_file string
---@param user_file? string
---@return string
function M.render_template(template, nonce, event_file, user_file)
	local src = template:gsub("__ITCHY_NONCE__", function()
		return nonce
	end)
	src = src:gsub("__ITCHY_EVENT_FILE__", function()
		return M.shell_dquote(event_file)
	end)
	if user_file then
		src = src:gsub("__ITCHY_USER_FILE__", function()
			return M.shell_dquote(user_file)
		end)
	end
	return src
end

--- Write content to a path. Returns true or nil + error.
---@param path string
---@param content string
---@return boolean?, string?
function M.write_file(path, content)
	local file, open_err = io.open(path, "w")
	if not file then
		return nil, open_err or ("failed to create file: " .. path)
	end
	local write_ok, write_result = pcall(file.write, file, content)
	if not write_ok or write_result == nil then
		pcall(file.close, file)
		return nil, write_result or ("failed to write file: " .. path)
	end
	local close_ok, close_err = file:close()
	if not close_ok then
		return nil, close_err or ("failed to close file: " .. path)
	end
	return true, nil
end

--- Read framed records from an adapter-private event file, in order.
--- Malformed or foreign-nonce lines are ignored, never fatal.
---@param event_file string?
---@param nonce string?
---@return itchy.FramedRecord[]
function M.read_records(event_file, nonce)
	---@type itchy.FramedRecord[]
	local records = {}
	if type(event_file) ~= "string" or event_file == "" then
		return records
	end
	local file = io.open(event_file, "r")
	if not file then
		return records
	end
	local content = file:read("*a")
	file:close()
	if type(content) ~= "string" or content == "" then
		return records
	end
	framed.each_line(content, function(line)
		local record = framed.decode_line(line, nonce or "")
		if record then
			table.insert(records, record)
		end
	end)
	return records
end

--- Parse one native shell stderr line against the user file.
--- Understands bash (`path: line N: msg`, also when `sh` is bash) and
--- zsh/dash (`path: N: msg`) diagnostics. Frames belonging to the adapter's
--- user file count. Arithmetic diagnostics emitted under a user-defined shell
--- function name are also accepted; their origin is returned for a shell
--- adapter to map.
--- Bash source excerpts (backtick-quoted follow-ups to syntax errors) are
--- skipped by the caller via `is_excerpt`.
---@param line string
---@param user_file string
---@param helper_leaf string fixed launcher filename to exclude
---@param source? string user source, used for shell function diagnostics
---@return integer? line 1-based source line
---@return string? message
---@return table? origin diagnostic origin metadata
function M.parse_native_error_line(line, user_file, helper_leaf, source)
	if type(line) ~= "string" or line == "" then
		return nil, nil, nil
	end

	local function is_arithmetic_diagnostic(message)
		return message:match("division by 0") ~= nil or message:match("division by zero") ~= nil
	end

	local function pattern_escape(value)
		return (value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
	end

	local function source_function_start(name, source)
		if type(name) ~= "string" or name == "" or type(source) ~= "string" then
			return nil
		end
		local escaped = pattern_escape(name)
		local line_number = 0
		for source_line in (source .. "\n"):gmatch("([^\n]*)\n") do
			line_number = line_number + 1
			if source_line:match("^%s*function%s+" .. escaped .. "%s*[%({]")
				or source_line:match("^%s*" .. escaped .. "%s*%(%s*%)")
			then
				return line_number
			end
		end
		return nil
	end

	local function parse_candidate(candidate, source, depth)
		if depth > 4 then
			return nil, nil, nil
		end
		-- Bash: "/tmp/x.sh: line 2: msg". A shell function can replace
		-- the file name in this diagnostic (for example, "divide: line 1:
		-- division by 0"), so retain that origin for the adapter that knows
		-- how to map function-relative coordinates.
		local path, lnum, msg = candidate:match("^(.-):%s+line%s+(%d+):%s*(.*)$")
		if path ~= nil then
			local n = tonumber(lnum)
			if n ~= nil and n >= 1 then
				if utils.is_user_file(path, user_file, helper_leaf) then
					return n, (msg ~= "" and msg or candidate), nil
				end
				local function_name = path:match("([^/:]+)$")
				local function_start = source_function_start(function_name, source)
				if is_arithmetic_diagnostic(msg) and function_start ~= nil then
					return n, msg, { kind = "function", name = function_name, start_line = function_start }
				end
				-- Some shells prefix a user diagnostic with the launcher
				-- location. Parse the nested user/function diagnostic rather
				-- than treating the whole line as locationless stderr.
				if msg ~= candidate then
					local nested_line, nested_message, nested_origin = parse_candidate(msg, source, depth + 1)
					if nested_line ~= nil then
						return nested_line, nested_message, nested_origin
					end
				end
			end
		end

		-- Zsh and dash: "/tmp/x.sh:2: msg" (dash pads extra spaces).
		path, lnum, msg = candidate:match("^(.-):%s*(%d+):%s*(.*)$")
		if path ~= nil then
			local n = tonumber(lnum)
			if n ~= nil and n >= 1 then
				if utils.is_user_file(path, user_file, helper_leaf) then
					return n, (msg ~= "" and msg or candidate), nil
				end
				local function_name = path:match("([^/:]+)$")
				local function_start = source_function_start(function_name, source)
				if is_arithmetic_diagnostic(msg) and function_start ~= nil then
					return n, msg, { kind = "function", name = function_name, start_line = function_start }
				end
				if msg ~= candidate then
					local nested_line, nested_message, nested_origin = parse_candidate(msg, source, depth + 1)
					if nested_line ~= nil then
						return nested_line, nested_message, nested_origin
					end
				end
			end
		end
		return nil, nil, nil
	end

	return parse_candidate(line, source, 0)
end

--- Allocate per-run temp paths (user source, launcher, event file) inside
--- a run-unique directory. The caller writes the files; `cleanup` removes
--- all of them exactly once.
---@param ctx itchy.AdapterContext
---@param prefix string e.g. "itchy-bash"
---@param nonce string
---@param suffix string user-file suffix, e.g. ".sh"
---@return string tmpdir, string user_path, string launcher_path, string event_path
function M.allocate_tmp(ctx, prefix, nonce, suffix)
	local tmpdir = utils.make_adapter_tmpdir(utils.project_dir(ctx), prefix, nonce):gsub("\\", "/")
	local user_path = tmpdir .. "/itchy-user-" .. nonce .. suffix
	local launcher_path = tmpdir .. "/itchy-launcher-" .. nonce .. ".sh"
	local event_path = tmpdir .. "/itchy-events-" .. nonce .. ".jsonl"
	return tmpdir, user_path, launcher_path, event_path
end

--- Build an exactly-once cleanup hook for adapter temp files.
---@param tmpdir string
---@param paths string[]
---@return fun()
function M.make_cleanup(tmpdir, paths)
	return function()
		for _, path in ipairs(paths) do
			utils.remove_temp_file(path)
		end
		-- Background shell calls reserve marker directories. The run directory
		-- is private and nonce-named, so recursive removal is safe and also
		-- cleans up a process killed between marker allocation and its end.
		pcall(vim.fn.delete, tmpdir, "rf")
	end
end

--- Build an argv list preserving user runtime.args, filtering out any inline `-c`.
---@param runtime itchy.Runtime
---@param script_path string
---@return string[]
function M.build_cmd(runtime, script_path)
	local cmd = { runtime.cmd }
	for _, arg in ipairs(runtime.args or {}) do
		if arg ~= "-c" then
			table.insert(cmd, arg)
		end
	end
	table.insert(cmd, script_path)
	return cmd
end

--- Prepare a launcher-backed shell execution (used by bash and zsh).
---@param ctx itchy.AdapterContext
---@param prefix string "itchy-bash" or "itchy-zsh"
---@param render_launcher fun(nonce: string, event_path: string, user_path: string): string
---@param helper_leaf string
---@return itchy.PreparedExecution
function M.prepare_launcher(ctx, prefix, render_launcher, helper_leaf)
	local name = ctx.filetype or prefix
	assert(ctx ~= nil, name .. " adapter requires a context")
	assert(ctx.runtime ~= nil, name .. " adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	-- Shell transformation filters commonly preserve uppercase letters while
	-- changing lowercase payloads (for example `tr a-z A-Z`). Keep the
	-- transport nonce in that stable alphabet so those pipelines cannot turn a
	-- valid marker into residual user-visible text.
	local nonce = framed.create_nonce():upper()

	local tmpdir, user_path, launcher_path, event_path = M.allocate_tmp(ctx, prefix, nonce, ".sh")

	local ok, werr = M.write_file(user_path, source)
	if not ok then
		error(name .. " adapter: failed to create source file: " .. tostring(werr))
	end
	local lok, lerr = M.write_file(launcher_path, render_launcher(nonce, event_path, user_path))
	if not lok then
		M.make_cleanup(tmpdir, { user_path })()
		error(name .. " adapter: failed to create launcher file: " .. tostring(lerr))
	end
	local eok, eerr = M.write_file(event_path, "")
	if not eok then
		M.make_cleanup(tmpdir, { user_path, launcher_path, event_path })()
		error(name .. " adapter: failed to create event file: " .. tostring(eerr))
	end

	local cmd = M.build_cmd(runtime, launcher_path)

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = M.make_cleanup(tmpdir, { user_path, launcher_path, event_path }),
		metadata = {
			nonce = nonce,
			user_file = user_path,
			event_file = event_path,
			helper_leaf = helper_leaf,
			filetype = ctx.filetype,
		},
	}
end

--- Decode an executor result using side-channel records plus native
--- stderr diagnostics.
---
--- Helpers delegate to the real builtins so redirections and pipelines behave
--- natively. All intercepted output (`echo`/`printf`) is recorded via structured
--- events in the adapter-private event file. The launcher brackets the raw
--- builtin copy with a nonce-authenticated transport marker; the decoder
--- removes only bracketed copies, while any residual stdout (including output
--- from external commands) becomes a locationless stdout event. This avoids
--- content-based correlation, which cannot distinguish external output that
--- happens to have the same bytes as a framed event. Delegated stderr copies
--- are removed by the same marker protocol, while native diagnostics and
--- non-diagnostic stderr become error events.
--- Native diagnostic coordinates remain unchanged unless the adapter supplies
--- the optional mapping callback.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@param map_native_line? fun(line: integer, origin?: table): integer? optional adapter-specific mapping for native diagnostics
---@return itchy.Event[]
function M.decode_sidechannel(ctx, prepared, result, map_native_line)
	local metadata = (prepared and prepared.metadata) or {}
	local nonce = metadata.nonce or ""
	local user_file = metadata.user_file or ""
	local event_file = metadata.event_file or ""
	local helper_leaf = metadata.helper_leaf or "itchy-launcher"
	---@type itchy.Event[]
	local events = {}

	local records = M.read_records(event_file, nonce)

	local function append_residual_stdout(events, text)
		framed.each_line(text, function(line)
			if line ~= "" then
				table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
			end
		end)
	end

	for _, record in ipairs(records) do
		table.insert(events, event.create(record.kind, record.message, record.line, record.column))
	end

	local stdout = M.strip_marked_output(result.stdout, nonce)
	append_residual_stdout(events, stdout)

	local stderr = M.strip_marked_output(result.stderr, nonce)
	framed.each_line(stderr, function(line)
		if line == "" then
			return
		end
		local clean = utils.clean_error_message(line)
		if clean:match("^`") then
			-- Shell source excerpt (bash reprints the offending source
			-- backtick-quoted after a syntax error): the diagnostic above
			-- already explains it.
			return
		end
		local eline, message, origin = M.parse_native_error_line(clean, user_file, helper_leaf, ctx and ctx.source)
		if message ~= nil and eline ~= nil then
			message = normalize_native_message(ctx, message)
			local src_line = eline
			if map_native_line ~= nil then
				src_line = map_native_line(eline, origin)
			end
			table.insert(events, event.create("error", framed.sanitize_message(message), src_line))
			return
		end
		-- Non-diagnostic stderr (external commands): visible as a
		-- locationless error rather than dropped or mislocated.
		table.insert(events, event.create("error", framed.sanitize_message(clean), nil))
	end)

	return events
end

return M
