---@class itchy
local M = {}

local config = require 'itchy.config'
local runtimes = require 'itchy.runtimes'
local utils = require 'itchy.utils'
local uv = vim.uv or vim.loop

---@param opts? itchy.Opts
function M.setup(opts)
  if M.did_setup then
    return vim.notify('itchy.nvim is already setup', vim.log.levels.ERROR, { title = 'itchy' })
  end
  M.did_setup = true

  config.cfg = vim.tbl_deep_extend('force', config.cfg, opts or {})

  -- If user provides custom runtimes, ensure they are correctly merged
  -- even if the runtime isn't loaded yet
  if config.cfg.runtimes then
    for ft, ft_runtimes in pairs(config.cfg.runtimes) do
      -- Initialize filetype entry if it doesn't exist
      runtimes.runtimes[ft] = runtimes.runtimes[ft] or {}

      for name, runtime_opts in pairs(ft_runtimes) do
        -- If the runtime already exists, merge with user options
        if runtimes.runtimes[ft][name] then
          runtimes.runtimes[ft][name] = vim.tbl_deep_extend('force', runtimes.runtimes[ft][name], runtime_opts)
        -- If it's in available_runtimes but not loaded yet, load it and then merge
        elseif runtimes.available_runtimes[ft] and runtimes.available_runtimes[ft][name] then
          local available_runtime = vim.deepcopy(runtimes.available_runtimes[ft][name])
          if available_runtime and vim.fn.executable(available_runtime.cmd) == 1 then
            runtimes.runtimes[ft][name] = vim.tbl_deep_extend('force', available_runtime, runtime_opts)
          end
        -- If it's a completely new user-defined runtime, add it directly
        else
          runtimes.runtimes[ft][name] = runtime_opts
        end
      end
    end
  end

  require 'itchy.commands'

  local augroup = vim.api.nvim_create_augroup('itchy_lazy_load', { clear = true })

  local supported_fts = {}
  for ft, _ in pairs(runtimes.available_runtimes) do
    supported_fts[ft] = true
  end

  if config.cfg.integrations.snacks and package.loaded['snacks'] then
    local snacks = package.loaded['snacks'].config
    local snacks_lua_opts = { scratch = { win_by_ft = {} } }
    snacks_lua_opts.scratch.win_by_ft['lua'] = {
      keys = {
        ['clear'] = {
          '<BS>',
          function(self)
            local ns_id = vim.api.nvim_get_namespaces()['snacks_debug']
            vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
          end,
          desc = 'Clear',
          mode = { 'n', 'x' },
        },
      },
    }
    snacks:merge(snacks_lua_opts)

    -- Set up initial runtimes that are already loaded
    for ft, _ in pairs(runtimes.runtimes) do
      utils.setup_snacks_for_ft(ft)
    end
  end

  -- Create autocmd to preload runtime when entering a buffer with supported filetype
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = vim.tbl_keys(supported_fts),
    callback = function(event)
      local ft = vim.bo[event.buf].filetype
      vim.defer_fn(function()
        if runtimes.available_runtimes[ft] then
          runtimes.runtimes[ft] = runtimes.runtimes[ft] or {}
          local loaded_runtime = false

          for name, runtime in pairs(runtimes.available_runtimes[ft]) do
            if runtime and not runtimes.runtimes[ft][name] then
              runtimes.runtimes[ft][name] = runtime
              loaded_runtime = true
              if config.cfg.debug_mode then
                vim.notify('Loaded runtime for ' .. ft .. ': ' .. name, vim.log.levels.DEBUG, { title = 'itchy' })
              end
            end
          end

          -- Update snacks integration if we loaded a runtime
          if loaded_runtime then
            utils.setup_snacks_for_ft(ft)
          end
        end
      end, 100)
    end,
  })
end

