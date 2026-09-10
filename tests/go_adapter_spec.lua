local go_adapter = require 'itchy.adapters.go'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local pending = pending or function(message)
  print('SKIPPED: ' .. tostring(message))
  io.stdout:flush()
  return true
end

local function ctx_for(source)
  return {
    runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
    filetype = 'go',
    source = source,
    buf = 1,
    cwd = '.',
  }
end

--- Run fn, always releasing prepared temp files (plus extra) even when an
--- assertion fails.
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

local FULL_SRC = table.concat({
  'package main',
  '',
  'import "fmt"',
  '',
  'func main() {',
  '\tfmt.Println("hello")',
  '}',
  '',
}, '\n')

describe('itchy.adapters.go', function()
  it('instruments fmt.Println via syntax nodes', function()
    local out = go_adapter._instrument(FULL_SRC)
    truthy(out:find('__itchyFmtPrintln("hello")', 1, true) ~= nil)
    falsy(out:find('fmt.Println("hello")', 1, true) ~= nil)
  end)

  it('instruments Printf including multiline calls', function()
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      '',
      'func main() {',
      '\tfmt.Printf(',
      '\t  "value: %v\\n",',
      '\t  42,',
      '\t)',
      '}',
      '',
    }, '\n')
    local out = go_adapter._instrument(src)
    truthy(out ~= nil)
    assert(out ~= nil)
    truthy(out:find('__itchyFmtPrintf(', 1, true) ~= nil)
    -- Line count preserved: native diagnostics stay on user lines.
    eq(#vim.split(out, '\n', { plain = true }), #vim.split(src, '\n', { plain = true }))
  end)

  it('ignores comments, strings and similarly named methods', function()
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      '',
      'func main() {',
      '\t// fmt.Println("comment")',
      '\ts := "fmt.Println(\\"str\\")"',
      '\t_ = s',
      '\tmyObj.Println("method")',
      '\tfmt.Println("real")',
      '}',
      '',
    }, '\n')
    local out = go_adapter._instrument(src)
    assert(out ~= nil)
    truthy(out:find('// fmt.Println("comment")', 1, true) ~= nil)
    truthy(out:find('myObj.Println("method")', 1, true) ~= nil)
    truthy(out:find('__itchyFmtPrintln("real")', 1, true) ~= nil)
    falsy(out:find('__itchyFmtPrintln("comment")', 1, true) ~= nil)
    falsy(out:find('__itchyFmtPrintln(\\"str', 1, true) ~= nil)
  end)

  it('prepare() keeps full-file line numbers stable (no header)', function()
    local prepared = go_adapter.prepare(ctx_for(FULL_SRC))
    with_cleanup(prepared, nil, function()
      eq(prepared.metadata.header_offset, 0)
      local f = io.open(prepared.metadata.user_file, 'r')
      assert(f ~= nil)
      local content = f:read '*a'
      f:close()
      -- fmt.Println was on source line 6; the rewrite stays on line 6.
      local n = 0
      for line in (content .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if n == 6 then
          truthy(line:find('__itchyFmtPrintln', 1, true) ~= nil)
        end
      end
      eq(prepared.cmd[1], 'go')
      eq(prepared.cmd[2], 'run')
      eq(prepared.temp_file, false)
      truthy(content:find('var _ = fmt.Sprint', 1, true) ~= nil)
    end)
  end)

  it('decodes framed stdout with native 1-based locations', function()
    -- Full-file source: no fragment header, so framed lines map 1:1.
    local ctx = ctx_for(FULL_SRC)
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local nonce = prepared.metadata.nonce
      local result = {
        code = 0,
        signal = 0,
        stdout = '\30ITCHY:'
          .. nonce
          .. ':{"kind":"stdout","line":6,"message":"hello"}\n',
        stderr = '',
      }
      local events = go_adapter.decode(ctx, prepared, result)
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 6)
      eq(events[1].message, 'hello')
    end)
  end)

  it('preserves unframed stdout beginning with a hash', function()
    local ctx = ctx_for('')
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events = go_adapter.decode(ctx, prepared, {
        code = 0,
        signal = 0,
        stdout = '# user output\n',
        stderr = '',
      })
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, nil)
      eq(events[1].message, '# user output')
    end)
  end)

  it('surfaces each meaningful stderr line alongside other events', function()
    local ctx = ctx_for('')
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local nonce = prepared.metadata.nonce
      local events = go_adapter.decode(ctx, prepared, {
        code = 1,
        signal = 0,
        stdout = '\30ITCHY:' .. nonce .. ':{"kind":"stdout","line":1,"message":"output"}\n',
        stderr = 'first stderr\nsecond stderr\n',
      })
      eq(#events, 3)
      eq(events[1].kind, 'stdout')
      eq(events[1].message, 'output')
      eq(events[2].kind, 'error')
      eq(events[2].line, nil)
      eq(events[2].message, 'first stderr')
      eq(events[3].kind, 'error')
      eq(events[3].line, nil)
      eq(events[3].message, 'second stderr')
    end)
  end)

  it('maps log output to stdout events (not error diagnostics)', function()
    local ctx = ctx_for(FULL_SRC)
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local nonce = prepared.metadata.nonce
      local result = {
        code = 0,
        signal = 0,
        stdout = '\30ITCHY:' .. nonce .. ':{"kind":"stdout","line":3,"message":"log-hi"}\n',
        stderr = '',
      }
      local events = go_adapter.decode(ctx, prepared, result)
      eq(#events, 1)
      -- Log content renders with the stdout highlight; only compiler
      -- diagnostics and panics use the error kind.
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 3)
    end)
  end)

  it('parses native compiler diagnostics with column', function()
    local ctx = ctx_for(FULL_SRC)
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local user_file = prepared.metadata.user_file
      local result = {
        code = 1,
        signal = 0,
        stdout = '',
        stderr = '# command-line-arguments\n' .. user_file .. ':6:14: undefined: foo\n',
      }
      local events = go_adapter.decode(ctx, prepared, result)
      eq(#events, 1)
      eq(events[1].kind, 'error')
      eq(events[1].line, 6)
      eq(events[1].column, 14)
      truthy(events[1].message:find('undefined: foo', 1, true) ~= nil)
    end)
  end)

  it('parses native panic stacks to the user frame', function()
    local ctx = ctx_for(FULL_SRC)
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local user_file = prepared.metadata.user_file
      local result = {
        code = 1,
        signal = 0,
        stdout = 'before\n',
        stderr = 'panic: runtime error: integer divide by zero\n\ngoroutine 1 [running]:\nmain.divide(...)\n\t'
          .. user_file
          .. ':6\nmain.main()\n\t'
          .. user_file
          .. ':11 +0x4b\nexit status 2\n',
      }
      local events = go_adapter.decode(ctx, prepared, result)
      -- Panic message + ordinary stdout; no manufactured offsets.
      local found = nil
      for _, e in ipairs(events) do
        if e.kind == 'error' then
          found = e
        end
      end
      assert(found ~= nil)
      eq(found.line, 6)
      truthy(found.message:find('divide by zero', 1, true) ~= nil)
    end)
  end)

  it('reports live syntax errors with native locations', function()
    if vim.fn.executable('go') ~= 1 then
      pending('go is required for live compiler diagnostics')
      return
    end
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      '',
      'func main() {',
      '\tfmt.Println("hi"',
      '}',
      '',
    }, '\n')
    local ctx = {
      runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
      filetype = 'go',
      source = src,
      buf = 1,
      cwd = '.',
    }
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 60000, env = { GO111MODULE = 'off' } }):wait()
      local events = go_adapter.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      local found = nil
      for _, e in ipairs(events) do
        if e.kind == 'error' then
          found = e
        end
      end
      assert(found ~= nil)
      eq(found.line, 6)
    end)
  end)

  it('scanner fallback rewrites the same calls without Tree-sitter', function()
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      'import "log"',
      '',
      'func main() {',
      '  fmt.Println("hello")',
      '  // fmt.Println("comment")',
      '  /* log.Println("block") */',
      '  s := "fmt.Println(\\"str\\") `fmt.Println(\\"raw\\")`"',
      '  _ = s',
      '  r := \'x\'',
      '  _, _ = r, log.Printf("v: %v", 1)',
      '  myObj.Println("method")',
      '  other.Println("other")',
      '  fmtx.Println("prefix")',
      '  logx.Println("prefix")',
      '  fmt . Println("spaced")',
      '  fmt.Println ("space-paren")',
      '  fmt.Printlnx("suffix")',
      '}',
      '',
    }, '\n')
    local out = go_adapter._instrument_lexer(src)
    truthy(out:find('__itchyFmtPrintln("hello")', 1, true) ~= nil)
    truthy(out:find('__itchyLogPrintf("v: %v", 1)', 1, true) ~= nil)
    truthy(out:find('__itchyFmtPrintln("spaced")', 1, true) ~= nil)
    truthy(out:find('__itchyFmtPrintln ("space-paren")', 1, true) ~= nil)
    truthy(out:find('// fmt.Println("comment")', 1, true) ~= nil)
    truthy(out:find('myObj.Println("method")', 1, true) ~= nil)
    truthy(out:find('other.Println("other")', 1, true) ~= nil)
    truthy(out:find('fmtx.Println("prefix")', 1, true) ~= nil)
    truthy(out:find('logx.Println("prefix")', 1, true) ~= nil)
    truthy(out:find('fmt.Printlnx("suffix")', 1, true) ~= nil)
    eq(#vim.split(out, '\n', { plain = true }), #vim.split(src, '\n', { plain = true }))
  end)

  it('scanner and Tree-sitter agree byte for byte', function()
    if not go_adapter._has_treesitter() then
      pending('Go Tree-sitter parser unavailable; scanner path covered above')
      return
    end
    local sources = {
      FULL_SRC,
      table.concat({
        'package main',
        '',
        'import "fmt"',
        'import "log"',
        '',
        'func main() {',
        '  fmt.Printf(',
        '    "value: %v\\n",',
        '    42,',
        '  )',
        '  // log.Println("comment")',
        '  x := `fmt.Println("raw")`',
        '  _, _ = x, fmt.Sprint("kept")',
        '  n, err := fmt.Println("ret")',
        '  _, _ = n, err',
        '  fmt . Printf("s: %d", 2)',
        '  log.Println("done")',
        '}',
        '',
      }, '\n'),
    }
    for _, src in ipairs(sources) do
      eq(go_adapter._instrument_lexer(src), go_adapter._instrument_ts(src))
    end
  end)

  it('prepare() uses the scanner when Tree-sitter fails', function()
    -- Force the production Tree-sitter probe to fail. Patching the exported
    -- helper would not exercise prepare(), which closes over the local
    -- instrument_ts implementation.
    local orig_get_parser = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
      error('forced unavailable')
    end
    local ok, prepared_or_err = pcall(go_adapter.prepare, ctx_for(FULL_SRC))
    vim.treesitter.get_string_parser = orig_get_parser
    assert(ok)
    local prepared = prepared_or_err
    with_cleanup(prepared, nil, function()
      -- The public prepare path used the embedded scanner fallback.
      truthy(prepared.metadata.nonce ~= nil)
      local f = io.open(prepared.metadata.user_file, 'r')
      assert(f ~= nil)
      local content = f:read('*a')
      f:close()
      truthy(content:find('__itchyFmtPrintln', 1, true) ~= nil)
      truthy(content:find('var _ = fmt.Sprint', 1, true) ~= nil)
    end)
  end)

  it('executes end to end with exact source-line mapping', function()
    if vim.fn.executable('go') ~= 1 then
      pending('go is required for executable source mapping')
      return
    end
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      '',
      'func main() {',
      '\tfmt.Println("hello")',
      '\tfmt.Printf("num: %d\\n", 42)',
      '\tn, err := fmt.Println("ret")',
      '\t_, _ = n, err',
      '}',
      '',
    }, '\n')
    local ctx = {
      runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
      filetype = 'go',
      source = src,
      buf = 1,
      cwd = '.',
    }
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 60000, env = { GO111MODULE = 'off' } }):wait()
      local events = go_adapter.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      local by_line = {}
      for _, e in ipairs(events) do
        if e.line then
          by_line[e.line] = e.message
        end
      end
      eq(by_line[6], 'hello')
      eq(by_line[7], 'num: 42')
      eq(by_line[8], 'ret')
    end)
  end)

  it('reports return values and multiline calls end to end', function()
    if vim.fn.executable('go') ~= 1 then
      pending('go is required for multiline execution coverage')
      return
    end
    local src = table.concat({
      'package main',
      '',
      'import "fmt"',
      '',
      'func main() {',
      '\tn, err := fmt.Println("hello")',
      '\tif err != nil || n != 6 {',
      '\t\tfmt.Println("bad")',
      '\t}',
      '\tfmt.Printf(',
      '\t  "value: %v\\n",',
      '\t  42,',
      '\t)',
      '}',
      '',
    }, '\n')
    local ctx = {
      runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
      filetype = 'go',
      source = src,
      buf = 1,
      cwd = '.',
    }
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 60000, env = { GO111MODULE = 'off' } }):wait()
      local events = go_adapter.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      -- n==6 ("hello\n") so no "bad"; multiline Printf lands on its start line (10).
      local messages = {}
      for _, e in ipairs(events) do
        messages[e.line or 0] = e.message
      end
      eq(messages[10], 'value: 42')
      eq(messages[8], nil)
    end)
  end)

  it('renders padded selection sources on original buffer lines', function()
    if vim.fn.executable('go') ~= 1 then
      pending('go is required for Go selection mapping coverage')
      return
    end
    -- Visual selection of buffer line 3: leading lines padded with newlines
    -- so the fragment's source line equals the original buffer line.
    local ctx = {
      runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
      filetype = 'go',
      source = '\n\nfmt.Println("sel")\n',
      buf = 1,
      cwd = '.',
    }
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 60000, env = { GO111MODULE = 'off' } }):wait()
      local events = go_adapter.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      local found = nil
      for _, e in ipairs(events) do
        if e.kind == 'stdout' then
          found = e
        end
      end
      assert(found ~= nil)
      -- Fragment header is subtracted: padded source line 3 stays line 3.
      eq(found.line, 3)
      eq(found.message, 'sel')
    end)
  end)

  it('handles bare, grouped, commented, and string-only import cases', function()
    local cases = {
      {
        name = 'bare fmt API',
        source = 'x := fmt.Sprintf("%d", 42)\nfmt.Println(x)\n',
        imports = { fmt = false, log = false },
        contains = { 'fmt.Sprintf', 'import "fmt"' },
        absent = { 'import "log"' },
      },
      {
        name = 'bare log API',
        source = 'log.Fatal("boom")\n',
        imports = { fmt = false, log = false },
        contains = { 'import "log"' },
        absent = { 'import "fmt"' },
      },
      {
        name = 'comments and strings',
        source = '// see fmt.Println docs\nfmt.Println("see catalog.")\n',
        imports = { fmt = false, log = false },
        contains = { '__itchyFmtPrintln("see catalog.")' },
        generated = { 'import "fmt"' },
        absent = { 'import "log"' },
      },
      {
        name = 'quoted full-file comment',
        source = table.concat({
          'package main', '', '// "fmt"', 'func main() {', '\tprintln("ok")', '}', '',
        }, '\n'),
        imports = { fmt = false, log = false },
        absent = { 'import "fmt"', 'import "log"' },
      },
      {
        name = 'grouped imports',
        source = table.concat({
          'package main', '', 'import (', '\t"fmt"', '\t"log"', ')', '',
          'func main() {', '\tfmt.Println("fmt")', '\tlog.Println("log")', '}', '',
        }, '\n'),
        imports = { fmt = true, log = true },
        contains = { 'var _ = fmt.Sprint', 'var _ = log.Print' },
      },
    }
    for _, case in ipairs(cases) do
      local prepared = go_adapter.prepare(ctx_for(case.source))
      with_cleanup(prepared, nil, function()
        local file = io.open(prepared.metadata.user_file, 'r')
        assert(file ~= nil)
        local content = file:read('*a')
        file:close()
        eq(go_adapter._has_import(case.source, 'fmt'), case.imports.fmt, case.name .. ' fmt import')
        eq(go_adapter._has_import(case.source, 'log'), case.imports.log, case.name .. ' log import')
        for _, needle in ipairs(case.contains or {}) do
          truthy(content:find(needle, 1, true) ~= nil, case.name .. ': missing ' .. needle)
        end
        for _, needle in ipairs(case.generated or {}) do
          truthy(content:find(needle, 1, true) ~= nil, case.name .. ': missing generated ' .. needle)
        end
        for _, needle in ipairs(case.absent or {}) do
          falsy(content:find(needle, 1, true) ~= nil, case.name .. ': unexpected ' .. needle)
        end
      end)
    end
    falsy(go_adapter._code_uses_package('// fmt.Println("comment")', 'fmt'))
    falsy(go_adapter._code_uses_package('s := "log.Fatal(\\"x\\")"', 'log'))
    truthy(go_adapter._code_uses_package('x := fmt.Sprintf("%d", 1)', 'fmt'))
  end)

  it('executes bare fragments using non-instrumented fmt APIs end to end', function()
    if vim.fn.executable('go') ~= 1 then
      pending('go is required for bare fragment execution coverage')
      return
    end
    local src = 'x := fmt.Sprintf("%d", 42)\nfmt.Println(x)\n'
    local ctx = {
      runtime = { cmd = 'go', args = { 'run' }, env = { GO111MODULE = 'off' } },
      filetype = 'go',
      source = src,
      buf = 1,
      cwd = '.',
    }
    local prepared = go_adapter.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = vim.system(prepared.cmd, { text = true, timeout = 60000, env = { GO111MODULE = 'off' } }):wait()
      local events = go_adapter.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      eq(out.code, 0)
      local found = nil
      for _, e in ipairs(events) do
        if e.kind == 'stdout' then
          found = e
        end
      end
      assert(found ~= nil)
      eq(found.line, 2)
      eq(found.message, '42')
    end)
  end)
end)
