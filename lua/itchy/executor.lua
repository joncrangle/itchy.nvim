---@class itchy.ExecutionRequest
---@field cmd string[] argv, e.g. { 'node', '-e', '<code>' }
---@field cwd string working directory
---@field env? table<string, string> child-process environment additions

---@class itchy.ExecutionResult
---@field code integer exit code
---@field signal integer exit signal
---@field stdout string captured stdout (text mode)
---@field stderr string captured stderr (text mode)

---@class itchy.ExecutionHandle
---@field cancel fun(self: itchy.ExecutionHandle) terminate the execution; idempotent
---@field is_running fun(self: itchy.ExecutionHandle): boolean

---@class itchy.ExecutorBackend
---@field execute fun(request: itchy.ExecutionRequest, callback: fun(err: any?, result: itchy.ExecutionResult?)): itchy.ExecutionHandle
---@field name string

local M = {}

--- Test-only backend override. Keep private; do not expose as user config.
---@type string?
M._backend_override = nil

--- Whether the running Neovim can use the vim.async backend.
---Requires explicit 0.13+ plus the expected structured-concurrency API.
---@return boolean
function M.supports_vim_async()
  if vim.fn.has('nvim-0.13') ~= 1 then
    return false
  end
  if type(vim.async) ~= 'table' then
    return false
  end
  return type(vim.async.run) == 'function' and type(vim.async.await) == 'function'
end

---@return string backend module name in use (for tests/CI assertions)
function M.backend_name()
  if M._backend_override then
    return M._backend_override
  end
  if M.supports_vim_async() then
    return 'itchy.executor.async'
  end
  return 'itchy.executor.system'
end

local function load_backend()
  local name = M.backend_name()
  local ok, backend = pcall(require, name)
  if ok and backend and type(backend.execute) == 'function' then
    return backend
  end
  -- Defensive fallback: a dev/nightly reporting 0.13 without a usable
  -- vim.async implementation must not break plugin startup.
  if name ~= 'itchy.executor.system' then
    return require('itchy.executor.system')
  end
  return backend
end

---@param request itchy.ExecutionRequest
---@param callback fun(err: any?, result: itchy.ExecutionResult?)
---@return itchy.ExecutionHandle
function M.execute(request, callback)
  return load_backend().execute(request, callback)
end

return M
