--- Python adapter with minimal source transformation (issue #12).
---
--- The user's source is executed unchanged from a temp file (no whole-program
--- `try:` indent). `print()` locations come from caller-frame introspection
--- in a separate launcher file; uncaught exceptions keep their native
--- tracebacks, parsed for the deepest frame belonging to the user's file.
--- No manufactured `LINE<n>` errors, no generated-source offset arithmetic.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local legacy = require("itchy.adapters.legacy")
local utils = require("itchy.utils")

M.name = "python"

--- Escape a path for embedding in a single-quoted Python string literal.
---@param path string
---@return string
local function py_escape(path)
	return (path:gsub("\\", "\\\\"):gsub("'", "\\'"))
end

-- Launcher: installs the print wrapper, then execs the (unchanged) user file
-- with its own filename so tracebacks carry true source coordinates.
local PY_HELPER = [[
import builtins as __itchy_builtins
import sys as __itchy_sys

__ITCHY_NONCE = "__ITCHY_NONCE__"
__ITCHY_USER_FILE = "__ITCHY_USER_FILE__"

__itchy_stdout = __itchy_sys.stdout
__itchy_orig_print = __itchy_builtins.print


def __itchy_caller_line():
    frame = __itchy_sys._getframe(2)
    while frame is not None:
        if frame.f_code.co_filename == __ITCHY_USER_FILE:
            return frame.f_lineno, frame.f_colno if hasattr(frame, "f_colno") else None
        frame = frame.f_back
    return None, None


def __itchy_emit(kind, message, line, column):
    evt = {"kind": kind, "message": message}
    if line is not None:
        evt["line"] = line
    if column is not None:
        evt["column"] = column
    import json as __itchy_json

    __itchy_stdout.write(
        "\x1eITCHY:" + __ITCHY_NONCE + ":" + __itchy_json.dumps(evt) + "\n"
    )
    __itchy_stdout.flush()


def __itchy_print(*args, sep=" ", end="\n", file=None, flush=False):
    target = __itchy_sys.stdout if file is None else file
    if target is not __itchy_sys.stdout:
        # Non-stdout destinations (files, pipes) behave normally. The
        # interpreter itself prints tracebacks via print(file=sys.stderr)
        # from non-user frames: forward those silently so tracebacks are
        # parsed once from real stderr instead of duplicated as events.
        __itchy_orig_print(*args, sep=sep, end=end, file=target, flush=flush)
        if target is __itchy_sys.stderr:
            line, column = __itchy_caller_line()
            if line is not None:
                __itchy_emit(
                    "stderr", sep.join(str(a) for a in args), line, column
                )
        return
    line, column = __itchy_caller_line()
    __itchy_emit("stdout", sep.join(str(a) for a in args), line, column)
    if flush:
        __itchy_stdout.flush()


__itchy_builtins.print = __itchy_print

__itchy_sys.argv = [__ITCHY_USER_FILE]
with open(__ITCHY_USER_FILE, "rb") as __itchy_fh:
    __itchy_src = __itchy_fh.read()
__itchy_code = compile(__itchy_src, __ITCHY_USER_FILE, "exec")
exec(__itchy_code, {"__name__": "__main__", "__file__": __ITCHY_USER_FILE})
]]

--- Write a temp file with the given suffix. Returns path or nil + err.
---@param suffix string
---@param content string
---@return string?, string?
local function write_temp(suffix, content)
	local base = vim.fn.tempname()
	local path = base .. suffix
	local file, open_err = io.open(path, "w")
	if not file then
		return nil, open_err or ("failed to create temp file: " .. path)
	end
	file:write(content)
	file:close()
	return path, nil
end

