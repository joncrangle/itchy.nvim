-- CI assertion: on Neovim 0.13-dev/nightly the vim.async backend must be selected.
-- Run with: nvim --headless --noplugin -u NONE --cmd "set rtp+=." -l tests/backend_check.lua
vim.opt.rtp:prepend('.')
local executor = require('itchy.executor')
local supports = executor.supports_vim_async()
local backend = executor.backend_name()
print('nvim: ' .. tostring(vim.fn.has('nvim-0.13')))
print('supports_vim_async: ' .. tostring(supports))
print('backend: ' .. tostring(backend))
assert(supports == true, 'expected supports_vim_async() == true on nightly/0.13-dev')
assert(backend == 'itchy.executor.async', 'expected async backend, got: ' .. tostring(backend))
-- The async module must load without error on 0.13+.
local ok, mod = pcall(require, 'itchy.executor.async')
assert(ok and type(mod.execute) == 'function', 'async backend failed to load')
print('backend_check: OK (async backend selected)')

-- Probe the nightly vim.system result shape: failures here explain silent
-- (markless, notificationless) runs, since empty stdout parses to nothing.
local sync_ok, sync_res = pcall(function()
  return vim.system({ 'echo', 'LINE0: probe' }, { text = true }):wait()
end)
print('system sync ok: ' .. tostring(sync_ok))
if sync_ok then
  print('system keys: ' .. vim.inspect(vim.tbl_keys(sync_res)))
  print('system code: ' .. vim.inspect(sync_res.code))
  print('system signal: ' .. vim.inspect(sync_res.signal))
  print('system stdout: ' .. vim.inspect(sync_res.stdout))
  print('system stderr: ' .. vim.inspect(sync_res.stderr))
else
  print('system sync err: ' .. tostring(sync_res))
end

-- End-to-end through the real async backend with full result dump.
local done = false
local cb_err, cb_res = nil, nil
mod.execute({ cmd = { 'echo', 'LINE0: async-probe' }, cwd = vim.fn.getcwd() }, function(err, res)
  cb_err, cb_res = err, res
  done = true
end)
local finished = vim.wait(15000, function()
  return done
end, 50)
print('async e2e finished: ' .. tostring(finished))
print('async e2e err: ' .. vim.inspect(cb_err))
if cb_res ~= nil then
  print('async e2e keys: ' .. vim.inspect(vim.tbl_keys(cb_res)))
  print('async e2e stdout: ' .. vim.inspect(cb_res.stdout))
  print('async e2e stderr: ' .. vim.inspect(cb_res.stderr))
else
  print('async e2e result: nil')
end
assert(finished and cb_err == nil and cb_res ~= nil, 'async backend e2e failed')
