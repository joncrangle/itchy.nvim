--- Neovim 0.13+ backend using vim.async structured concurrency.
---This module is required only after itchy.executor.supports_vim_async()
---passes, so referencing vim.async here never runs on Neovim 0.11/0.12.
local M = {}

M.name = 'itchy.executor.async'

---@param request itchy.ExecutionRequest
---@param callback fun(err: any?, result: itchy.ExecutionResult?)
---@return itchy.ExecutionHandle
function M.execute(request, callback)
  local async = vim.async

  local cancelled = false
  local completed = false
  ---@type vim.SystemObj?
  local sys_obj = nil
  ---@type vim.async.Task?
  local task = nil

  local state = {
    closing = false,
    exited = false,
    done = false,
    result = nil,
    resolve = nil,
    ---@type fun()[]
    close_cbs = {},
  }

  local function drain_close_cbs()
    local cbs = state.close_cbs
    state.close_cbs = {}
    for _, cb in ipairs(cbs) do
      pcall(cb)
    end
  end

  -- Both backends share one callback contract, invoked exactly once:
  -- (nil, result) on success, ('cancelled', nil) on cancellation,
  -- (err, nil) on spawn/backend failure. Callers suppress stale results
  -- and stay silent on 'cancelled', so normal cancellation never notifies.
  local function finish_once(err, result)
    if completed then
      return
    end
    completed = true
    if cancelled or state.closing then
      callback('cancelled', nil)
      return
    end
    if err then
      callback(err, nil)
    else
      callback(nil, result)
    end
  end

  -- Process exit is observed here, but resumption and close-completion run
  -- on the main loop: vim.system may invoke on_exit in a fast-event
  -- context, where resuming the task coroutine would fail and strand the
  -- task (and its temp files) forever.
  local function raw_on_exit(res)
    if state.exited then
      return
    end
    state.exited = true
    state.result = res
    vim.schedule(function()
      if state.done then
        return
      end
      state.done = true
      if state.closing then
        drain_close_cbs()
        return
      end
      local resolve = state.resolve
      state.resolve = nil
      if resolve then
        resolve(res)
      end
    end)
  end

  -- Closable adapter: Task:close() closes this while the task is suspended
  -- in vim.async.await(). Race-safe for immediate exit, immediate cancel,
  -- near-simultaneous exit/cancel, and repeated close().
  local function make_closable()
    return {
      is_closing = function()
        return state.closing
      end,
      close = function(_, cb)
        if cb then
          table.insert(state.close_cbs, cb)
        end
        if not state.closing then
          state.closing = true
          cancelled = true
          if sys_obj and not state.exited then
            pcall(function()
              sys_obj:kill('sigterm')
            end)
          end
        end
        if state.exited then
          -- Process already gone; unblock the closer now. The scheduled
          -- on_exit body re-checks flags and stays silent.
          drain_close_cbs()
        end
      end,
    }
  end

  local handle = {}

  function handle:cancel()
    if completed or cancelled then
      return
    end
    cancelled = true
    state.closing = true
    if task then
      pcall(function()
        task:close()
      end)
    end
    if sys_obj and not state.exited then
      pcall(function()
        sys_obj:kill('sigterm')
      end)
    end
  end

  function handle:is_running()
    if completed or cancelled then
      return false
    end
    if task == nil then
      return false
    end
    local ok, done = pcall(function()
      return task:completed()
    end)
    if ok then
      return not done
    end
    return true
  end

  -- Spawn outside the task: a spawn failure is reported through the normal
  -- callback instead of thrown from inside the await callback, where the
  -- task machinery could strand it.
  local spawn_ok, obj_or_err = pcall(vim.system, request.cmd, {
    cwd = request.cwd,
    env = request.env and next(request.env) ~= nil and request.env or nil,
    text = true,
  }, raw_on_exit)

  if not spawn_ok then
    local spawn_err = obj_or_err
    vim.schedule(function()
      finish_once(spawn_err, nil)
    end)
    return handle
  end

  sys_obj = obj_or_err
  -- Cancellation arrived synchronously during spawn.
  if state.closing and sys_obj then
    pcall(function()
      sys_obj:kill('sigterm')
    end)
  end

  -- Suspend without blocking; never use SystemObj:wait() here.
  local task_ok, task_or_err = pcall(async.run, function()
    local result = async.await(function(resolve)
      if state.closing then
        -- Cancelled before awaiting; the runtime closes our closable.
      elseif state.done then
        resolve(state.result)
      else
        state.resolve = resolve
      end
      return make_closable()
    end)
    return result
  end)

  if not task_ok then
    local task_err = task_or_err
    if sys_obj and not state.exited then
      pcall(function()
        sys_obj:kill('sigterm')
      end)
    end
    vim.schedule(function()
      finish_once(task_err, nil)
    end)
    return handle
  end

  task = task_or_err
  task:on_complete(function(err, result)
    if cancelled or state.closing then
      -- Closed before producing a result: report cancellation like the
      -- fallback backend so callers observe one shared contract.
      finish_once('cancelled', nil)
      return
    end
    if err then
      finish_once(err, nil)
      return
    end
    if result == nil then
      finish_once('cancelled', nil)
      return
    end
    finish_once(nil, {
      code = result.code,
      signal = result.signal,
      stdout = result.stdout or '',
      stderr = result.stderr or '',
    })
  end)

  return handle
end

return M
