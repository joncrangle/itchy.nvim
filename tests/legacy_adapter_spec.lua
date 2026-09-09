local legacy = require 'itchy.adapters.legacy'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal

describe('itchy.adapters.legacy', function()
  it('resolves as the default adapter', function()
    local adapter = adapters.resolve({})
    eq(adapter.name, 'legacy')
    local fallback = adapters.resolve(nil)
    eq(fallback.name, 'legacy')
  end)

  it('prepare() preserves the current wrapped source', function()
    local wrapper = function(code, offset)
      return 'wrapped(' .. tostring(offset) .. '):' .. code
    end
    local ctx = {
      runtime = { wrapper = wrapper, offset = 3 },
      filetype = 'javascript',
      source = 'console.log(1)',
      buf = 1,
      cwd = '.',
    }
    local prepared = legacy.prepare(ctx)
    eq(prepared.source, 'wrapped(3):console.log(1)')
    eq(prepared.metadata.offset, 3)
  end)

  it('prepare() passes through source without a wrapper', function()
    local ctx = {
      runtime = {},
      filetype = 'javascript',
      source = 'plain',
      buf = 1,
      cwd = '.',
    }
    local prepared = legacy.prepare(ctx)
    eq(prepared.source, 'plain')
  end)

  it('decodes JS wrapper stdout LINE<n> (0-based) to 1-based events', function()
    local ctx = { filetype = 'javascript' }
    local events = legacy.decode(ctx, {}, { code = 0, signal = 0, stdout = 'LINE4: hello\n', stderr = '' })
    eq(#events, 1)
    eq(events[1].kind, 'stdout')
    eq(events[1].line, 5)
    eq(events[1].message, 'hello')
  end)

  it('decodes Python wrapper stdout LINE<n> (0-based) to 1-based events', function()
    local ctx = { filetype = 'python' }
    local events = legacy.decode(ctx, {}, { code = 0, signal = 0, stdout = 'LINE4: hello\n', stderr = '' })
    eq(#events, 1)
    eq(events[1].kind, 'stdout')
    eq(events[1].line, 5)
  end)

  it('maps stdout ItchyError records to error events', function()
    local ctx = { filetype = 'python' }
    local events = legacy.decode(ctx, {}, { code = 0, signal = 0, stdout = 'LINE2: ItchyError: boom\n', stderr = '' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 3)
    eq(events[1].message, 'boom')
  end)

  it('decodes representative JavaScript errors', function()
    local ctx = { filetype = 'javascript' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'LINE5: Error: Unexpected token\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 6)
    eq(events[1].message, 'Unexpected token')
  end)

  it('decodes TypeScript errors the same as JavaScript', function()
    local ctx = { filetype = 'typescript' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'LINE5: Error: Unexpected token\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 6)
    eq(events[1].message, 'Unexpected token')
  end)

  it('decodes JavaScript stack-trace errors to 1-based lines', function()
    local ctx = { filetype = 'javascript' }
    local events =
      legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'Error: boom\n    at eval (eval at <anonymous>:14:5)\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    -- (14 - 10) / 2 = 2 (0-based row) -> 1-based line 3.
    eq(events[1].line, 3)
  end)

  it('decodes representative Python errors', function()
    local ctx = { filetype = 'python' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'LINE7: ItchyError: division by zero\n' })
    -- Python manufactured errors arrive via the LINE protocol; decode
    -- normalizes 0-based LINE7 to 1-based line 8.
    eq(#events >= 1, true)
    eq(events[1].kind, 'error')
    eq(events[1].line, 8)
  end)

  it('decodes representative Go diagnostics without magic offsets in the adapter API', function()
    local ctx = { filetype = 'go' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = '/tmp/file.go:10:5: undefined: foo\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    -- Legacy correction (line - 2) expressed as a 1-based event.
    eq(events[1].line, 9)
  end)

  it('decodes representative shell diagnostics', function()
    local ctx = { filetype = 'bash' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'bash: line 3: division by 0\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 3)
  end)

  it('decodes locationless diagnostics with nil line', function()
    local ctx = { filetype = 'bash' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'bash: something went wrong\n' })
    eq(#events, 1)
    eq(events[1].line, nil)
  end)

  it('decodes unrecognized runtimes (e.g. powershell) via the generic error fallback', function()
    local ctx = { filetype = 'ps1' }
    local events = legacy.decode(ctx, {}, { code = 1, signal = 0, stdout = '', stderr = 'some error: bad thing\n' })
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, nil)
    eq(events[1].message, 'bad thing')
  end)

  it('falls back to legacy with a warning for unknown adapter names', function()
    local seen = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(seen, msg)
    end
    local adapter = adapters.resolve({ adapter = 'does-not-exist' })
    vim.notify = orig_notify
    eq(adapter.name, 'legacy')
    eq(#seen, 1)
  end)

  it('applies an explicit source_map when provided', function()
    local ctx = { filetype = 'javascript', source_map = { [1] = 40 } }
    local events = legacy.decode(ctx, {}, { code = 0, signal = 0, stdout = 'LINE0: hi\n', stderr = '' })
    eq(events[1].line, 40)
  end)
end)
