local M = {}

local config = require 'itchy.config'

local filetype_to_extension = {
  javascript = 'js',
  typescript = 'ts',
}

--- Return the extension for a filetype
---@param ft string
---@return string
function M.ft_to_ext(ft)
  return filetype_to_extension[ft] or ft
end

--- Print debug messages
---@vararg any
function M.debug_print(...)
  if config.cfg.debug_mode then
    print(...)
  end
end

--- Get the appropriate wrapper for the filetype
---@param runtime itchy.Runtime
---@param code string
---@return string
function M.get_wrapped_code(runtime, code)
  if runtime and runtime.wrapper then
    return runtime.wrapper(code, runtime.offset)
  end
  return code
end

--- Clean error messages by removing ANSI escape codes
---@param err string
---@return string,_
function M.clean_error_message(err)
  return err:gsub('\27%[[%d;]*m', '')
end

--- Parse line-prefixed output to get line number and message
---@param line string
---@return integer|nil, string|nil
function M.parse_line_output(line)
  -- Strip any carriage returns to handle Windows line endings
  line = line:gsub('\r', '')

  local line_num_str, msg = line:match '^LINE(%d+):%s*(.+)'
  if line_num_str and msg then
    return tonumber(line_num_str), msg
  end

  return nil, nil
end

--- Process error output to get line number and message
---@param ft string
---@param err string
---@return integer?, string?
function M.parse_error_output(ft, err)
  err = err:gsub('\r', '')
  local line_num_str, msg = err:match 'LINE(%d+):%s*Error:%s*(.+)'

  if line_num_str and msg then
    return tonumber(line_num_str) or 0, msg
  end

  if ft == 'typescript' or ft == 'javascript' then
    local stack_line = err:match 'at eval[^:]+:(%d+):'
    if stack_line then
      local row = math.floor((tonumber(stack_line) - 10) / 2)
      local error_msg = err:match 'Error:%s*(.+)'
      return row, error_msg
    end
  elseif ft == 'python' then
    local line_num = err:match 'LINE(%d+)'
    local error_msg = err:match 'Error:%s*(.+)'
    if line_num and error_msg then
      return tonumber(line_num) or 0, error_msg
    end
  elseif ft == 'go' then
    -- Match Go runtime errors
    local runtime_line, runtime_msg = err:match ':(%d+):%s*(.+)'
    if runtime_line and runtime_msg then
      return tonumber(runtime_line - 2) or 0, runtime_msg
    end

    -- Match panic traces like
    local panic_line = err:match '(%d+)%s+%+0x'
    if panic_line then
      return tonumber(panic_line - 1) or 0, 'Panic occurred'
    end
  elseif ft == 'bash' or ft == 'sh' or ft == 'zsh' then
    -- Match standard shell error with line number: "sh: line X: ..."
    local line_num, error_msg = err:match '^[^:]+:%s*line%s*(%d+):%s*(.+)'
    if line_num and error_msg then
      return tonumber(line_num) or 0, error_msg
    end

    -- Match general error messages without line numbers
    local general_error = err:match '^[^:]+:%s*(.+)'
    if general_error then
      return -1, general_error
    end
  end

  local runtime_err_msg = err:match 'error:%s*(.+)'
  if runtime_err_msg then
    return -1, runtime_err_msg
  end
end

--- Check if a line should be filtered based on noise patterns
---@param line string
---@return boolean
function M.should_filter_line(line)
  local noise_patterns = {
    "hint: Replace 'window' with 'globalThis'",
    'window is not defined',
    '^$', -- Empty lines
  }

  for _, pattern in ipairs(noise_patterns) do
    if line:match(pattern) then
      return true
    end
  end

  return false
end

--- Create a temporary source-code file for runtimes requiring a file.
---Only the source file is created; stdout/stderr are captured via vim.system.
---@param ft string
---@param wrapped_code string
---@return string? path returns nil + error on failure
---@return string? err
function M.create_temp_code_file(ft, wrapped_code)
  local base = vim.fn.tempname()
  local extension = M.ft_to_ext(ft)
  local code_file = base .. '.' .. extension
  local file, open_err = io.open(code_file, 'w')
  if not file then
    return nil, open_err or ('failed to create temp file: ' .. code_file)
  end
  file:write(wrapped_code)
  file:close()
  return code_file, nil
end

--- Remove a temporary file exactly once (harmless if missing).
---@param path? string
function M.remove_temp_file(path)
  if type(path) ~= 'string' or path == '' then
    return
  end
  pcall(os.remove, path)
end

