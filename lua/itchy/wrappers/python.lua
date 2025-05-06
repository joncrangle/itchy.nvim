local M = {}

--- Create a wrapper for Python code that captures console output with line numbers.
---@param code string
---@param offset integer
---@return string
function M.wrap(code, offset)
  local indented_code = ''
  for line in code:gmatch '([^\n]*)\n?' do
    if #line > 0 then
      indented_code = indented_code .. '    ' .. line .. '\n'
    else
      indented_code = indented_code .. '\n'
    end
  end

  return string.format(
    [[
import sys
import traceback

original_print = print

def custom_print(*args, **kwargs):
    try:
        frame = sys._getframe(1)
        line_num = frame.f_lineno - %d

        # Check if we're inside an exception block
        exc_info = sys.exc_info()
        if exc_info[0] is not None:
            prefix = f"LINE{line_num}: ItchyError: "
        else:
            prefix = f"LINE{line_num}:"

    except ValueError:
        prefix = "LINE?:"

    original_print(prefix, *args, **kwargs)

print = custom_print

try:
%s
except Exception as e:
    tb = traceback.extract_tb(sys.exc_info()[2])
    if tb:
        line_num = tb[-1].lineno - %d
        original_print(f"LINE{line_num}: ItchyError: {str(e)}", file=sys.stderr)
    else:
        original_print(f"Error: {str(e)}", file=sys.stderr)
]],
    offset,
    indented_code,
    offset
  )
end

return M
