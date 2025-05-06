local M = {}

local config = require 'itchy.config'

M.runtimes = {}

---@class itchy.Runtime
---@field cmd string
---@field args string[]
---@field offset integer
---@field wrapper fun(code: string, offset?: integer): string
---@field temp_file? boolean
---@field env? table<string, string>

--- Get the runtime config by filetype and name
---@param ft string
---@param name? string
---@return itchy.Runtime?, string?
function M.get_runtime(ft, name)
  if not M.runtimes[ft] then
    return nil, string.format('No runtimes available for %s', ft)
  end

  -- Use the specified runtime or the first available one
  name = name or config.cfg.defaults[ft]
  local runtime
  if name and M.runtimes[ft][name] then
    runtime = M.runtimes[ft][name]
  elseif not name then
    for _, rt in pairs(M.runtimes[ft]) do
      runtime = rt
      break
    end
  else
    return nil, string.format('Runtime %s not found for %s', name, ft)
  end

  return runtime, nil
end

--- Create a runtime configuration
---@param ft string
---@param cmd string
---@param args string[]
---@param offset? integer
---@param temp_file? boolean
---@param env? table<string, string>
function M.create_runtime(ft, cmd, args, offset, temp_file, env)
  if vim.fn.executable(cmd) ~= 1 then
    return nil
  end

  return {
    cmd = cmd,
    args = args,
    offset = offset or 0,
    wrapper = function(code, wrapper_offset)
      return require('itchy.wrappers').create_wrapper(ft, code, wrapper_offset)
    end,
    temp_file = temp_file or false,
    env = env or {},
  }
end

-- Helper function to find the primary python executable ('python' or 'python3')
local function get_python_runtime()
  local cmd
  if vim.fn.executable 'python' == 1 then
    cmd = 'python'
  elseif vim.fn.executable 'python3' == 1 then
    cmd = 'python3'
  end

  if cmd then
    return M.create_runtime('python', cmd, { '-c' }, 26)
  end
  return nil
end

---@type table<string, itchy.Runtime[]>
M.available_runtimes = {
  go = {
    go = M.create_runtime('go', 'go', { 'run' }, 0, true, { GO111MODULE = 'off' }),
  },
  javascript = {
    bun = M.create_runtime('javascript', 'bun', { 'run' }, 0, true),
    deno = M.create_runtime('javascript', 'deno', { 'eval' }),
    node = M.create_runtime('javascript', 'node', { '-e' }),
  },
  typescript = {
    bun = M.create_runtime('typescript', 'bun', { 'run' }, 0, true),
    deno = M.create_runtime('typescript', 'deno', { 'eval', '--ext=ts' }),
    node = M.create_runtime('typescript', 'node', { '--no-warnings', '-e' }),
  },
  python = {
    python = get_python_runtime(),
    uv = M.create_runtime('python', 'uv', { 'run', 'python', '-c' }, 26),
  },
  -- shell command runtimes
  bash = {
    bash = M.create_runtime('bash', 'bash', { '-c' }),
  },
  zsh = {
    zsh = M.create_runtime('zsh', 'zsh', { '-c' }),
  },
  sh = {
    sh = M.create_runtime('sh', 'sh', { '-c' }),
  },
  -- windows shell runtimes
  dosbatch = {
    cmd = M.create_runtime('dosbatch', 'cmd', { '/c' }),
  },
  ps1 = {
    pwsh = M.create_runtime('ps1', 'pwsh', { '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' }),
    powershell = M.create_runtime('ps1', 'powershell', { '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' }),
  },
}

--- Remove nil runtimes (from missing executables)
function M.load_runtimes()
  for ft, runtimes in pairs(M.available_runtimes) do
    for name, runtime in pairs(runtimes) do
      if runtime and vim.fn.executable(runtime.cmd) == 1 then
        M.runtimes[ft] = M.runtimes[ft] or {}
        M.runtimes[ft][name] = runtime
      end
    end
  end
end

return M
