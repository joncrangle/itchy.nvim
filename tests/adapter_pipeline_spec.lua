local itchy = require 'itchy'
local runtimes = require 'itchy.runtimes'
local executor = require 'itchy.executor'
local assert = require 'luassert'

local eq = assert.are.equal
local same = assert.are.same
local truthy = assert.is_true

local api = vim.api

describe('itchy custom adapter pipeline', function()
  local original_execute
  local fake
  local buf

  before_each(function()
    package.loaded['itchy'] = nil
    package.loaded['itchy.runtimes'] = nil
    itchy = require 'itchy'
    runtimes = require 'itchy.runtimes'
    executor = require 'itchy.executor'
    fake = { requests = {}, callbacks = {} }
    original_execute = executor.execute
    executor.execute = function(request, callback)
      table.insert(fake.requests, request)
      table.insert(fake.callbacks, callback)
      local handle = { cancelled = false }
      function handle:cancel()
        self.cancelled = true
      end
      function handle:is_running()
        return not self.cancelled
      end
      return handle
    end

    local event = require 'itchy.event'
    local custom = {
      name = 'custom',
      prepare = function(ctx)
        return { source = ctx.source, metadata = { filetype = ctx.filetype } }
      end,
      decode = function(_, _, result)
        local events = {}
        for line in (result.stdout or ''):gmatch('[^\r\n]+') do
          local text = line:match '^OUT:(.*)'
          if text then
            table.insert(events, event.create('stdout', text, 2))
          end
        end
        return events
      end,
    }
    runtimes.runtimes.itchytest = {
      custom = { cmd = 'custom-runtime', args = { '--run' }, adapter = custom, temp_file = false },
    }
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'itchytest'
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'first', 'second', 'third' })
    api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    executor.execute = original_execute
    runtimes.runtimes.itchytest = nil
    itchy._reset_runs()
    if buf and api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
    buf = nil
  end)

  it('runs a custom adapter through prepare, executor, decode, and renderer', function()
    itchy.run('custom', buf)
    eq(#fake.requests, 1)
     same(fake.requests[1].cmd, { 'custom-runtime', '--run', 'first\nsecond\nthird' })
    eq(fake.requests[1].cwd, vim.fn.getcwd())

    fake.callbacks[1](nil, { code = 0, signal = 0, stdout = 'OUT:hello\n', stderr = '' })
    local namespace = api.nvim_get_namespaces()['itchy_itchytest_result']
    truthy(namespace ~= nil)
    local ready = vim.wait(2000, function()
      return #api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true }) > 0
    end, 50)
    truthy(ready)
    local marks = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 1)
    eq(marks[1][2], 1)
    eq(marks[1][4].virt_lines[1][2][1], 'hello')
  end)
end)