--- Iterate every non-empty line of captured process output, including a
---final line without a trailing newline. Normalizes CRLF/CR.
---@param text string?
---@param fn fun(line: string)
function M.process_output_text(text, fn)
  if type(text) ~= 'string' or text == '' then
    return
  end
  text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
  local start = 1
  while true do
    local nl = text:find('\n', start, true)
    if nl then
      local line = text:sub(start, nl - 1)
      if line ~= '' then
        fn(line)
      end
      start = nl + 1
    else
      local rest = text:sub(start)
      if rest ~= '' then
        fn(rest)
      end
      break
    end
  end
end

--- Process a single output line.
---@param line string
---@param outputs_by_line table
---@param line_count integer
---@param line_mapping table
function M.process_output(line, outputs_by_line, line_count, line_mapping)
  if not line or line == '' or M.should_filter_line(line) then
    return
  end

  local row, msg = M.parse_line_output(line)
  row = row and math.max(0, math.min(line_count - 1, row)) or 0
  msg = msg or ''

  if row and line_mapping and line_mapping[row] then
    row = line_mapping[row]
  end

  outputs_by_line[row] = outputs_by_line[row] and (outputs_by_line[row] .. ' | ' .. msg) or msg
end

--- Cache check for neovim headless mode
local is_headless = not vim.env.DISPLAY and #vim.api.nvim_list_uis() == 0

--- Process a single error line.
---@param line string
---@param errors_by_line table
---@param ft string
---@param line_count integer
---@param line_mapping table
function M.process_error(line, errors_by_line, ft, line_count, line_mapping)
  if not line or line == '' then
    return
  end

  local cleaned_err = M.clean_error_message(line)
  M.debug_print('stderr data:', cleaned_err)

  if M.should_filter_line(cleaned_err) then
    return
  end

  local row, error_msg = M.parse_error_output(ft, cleaned_err)

  if row == -1 then
    local msg = error_msg or 'Unknown error.'
    if not is_headless then
      vim.schedule(function()
        vim.notify(msg, vim.log.levels.ERROR, { title = 'itchy' })
      end)
    else
      vim.schedule(function()
        vim.notify('itchy error: ' .. msg, vim.log.levels.ERROR, { title = 'itchy' })
      end)
    end
  elseif row and error_msg then
    if row and line_mapping and line_mapping[row] then
      row = line_mapping[row]
    elseif row and row > 0 then
      -- Ensure row is valid
      row = math.max(0, math.min(line_count - 1, row))
    end
    errors_by_line[row] = errors_by_line[row] and (errors_by_line[row] .. ' | ' .. error_msg) or error_msg
  end
end

--- Apply collected outputs and errors as extmarks.
---Stale/current-run validity is checked inside the scheduled callback so a
---run that becomes stale between scheduling and rendering cannot publish.
---@param buf integer
---@param namespace integer
---@param outputs_by_line table
---@param errors_by_line table
---@param is_current? fun(): boolean guard; when provided and returns false, rendering is skipped
function M.apply_extmarks(buf, namespace, outputs_by_line, errors_by_line, is_current)
  local hl_stdout = config.cfg.highlights.stdout
  local hl_stderr = config.cfg.highlights.stderr
  vim.schedule(function()
    if type(is_current) == 'function' then
      local ok, current = pcall(is_current)
      if not ok or not current then
        return
      end
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    for row, output in pairs(outputs_by_line) do
      local is_error = output:match 'ItchyError'
      local cleaned_output = is_error and output:gsub('ItchyError: ', '') or output
      local hl_group = is_error and hl_stderr or hl_stdout
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        virt_lines = { { { '  │ ', hl_group }, { cleaned_output, hl_group } } },
      })
    end

    for row, err_msg in pairs(errors_by_line) do
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        virt_lines = { { { '  │ ', hl_stderr }, { err_msg, hl_stderr } } },
      })
    end
  end)
end

--- Setup snacks integration for a specific filetype.
---@param ft string
function M.setup_snacks_for_ft(ft)
  local snacks = package.loaded['snacks'] and package.loaded['snacks'].config
  if not (config.cfg.integrations.snacks and snacks) then
    return
  end

  local snacks_opts = { scratch = { win_by_ft = {} } }
  snacks_opts.scratch.win_by_ft[ft] = {
    keys = {
      ['clear'] = {
        config.cfg.integrations.snacks.keys.clear,
        function(self)
          require('itchy').clear(self.buf)
        end,
        desc = 'Clear',
        mode = { 'n', 'x' },
      },
      ['run'] = {
        config.cfg.integrations.snacks.keys.run,
        function(self)
          require('itchy').run(self.buf)
        end,
        desc = 'Run code',
        mode = { 'n', 'x' },
      },
    },
  }

  snacks:merge(snacks_opts)

  if config.cfg.debug_mode then
    vim.notify('Added snacks integration for filetype: ' .. ft, vim.log.levels.DEBUG, { title = 'itchy' })
  end
end

return M
