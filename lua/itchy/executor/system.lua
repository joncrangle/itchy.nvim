--- Callback-based vim.system backend for Neovim < 0.13.
---No reference to vim.async; safe on Neovim 0.11+.
local M = {}

M.name = 'itchy.executor.system'

---@param request itchy.ExecutionRequest
---@param callback fun(err: any?, result: itchy.ExecutionResult?)
---@return itchy.ExecutionHandle
function M.execute(request, callback)
  local cancelled = false
  local completed = false
  ---@type vim.SystemObj?
  local process = nil

  local handle = {}

  function handle:cancel()
    if completed or cancelled then
      return
    end
    cancelled = true
    if process then
      pcall(function()
        process:kill('sigterm')
      end)
    end
  end

  function handle:is_running()
    return not completed and not cancelled
  end

  local function finish(err, result)
    if completed then
      return
    end
    completed = true
    -- Even after cancellation vim.system still invokes on_exit. Forward it;
    -- callers enforce latest-run-wins via generation checks, so a stale
    -- completion can never publish. Cancellation itself never notifies.
    if cancelled then
      -- Invoke callback so callers with cleanup-once guards can release
      -- resources, but mark cancellation explicitly.
      callback('cancelled', nil)
      return
    end
    callback(err, result)
  end

  local opts = {
    cwd = request.cwd,
    text = true,
  }
  if request.env and next(request.env) ~= nil then
    opts.env = request.env
  end

  local ok, obj_or_err = pcall(vim.system, request.cmd, opts, function(result)
    vim.schedule(function()
      finish(nil, {
        code = result.code,
        signal = result.signal,
        stdout = result.stdout or '',
        stderr = result.stderr or '',
      })
    end)
  end)

  if not ok then
    vim.schedule(function()
      finish(obj_or_err, nil)
    end)
  else
    process = obj_or_err
    -- Spawned but cancelled synchronously before SystemObj assignment.
    if cancelled and process then
      pcall(function()
        process:kill('sigterm')
      end)
    end
  end

  return handle
end

return M
