local event = require 'itchy.event'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

describe('itchy.event', function()
	it('creates exact normalized event records for every supported kind', function()
		local cases = {
			{ kind = 'stdout', message = 'hello', line = 4 },
			{ kind = 'stderr', message = 'warn stream', line = 5 },
			{ kind = 'error', message = 'boom', line = 2 },
			{ kind = 'warning', message = 'careful', line = 1 },
			{ kind = 'error', message = 'no location', line = nil },
			{ kind = 'stdout', message = 'hi', line = 3, column = 7 },
		}
		for _, wanted in ipairs(cases) do
			local actual = event.create(wanted.kind, wanted.message, wanted.line, wanted.column)
			eq(actual.kind, wanted.kind)
			eq(actual.message, wanted.message)
			eq(actual.line, wanted.line)
			eq(actual.column, wanted.column)
		end
	end)

  it('rejects invalid line values', function()
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
