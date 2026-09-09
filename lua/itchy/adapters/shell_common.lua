--- Shared machinery for the shell adapters (issue #16).
---
--- Bash and Zsh intercept `echo`/`printf` with native caller metadata and
--- report framed records through an adapter-private side channel (an event
--- file), so redirections and pipelines are never polluted with metadata.
--- POSIX `sh` uses the same side channel with explicit line numbers passed
--- by a conservative source transformation (see `itchy.adapters.sh`).
---
--- This module owns everything shell-specific about decoding: reading the
--- event file, folding delegated duplicates, and parsing native shell
--- diagnostics. Generic core code (`init.lua`, `executor.lua`,
--- `renderer.lua`, `event.lua`) never sees shell protocols.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local legacy = require("itchy.adapters.legacy")
local utils = require("itchy.utils")

--- Escape a filesystem path for embedding in a double-quoted shell string.
---@param path string
---@return string
function M.shell_dquote(path)
	return (path:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`"))
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
	file:write(content)
	file:close()
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
--- zsh/dash (`path: N: msg`) diagnostics. Only frames belonging to the
--- adapter's user file count; anything else is not a shell diagnostic.
--- Bash source excerpts (backtick-quoted follow-ups to syntax errors) are
--- skipped by the caller via `is_excerpt`.
---@param line string
---@param user_file string
---@param helper_leaf string fixed launcher filename to exclude
---@return integer? line 1-based source line
---@return string? message
function M.parse_native_error_line(line, user_file, helper_leaf)
	if type(line) ~= "string" or line == "" then
		return nil, nil
	end
	-- Bash: "/tmp/x.sh: line 2: msg".
	local path, lnum, msg = line:match("^(.-):%s+line%s+(%d+):%s*(.*)$")
	if path ~= nil and utils.is_user_file(path, user_file, helper_leaf) then
		local n = tonumber(lnum)
		if n ~= nil and n >= 1 then
			return n, (msg ~= "" and msg or line)
		end
	end
	-- Zsh and dash: "/tmp/x.sh:2: msg" (dash pads extra spaces).
	path, lnum, msg = line:match("^(.-):%s*(%d+):%s*(.*)$")
	if path ~= nil and utils.is_user_file(path, user_file, helper_leaf) then
		local n = tonumber(lnum)
		if n ~= nil and n >= 1 then
			return n, (msg ~= "" and msg or line)
		end
	end
	return nil, nil
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
	local tmpdir = utils.make_adapter_tmpdir(utils.project_dir(ctx), prefix, nonce)
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
		pcall(vim.fn.delete, tmpdir, "d")
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
	local nonce = framed.create_nonce()

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
	M.write_file(event_path, "")

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
--- Helpers delegate to the real builtins, so real output still reaches
--- stdout/stderr (redirections and pipelines behave natively). Delegated
--- duplicates are folded away: a raw line equal to a framed message part
--- is consumed rather than reported twice. Remaining raw stdout becomes
--- locationless output (external commands); remaining non-diagnostic
--- stderr becomes locationless errors. Nothing is ever guessed a location.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode_sidechannel(ctx, prepared, result)
	local metadata = (prepared and prepared.metadata) or {}
	local nonce = metadata.nonce or ""
	local user_file = metadata.user_file or ""
	local event_file = metadata.event_file or ""
	local helper_leaf = metadata.helper_leaf or "itchy-launcher"
	-- Single-file adapters (sh) prepend a helper header: native
	-- diagnostics carry shifted coordinates, mapped back here. Records
	-- already carry absolute coordinates and need no mapping.
	local line_offset = metadata.line_offset or 0
	---@type itchy.Event[]
	local events = {}

	local records = M.read_records(event_file, nonce)

	-- Multiset of framed message parts (split on embedded newlines) used
	-- to fold delegated duplicates out of the raw streams.
	---@type table<string, integer>
	local pending = {}
	local function expect(message)
		for _, part in ipairs(vim.split(message, "\n", { plain = true })) do
			if part ~= "" then
				pending[part] = (pending[part] or 0) + 1
			end
		end
	end
	local function consume(message)
		if (pending[message] or 0) > 0 then
			pending[message] = pending[message] - 1
			return true
		end
		return false
	end

	for _, record in ipairs(records) do
		if record.kind == "stdout" or record.kind == "stderr" then
			expect(record.message)
		end
		table.insert(events, event.create(record.kind, record.message, record.line, record.column))
	end

	framed.each_line(result.stdout, function(line)
		if line == "" or legacy.should_filter_line(line) then
			return
		end
		-- A framed record leaking onto raw stdout (foreign prefix) is
		-- ordinary output, never a location.
		if framed.decode_line(line, nonce) then
			return
		end
		if consume(line) then
			return
		end
		table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
	end)

	framed.each_line(result.stderr, function(line)
		if line == "" or legacy.should_filter_line(line) then
			return
		end
		local clean = legacy.clean_error_message(line)
		if clean:match("^`") then
			-- Shell source excerpt (bash reprints the offending source
			-- backtick-quoted after a syntax error): the diagnostic above
			-- already explains it.
			return
		end
		local eline, message = M.parse_native_error_line(clean, user_file, helper_leaf)
		if message ~= nil and eline ~= nil then
			local src_line = eline - line_offset
			if src_line >= 1 then
				table.insert(events, event.create("error", framed.sanitize_message(message), src_line))
			else
				-- A diagnostic inside the adapter's own header (never
				-- expected): locationless rather than mislocated.
				table.insert(events, event.create("error", framed.sanitize_message(message), nil))
			end
			return
		end
		if consume(clean) then
			-- Redirected helper output (e.g. `echo hi >&2`): the framed
			-- record already carries it with its source line.
			return
		end
		-- Non-diagnostic stderr (external commands): visible as a
		-- locationless error rather than dropped or mislocated.
		table.insert(events, event.create("error", framed.sanitize_message(clean), nil))
	end)

	return events
end

return M
