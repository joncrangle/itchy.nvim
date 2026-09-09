--- Generic event renderer. Consumes normalized itchy.Event objects and
--- paints virtual lines. Knows nothing about runtimes, filetypes, or the
--- legacy LINE<n> wire protocol.
local M = {}

local config = require("itchy.config")
local event_mod = require("itchy.event")

--- Group events by 1-based source line. Locationless events are returned
--- separately so the caller can notify rather than place an extmark.
---@param events itchy.Event[]
---@param line_count integer
---@return table<integer, itchy.Event[]> by_line
---@return itchy.Event[] locationless
---@return itchy.Event[] invalid out-of-range or malformed locations
local function group_events(events, line_count)
	---@type table<integer, itchy.Event[]>
	local by_line = {}
	---@type itchy.Event[]
	local locationless = {}
	---@type itchy.Event[]
	local invalid = {}
	for _, e in ipairs(events or {}) do
		if type(e) ~= "table" or type(e.message) ~= "string" then
			table.insert(invalid, e)
		elseif e.line == nil then
			table.insert(locationless, e)
		elseif event_mod.is_valid_line(e.line, line_count) then
			by_line[e.line] = by_line[e.line] or {}
			table.insert(by_line[e.line], e)
		else
			table.insert(invalid, e)
		end
	end
	return by_line, locationless, invalid
end

--- Notify about a locationless diagnostic, preserving the legacy behavior
--- of surfacing unattributed errors via vim.notify instead of an extmark.
---@param message string
local function notify_locationless(message)
	local msg = message or "Unknown error."
	local is_headless = not vim.env.DISPLAY and #vim.api.nvim_list_uis() == 0
	vim.schedule(function()
		if is_headless then
			vim.notify("itchy error: " .. msg, vim.log.levels.ERROR, { title = "itchy" })
		else
			vim.notify(msg, vim.log.levels.ERROR, { title = "itchy" })
		end
	end)
end

--- Render normalized events into a buffer namespace.
--- Validates 1-based event lines, converts to 0-based extmark rows in this
--- single place, aggregates multiple events per line with ' | ', and keeps
--- stale-run/current-run guards. Never branches on language or filetype.
---
--- Location policy (legacy-compatible): numeric lines beyond the buffer are
--- clamped to the last line, matching the pre-adapter
--- `math.max(0, math.min(line_count - 1, row))` behavior. Wrapper-native
--- diagnostics (e.g. shell arithmetic errors, JS stack frames) report wrapped
--- line numbers that can exceed the source buffer; clamping keeps them visible
--- as extmarks so end-to-end expectations are preserved. Truly locationless
--- events (`line == nil`) still notify. Locationless `stdout` is pinned to
--- row 0 to preserve visible output.
---@param buf integer
---@param namespace integer
---@param events itchy.Event[]
---@param opts? table
---@field opts.line_count? integer override buffer line count (tests)
---@field opts.is_current? fun(): boolean guard; when provided and false, rendering is skipped
---@field opts.on_locationless? fun(event: itchy.Event) test hook; defaults to vim.notify
function M.render(buf, namespace, events, opts)
	opts = opts or {}
	local hl_stdout = config.cfg.highlights.stdout
	local hl_stderr = config.cfg.highlights.stderr
	local on_locationless = opts.on_locationless

	vim.schedule(function()
		if type(opts.is_current) == "function" then
			local ok, current = pcall(opts.is_current)
			if not ok or not current then
				return
			end
		end
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local line_count = opts.line_count or vim.api.nvim_buf_line_count(buf)
		local by_line, locationless, invalid = group_events(events, line_count)

		-- Legacy compatibility: clamp numeric out-of-range lines to the last
		-- buffer line instead of dropping/notifying them. Truly locationless
		-- (nil) and malformed events keep the group_events routing.
		for _, e in ipairs(invalid) do
			if type(e) == "table" and type(e.message) == "string" and type(e.line) == "number" then
				local clamped = math.max(1, math.min(line_count, math.floor(e.line)))
				by_line[clamped] = by_line[clamped] or {}
				table.insert(by_line[clamped], e)
			end
		end

		for _, e in ipairs(locationless) do
			-- Only surface diagnostics; locationless stdout is rendered at the
			-- first line to preserve visible output instead of dropping it.
			if e.kind == "error" or e.kind == "warning" or e.kind == "stderr" then
				if type(on_locationless) == "function" then
					pcall(on_locationless, e)
				else
					notify_locationless(e.message)
				end
			elseif e.kind == "stdout" then
				vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
					virt_lines = { { { "  │ ", hl_stdout }, { e.message, hl_stdout } } },
				})
			end
		end

		for src_line, line_events in pairs(by_line) do
			local row = src_line - 1
			---@type string[]
			local stdout_parts = {}
			---@type string[]
			local error_parts = {}
			for _, e in ipairs(line_events) do
				if e.kind == "error" or e.kind == "stderr" or e.kind == "warning" then
					table.insert(error_parts, e.message)
				else
					table.insert(stdout_parts, e.message)
				end
			end
			if #stdout_parts > 0 then
				vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
					virt_lines = { { { "  │ ", hl_stdout }, { table.concat(stdout_parts, " | "), hl_stdout } } },
				})
			end
			if #error_parts > 0 then
				vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
					virt_lines = { { { "  │ ", hl_stderr }, { table.concat(error_parts, " | "), hl_stderr } } },
				})
			end
		end
	end)
end

-- Exposed for unit tests (pure, synchronous).
M._group_events = group_events

return M
