local adapters = require 'itchy.adapters'
local renderer = require 'itchy.renderer'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true

local api = vim.api

describe('itchy adapter pipeline', function()
  it('prepare -> executor result -> decode -> render without touching parser internals', function()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'first', 'second', 'third' })
    api.nvim_set_current_buf(buf)

    local runtime = {
      cmd = 'fake',
      args = {},
      offset = 0,
      wrapper = function(code, _)
        return code
      end,
      adapter = 'legacy',
    }
    local adapter = adapters.resolve(runtime)
    -- The run path resolves through the registry, not filetype branches.
    eq(adapter.name, 'legacy')

    local source = table.concat(api.nvim_buf_get_lines(buf, 0, -1, true), '\n')
    local ctx = { runtime = runtime, filetype = 'itchytest', source = source, buf = buf, cwd = vim.fn.getcwd() }
    local prepared = adapter.prepare(ctx)
    eq(prepared.source, source)
    eq(prepared.metadata.filetype, 'itchytest')

    -- Simulated executor result using the legacy wire format.
    local result = { code = 0, signal = 0, stdout = 'LINE1: hello\n', stderr = '' }
    local events = adapter.decode(ctx, prepared, result)
    eq(#events, 1)
    eq(events[1].kind, 'stdout')
    -- Legacy 0-based LINE1 -> 1-based line 2.
    eq(events[1].line, 2)

    local ns = api.nvim_create_namespace('itchy_pipeline_test')
    renderer.render(buf, ns, events)
    local ok = vim.wait(2000, function()
      return #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
    end, 50)
    truthy(ok)
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    -- 1-based line 2 -> 0-based row 1.
    eq(marks[1][2], 1)

    pcall(api.nvim_buf_delete, buf, { force = true })
  end)
end)
