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
