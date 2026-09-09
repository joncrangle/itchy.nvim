local js = require 'itchy.adapters.javascript'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local function ctx_for(source, cmd, args, ft)
  return {
    runtime = { cmd = cmd or 'node', args = args or { '-e' }, offset = 0 },
    filetype = ft or 'javascript',
    source = source,
    buf = 1,
    cwd = '.',
  }
end

describe('itchy.adapters.javascript', function()
  it('resolves by name through the registry', function()
    eq(adapters.resolve({ adapter = 'javascript' }).name, 'javascript')
  end)

  it('prepare() keeps user source unchanged (no currentLine rewriting)', function()
    local source = 'console.log("one")\nfunction foo() {\n  console.log("inside")\n}\nfoo()\n'
    local prepared = js.prepare(ctx_for(source))
    -- The temp source file must byte-match the input.
    local user_file = prepared.metadata.user_file
    local f = io.open(user_file, 'r')
    truthy(f ~= nil)
    local content = f:read '*a'
    f:close()
    eq(content, source)
    falsy(content:find('currentLine', 1, true) ~= nil)
    -- Helper lives in a separate file.
    truthy(prepared.metadata.user_file ~= nil)
    eq(prepared.temp_file, false)
    truthy(type(prepared.cleanup) == 'function')
    truthy(type(prepared.cmd) == 'table')
    eq(prepared.cmd[1], 'node')
    prepared.cleanup()
    falsy(vim.fn.filereadable(user_file) == 1)
  end)

  it('prepare() preserves the file extension for TypeScript', function()
    local prepared = js.prepare(ctx_for('console.log("hi")\n', 'deno', { 'eval', '--ext=ts' }, 'typescript'))
    truthy(prepared.metadata.user_file:match '%.ts$' ~= nil)
    -- File execution replaces inline eval; --ext=ts is redundant there.
    eq(prepared.cmd[1], 'deno')
    eq(prepared.cmd[2], 'run')
    prepared.cleanup()
  end)

  it('decodes framed stdout with native 1-based locations', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local function frame(kind, line, msg)
      return '\30ITCHY:' .. nonce .. ':{"kind":"' .. kind .. '","line":' .. line .. ',"message":"' .. msg .. '"}'
    end
    local result = {
      code = 0,
      signal = 0,
      stdout = frame('stdout', 2, 'one') .. '\n' .. frame('stdout', 5, 'inside') .. '\n',
      stderr = '',
    }
    local events = js.decode(ctx, prepared, result)
    eq(#events, 2)
    eq(events[1].kind, 'stdout')
    eq(events[1].line, 2)
    eq(events[2].line, 5)
    prepared.cleanup()
  end)

  it('does not let user output spoof locations', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local result = {
      code = 0,
      signal = 0,
      stdout = 'LINE12: fake\n{"kind":"stdout","line":99,"message":"x"}\n'
        .. '\30ITCHY:wrong:{"kind":"stdout","line":3,"message":"nope"}\n',
      stderr = '',
    }
    local events = js.decode(ctx, prepared, result)
    -- Nothing carries the run nonce: all locationless, never line 12/99/3.
    for _, e in ipairs(events) do
      eq(e.line, nil)
    end
    truthy(#events >= 1)
    -- The run's own nonce still decodes.
    local own = js.decode(ctx, prepared, {
      code = 0,
      signal = 0,
      stdout = '\30ITCHY:' .. nonce .. ':{"kind":"stdout","line":4,"message":"real"}\n',
      stderr = '',
    })
    eq(#own, 1)
    eq(own[1].line, 4)
    prepared.cleanup()
  end)

  it('parses native V8 stacks to the user file without offset arithmetic', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local user_file = prepared.metadata.user_file
    local result = {
      code = 1,
      signal = 0,
      stdout = '',
      stderr = 'Error: boom\n    at explode ('
        .. user_file
        .. ':2:9)\n    at Object.<anonymous> ('
        .. user_file
        .. ':4:1)\n',
    }
    local events = js.decode(ctx, prepared, result)
    eq(#events, 1)
    eq(events[1].kind, 'error')
    eq(events[1].line, 2)
    eq(events[1].column, 9)
    eq(events[1].message, 'boom')
    prepared.cleanup()
  end)

  it('parses deno file:// stacks', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local user_file = prepared.metadata.user_file:gsub('\\', '/')
    local result = {
      code = 1,
      signal = 0,
      stdout = '',
      stderr = 'error: Uncaught (in promise) Error: boom\n    at file:///' .. user_file .. ':1:7\n',
    }
    local events = js.decode(ctx, prepared, result)
    eq(#events, 1)
    eq(events[1].line, 1)
    eq(events[1].message, 'boom')
    prepared.cleanup()
  end)
end)
