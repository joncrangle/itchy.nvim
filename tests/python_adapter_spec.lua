local py = require 'itchy.adapters.python'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local function ctx_for(source)
  return {
    runtime = { cmd = 'python', args = { '-c' }, offset = 26 },
    filetype = 'python',
    source = source,
    buf = 1,
    cwd = '.',
  }
end

describe('itchy.adapters.python', function()
  it('resolves by name through the registry', function()
    eq(adapters.resolve({ adapter = 'python' }).name, 'python')
  end)

  it('prepare() keeps user source unchanged (no try: indent)', function()
    local source = 'print("hello")\ndef foo():\n    print("inside")\n\nfoo()\n'
    local prepared = py.prepare(ctx_for(source))
    local user_file = prepared.metadata.user_file
    local f = io.open(user_file, 'r')
    truthy(f ~= nil)
    local content = f:read '*a'
    f:close()
    eq(content, source)
    -- File execution replaces `-c`; uv keeps its launcher prefix.
    eq(prepared.cmd[1], 'python')
    eq(prepared.temp_file, false)
    prepared.cleanup()
    falsy(vim.fn.filereadable(user_file) == 1)
  end)

  it('prepare() drops -c but keeps the uv launcher prefix', function()
    local ctx = {
      runtime = { cmd = 'uv', args = { 'run', 'python', '-c' }, offset = 26 },
      filetype = 'python',
      source = 'print(1)\n',
      buf = 1,
      cwd = '.',
    }
    local prepared = py.prepare(ctx)
    eq(prepared.cmd[1], 'uv')
    eq(prepared.cmd[2], 'run')
    eq(prepared.cmd[3], 'python')
    prepared.cleanup()
  end)

  it('decodes framed prints with sep/line preserved', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local result = {
      code = 0,
      signal = 0,
      stdout = '\30ITCHY:'
        .. nonce
        .. ':{"kind":"stdout","line":2,"message":"x 123"}\n\30ITCHY:'
        .. nonce
        .. ':{"kind":"stdout","line":3,"message":"a-b"}\n',
      stderr = '',
    }
    local events = py.decode(ctx, prepared, result)
    eq(#events, 2)
    eq(events[1].line, 2)
    eq(events[1].message, 'x 123')
    eq(events[2].message, 'a-b')
    prepared.cleanup()
  end)

  it('parses native tracebacks to the deepest user frame', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local user_file = prepared.metadata.user_file
    local result = {
      code = 1,
      signal = 0,
      stdout = '',
      stderr = 'Traceback (most recent call last):\n'
        .. '  File "'
        .. user_file
        .. '", line 4, in <module>\n    explode()\n  File "'
        .. user_file
        .. '", line 2, in explode\n    raise RuntimeError("boom")\nRuntimeError: boom\n',
    }
    local events = py.decode(ctx, prepared, result)
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 2)
    eq(events[1].message, 'RuntimeError: boom')
    prepared.cleanup()
  end)

  it('does not double-report stderr-targeted prints', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local framed_stderr = '\30ITCHY:' .. nonce .. ':{"kind":"stderr","line":2,"message":"to-err"}'
    local result = { code = 0, signal = 0, stdout = framed_stderr .. '\n', stderr = 'to-err\n' }
    local events = py.decode(ctx, prepared, result)
    -- One framed stderr event; the passthrough copy on real stderr is deduped.
    eq(#events, 1)
    eq(events[1].kind, 'stderr')
    prepared.cleanup()
  end)

  it('ignores spoofed and malformed records', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local result = {
      code = 0,
      signal = 0,
      stdout = 'LINE7: ItchyError: fake\n\30ITCHY:wrong:{"kind":"stdout","line":1,"message":"x"}\n',
      stderr = '',
    }
    local events = py.decode(ctx, prepared, result)
    for _, e in ipairs(events) do
      eq(e.line, nil)
    end
    prepared.cleanup()
  end)
end)