--- Prepare execution: unchanged user source + separate launcher.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "python adapter requires a context")
	assert(ctx.runtime ~= nil, "python adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local nonce = framed.create_nonce()

	local user_path, uerr = utils.create_temp_code_file("python", source)
	if not user_path then
		error("python adapter: failed to create source file: " .. tostring(uerr))
	end

	local helper_src = PY_HELPER
	helper_src = helper_src:gsub("__ITCHY_NONCE__", function()
		return nonce
	end)
	helper_src = helper_src:gsub("__ITCHY_USER_FILE__", function()
		return py_escape(user_path)
	end)
	local helper_path, herr = write_temp(".py", helper_src)
	if not helper_path then
		utils.remove_temp_file(user_path)
		error("python adapter: failed to create helper file: " .. tostring(herr))
	end

	-- Keep runtime launcher args except the inline `-c` selector; file
	-- execution replaces it (e.g. `uv run python -c` -> `uv run python`).
	local cmd = { runtime.cmd }
	for _, arg in ipairs(runtime.args or {}) do
		if arg ~= "-c" then
			table.insert(cmd, arg)
		end
	end
	table.insert(cmd, helper_path)
	table.insert(cmd, user_path)

	local function cleanup()
		utils.remove_temp_file(user_path)
		utils.remove_temp_file(helper_path)
	end

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = cleanup,
		metadata = { nonce = nonce, user_file = user_path, filetype = ctx.filetype },
	}
end

--- Whether a traceback frame path refers to the user's source file.
---@param frame_path string?
---@param user_file string
---@return boolean
local function is_user_frame(frame_path, user_file)
	if type(frame_path) ~= "string" or type(user_file) ~= "string" then
		return false
	end
	local function norm(p)
		return (p:gsub("\\", "/"))
	end
	return norm(frame_path) == norm(user_file)
end

--- Parse native stderr: deepest user-file traceback frame + exception message.
---@param stderr_text string
---@param user_file string
---@return integer?, string?
local function parse_traceback(stderr_text, user_file)
	local best_line = nil
	framed.each_line(stderr_text, function(line)
		local path, lnum = line:match('^%s*File "(.+)", line (%d+)')
		if path and is_user_frame(path, user_file) then
			best_line = tonumber(lnum)
		end
	end)
	-- Exception message: last non-empty, non-frame, non-context line.
	local message = nil
	framed.each_line(stderr_text, function(line)
		if line:match('^%s*File "') or line:match("^%s*%^+%s*$") or line:match("^Traceback") or line:match("^%s*$") then
			return
		end
		if
			line:match("Error")
			or line:match("Exception")
			or line:match("Warning")
			or line:match("KeyboardInterrupt")
		then
			message = line:match("^%s*(.-)%s*$")
		end
	end)
	if message == nil then
		framed.each_line(stderr_text, function(line)
			if not line:match('^%s*File "') and not line:match("^%s*%^+%s*$") and not line:match("^Traceback") then
				local trimmed = line:match("^%s*(.-)%s*$")
				if trimmed ~= "" then
					message = trimmed
				end
			end
		end)
	end
	return best_line, message
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
	---@type itchy.Event[]
	local events = {}
	-- Messages already surfaced as framed stderr events (the helper forwards
	-- stderr-targeted prints to real stderr AND emits an event for them).
	-- The native traceback parser must not report them a second time.
	local seen_stderr = {}

	framed.each_line(result.stdout, function(line)
		if legacy.should_filter_line(line) then
			return
		end
		local record = framed.decode_line(line, nonce)
		if record then
			if record.kind == "stderr" then
				seen_stderr[record.message] = true
			end
			table.insert(events, event.create(record.kind, record.message, record.line, record.column))
		elseif line ~= "" then
			table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
		end
	end)

	local stderr_text = type(result.stderr) == "string" and result.stderr or ""
	local has_stderr = false
	framed.each_line(stderr_text, function(line)
		if line ~= "" and not legacy.should_filter_line(line) then
			has_stderr = true
		end
	end)
	if has_stderr then
		local eline, message = parse_traceback(stderr_text, user_file)
		if message and message ~= "" and not seen_stderr[message] then
			table.insert(events, event.create("error", framed.sanitize_message(message), eline))
		end
	end

	return events
end

return M
