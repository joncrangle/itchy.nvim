---@class itchy.EventKind
--- Normalized output and error categories mapped to highlights by the renderer.

---@alias itchy.EventKind
---| 'stdout'
---| 'stderr'
---| 'error'
---| 'warning'

---@class itchy.Event
---@field kind itchy.EventKind
---@field message string
---@field line? integer 1-based source line; nil means locationless
---@field column? integer 1-based column; nil when unknown
---@field path? string optional source path for future adapters

local M = {}

--- Event.line is 1-based source line. Conversion to Neovim 0-based extmark
--- rows is handled by itchy.renderer.
M.LINE_BASE = 1

---@param line any
---@return boolean
local function is_valid_line(line)
	return type(line) == "number" and line == math.floor(line) and line >= 1
end

--- Validate a 1-based event line against a buffer line count.
---@param line? integer
---@param line_count integer
---@return boolean
function M.is_valid_line(line, line_count)
	if not is_valid_line(line) then
		return false
	end
	if type(line_count) == "number" and line_count >= 1 then
		return line <= line_count
	end
	return true
end

--- Validate a 1-based column.
---@param col? integer
---@return boolean
function M.is_valid_column(col)
	if col == nil then
		return true
	end
	return is_valid_line(col)
end

--- Construct an event, normalizing locationless markers.
--- Rejects magic sentinel values (e.g. line = -1); callers must use nil.
---@param kind itchy.EventKind
---@param message string
---@param line? integer 1-based or nil
---@param column? integer 1-based or nil
---@param path? string optional source path
---@return itchy.Event
function M.create(kind, message, line, column, path)
	assert(
		kind == "stdout" or kind == "stderr" or kind == "error" or kind == "warning",
		"invalid event kind: " .. tostring(kind)
	)
	assert(type(message) == "string", "event message must be a string")
	if line ~= nil then
		assert(is_valid_line(line), "event line must be a 1-based integer or nil, got: " .. tostring(line))
	end
	if column ~= nil then
		assert(is_valid_line(column), "event column must be a 1-based integer or nil, got: " .. tostring(column))
	end
	if path ~= nil then
		assert(type(path) == "string", "event path must be a string or nil")
	end
	---@type itchy.Event
	local event = { kind = kind, message = message, line = line, column = column, path = path }
	return event
end

return M
