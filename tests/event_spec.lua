local event = require 'itchy.event'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

describe('itchy.event', function()
  it('creates a stdout event with a 1-based line', function()
    local e = event.create('stdout', 'hello', 4)
    eq(e.kind, 'stdout')
    eq(e.line, 4)
    eq(e.message, 'hello')
  end)

  it('creates an error event with a line', function()
    local e = event.create('error', 'boom', 2)
    eq(e.kind, 'error')
    eq(e.line, 2)
  end)

  it('creates a warning event', function()
    local e = event.create('warning', 'careful', 1)
    eq(e.kind, 'warning')
    eq(e.line, 1)
  end)

  it('supports locationless events via nil line', function()
    local e = event.create('error', 'no location', nil)
    eq(e.line, nil)
    eq(e.message, 'no location')
  end)

  it('supports an optional 1-based column', function()
    local e = event.create('stdout', 'hi', 3, 7)
    eq(e.column, 7)
    local no_col = event.create('stdout', 'hi', 3)
    eq(no_col.column, nil)
  end)

  it('rejects legacy magic line values', function()
    assert.has_error(function()
      event.create('error', 'bad', -1)
    end)
    assert.has_error(function()
      event.create('error', 'bad', 0)
    end)
  end)

  it('validates lines against a buffer line count', function()
    truthy(event.is_valid_line(1, 10))
    truthy(event.is_valid_line(10, 10))
    falsy(event.is_valid_line(11, 10))
    falsy(event.is_valid_line(0, 10))
    falsy(event.is_valid_line(nil, 10))
    falsy(event.is_valid_line(1.5, 10))
  end)
end)
