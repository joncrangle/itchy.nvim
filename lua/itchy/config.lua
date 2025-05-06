local M = {}

---@class itchy.Integration
---@field enabled boolean
---@field keys table<string, string>

---@class itchy.Opts
---@field defaults? table<string, string>
---@field runtimes? table<string, itchy.Runtime[]>
---@field debug_mode? boolean
---@field highlights? table<"stdout"|"stderr", string>
---@field integrations? table<"snacks", itchy.Integration>

-- stylua: ignore
---@type itchy.Opts
local default_config = {
  --- Default runtimes
  ---@type table<string, string>
  defaults = {
    javascript = 'node', -- or 'deno'|'bun'
    typescript = 'deno', -- or 'node'|'bun'
    python = 'python',   -- or 'uv'
    ps1 = 'pwsh',        -- or 'powershell'
  },
  ---@type table<string, itchy.Runtime>
  runtimes = {},
  debug_mode = false, ---@type boolean
  --- highlight groups to apply to virtual lines
  ---@type table<"stdout"|"stderr", string>
  highlights = {
    stdout = 'Comment',
    stderr = 'Error',
  },
  --- integrations to enable
  ---@type itchy.Integration[]
  integrations = {
    snacks = {
      -- snacks.nvim scratch buffer integration
      enabled = true,   -- or false
      keys = {
        run = '<CR>',   -- Carriage Return (Enter)
        clear = '<BS>', -- Backspace
      }
    },
  },
}

---@type itchy.Opts
M.cfg = default_config

return M
