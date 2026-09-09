local framed = require 'itchy.adapters.framed'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true

describe('itchy.adapters.framed', function()
  it('creates unique nonces', function()
    local a = framed.create_nonce()
    local b = framed.create_nonce()
    eq(#a, 8)
    truthy(a:match '^%x+$' ~= nil)
    truthy(a ~= b)
  end)

  it('decodes a framed record with the right nonce', function()
    local line = '\30ITCHY:abc123:' .. '{"kind":"stdout","line":12,"column":3,"message":"hello"}'
    local record = framed.decode_line(line, 'abc123')
    eq(record.kind, 'stdout')
    eq(record.line, 12)
    eq(record.column, 3)
    eq(record.message, 'hello')
  end)

  it('rejects records with the wrong nonce', function()
    local line = '\30ITCHY:other:' .. '{"kind":"stdout","line":12,"message":"hello"}'
    eq(framed.decode_line(line, 'abc123'), nil)
  end)

  it('leaves ordinary output alone (spoof resistance)', function()
    eq(framed.decode_line('LINE12: fake', 'abc123'), nil)
    eq(framed.decode_line('{"kind":"stdout","line":99,"message":"x"}', 'abc123'), nil)
    eq(framed.decode_line('ITCHY:abc123:{"kind":"stdout","line":1,"message":"x"}', 'abc123'), nil)
  end)

  it('drops malformed records without error', function()
    eq(framed.decode_line('\30ITCHY:abc123:not-json', 'abc123'), nil)
    eq(framed.decode_line('\30ITCHY:abc123:{"kind":"nope","message":"x"}', 'abc123'), nil)
    eq(framed.decode_line('\30ITCHY:abc123:{"kind":"stdout","message":42}', 'abc123'), nil)
    eq(framed.decode_line('\30ITCHY:abc123:{"kind":"stdout","line":0,"message":"x"}', 'abc123'), nil)
    eq(framed.decode_line('\30ITCHY:abc123:{"kind":"stdout","line":-1,"message":"x"}', 'abc123'), nil)
  end)

  it('sanitizes multiline messages for virtual text', function()
    eq(framed.sanitize_message('a\nb\rc\nd'), 'a b c d')
  end)
end)
