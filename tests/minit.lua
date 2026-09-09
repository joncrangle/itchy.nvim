#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = '.tests'
load(vim.fn.system 'curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua')()

-- Setup lazy.nvim
require('lazy.minit').setup {
  spec = {
    { dir = vim.uv.cwd() },
    -- Test-only: Go Tree-sitter parser so CI exercises the adapter's
    -- primary syntax-aware path (clean images ship no `go` parser).
    -- Pinned to master for the Neovim 0.11 floor. The plugin itself never
    -- requires it: without the parser the embedded scanner fallback runs.
    { 'nvim-treesitter/nvim-treesitter', branch = 'master', build = ':TSInstallSync go' },
  },
}
