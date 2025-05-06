local M = {}

--- Wrap Go code by injecting line numbers into logging and error calls.
---@param code string
---@param offset? integer
---@return string
function M.wrap(code, offset)
  local line_counter = offset or 0
  local modified_code = ''

  local has_log = code:match 'log%.[%w_]+'
  local original_code = code

  -- Ensure valid Go main package
  if not code:match 'package%s+main' then
    code = 'package main\n\n'
    if original_code:match 'fmt%.[%w_]+' then
      code = code .. 'import "fmt"\n'
      line_counter = line_counter - 1
    end
    if has_log then
      code = code .. 'import "log"\n'
      line_counter = line_counter - 1
    end
    if original_code:match 'panic' or original_code:match 'os%.[%w_]+' then
      code = code .. 'import "os"\n'
      line_counter = line_counter - 1
    end
    if original_code:match 'errors%.[%w_]+' then
      code = code .. 'import "errors"\n'
      line_counter = line_counter - 1
    end
    code = code .. '\nfunc main() {\n' .. original_code .. '\n}\n'
    line_counter = line_counter - 4
  end

  if has_log then
    -- Set log flags immediately after func main() {
    code = code:gsub('func main%(%)[%s{]*', 'func main() {\n\tlog.SetFlags(log.Lshortfile)\n')
    line_counter = line_counter - 1
  end

  -- Patterns for matching log and error calls with dedicated transform functions for each
  local log_calls = {
    {
      pattern = 'fmt%.Print[fln]',
      transform = function(line, line_num)
        return string.format('fmt.Printf("LINE%d: "); %s', line_num, line)
      end,
    },
    {
      pattern = 'log%.Print[fln]?%b()',
      transform = function(line, line_num)
        -- Handle log.Print* differently to avoid error-like formatting
        local content = line:match '%((.+)%)'
        if content then
          -- Format regular logs without error formatting
          return string.format('log.Printf("LINE%d: %%s", %s', line_num, content)
        else
          return string.format('log.Printf("LINE%d: ")', line_num) .. line
        end
      end,
    },
    {
      pattern = 'log%.Fatal',
      transform = function(line, line_num)
        local error_message = line:match '%((.+)%)'
        if error_message then
          return string.format('log.Fatalf("LINE%d: Error: %%v", %s', line_num, error_message)
        else
          return string.format('log.Fatalf("LINE%d: Error: ")', line_num) .. line
        end
      end,
    },
    {
      pattern = 'fmt%.Errorf%b()',
      transform = function(line, line_num)
        local error_message = line:match '%((.+)%)'
        if error_message then
          return string.format('fmt.Printf("LINE%d: ItchyError: %%v\\n", %s', line_num, error_message:gsub('\n', '\\n'):gsub(',%s*%)$', '') .. ')')
        else
          return string.format('fmt.Printf("LINE%d: ItchyError: ")', line_num) .. line
        end
      end,
    },
    {
      pattern = 'panic%b()',
      transform = function(line, line_num)
        return string.format('fmt.Printf("LINE%d: Panic: "); %s', line_num, line)
      end,
    },
  }

  -- Add line numbers and error formatting
  for line in code:gmatch '([^\n]*)\n?' do
    local matched = false

    if not line:match '^%s*//' then
      for _, call in ipairs(log_calls) do
        if line:match(call.pattern) then
          modified_code = modified_code .. call.transform(line, line_counter) .. '\n'
          matched = true
          break
        end
      end
    end

    if not matched then
      modified_code = modified_code .. line .. '\n'
    end

    line_counter = line_counter + 1
  end

  return modified_code
end

return M
