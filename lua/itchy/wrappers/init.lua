local M = {}

--- Create a wrapper for code that captures console output with line numbers.
---@param ft string
---@param code string
---@param offset? integer
---@return string
function M.create_wrapper(ft, code, offset)
  local wrappers = {
    go = require('itchy.wrappers.go').wrap,
    javascript = require('itchy.wrappers.javascript').wrap,
    typescript = require('itchy.wrappers.javascript').wrap,
    python = require('itchy.wrappers.python').wrap,
    bash = require('itchy.wrappers.shell').wrap,
    sh = require('itchy.wrappers.shell').wrap,
    zsh = require('itchy.wrappers.shell').wrap,
    dosbatch = require('itchy.wrappers.windows').wrap.cmd,
    ps1 = require('itchy.wrappers.windows').wrap.pwsh,
  }

  local wrapper = wrappers[ft]
  if wrapper then
    return wrapper(code, offset or 0)
  end
  return code
end

return M
