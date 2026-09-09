--- Legacy wrapper-backed runtime adapter (transitional).
--- Preserves the current wrapper architecture during the migration to
--- runtime adapters + structured events. All supported runtimes use this
--- adapter until they migrate one at a time (issues #12, #13).
---
--- Wire protocol understood here (and only here):
---   stdout: "LINE<n>: <message>"
---   stderr: "LINE<n>: Error: <message>" plus runtime-specific diagnostics
--- Normalizes both into itchy.Event objects with 1-based source lines.
local M = {}

local event = require("itchy.event")

--- Strip ANSI escape codes.
---@param err string
---@return string
local function clean_error_message(err)
	return (err:gsub("\27%[[%d;]*m", ""))
end

M.clean_error_message = clean_error_message

--- Whether a line is plugin noise and must be dropped.
---@param line string
---@return boolean
function M.should_filter_line(line)
	local noise_patterns = {
		"hint: Replace 'window' with 'globalThis'",
		"window is not defined",
		"^$", -- Empty lines
	}
	for _, pattern in ipairs(noise_patterns) do
		if line:match(pattern) then
			return true
		end
	end
	return false
end

--- Parse legacy "LINE<n>: <message>" stdout records.
---@param line string
---@return integer|nil, string|nil raw 0-based number + message (see to_source_line)
function M.parse_line_output(line)
	line = line:gsub("\r", "")
	local line_num_str, msg = line:match("^LINE(%d+):%s*(.+)")
	if line_num_str and msg then
		return tonumber(line_num_str), msg
	end
	return nil, nil
end

--- Convert a raw legacy LINE number to a 1-based source line.
--- The legacy wire protocol ("LINE<n>: ...") is 0-based for all current
--- wrappers (verified empirically for JS, Python, Go, shell, PowerShell:
--- first buffer line emits LINE0).
---@param raw integer
---@return integer 1-based source line
function M.to_source_line(raw)
	return raw + 1
end

--- Parse legacy stderr diagnostics. Returns a 1-based source line, a
--- message, or (nil, message) for locationless diagnostics that the
--- renderer notifies about instead of placing an extmark.
---@param ft string
---@param err string
---@return integer?, string?
function M.parse_error_output(ft, err)
	err = err:gsub("\r", "")
	local line_num_str, msg = err:match("LINE(%d+):%s*Error:%s*(.+)")
	if line_num_str and msg then
		return M.to_source_line(tonumber(line_num_str) or 0), msg
	end

	if ft == "typescript" or ft == "javascript" then
		local stack_line = err:match("at eval[^:]+:(%d+):")
		if stack_line then
			-- Generated-source correction for the legacy JS wrapper, which emits
			-- two lines per user line. Returns a 1-based event line.
			local row = math.floor((tonumber(stack_line) - 10) / 2)
			local error_msg = err:match("Error:%s*(.+)")
			if error_msg then
				return row + 1, error_msg
			end
			return row + 1, err
		end
	elseif ft == "python" then
		local line_num = err:match("LINE(%d+)")
		local error_msg = err:match("Error:%s*(.+)")
		if line_num and error_msg then
			return (tonumber(line_num) or 0) + 1, error_msg
		end
	elseif ft == "bash" or ft == "sh" or ft == "zsh" then
		local line_num, error_msg = err:match("^[^:]+:%s*line%s*(%d+):%s*(.+)")
		if line_num and error_msg then
			-- Native shell diagnostics are already 1-based source lines.
			return tonumber(line_num) or 1, error_msg
		end
		local general_error = err:match("^[^:]+:%s*(.+)")
		if general_error then
			return nil, general_error
		end
	end

	local runtime_err_msg = err:match("error:%s*(.+)")
	if runtime_err_msg then
		return nil, runtime_err_msg
	end
	return nil, nil
end

--- Iterate every non-empty line of captured process output, including a
--- final line without a trailing newline. Normalizes CRLF/CR.
---@param text string?
---@param fn fun(line: string)
function M.each_line(text, fn)
	if type(text) ~= "string" or text == "" then
		return
	end
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	local start = 1
	while true do
		local nl = text:find("\n", start, true)
		if nl then
			local line = text:sub(start, nl - 1)
			if line ~= "" then
				fn(line)
			end
			start = nl + 1
		else
			local rest = text:sub(start)
			if rest ~= "" then
				fn(rest)
			end
			break
		end
	end
end

--- Apply an explicit source map when present (e.g. future selection
--- mappings). Identity when no map is provided.
---@param line? integer 1-based source line
---@param source_map? table<integer, integer>
---@return integer?
local function apply_source_map(line, source_map)
	if line ~= nil and source_map ~= nil and source_map[line] ~= nil then
		return source_map[line]
	end
	return line
end

---@class itchy.AdapterContext
---@field runtime itchy.Runtime
---@field filetype string
---@field source string
---@field buf integer
---@field cwd string
---@field source_map? table<integer, integer> explicit 1-based line remapping

---@class itchy.PreparedExecution
---@field source string wrapped/prepared source handed to the executor
---@field cmd? string[] full argv override; when nil the core builds argv from runtime.cmd/args
---@field env? table<string, string> env override; when nil the core falls back to runtime.env
---@field temp_file? boolean temp-file override; when nil the core falls back to runtime.temp_file
---@field cleanup? fun() optional post-render cleanup hook invoked by the core
---@field metadata? table adapter-specific data (offset, filetype, source_map)

--- Prepare execution through the legacy wrapper.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "legacy adapter requires a context")
	assert(ctx.runtime ~= nil, "legacy adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local wrapped = source
	if runtime.wrapper then
		wrapped = runtime.wrapper(source, runtime.offset or 0)
	end
	return {
		source = wrapped,
		metadata = {
			offset = runtime.offset or 0,
			filetype = ctx.filetype,
			source_map = ctx.source_map,
		},
	}
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	local ft = ctx.filetype
	local source_map = ctx.source_map or (prepared and prepared.metadata and prepared.metadata.source_map)
	---@type itchy.Event[]
	local events = {}

	M.each_line(result.stdout, function(line)
		if line == "" or M.should_filter_line(line) then
			return
		end
		local raw, msg = M.parse_line_output(line)
		if raw == nil or msg == nil then
			return
		end
		local src_line = apply_source_map(M.to_source_line(raw), source_map)
		-- Stdout records embedding ItchyError are error diagnostics that the
		-- legacy renderer highlighted as errors; normalize them explicitly.
		local is_error = msg:match("ItchyError") ~= nil
		local cleaned = is_error and (msg:gsub("ItchyError:%s*", "")) or msg
		if is_error then
			table.insert(events, event.create("error", cleaned, src_line))
		else
			table.insert(events, event.create("stdout", msg, src_line))
		end
	end)

	M.each_line(result.stderr, function(line)
		if line == "" then
			return
		end
		local cleaned_err = clean_error_message(line)
		if M.should_filter_line(cleaned_err) then
			return
		end
		local row, error_msg = M.parse_error_output(ft, cleaned_err)
		if error_msg == nil then
			return
		end
		if row == nil then
			table.insert(events, event.create("error", error_msg, nil))
		else
			local src_line = apply_source_map(row, source_map)
			table.insert(events, event.create("error", error_msg, src_line))
		end
	end)

	return events
end

M.name = "legacy"

return M
