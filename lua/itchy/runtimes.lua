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

--- Create a runtime configuration (checks executable availability)
---@param ft string
---@param cmd string
---@param args string[]
---@param offset? integer
---@param temp_file? boolean
---@param env? table<string, string>
---@return itchy.Runtime?
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

---@class itchy.RuntimeSpec
---@field ft string
---@field cmd string|string[] Command name(s) to check (first available is used)
---@field args string[]
---@field offset? integer
---@field temp_file? boolean
---@field env? table<string, string>

-- Runtime specifications (deferred - executable check happens in load_runtimes)
---@type table<string, table<string, itchy.RuntimeSpec>>
local runtime_specs = {
  go = {
    go = { ft = 'go', cmd = 'go', args = { 'run' }, offset = 0, temp_file = true, env = { GO111MODULE = 'off' } },
  },
  javascript = {
    bun = { ft = 'javascript', cmd = 'bun', args = { 'run' }, offset = 0, temp_file = true },
    deno = { ft = 'javascript', cmd = 'deno', args = { 'eval' } },
    node = { ft = 'javascript', cmd = 'node', args = { '-e' } },
  },
  typescript = {
    bun = { ft = 'typescript', cmd = 'bun', args = { 'run' }, offset = 0, temp_file = true },
    deno = { ft = 'typescript', cmd = 'deno', args = { 'eval', '--ext=ts' } },
    node = { ft = 'typescript', cmd = 'node', args = { '--no-warnings', '-e' } },
  },
  python = {
    python = { ft = 'python', cmd = { 'python', 'python3' }, args = { '-c' }, offset = 26 },
    uv = { ft = 'python', cmd = 'uv', args = { 'run', 'python', '-c' }, offset = 26 },
  },
  -- shell command runtimes
  bash = {
    bash = { ft = 'bash', cmd = 'bash', args = { '-c' } },
  },
  zsh = {
    zsh = { ft = 'zsh', cmd = 'zsh', args = { '-c' } },
  },
  sh = {
    sh = { ft = 'sh', cmd = 'sh', args = { '-c' } },
  },
  -- windows shell runtimes
  dosbatch = {
    cmd = { ft = 'dosbatch', cmd = 'cmd', args = { '/c' } },
  },
  ps1 = {
    pwsh = { ft = 'ps1', cmd = 'pwsh', args = { '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' } },
    powershell = { ft = 'ps1', cmd = 'powershell', args = { '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' } },
  },
}

-- Keep available_runtimes for backwards compatibility (now contains RuntimeSpec, not Runtime)
-- Note: This is for reference only. Use M.runtimes after calling load_runtimes() for actual runtime objects.
M.available_runtimes = runtime_specs

--- Load runtimes by checking executable availability at call time.
--- This resets M.runtimes to allow re-detection of newly installed executables.
function M.load_runtimes()
  M.runtimes = {} -- Reset to allow re-detection
  for ft, specs in pairs(runtime_specs) do
    for name, spec in pairs(specs) do
      -- Handle cmd as string or array of strings (for fallback like python/python3)
      local cmds = type(spec.cmd) == 'table' and spec.cmd or { spec.cmd }
      for _, cmd in ipairs(cmds) do
        if vim.fn.executable(cmd) == 1 then
          M.runtimes[ft] = M.runtimes[ft] or {}
          M.runtimes[ft][name] = {
            cmd = cmd,
            args = spec.args,
            offset = spec.offset or 0,
            wrapper = function(code, wrapper_offset)
              return require('itchy.wrappers').create_wrapper(spec.ft, code, wrapper_offset)
            end,
            temp_file = spec.temp_file or false,
            env = spec.env or {},
          }
          break -- Use first available command
        end
      end
    end
  end
end

return M
