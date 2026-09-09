---@class itchy
local M = {}

local config = require 'itchy.config'
local runtimes = require 'itchy.runtimes'
local utils = require 'itchy.utils'
local executor = require 'itchy.executor'
local adapters = require 'itchy.adapters'
local renderer = require 'itchy.renderer'

---@class itchy.ActiveRun
---@field id integer generation
---@field buf integer owning buffer
---@field handle itchy.ExecutionHandle|nil
---@field temp_file? string source tempfile to clean exactly once
---@field cleaned boolean whether temp resources were released
---@field cancelled boolean whether the run was superseded/cleared
---@field namespace integer result namespace
---@field ft string filetype
---@field prepared? itchy.PreparedExecution adapter execution request
---@field adapter_cleaned? boolean whether prepared.cleanup ran

---@type table<integer, itchy.ActiveRun>
local active_runs = {}
local next_run_id = 0
---@type table<integer, boolean>
local lifecycle_attached = {}

-- Test-only introspection (not public API).
M._active_runs = active_runs
M._executor = executor

---@param run itchy.ActiveRun
local function cleanup_run_resources(run)
  if run.cleaned then
    return
  end
  run.cleaned = true
  if run.temp_file then
    utils.remove_temp_file(run.temp_file)
  end
end

--- Exactly-once adapter cleanup, analogous to cleanup_run_resources().
--- PreparedExecution.cleanup is part of the adapter contract (#11); future
--- adapters (e.g. JS/Python helper preload/temp resources) may allocate
--- there, so every terminal run path must release it even when the run is
--- stale, cancelled, invalid, or fails before rendering.
---@param run itchy.ActiveRun
local function cleanup_prepared(run)
  if run.adapter_cleaned then
    return
  end
  run.adapter_cleaned = true
  local prepared = run.prepared
  if prepared and prepared.cleanup then
    pcall(prepared.cleanup)
  end
end

function M._reset_runs()
  for _, run in pairs(active_runs) do
    if run.handle then
      pcall(function()
        run.handle:cancel()
      end)
    end
    cleanup_run_resources(run)
    cleanup_prepared(run)
  end
  for k in pairs(active_runs) do
    active_runs[k] = nil
  end
  for k in pairs(lifecycle_attached) do
    lifecycle_attached[k] = nil
  end
end

---@param run itchy.ActiveRun
---@return boolean
local function is_current_run(run)
  local current = active_runs[run.buf]
  return current ~= nil and current.id == run.id and not run.cancelled
end

M._is_current_run = is_current_run

---@param buf integer
---@param clear_namespace? boolean
local function invalidate_run(buf, clear_namespace)
  local run = active_runs[buf]
  if run then
    run.cancelled = true
    if run.handle then
      pcall(function()
        run.handle:cancel()
      end)
    end
    cleanup_run_resources(run)
    cleanup_prepared(run)
    active_runs[buf] = nil
  end
  if clear_namespace then
    if vim.api.nvim_buf_is_valid(buf) then
      if run and run.namespace then
        -- Clear the namespace the run actually rendered into, not the
        -- buffer's live filetype (which may have changed since the run).
        pcall(vim.api.nvim_buf_clear_namespace, buf, run.namespace, 0, -1)
      else
        -- Idle clear with no active run: fall back to the live filetype.
        local ft = vim.bo[buf].filetype
        local ns_id = vim.api.nvim_get_namespaces()['itchy_' .. ft .. '_result']
        if ns_id then
          pcall(vim.api.nvim_buf_clear_namespace, buf, ns_id, 0, -1)
        end
      end
    end
  end
end

M._invalidate_run = invalidate_run

---@param buf integer
local function ensure_lifecycle(buf)
  if lifecycle_attached[buf] then
    return
  end
  lifecycle_attached[buf] = true
  local group = vim.api.nvim_create_augroup('itchy_lifecycle_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      invalidate_run(buf, true)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = group,
    buffer = buf,
    callback = function()
      invalidate_run(buf, false)
      lifecycle_attached[buf] = nil
    end,
  })
end

--- Load executable runtimes on demand. The FileType autocmd in setup()
--- populates runtimes asynchronously, so a :Itchy command issued before it
--- fires (or in a buffer whose FileType already fired) would otherwise see
--- an empty table. load_runtimes() is idempotent and re-checks executables.
---@param ft string
local function ensure_runtimes(ft)
  if not runtimes.runtimes[ft] or vim.tbl_count(runtimes.runtimes[ft]) == 0 then
    runtimes.load_runtimes()
  end
