---@diagnostic disable: missing-fields, undefined-field

local itchy = require 'itchy'
local config = require 'itchy.config'
local runtimes = require 'itchy.runtimes'
local assert = require 'luassert'

local eq = assert.are.equal
local same = assert.are.same -- compare tables
local truthy = assert.is_true

describe('itchy.nvim setup', function()
  before_each(function()
    package.loaded['itchy'] = nil
    package.loaded['itchy.config'] = nil
    package.loaded['itchy.runtimes'] = nil
    itchy = require 'itchy'
    config = require 'itchy.config'
    runtimes = require 'itchy.runtimes'
  end)

  it('applies default configuration', function()
    itchy.setup {}
    eq(config.cfg.integrations.snacks.enabled, true)
    same(config.cfg.defaults.javascript, 'node')
    eq(vim.tbl_count(config.cfg.runtimes), 0)
    eq(config.cfg.debug_mode, false)
    eq(config.cfg.highlights.stderr, 'Error')
  end)

  it('overrides default configuration', function()
    itchy.setup {
      integrations = { snacks = { enabled = false } },
      defaults = { python = 'custom' },
      runtimes = {
        python = {
          custom = {
            cmd = 'mypython',
            args = { '-O' },
          },
        },
      },
    }
    eq(config.cfg.integrations.snacks.enabled, false)
    eq(config.cfg.defaults.python, 'custom')
    eq(runtimes.runtimes.python.custom.cmd, 'mypython')
    same(runtimes.runtimes.python.custom.args, { '-O' })
  end)

  it('crates a custom runtime', function()
    itchy.setup {
      runtimes = {
        python = {
          custom = {
            cmd = 'python',
            args = { '-O' },
          },
        },
      },
    }
    eq(runtimes.runtimes.python.custom.cmd, 'python')
    same(runtimes.runtimes.python.custom.args, { '-O' })
  end)

  it('merges user-defined runtime opts', function()
    local wrapper_called = false
    local test_wrapper = function(code, _)
      wrapper_called = true
      return code .. ' -- wrapped'
    end

    itchy.setup {
      runtimes = {
        python = {
          python = {
            args = { '-c' },
            wrapper = test_wrapper,
          },
        },
      },
    }

    assert.is_table(runtimes.runtimes.python)
    assert.is_table(runtimes.runtimes.python.python)

    -- Check that args were merged correctly
    same(runtimes.runtimes.python.python.args, { '-c' })

    -- Test wrapper is correctly assigned
    local cmd = runtimes.runtimes.python.python.cmd
    assert.is_true(cmd == 'python' or cmd == 'python3')
    eq(runtimes.runtimes.python.python.wrapper, test_wrapper)

    -- Test the wrapper function execution
    local result = runtimes.runtimes.python.python.wrapper('print("test")', 0)
    eq(result, 'print("test") -- wrapped')
    truthy(wrapper_called)
  end)

  it('handles empty user runtime configuration', function()
    local original_runtimes = vim.deepcopy(runtimes.runtimes)

    itchy.setup { runtimes = {} }

    -- Ensure no existing runtimes were removed
    same(runtimes.runtimes, original_runtimes)
  end)
end)
