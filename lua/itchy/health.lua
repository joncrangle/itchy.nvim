local M = {}

local itchy = require 'itchy'

local function check_runtimes()
  vim.health.start 'Runtimes'

  local runtimes = itchy.get_runtimes()

  for ft, runtime_table in pairs(runtimes) do
    vim.health.info(('Filetype: %s'):format(ft))

    local has_runtime = false
    for name, _ in pairs(runtime_table) do
      has_runtime = true
      vim.health.ok(('Runtime: %s'):format(name))
    end

    if not has_runtime then
      vim.health.warn 'No supported runtimes found'
    end
  end
end

M.check = function()
  vim.health.start 'itchy.nvim'

  check_runtimes()
end

return M
