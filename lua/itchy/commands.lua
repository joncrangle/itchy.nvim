local itchy = require 'itchy'

---@type table<string, fun(runtime?: string)>
local sub_cmds = {
  run = function(runtime)
    itchy.run(runtime)
  end,
  clear = function()
    itchy.clear()
  end,
  list = function()
    itchy.list()
  end,
  current = function()
    itchy.current()
  end,
}

local sub_cmds_keys = {}
for k, _ in pairs(sub_cmds) do
  table.insert(sub_cmds_keys, k)
end

--- Parse the command to extract subcommand and optional runtime
---@param args string
---@return string, string?
local function parse_args(args)
  local sub_cmd, runtime = args:match '^(%S+)%s*%(?([^%)]*)%)?$'
  return sub_cmd, runtime ~= '' and runtime or nil
end

--- Main command handler
---@param opts table
local function main_cmd(opts)
  local sub_cmd, runtime = parse_args(opts.args or '')
  local handler = sub_cmds[sub_cmd]
  if handler then
    handler(runtime)
  else
    vim.notify('Itchy: invalid command', vim.log.levels.ERROR)
  end
end

--- Completion for subcommands and runtimes
---@param arg_lead string
---@param cmd_line string
local function complete_args(arg_lead, cmd_line, _)
  local cmd_parts = vim.split(cmd_line, '%s+')
  local sub_cmd = cmd_parts[2] -- first part is "Itchy", second is the subcommand

  if sub_cmd == 'run' and #cmd_parts > 2 then
    local runtime_keys = itchy.list(true) or {}
    return vim.tbl_filter(function(runtime)
      return runtime:find(arg_lead, 1, true) ~= nil
    end, runtime_keys)
  else
    return vim.tbl_filter(function(cmd)
      return cmd:find(arg_lead, 1, true) ~= nil
    end, sub_cmds_keys)
  end
end

vim.api.nvim_create_user_command('Itchy', main_cmd, {
  nargs = '?',
  desc = 'Itchy',
  complete = complete_args,
})