end

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
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ft = vim.bo[buf].filetype
  ensure_runtimes(ft)

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
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  local code
  local mode = vim.fn.mode()

  ---@attribution @folke https://github.com/folke/snacks.nvim/blob/main/lua/snacks/debug.lua#L82C3-L101C7
  -- Visual selections preserve original buffer lines by padding omitted
  -- leading lines with newlines, so runtime-reported lines map directly.
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

  local adapter = adapters.resolve(runtime)
  ---@type itchy.AdapterContext
  local adapter_ctx = {
    runtime = runtime,
    filetype = ft,
    source = code,
    buf = buf,
    cwd = vim.fn.getcwd(),
  }
  local prep_ok, prepared_or_err = pcall(adapter.prepare, adapter_ctx)
  if not prep_ok then
    vim.notify('itchy: failed to prepare execution: ' .. tostring(prepared_or_err), vim.log.levels.ERROR, { title = 'itchy' })
    return
  end
  local prepared = prepared_or_err

  -- Latest run wins: cancel any previous execution for this buffer.
  invalidate_run(buf, false)
  -- Re-clear after invalidation (invalidate with false keeps extmarks until now).
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, namespace, 0, -1)
  end

  -- Build argv without shell strings; preserves spaces/special chars.
  -- Adapters prepare source only; argv/env still come from the runtime
  -- unless a future adapter overrides them via PreparedExecution.
  local cmd = {}
  if prepared.cmd then
    for _, arg in ipairs(prepared.cmd) do
      table.insert(cmd, arg)
    end
  else
    table.insert(cmd, runtime.cmd)
    for _, arg in ipairs(runtime.args or {}) do
      table.insert(cmd, arg)
    end
  end

  local temp_file = nil
  local use_temp_file = prepared.temp_file
  if use_temp_file == nil then
    use_temp_file = runtime.temp_file
  end
  if use_temp_file then
    local path, terr = utils.create_temp_code_file(ft, prepared.source)
    if not path then
      if prepared.cleanup then
        pcall(prepared.cleanup)
      end
      vim.notify('itchy: failed to create temp file: ' .. tostring(terr), vim.log.levels.ERROR, { title = 'itchy' })
      return
    end
    temp_file = path
    table.insert(cmd, path)
  elseif not prepared.cmd then
    -- Legacy adapters hand back a wrapped source string to evaluate
    -- (`pwsh -Command "<wrapped>"`); structured adapters (go, powershell,
    -- python, javascript) return a complete argv in prepared.cmd whose
    -- sources already live in temp files. Appending the raw source there
    -- would add a stray multiline argv element (fragile quoting on
    -- Windows, confusing `$args`/`os.Args` on every OS).
    table.insert(cmd, prepared.source)
  end

  next_run_id = next_run_id + 1
  ---@type itchy.ActiveRun
  local run = {
    id = next_run_id,
    buf = buf,
    handle = nil,
    temp_file = temp_file,
    cleaned = false,
    cancelled = false,
    namespace = namespace,
    ft = ft,
    prepared = prepared,
    adapter_cleaned = false,
  }
  active_runs[buf] = run
  ensure_lifecycle(buf)

  local function complete_run(err, result)
    -- Stale results must never publish, even if the backend still invokes
    -- its callback after cancellation.
    if not is_current_run(run) then
      cleanup_run_resources(run)
      cleanup_prepared(run)
      return
    end
    if not vim.api.nvim_buf_is_valid(run.buf) then
      cleanup_run_resources(run)
      cleanup_prepared(run)
      active_runs[run.buf] = nil
      return
    end
    if err then
      cleanup_run_resources(run)
      cleanup_prepared(run)
      active_runs[run.buf] = nil
      if err == 'cancelled' then
        return
      end
      vim.notify('itchy: execution failed: ' .. tostring(err), vim.log.levels.ERROR, { title = 'itchy' })
      return
    end
    assert(result ~= nil)
    -- Non-zero exits still render stdout/stderr; the adapter normalizes
    -- runtime diagnostics into events and the generic renderer paints them.
    -- A throwing decoder must not break run cleanup: treat it as an
    -- ordinary pipeline failure.
    local decode_ok, events_or_err = pcall(adapter.decode, adapter_ctx, prepared, result)
    if not decode_ok then
      cleanup_run_resources(run)
      cleanup_prepared(run)
      active_runs[run.buf] = nil
      vim.notify('itchy: failed to decode execution result: ' .. tostring(events_or_err), vim.log.levels.ERROR, { title = 'itchy' })
      return
    end
    local events = events_or_err

    cleanup_run_resources(run)
    cleanup_prepared(run)
    -- Keep ownership through the scheduled render: renderer runs
    -- inside vim.schedule, so a clear/edit arriving between completion and
    -- rendering must still find this run to invalidate it. Releasing here
    -- would make that clear a no-op (nil entry) and let the pending render
    -- resurrect extmarks. Guard requires identity (nil fails); release runs
    -- one tick after render via FIFO vim.schedule ordering.
    local guard_buf = run.buf
    renderer.render(buf, namespace, events, {
      is_current = function()
        -- Decline rendering when superseded/cleared/invalid. Identity check
        -- covers superseded (different object), cleared-after-completion
        -- (nil entry), and cancelled-but-not-yet-replaced.
        if run.cancelled then
          return false
        end
        if active_runs[guard_buf] ~= run then
          return false
        end
        return vim.api.nvim_buf_is_valid(guard_buf)
      end,
    })
    vim.schedule(function()
      if active_runs[guard_buf] == run then
        active_runs[guard_buf] = nil
      end
    end)
  end

  local env = nil
  local prepared_env = prepared.env or runtime.env
  if prepared_env and next(prepared_env) ~= nil then
    env = prepared_env
  end

  local ok, handle_or_err = pcall(executor.execute, {
    cmd = cmd,
    cwd = vim.fn.getcwd(),
    env = env,
  }, complete_run)

  if not ok then
    cleanup_run_resources(run)
    cleanup_prepared(run)
    active_runs[buf] = nil
    vim.notify('itchy: failed to start execution: ' .. tostring(handle_or_err), vim.log.levels.ERROR, { title = 'itchy' })
    return
  end
  run.handle = handle_or_err
  if run.handle == nil then
    cleanup_run_resources(run)
    cleanup_prepared(run)
    active_runs[buf] = nil
    vim.notify('itchy: failed to spawn process', vim.log.levels.ERROR, { title = 'itchy' })
    return
  end
end

--- Clear extmarks from the buffer.
---@param buf? integer
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Cancel/invalidate active work so delayed completions cannot recreate
  -- virtual lines, then clear the namespace.
  invalidate_run(buf, true)
end

--- Print available runtimes for the current buffer.
---@param cmd? boolean
---@param buf? integer
---@return string[]?
function M.list(cmd, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  ensure_runtimes(ft)
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
  ensure_runtimes(ft)

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
