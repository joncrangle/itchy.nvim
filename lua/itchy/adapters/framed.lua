--- Shared framed-event protocol for structured adapters.
---
--- Runtime helpers emit machine-readable records on a dedicated framing that
--- cannot be confused with normal user output:
---
---   <RS>ITCHY:<nonce>:<json>\n
---
--- where <RS> is the ASCII record separator (0x1E), <nonce> is a per-run
--- random marker, and <json> encodes {kind, line?, column?, message}.
--- Arbitrary user stdout (including JSON-looking text) never starts with
--- the run's nonce marker, so it stays ordinary output. Malformed records
--- are ignored, never fatal.
local M = {}

--- Record separator prefix (Lua decimal escape for 0x1E).
M.RS = "\30"
M.PREFIX = "\30ITCHY:"

local seeded = false

--- Generate a per-run nonce (8 lowercase hex chars).
---@return string
function M.create_nonce()
	if not seeded then
		seeded = true
		math.randomseed(os.time() + math.floor(os.clock() * 1000000) + math.random(65536))
	end
	local parts = {}
	for _ = 1, 8 do
		table.insert(parts, string.format("%x", math.random(0, 15)))
	end
	return table.concat(parts)
end

---@class itchy.FramedRecord
---@field kind string
---@field line? number
---@field column? number
---@field message? string

--- Validate a decoded JSON payload. Returns a normalized record or nil.
--- JSON null decodes to vim.NIL, which is treated as absent.
---@param payload any
---@return itchy.FramedRecord?
local function validate(payload)
	if type(payload) ~= "table" then
		return nil
	end
	local kind = payload.kind
	if kind ~= "stdout" and kind ~= "stderr" and kind ~= "error" and kind ~= "warning" then
		return nil
	end
	if type(payload.message) ~= "string" then
		return nil
	end
	local line = payload.line
	if line == vim.NIL then
		line = nil
	end
	if line ~= nil then
		if type(line) ~= "number" or line ~= math.floor(line) or line < 1 then
			return nil
		end
	end
	local column = payload.column
	if column == vim.NIL then
		column = nil
	end
	if column ~= nil then
		if type(column) ~= "number" or column ~= math.floor(column) or column < 1 then
			return nil
		end
	end
	return { kind = kind, line = line, column = column, message = payload.message }
end

--- Sanitize a message for single-line virtual-text rendering.
---@param message string
---@return string
function M.sanitize_message(message)
	return (message:gsub("\r\n?", " "):gsub("\n", " "))
end

--- Decode one output line. Returns the record when the line carries this
--- run's nonce marker with a valid JSON payload; otherwise nil.
---@param line string
---@param nonce string
---@return itchy.FramedRecord?
function M.decode_line(line, nonce)
	if type(line) ~= "string" or type(nonce) ~= "string" or nonce == "" then
		return nil
	end
	if line:sub(1, #M.PREFIX) ~= M.PREFIX then
		return nil
	end
	local rest = line:sub(#M.PREFIX + 1)
	local marker, json_text = rest:match("^([^:]+):(.*)$")
	if marker ~= nonce or json_text == nil then
		return nil
	end
	local ok, payload = pcall(vim.json.decode, json_text)
	if not ok then
		return nil
	end
	local record = validate(payload)
	if record == nil then
		return nil
	end
	record.message = M.sanitize_message(record.message)
	return record
end

--- Iterate every non-empty line of captured output, including a final line
--- without a trailing newline. Normalizes CRLF/CR.
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

return M
