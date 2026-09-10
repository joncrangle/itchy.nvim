local M = {}

local config = require 'itchy.config'

M.runtimes = {}

---@class itchy.Runtime
---@field cmd string
---@field args? string[]
---@field adapter string|itchy.RuntimeAdapter adapter name or custom adapter module
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
---@param cmd string
---@param args? string[]
---@param adapter string|itchy.RuntimeAdapter
---@param temp_file? boolean
---@param env? table<string, string>
---@return itchy.Runtime?
function M.create_runtime(cmd, args, adapter, temp_file, env)
  if vim.fn.executable(cmd) ~= 1 then
    return nil
  end

  return {
    cmd = cmd,
    args = args,
    adapter = adapter,
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
    return M.create_runtime(cmd, { '-c' }, 'python')
  end
  return nil
end

---@type table<string, table<string, itchy.Runtime?>>
M.available_runtimes = {
  go = {
    go = M.create_runtime('go', { 'run' }, 'go', true, { GO111MODULE = 'off' }),
  },
  javascript = {
    bun = M.create_runtime('bun', { 'run' }, 'javascript', true),
    deno = M.create_runtime('deno', { 'eval' }, 'javascript', false),
    node = M.create_runtime('node', { '-e' }, 'javascript', false),
  },
  typescript = {
    bun = M.create_runtime('bun', { 'run' }, 'javascript', true),
    deno = M.create_runtime('deno', { 'eval', '--ext=ts' }, 'javascript', false),
    node = M.create_runtime('node', { '-e' }, 'javascript', false),
  },
  python = {
    python = get_python_runtime(),
    uv = M.create_runtime('uv', { 'run', 'python', '-c' }, 'python'),
  },
  bash = {
    bash = M.create_runtime('bash', {}, 'bash'),
  },
  zsh = {
    -- Do not let a user's zshrc alter the fixture's options, aliases, or
    -- error handling. The adapter supplies its own launcher and source file.
    zsh = M.create_runtime('zsh', { '-f' }, 'zsh'),
  },
  sh = {
    sh = M.create_runtime('sh', {}, 'sh'),
  },
  ps1 = {
    -- -ExecutionPolicy Bypass permits temp scripts to execute under Windows defaults.
    pwsh = M.create_runtime('pwsh', { '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command' }, 'powershell'),
    powershell = M.create_runtime('powershell', { '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command' }, 'powershell'),
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
