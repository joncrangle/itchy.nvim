local js = require 'itchy.adapters.javascript'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local pending = pending or function(message)
  print('SKIPPED: ' .. tostring(message))
  io.stdout:flush()
  return true
end

local function ctx_for(source, cmd, args, ft)
  return {
    runtime = { cmd = cmd or 'node', args = args or { '-e' } },
    filetype = ft or 'javascript',
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

describe('itchy.adapters.javascript', function()
  it('prepare() keeps user source unchanged', function()
    local source = 'console.log("one")\nfunction foo() {\n  console.log("inside")\n}\nfoo()\n'
    local prepared = js.prepare(ctx_for(source))
    -- The temp source file must byte-match the input.
    local user_file = prepared.metadata.user_file
    local f = io.open(user_file, 'r')
    truthy(f ~= nil)
    local content = f:read '*a'
    f:close()
    eq(content, source)
    -- Helper lives in a separate file.
    truthy(prepared.metadata.user_file ~= nil)
    eq(prepared.temp_file, false)
    truthy(type(prepared.cleanup) == 'function')
    truthy(type(prepared.cmd) == 'table')
    eq(prepared.cmd[1], 'node')
    prepared.cleanup()
    falsy(vim.fn.filereadable(user_file) == 1)
  end)

  it('encodes generated launcher paths as JSON string literals', function()
    local user_path = "dir/quote\"slash\\line\n\t\r"
    local helper_path = "helper\"slash\\line\n\t\r"
    local rendered = js._render_helper('nonce', user_path, helper_path)
    eq(js._js_escape(user_path), vim.json.encode(user_path))
    eq(js._js_escape(helper_path), vim.json.encode(helper_path))
    truthy(rendered:find('const __ITCHY_USER_RAW = ' .. vim.json.encode(user_path) .. ';', 1, true) ~= nil)
    truthy(rendered:find('const __ITCHY_HELPER_RAW = ' .. vim.json.encode(helper_path) .. ';', 1, true) ~= nil)
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

  it('decodes framed warning/error kinds for diagnostic highlighting', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local function frame(kind, line, msg)
      return '\30ITCHY:' .. nonce .. ':{"kind":"' .. kind .. '","line":' .. line .. ',"message":"' .. msg .. '"}'
    end
    local result = {
      code = 0,
      signal = 0,
      stdout = frame('warning', 2, 'careful') .. '\n' .. frame('error', 3, 'boom') .. '\n',
      stderr = '',
    }
    local events = js.decode(ctx, prepared, result)
    with_cleanup(prepared, nil, function()
      eq(#events, 2)
      -- Renderer paints warning with the warning highlight and error with
      -- the error highlight. Preserving kind here is what keeps the
      -- centralized mapping correct.
      eq(events[1].kind, 'warning')
      eq(events[1].line, 2)
      eq(events[2].kind, 'error')
      eq(events[2].line, 3)
    end)
  end)

  it('does not let user output spoof locations', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local nonce = prepared.metadata.nonce
    local result = {
      code = 0,
      signal = 0,
      stdout = 'plain output: fake\n{"kind":"stdout","line":99,"message":"x"}\n'
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

  it('decodes the Node MODULE_TYPELESS_PACKAGE_JSON warning as a warning', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local user_file = prepared.metadata.user_file
    local warning = '(node:12345) [MODULE_TYPELESS_PACKAGE_JSON] Warning: Module type of '
      .. user_file
      .. ' is not specified and it doesn\'t parse as CommonJS.\n'
      .. 'Reparsing as ES module because module syntax was detected. This incurs a performance overhead.\n'
      .. 'To eliminate this warning, add "type": "module" to '
      .. user_file
      .. '.\n'
      .. '(Use `node --trace-warnings ...` to show where the warning was created)\n'
    local events = js.decode(ctx, prepared, { code = 0, signal = 0, stdout = '', stderr = warning })
    with_cleanup(prepared, nil, function()
      eq(#events, 1)
      eq(events[1].kind, 'warning')
      eq(events[1].line, nil)
      eq(
        events[1].message,
        'Module type of '
          .. user_file
          .. ' is not specified and it doesn\'t parse as CommonJS. '
          .. 'Reparsing as ES module because module syntax was detected. This incurs a performance overhead. '
          .. 'To eliminate this warning, add "type": "module" to '
          .. user_file
          .. '. '
          .. '(Use `node --trace-warnings ...` to show where the warning was created)'
      )
    end)
  end)

  it('preserves a Node warning and a real error from the same stderr', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local warning = '(node:12345) [MODULE_TYPELESS_PACKAGE_JSON] Warning: module type is ambiguous.\n'
      .. 'Reparsing as ES module because module syntax was detected.\n'
      .. '(Use `node --trace-warnings ...` to show where the warning was created)\n'
    local stderr = warning .. 'Error: boom\n    at explode (' .. prepared.metadata.user_file .. ':2:9)\n'
    local events = js.decode(ctx, prepared, { code = 1, signal = 0, stdout = '', stderr = stderr })
    with_cleanup(prepared, nil, function()
      eq(#events, 2)
      eq(events[1].kind, 'warning')
      eq(events[1].message, 'module type is ambiguous. Reparsing as ES module because module syntax was detected. '
        .. '(Use `node --trace-warnings ...` to show where the warning was created)')
      eq(events[2].kind, 'error')
      eq(events[2].message, 'boom')
      eq(events[2].line, 2)
      eq(events[2].column, 9)
    end)
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

  it('maps native syntax-error preambles to the reported line', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local user_file = prepared.metadata.user_file
    -- Node reports syntax failures as a bare path:line preamble with an
    -- excerpt and caret; no `at` frame references the user file.
    local result = {
      code = 1,
      signal = 0,
      stdout = '',
      stderr = user_file
        .. ':2\nfoo bar!!!\n    ^^^\n\nSyntaxError: Unexpected identifier \'bar\'\n'
        .. '    at wrapSafe (node:internal/modules/cjs/loader:1866:18)\n',
    }
    local events = js.decode(ctx, prepared, result)
    with_cleanup(prepared, nil, function()
      eq(#events, 1)
      eq(events[1].kind, 'error')
      eq(events[1].line, 2)
    end)
  end)

  it('keeps framed records containing ordinary messages', function()
    local ctx = ctx_for('')
    local prepared = js.prepare(ctx)
    local nonce = prepared.metadata.nonce
    -- A nonce-authenticated structured event remains structured even when its
    -- message resembles ordinary runtime output.
    local result = {
      code = 0,
      signal = 0,
      stdout = '\30ITCHY:'
        .. nonce
        .. ':{"kind":"stdout","line":1,"message":"window is not defined"}\n',
      stderr = '',
    }
    local events = js.decode(ctx, prepared, result)
    with_cleanup(prepared, nil, function()
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 1)
      eq(events[1].message, 'window is not defined')
    end)
  end)

  it('executes project-relative imports from the run cwd', function()
    if vim.fn.executable('node') ~= 1 then
      pending('node is required for project-relative import coverage')
      return
    end
    local proj = vim.fn.tempname() .. '_jsproj'
    vim.fn.mkdir(proj, 'p')
    local f = io.open(proj .. '/helper.js', 'w')
    assert(f ~= nil)
    f:write('module.exports = { v: 42 };\n')
    f:close()
    local ctx = ctx_for("const h = require('./helper.js');\nconsole.log(h.v);\n", 'node', { '-e' })
    ctx.cwd = proj
    local prepared = js.prepare(ctx)
    -- The source file must live in the project so relative imports resolve.
    truthy(prepared.metadata.user_file:find(proj, 1, true) ~= nil)
    with_cleanup(prepared, function()
      vim.fn.delete(proj, 'rf')
    end, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
      local events =
        js.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      if #events ~= 1 then
        -- Failure diagnostics: this test proved flaky on CI Windows
        -- runners (zero events with no functional change), so dump the
        -- execution context when the count is unexpected.
        local ver = vim.system({ 'node', '--version' }, { text = true }):wait()
        print(
          'DIAG js-import: code='
            .. vim.inspect(out.code)
            .. ' stdout='
            .. vim.inspect(out.stdout)
            .. ' stderr='
            .. vim.inspect(out.stderr)
            .. ' node='
            .. vim.inspect(ver.stdout)
            .. ' userfile='
            .. prepared.metadata.user_file
            .. ' userreadable='
            .. tostring(vim.fn.filereadable(prepared.metadata.user_file))
            .. ' helperreadable='
            .. tostring(vim.fn.filereadable(prepared.cmd[2]))
        )
      end
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 2)
      eq(events[1].message, '42')
    end)
  end)

  it('renders padded selection sources on original buffer lines', function()
    if vim.fn.executable('node') ~= 1 then
      pending('node is required for JavaScript selection mapping coverage')
      return
    end
    local renderer = require('itchy.renderer')
    -- Visual selections pad omitted leading lines with newlines; native
    -- locations must then equal original buffer lines (offset of 2 here).
    local ctx = ctx_for('\n\nconsole.log("sel");\n', 'node', { '-e' })
    local prepared = js.prepare(ctx)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '', 'console.log("sel");' })
    with_cleanup(prepared, function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
      local events =
        js.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      eq(#events, 1)
      eq(events[1].line, 3)
      local ns = vim.api.nvim_create_namespace('itchy_js_sel_' .. tostring(buf))
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
