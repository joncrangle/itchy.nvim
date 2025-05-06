local M = {}

-- BUG: control statements (else) and for loops don't quite work
--- Create a wrapper for Windows CMD scripts that captures command output with line numbers.
---@param code string
---@param offset? integer
---@return string
function M.wrap_cmd(code, offset)
  --- Escape special CMD characters, optionally allow % for variables
  ---@param str string
  ---@param allow_percent? boolean
  ---@return string
  local function escape_cmd_chars(str, allow_percent)
    local escaped, _ = str:gsub('%%', allow_percent and '%%' or '%%%%'):gsub('[&|<>!^]', '^%1')
    return escaped
  end

  local function is_block_header(line)
    return line:match '^%s*%($' or line:match '^%($' -- Revised version
  end

  local function is_block_closing(line)
    return line == ')'
  end

  local function is_empty_or_comment(line)
    return line == '' or line:match '^%s*REM' or line:match '^%s*::' or line:match '^%s*:[^:]'
  end

  local function is_control_flow_start(line)
    return line:match '^%s*if%s+' or line:match '^%s*for%s+' or line:match '^%s*else%s*'
  end

  offset = offset or 0
  local all_lines = {}
  for line in (code .. '\n'):gmatch '([^\r\n]*)[\r\n]' do
    table.insert(all_lines, line)
  end

  local output_lines = {}
  local original_lines_for_output = {}

  for i, line in ipairs(all_lines) do
    local line_num = i + offset - 1
    local trimmed = line:match '^%s*(.-)%s*$'

    local function add_output_line(out_line, original)
      table.insert(output_lines, out_line)
      original_lines_for_output[#output_lines] = original
    end

    if is_empty_or_comment(trimmed) then
      -- Skip comments and empty lines
    elseif trimmed:match '^%s*@?echo%s' then
      local indent, rest = trimmed:match '^(%s*@?echo%s*)(.*)$'
      if rest:match '^off$' or rest:match '^on$' then
        add_output_line(trimmed, trimmed) -- Map to itself
      else
        if rest:match '%%[%%]?[%w_]+%%' then
          add_output_line('call echo LINE' .. line_num .. ': ' .. rest, trimmed)
        else
          add_output_line(indent .. 'LINE' .. line_num .. ': ' .. rest, trimmed)
        end
      end
    elseif trimmed:match '^%s*set%s+' then
      add_output_line(escape_cmd_chars(trimmed, true), trimmed) -- Map to original set
    elseif is_control_flow_start(trimmed) then
      add_output_line(trimmed, trimmed) -- Map to itself
    elseif is_block_header(trimmed) then
      add_output_line(trimmed, trimmed) -- Map to itself (though unlikely standalone)
    elseif is_block_closing(trimmed) then
      add_output_line(trimmed, trimmed) -- Map to itself
    else
      if trimmed:match '^%s*[%%]?[%w_]+[%%]?%s*=' then
        add_output_line(escape_cmd_chars(trimmed, true), trimmed) -- Map to original assignment
      else
        -- For commands generating two lines, map BOTH back to the original command
        add_output_line('echo LINE' .. line_num .. ':', trimmed)
        local escaped = escape_cmd_chars(trimmed, false)
        add_output_line(escaped .. ' || echo LINE' .. line_num .. ': ItchyError: %errorlevel%', trimmed)
      end
    end
  end

  local result = ''
  local in_block = false

  for i, line in ipairs(output_lines) do
    local trimmed_line = line:match '^%s*(.-)%s*$'
    local original_trimmed = original_lines_for_output[i] or ''

    local separator = ' & '

    if i == 1 then
      separator = ''
      -- Use SPACE if:
      -- 1. We are currently inside a block (determined *after* processing previous line)
      -- 2. The *original* line that generated the *current* output line starts control flow
      -- 3. The *current processed* line is a block header
      -- 4. The *current processed* line is a block closing
    elseif in_block or is_control_flow_start(original_trimmed) or is_block_header(trimmed_line) or is_block_closing(trimmed_line) then
      separator = ' '
    end

    result = result .. separator .. line

    -- Update in_block status *after* processing the current line
    -- This determines the state for the *next* line's separator decision
    if is_block_header(trimmed_line) then
      in_block = true
    elseif is_block_closing(trimmed_line) then
      in_block = false
    end
  end

  return result
end

--- Create a wrapper for PowerShell scripts that captures command output with line numbers.
---@param code string
---@param offset? integer
---@return string
function M.wrap_pwsh(code, offset)
  offset = offset or 0

  -- Split the code into lines
  local all_lines = {}
  for line in (code .. '\n'):gmatch '([^\r\n]*)[\r\n]' do
    table.insert(all_lines, line)
  end

  -- Count the number of lines in the wrapper preamble to adjust error line numbers
  local wrapper_preamble = [[
$PSStyle.OutputRendering = 'PlainText'
function Write-LineMarker {
    param(
        [int]$LineNumber,
        [string]$Content,
        [switch]$IsError
    )
    
    if ($IsError) {
        [Console]::Error.WriteLine("LINE$LineNumber`: ItchyError: $Content")
    } else {
        # Match Python's output format: "LINE{line_num}: {content}"
        [Console]::Out.WriteLine("LINE$LineNumber`: $Content")
    }
}

# Global error handler to capture and format all errors
$ErrorActionPreference = 'Stop'
trap {
    # Get the error details
    $errorLineNumber = $_.InvocationInfo.ScriptLineNumber
    # Account for the wrapper's preamble lines
    $adjustedLineNumber = $errorLineNumber - WRAPPER_LINES_PLACEHOLDER
    if ($adjustedLineNumber -lt 1) { $adjustedLineNumber = 1 }
    
    # Handle multiline errors by joining them with a space
    $errorMessage = $_.Exception.Message -replace "`n", " " -replace "`r", " "
    
    # Format the error using our standard format with adjusted line number
    [Console]::Out.WriteLine("LINE$adjustedLineNumber`: ItchyError: $errorMessage")
    
    # Continue execution
    continue
}
]]

  -- Count the number of lines in the wrapper preamble
  local wrapper_lines = 0
  for _ in wrapper_preamble:gmatch '\n' do
    wrapper_lines = wrapper_lines + 1
  end

  -- Replace the placeholder with the actual number of wrapper lines
  wrapper_preamble = wrapper_preamble:gsub('WRAPPER_LINES_PLACEHOLDER', tostring(wrapper_lines + 1))

  local wrapped = wrapper_preamble

  local in_param_block = false
  local param_block_lines = {}

  for i, line in ipairs(all_lines) do
    local line_num = i + offset - 1
    local trimmed = line:match '^%s*(.-)%s*$'

    -- Check if we're entering a param block
    if trimmed:match '^param%s*%(%s*$' then
      in_param_block = true
      param_block_lines = { line }
    elseif in_param_block then
      table.insert(param_block_lines, line)
      -- Check if the param block is ending
      if line:match '%s*%)%s*$' then
        in_param_block = false
        -- Write out the entire param block unchanged
        wrapped = wrapped .. table.concat(param_block_lines, '\n') .. '\n'
      end
    else
      -- Skip empty lines and comments
      if trimmed == '' or trimmed:match '^#' then
        wrapped = wrapped .. line .. '\n'

      -- Process output commands with proper escaping
      elseif line:match '^%s*echo%s+' then
        local indent, content = line:match '^(%s*)echo%s+(.*)$'
        content = content:gsub('`', '``'):gsub('"', '`"'):gsub('\\', '`\\')
        wrapped = wrapped .. indent .. 'Write-LineMarker -LineNumber ' .. line_num .. ' -Content "' .. content .. '"\n'
      elseif line:match '^%s*Write%-Host%s+' then
        local indent, content = line:match '^(%s*)Write%-Host%s+(.*)$'
        if content:match '^".*"$' or content:match "^'.*'$" then
          wrapped = wrapped .. indent .. 'Write-LineMarker -LineNumber ' .. line_num .. ' -Content ' .. content .. '\n'
        else
          content = content:gsub('`', '``'):gsub('"', '`"'):gsub('\\', '`\\')
          wrapped = wrapped .. indent .. 'Write-LineMarker -LineNumber ' .. line_num .. ' -Content "' .. content .. '"\n'
        end
      elseif line:match '^%s*Write%-Output%s+' then
        local indent, content = line:match '^(%s*)Write%-Output%s+(.*)$'
        if content:match '^".*"$' or content:match "^'.*'$" then
          wrapped = wrapped .. indent .. 'Write-LineMarker -LineNumber ' .. line_num .. ' -Content ' .. content .. '\n'
        else
          content = content:gsub('`', '``'):gsub('"', '`"'):gsub('\\', '`\\')
          wrapped = wrapped .. indent .. 'Write-LineMarker -LineNumber ' .. line_num .. ' -Content "' .. content .. '"\n'
        end

      -- Keep function definitions and control structures intact
      elseif
        line:match '^%s*function%s+'
        or line:match '^%s*{%s*$'
        or line:match '^%s*}%s*$'
        or line:match '^%s*if%s+'
        or line:match '^%s*else%s*{?%s*$'
        or line:match '^%s*elseif%s+'
        or line:match '^%s*for%s+'
        or line:match '^%s*foreach%s+'
        or line:match '^%s*while%s+'
        or line:match '^%s*switch%s+'
        or line:match '^%s*do%s*{?%s*$'
        or line:match '^%s*try%s*{?%s*$'
        or line:match '^%s*catch%s*{?%s*$'
        or line:match '^%s*finally%s*{?%s*$'
        or line:match '^%s*begin%s*{?%s*$'
        or line:match '^%s*process%s*{?%s*$'
        or line:match '^%s*end%s*{?%s*$'
        or line:match '^%s*return%s+'
      then
        wrapped = wrapped .. line .. '\n'
      else
        wrapped = wrapped .. line .. '\n'
      end
    end
  end

  wrapped = wrapped .. [[
# End of script
]]

  return wrapped
end

-- Expose both wrappers
M.wrap = {
  cmd = M.wrap_cmd,
  pwsh = M.wrap_pwsh,
}

return M
