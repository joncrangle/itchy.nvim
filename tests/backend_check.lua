-- Backend consistency + smoke check. Version-agnostic: asserts the selected
-- backend matches the detected capability (async on 0.13+, system below),
-- then runs one real execution end-to-end through the coordinator.
-- Run with: nvim --headless --noplugin -u NONE --cmd "set rtp+=." -l tests/backend_check.lua
vim.opt.rtp:prepend('.')
local executor = require('itchy.executor')
local supports = executor.supports_vim_async()
local backend = executor.backend_name()
print('nvim-0.13: ' .. tostring(vim.fn.has('nvim-0.13')))
print('supports_vim_async: ' .. tostring(supports))
print('backend: ' .. tostring(backend))
local expected = supports and 'itchy.executor.async' or 'itchy.executor.system'
assert(backend == expected, 'expected backend ' .. expected .. ', got: ' .. tostring(backend))
local ok, mod = pcall(require, backend)
assert(ok and type(mod.execute) == 'function', 'selected backend failed to load: ' .. backend)

-- Probe command uses Neovim itself: present on every runner/OS.
local probe_cmd = { vim.v.progpath, '--version' }

local sync_ok, sync_res = pcall(function()
  return vim.system(probe_cmd, { text = true }):wait()
end)
assert(sync_ok and sync_res ~= nil, 'vim.system probe failed: ' .. tostring(sync_res))
print('system keys: ' .. vim.inspect(vim.tbl_keys(sync_res)))
assert(
  type(sync_res.stdout) == 'string' and sync_res.stdout:find('NVIM', 1, true) ~= nil,
  'unexpected vim.system stdout shape: ' .. vim.inspect(sync_res.stdout)
)

local done = false
local cb_err, cb_res = nil, nil
executor.execute({ cmd = probe_cmd, cwd = vim.fn.getcwd() }, function(err, res)
  cb_err, cb_res = err, res
  done = true
end)
local finished = vim.wait(15000, function()
  return done
end, 50)
assert(finished, 'backend execution timed out')
assert(cb_err == nil, 'backend execution failed: ' .. tostring(cb_err))
assert(
  cb_res ~= nil and type(cb_res.stdout) == 'string' and cb_res.stdout:find('NVIM', 1, true) ~= nil,
  'unexpected backend stdout: ' .. vim.inspect(cb_res and cb_res.stdout)
)
print('backend_check: OK (' .. backend .. ' selected and executed)')