--- Run evaluation of a buffer.
--- Shows the output of logs and errors inlined with the code.
---@param rt? string
---@param buf? integer
function M.run(rt, buf)
  if type(rt) == 'number' and not buf then
    buf = rt
    rt = nil
  end

  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype

  -- snacks.nvim fallback for lua
  if ft == 'lua' and config.cfg.integrations.snacks and package.loaded['snacks'] then
    local snacks = package.loaded['snacks']
    snacks.debug.run()
    return
  end

  local runtime, error = runtimes.get_runtime(ft, rt)
  if error then
    return vim.notify(error, vim.log.levels.ERROR)
  end
  assert(runtime ~= nil)

  local namespace = vim.api.nvim_create_namespace('itchy_' .. ft .. '_result')
  local function clear()
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
  clear()

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = vim.api.nvim_create_augroup('itchy_debug_run_' .. buf, { clear = true }),
    buffer = buf,
    callback = clear,
  })
  local code
  local mode = vim.fn.mode()
  local line_mapping = {}

  ---@attribution @folke https://github.com/folke/snacks.nvim/blob/main/lua/snacks/debug.lua#L82C3-L101C7
  if mode:find '[vV]' then
    if mode == 'v' then
      vim.cmd 'normal! v'
    elseif mode == 'V' then
      vim.cmd 'normal! V'
    end
    local from = vim.api.nvim_buf_get_mark(buf, '<')
    local to = vim.api.nvim_buf_get_mark(buf, '>')

    local col_to = math.min(to[2] + 1, #vim.api.nvim_buf_get_lines(buf, to[1] - 1, to[1], false)[1])

    local text = vim.api.nvim_buf_get_text(buf, from[1] - 1, from[2], to[1] - 1, col_to, {})
    code = table.concat(text, '\n')
    code = string.rep('\n', from[1] - 1) .. code
    vim.fn.feedkeys('gv', 'nx')
  else
    code = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, true), '\n')
  end

  local wrapped_code = utils.get_wrapped_code(runtime, code)

  local line_count = vim.api.nvim_buf_line_count(buf)
  local outputs_by_line = {}
  local errors_by_line = {}

  if runtime.temp_file then
    local stdout_file, stderr_file, code_file = utils.create_temp_file(ft, wrapped_code)

    local shell, shell_arg, command_str

    if utils.is_windows() then
      shell = 'cmd.exe'
      shell_arg = '/C'
    else
      shell = 'sh'
      shell_arg = '-c'
    end

    command_str = string.format(
      '%s %s %s "%s" > "%s" 2> "%s"',
      runtime.env and table.concat(runtime.env, ' ') or '',
      runtime.cmd,
      table.concat(runtime.args, ' '),
      code_file,
      stdout_file,
      stderr_file
    )

    local handle
    ---@diagnostic disable-next-line: missing-fields
    handle = uv.spawn(shell, { args = { shell_arg, command_str }, cwd = vim.fn.getcwd() }, function()
      for line in io.lines(stdout_file) do
        utils.process_output(line, outputs_by_line, line_count, line_mapping)
      end
      for line in io.lines(stderr_file) do
        utils.process_error(line, errors_by_line, ft, line_count, line_mapping)
      end

      utils.apply_extmarks(buf, namespace, outputs_by_line, errors_by_line)

      os.remove(code_file)
      os.remove(stdout_file)
      os.remove(stderr_file)

      if handle then
        handle:close()
      end
    end)

    if not handle then
      vim.notify('Failed to spawn process', vim.log.levels.ERROR)
      return
    end
  else
    local stdout_handle = uv.new_pipe(false)
    local stderr_handle = uv.new_pipe(false)

    local args = vim.deepcopy(runtime.args)
    table.insert(args, wrapped_code)

    if runtime.env then
      for key, value in pairs(runtime.env) do
        vim.fn.setenv(key, value)
      end
    end

    local handle
    ---@diagnostic disable-next-line: missing-fields
    handle = uv.spawn(runtime.cmd, {
      args = args,
      cwd = vim.fn.getcwd(),
      stdio = { nil, stdout_handle, stderr_handle },
      hide = true,
    }, function()
      utils.apply_extmarks(buf, namespace, outputs_by_line, errors_by_line)

      if stdout_handle then
        stdout_handle:read_stop()
        stdout_handle:close()
      end

      if stderr_handle then
        stderr_handle:read_stop()
        stderr_handle:close()
      end

      if handle then
        handle:close()
      end
    end)

    if not handle then
      vim.notify('Failed to spawn process', vim.log.levels.ERROR)
      return
    end

    if stdout_handle then
      stdout_handle:read_start(utils.create_stream_handler(function(line)
        utils.process_output(line, outputs_by_line, line_count, line_mapping)
      end))
    end

    if stderr_handle then
      stderr_handle:read_start(utils.create_stream_handler(function(line)
        utils.process_error(line, errors_by_line, ft, line_count, line_mapping)
      end))
    end
  end
end

--- Clear extmarks from the buffer.
---@param buf? integer
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  local namespaces = vim.api.nvim_get_namespaces()
  local ns_id = namespaces['itchy_' .. ft .. '_result']
  if not ns_id then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

--- Print available runtimes for the current buffer.
---@param cmd? boolean
---@param buf? integer
---@return string[]?
function M.list(cmd, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  local runtime_keys = {}

  for key, _ in pairs(runtimes.runtimes[ft] or {}) do
    table.insert(runtime_keys, key)
  end

  if cmd then
    return runtime_keys
  end

  if #runtime_keys > 0 then
    vim.notify('Available ' .. ft .. ' runtimes:\n' .. table.concat(runtime_keys, '\n'), vim.log.levels.INFO, { title = 'itchy' })
  else
    vim.notify('No ' .. ft .. ' runtimes found', vim.log.levels.INFO, { title = 'itchy' })
  end
end

--- Print current runtime for the current buffer.
---@param buf? integer
function M.current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype

  local runtime, error = runtimes.get_runtime(ft)
  if error then
    return vim.notify(error, vim.log.levels.ERROR)
  end

  if not runtime then
    return vim.notify('No ' .. ft .. ' runtime found', vim.log.levels.INFO, { title = 'itchy' })
  end
  vim.notify('Current ' .. ft .. ' runtime: ' .. runtime.cmd, vim.log.levels.INFO, { title = 'itchy' })
end

--- Get all available runtimes.
---@return table<string, itchy.Runtime[]>
function M.get_runtimes()
  runtimes.load_runtimes()
  return runtimes.runtimes or {}
end

return M
