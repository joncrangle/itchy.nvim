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
    _G.print = function(...)
      table.insert(printed_output, table.concat({ ... }, ' '))
    end
    M.debug_print 'test message'
    eq(printed_output[1], 'test message')
  end)

  it('get_wrapped_code should apply wrapper function', function()
    local runtime = {
      wrapper = function(code)
        return 'wrapped: ' .. code
      end,
    }
    eq(M.get_wrapped_code(runtime, 'code'), 'wrapped: code')
    ---@diagnostic disable-next-line: param-type-mismatch
    eq(M.get_wrapped_code(nil, 'code'), 'code')
  end)

  it('clean_error_message should remove ANSI escape codes', function()
    local error_msg = '\27[31mError:\27[0m Something went wrong'
    eq(M.clean_error_message(error_msg), 'Error: Something went wrong')
  end)

  it('parse_line_output should extract line number and message', function()
    local line_num, msg = M.parse_line_output 'LINE10: Syntax error'
    eq(line_num, 10)
    eq(msg, 'Syntax error')
  end)

  it('parse_error_output should extract correct line numbers and messages', function()
    local line, msg = M.parse_error_output('javascript', 'LINE5: Error: Unexpected token')
    eq(line, 5)
    eq(msg, 'Unexpected token')
  end)

  it('should_filter_line should filter noise patterns', function()
    truthy(M.should_filter_line 'window is not defined')
    truthy(M.should_filter_line "hint: Replace 'window' with 'globalThis'")
    falsy(M.should_filter_line 'Some real error message')
  end)

  it('create_temp_file should create files with correct extensions', function()
    local _, _, code = M.create_temp_file('javascript', 'console.log(1);')
    truthy(code:match '%.js$' ~= nil)
  end)
end)
