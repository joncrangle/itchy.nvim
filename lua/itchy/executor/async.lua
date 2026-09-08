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

  local state = {
    closing = false,
    done = false,
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
          if state.done then
            pcall(cb)
            return
          end
          table.insert(state.close_cbs, cb)
        end
        if state.done then
          return
        end
        if not state.closing then
          state.closing = true
          cancelled = true
          if sys_obj then
            pcall(function()
              sys_obj:kill('sigterm')
            end)
          end
        end
        if state.done and cb then
          -- on_exit already ran between the checks above.
          drain_close_cbs()
        end
      end,
    }
  end

  local task = async.run(function()
    -- Suspend without blocking; never use SystemObj:wait() here.
    local result = async.await(function(resolve)
      local closable = make_closable()

      local ok, obj_or_err = pcall(
        vim.system,
        request.cmd,
        {
          cwd = request.cwd,
          env = request.env and next(request.env) ~= nil and request.env or nil,
          text = true,
        },
        function(res)
          if state.done then
            return
          end
          state.done = true
          if state.closing then
            -- Cancelled: let the task report "closed" instead of the
            -- killed-process result; unblock Task:close().
            drain_close_cbs()
            return
          end
          resolve(res)
          -- If close() arrived between resolve and now, unblock it.
          if state.closing then
            drain_close_cbs()
          end
        end
      )

      if not ok then
        state.done = true
        error(obj_or_err, 0)
      end

      sys_obj = obj_or_err
      -- Cancellation arrived synchronously before SystemObj assignment.
      if state.closing and sys_obj then
        pcall(function()
          sys_obj:kill('sigterm')
        end)
      end

      return closable
    end)

    return result
  end)

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

  local handle = {}

  function handle:cancel()
    if completed or cancelled then
      return
    end
    cancelled = true
    state.closing = true
    pcall(function()
      task:close()
    end)
    if sys_obj and not state.done then
      pcall(function()
        sys_obj:kill('sigterm')
      end)
    end
  end

  function handle:is_running()
    if completed or cancelled then
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

  return handle
end

return M
