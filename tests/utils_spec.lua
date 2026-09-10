local M = require 'itchy.utils'
local config = require 'itchy.config'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

describe('itchy.utils', function()
  before_each(function()
    config.cfg.debug_mode = false
  end)

  it('ft_to_ext should return correct extensions', function()
    eq(M.ft_to_ext 'javascript', 'js')
    eq(M.ft_to_ext 'typescript', 'ts')
    eq(M.ft_to_ext 'python', 'python') -- Defaults to ft name
  end)

  it('debug_print should print only when debug_mode is enabled', function()
    config.cfg.debug_mode = true
    local printed_output = {}
    local orig_print = _G.print
    _G.print = function(...)
      table.insert(printed_output, table.concat({ ... }, ' '))
    end
    M.debug_print 'test message'
    _G.print = orig_print
    eq(printed_output[1], 'test message')
  end)

  it('clean_error_message should remove ANSI escape codes', function()
    local error_msg = '\27[31mError:\27[0m Something went wrong'
    eq(M.clean_error_message(error_msg), 'Error: Something went wrong')
  end)


  it('create_temp_code_file should create only the source file with correct extension', function()    local path, err = M.create_temp_code_file('javascript', 'console.log(1);')
    assert(path ~= nil, tostring(err))
    truthy(path:match '%.js$' ~= nil)
    local f = io.open(path, 'r')
    truthy(f ~= nil)
    if f then
      local content = f:read '*a'
      f:close()
      eq(content, 'console.log(1);')
    end
    M.remove_temp_file(path)
    falsy(vim.fn.filereadable(path) == 1)
  end)



  it('project-local temp files never truncate an existing file on collision', function()
    local proj = vim.fn.tempname() .. '_collide'
    vim.fn.mkdir(proj, 'p')
    -- Force every candidate leaf to collide with a real user file.
    local orig_leaf = M._project_leaf
    M._project_leaf = function()
      return '1'
    end
    local sentinel = proj .. '/1.js'
    local f = io.open(sentinel, 'w')
    assert(f ~= nil)
    f:write('USER DATA - DO NOT TOUCH')
    f:close()
    local ok, err = pcall(function()
      -- All 32 attempts collide: must fail instead of truncating.
      local path, _ = M.create_temp_code_file('javascript', 'console.log(1);', proj)
      assert(path == nil, 'expected failure on exhausted collisions, got: ' .. tostring(path))
    end)
    M._project_leaf = orig_leaf
    local check = io.open(sentinel, 'r')
    assert(check ~= nil)
    local content = check:read '*a'
    check:close()
    eq(content, 'USER DATA - DO NOT TOUCH')
    vim.fn.delete(proj, 'rf')
    if not ok then
      error(err, 0)
    end
  end)

  it('project-local temp files use unique names inside the project', function()
    local proj = vim.fn.tempname() .. '_unique'
    vim.fn.mkdir(proj, 'p')
    local ok, err = pcall(function()
      local a = M.create_temp_code_file('python', 'print(1)', proj)
      local b = M.create_temp_code_file('python', 'print(2)', proj)
      assert(a ~= nil and b ~= nil)
      truthy(a ~= b)
      truthy(a:find(proj, 1, true) ~= nil)
      truthy(b:find(proj, 1, true) ~= nil)
      M.remove_temp_file(a)
      M.remove_temp_file(b)
    end)
    vim.fn.delete(proj, 'rf')
    if not ok then
      error(err, 0)
    end
  end)

  it('make_adapter_tmpdir prefers the project dir and falls back to temp', function()
    local proj = vim.fn.tempname() .. '_adapterdir'
    vim.fn.mkdir(proj, 'p')
    local ok, err = pcall(function()
      local dir = M.make_adapter_tmpdir(proj, 'itchy-go', 'abc123')
      truthy(dir:find(proj, 1, true) ~= nil)
      eq(vim.fn.isdirectory(dir), 1)
      vim.fn.delete(dir, 'd')
      local fallback = M.make_adapter_tmpdir(nil, 'itchy-go', 'abc123')
      truthy(fallback ~= nil and fallback ~= '')
      eq(vim.fn.isdirectory(fallback), 1)
      vim.fn.delete(fallback, 'd')
    end)
    vim.fn.delete(proj, 'rf')
    if not ok then
      error(err, 0)
    end
  end)

  it('is_user_file matches user diagnostics and excludes the helper', function()
    truthy(M.is_user_file('/tmp/x/itchy-user-abc.go', '/tmp/x/itchy-user-abc.go', 'itchy_helper.go'))
    truthy(M.is_user_file('C:\\tmp\\x\\itchy-user-abc.go', 'C:/tmp/x/itchy-user-abc.go', 'itchy_helper.go'))
    falsy(M.is_user_file('/tmp/x/itchy_helper.go', '/tmp/x/itchy-user-abc.go', 'itchy_helper.go'))
    falsy(M.is_user_file('/other/main.go', '/tmp/x/itchy-user-abc.go', 'itchy_helper.go'))
    falsy(M.is_user_file(nil, '/tmp/x/itchy-user-abc.go', 'itchy_helper.go'))
  end)
end)
