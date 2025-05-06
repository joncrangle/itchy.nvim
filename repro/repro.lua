-- 1. Run `nvim -u repro/repro.lua`
-- 2. Reproduce the issue
-- 3. Report the repro.lua and logs from .repro directory in the issue

vim.env.LAZY_STDPATH = '.repro'
load(vim.fn.system 'curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua')()

local plugins = {
  {
    'joncrangle/itchy.nvim',
    lazy = false,
    opts = {},
  },
}

require('lazy.minit').repro { spec = plugins }
