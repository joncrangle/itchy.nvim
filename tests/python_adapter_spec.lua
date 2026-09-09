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

--- Run fn, always releasing prepared temp files (plus extra) even when an
--- assertion fails, so red tests never litter the project cwd where temp
--- sources now live for import resolution.
local function with_cleanup(prepared, extra, fn)
  local ok, err = pcall(fn)
  pcall(function()
    prepared.cleanup()
  end)
  if extra then
    pcall(extra)
  end
  if not ok then
    error(err, 0)
  end
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

  it('preserves framed error diagnostics from stdout for error highlighting', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local result = {
      code = 0,
      signal = 0,
      stdout = '\30ITCHY:'
        .. nonce
        .. ':{"kind":"error","line":9,"message":"Caught runtime error: division by zero"}\n',
      stderr = '',
    }
    local events = py.decode(ctx, prepared, result)
    with_cleanup(prepared, nil, function()
      eq(#events, 1)
      -- Renderer paints error with the diagnostic error highlight; the
      -- adapter labels the diagnostic kind, the renderer owns the mapping.
      eq(events[1].kind, 'error')
      eq(events[1].line, 9)
    end)
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

  it('keeps framed records containing legacy noise patterns', function()
    local ctx = ctx_for('')
    local prepared = py.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local result = {
      code = 0,
      signal = 0,
      stdout = '\30ITCHY:'
        .. nonce
        .. ':{"kind":"stdout","line":2,"message":"window is not defined"}\n',
      stderr = '',
    }
    local events = py.decode(ctx, prepared, result)
    with_cleanup(prepared, nil, function()
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 2)
      eq(events[1].message, 'window is not defined')
    end)
  end)

  it('executes sibling imports from the run cwd', function()
    if vim.fn.executable('python') ~= 1 and vim.fn.executable('python3') ~= 1 then
      return
    end
    local cmd = vim.fn.executable('python') == 1 and 'python' or 'python3'
    local proj = vim.fn.tempname() .. '_pyproj'
    vim.fn.mkdir(proj, 'p')
    local f = io.open(proj .. '/helper.py', 'w')
    assert(f ~= nil)
    f:write('VALUE = "sibling-ok"\n')
    f:close()
    local ctx = {
      runtime = { cmd = cmd, args = { '-c' }, offset = 26 },
      filetype = 'python',
      source = 'import helper\nprint(helper.VALUE)\n',
      buf = 1,
      cwd = proj,
    }
    local prepared = py.prepare(ctx)
    truthy(prepared.metadata.user_file:find(proj, 1, true) ~= nil)
    with_cleanup(prepared, function()
      vim.fn.delete(proj, 'rf')
    end, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
      local events =
        py.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 2)
      eq(events[1].message, 'sibling-ok')
    end)
  end)

  it('preserves explicit print end= terminators', function()
    if vim.fn.executable('python') ~= 1 and vim.fn.executable('python3') ~= 1 then
      return
    end
    local cmd = vim.fn.executable('python') == 1 and 'python' or 'python3'
    local ctx = {
      runtime = { cmd = cmd, args = { '-c' }, offset = 26 },
      filetype = 'python',
      source = 'print("hello", end="!")\nprint("plain")\n',
      buf = 1,
      cwd = '.',
    }
    local prepared = py.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
      local events =
        py.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      eq(#events, 2)
      eq(events[1].line, 1)
      eq(events[1].message, 'hello!')
      eq(events[2].line, 2)
      eq(events[2].message, 'plain')
    end)
  end)

  it('renders padded selection sources on original buffer lines', function()
    if vim.fn.executable('python') ~= 1 and vim.fn.executable('python3') ~= 1 then
      return
    end
    local cmd = vim.fn.executable('python') == 1 and 'python' or 'python3'
    local renderer = require('itchy.renderer')
    -- Visual selections pad omitted leading lines with newlines; native
    -- frame locations must then equal original buffer lines (offset of 2).
    local ctx = {
      runtime = { cmd = cmd, args = { '-c' }, offset = 26 },
      filetype = 'python',
      source = '\n\nprint("sel")\n',
      buf = 1,
      cwd = '.',
    }
    local prepared = py.prepare(ctx)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '', 'print("sel")' })
    with_cleanup(prepared, function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
      local events =
        py.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      eq(#events, 1)
      eq(events[1].line, 3)
      local ns = vim.api.nvim_create_namespace('itchy_py_sel_' .. tostring(buf))
      renderer.render(buf, ns, events, { line_count = 3 })
      vim.wait(2000, function()
        return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
      end, 50)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      eq(#marks, 1)
      eq(marks[1][2], 2)
    end)
  end)
end)
