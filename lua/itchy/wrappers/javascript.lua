local M = {}

--- Create a wrapper for JavaScript and TypeScript code that captures console output with line numbers.
---@param code string
---@param offset? integer
---@return string
function M.wrap(code, offset)
  local lines = vim.split(code, '\n', { plain = true })
  local modified_code = {}
  offset = offset or 0

  for i, line in ipairs(lines) do
    -- Check if line is a comment or empty
    local trimmed = line:match '^%s*(.*)$'
    local is_comment = trimmed:match '^//' or trimmed == ''

    if is_comment then
      table.insert(modified_code, line)
    else
      -- Add line tracking for non-comment lines
      table.insert(modified_code, ('currentLine = %d;\n%s'):format(i - 1 + offset, line))
    end
  end

  -- Ensure the code is treated as a module
  return [[
let currentLine = 0;

const originalLog = console.log;
const originalWarn = console.warn;
const originalError = console.error;
const originalDebug = console.debug;

// Override console methods
console.log = (...args) => {
  originalLog(`LINE${currentLine}:`, ...args);
};

console.warn = (...args) => {
  originalWarn(`LINE${currentLine}:`, ...args);
};

console.error = (...args) => {
  originalError(`LINE${currentLine}: Error: `, ...args);
};

console.debug = (...args) => {
  originalDebug(`LINE${currentLine}:`, ...args);
};

(async () => {
  try {
    ]] .. table.concat(modified_code, '\n') .. [[
  } catch (e) {
    console.error(`Error: ${e.message}`);
  }
})();
]]
end

return M
