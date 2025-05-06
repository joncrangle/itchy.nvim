local M = {}

--- Create a wrapper for shell scripts that captures command output (stdout and stderr) with line numbers.
---@param code string
---@param offset? integer
---@return string
function M.wrap(code, offset)
  offset = offset or 0

  local all_lines = {}
  local has_shebang = false

  for line in (code .. '\n'):gmatch '([^\r\n]*)[\r\n]' do
    table.insert(all_lines, line)
  end

  -- Check for a shebang (#!) in the first line
  if #all_lines > 0 and all_lines[1]:match '^#!' then
    has_shebang = true
  end

  -- Start with either the user-provided shebang or default to bash
  local result = has_shebang and (all_lines[1] .. '\n\n') or '#!/bin/bash\n\n'

  -- Function to prefix line numbers to output (stdout and stderr)
  result = result
    .. ([[
# Override echo and printf to include line numbers
function log_stdout() {
  local line_num=$(($1 - 1))
  shift
  echo "LINE$line_num: $*" >&1
}

function log_stderr() {
  local line_num=$(($1 + 1 - %d))
  shift
  echo "LINE$line_num: Error: $*" >&2
}

# Replace echo and printf
alias echo='log_stdout $LINENO'
alias printf='log_stdout $LINENO'

# Trap errors to capture line numbers
trap 'log_stderr $(($LINENO - %d)) "$BASH_COMMAND"' ERR

# Enable command tracing for debugging
set -o pipefail
]]):format(offset, offset)

  -- Add line numbers to non-shebang lines
  for i, line in ipairs(all_lines) do
    if not (i == 1 and has_shebang) then
      local line_num = i
      local trimmed = line:match '^%s*(.*)$'
      local is_comment = trimmed:match '^#' or trimmed == ''

      if is_comment then
        result = result .. line .. '\n'
      else
        -- Handle echo, printf, and other commands
        if line:match '^%s*echo%s+' then
          local indent, args = line:match '^(%s*)echo%s+(.*)$'
          args = args:gsub('"', '\\"')
          result = result .. indent .. ('log_stdout %d "%s"\n'):format(line_num, args)
        elseif line:match '^%s*printf%s+' then
          local indent, args = line:match '^(%s*)printf%s+(.*)$'
          args = args:gsub('"', '\\"')
          result = result .. indent .. ('log_stdout %d "%s"\n'):format(line_num, args)
        else
          result = result .. line .. '\n'
        end
      end
    end
  end

  return result
end

return M
