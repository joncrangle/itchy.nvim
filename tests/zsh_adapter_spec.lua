local zsh = require 'itchy.adapters.zsh'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local function ctx_for(source)
  return {
    runtime = { cmd = 'zsh', args = {} },
    filetype = 'zsh',
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

--- Execute a prepared run and decode the real result.
local function run_decode(ctx, prepared)
  local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
  return zsh.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr }), out
end

local function events_by_line(events)
  local by_line = {}
  for _, e in ipairs(events) do
    if e.line ~= nil then
      by_line[e.line] = by_line[e.line] or {}
      table.insert(by_line[e.line], e)
    end
  end
  return by_line
end

describe('itchy.adapters.zsh', function()
  it('resolves by name through the registry', function()
    eq(adapters.resolve({ adapter = 'zsh' }).name, 'zsh')
  end)

  it('prepare() keeps user source unchanged and passes a launcher argv', function()
    local source = 'echo hello\n'
    local prepared = zsh.prepare(ctx_for(source))
    with_cleanup(prepared, nil, function()
      local f = io.open(prepared.metadata.user_file, 'r')
      truthy(f ~= nil)
      local content = f:read '*a'
      f:close()
      eq(content, source)
      eq(prepared.cmd[1], 'zsh')
      truthy(prepared.cmd[2]:find('itchy%-launcher', 1) ~= nil)
      eq(prepared.temp_file, false)
    end)
  end)

  it('prepare() preserves custom runtime.args while filtering -c', function()
    local ctx = ctx_for('echo hello\n')
    ctx.runtime.args = { '-c', '--no-rcs' }
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      eq(prepared.cmd[1], 'zsh')
      eq(prepared.cmd[2], '--no-rcs')
      truthy(prepared.cmd[3]:find('itchy%-launcher', 1) ~= nil)
    end)
  end)

  it('launcher captures caller metadata inline via funcfiletrace', function()
    local launcher = zsh._launcher('nonce', '/tmp/ev', '/tmp/user')
    truthy(launcher:find('zmodload zsh/parameter', 1, true) ~= nil)
    truthy(launcher:find('funcfiletrace', 1, true) ~= nil)
    truthy(launcher:find('builtin echo', 1, true) ~= nil)
    truthy(launcher:find('builtin printf', 1, true) ~= nil)
    falsy(launcher:find('currentLine', 1, true) ~= nil)
    falsy(launcher:find('BASH_LINENO', 1, true) ~= nil)
  end)

  it('decodes framed records with exact source lines', function()
    local ctx = ctx_for('')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local nonce = prepared.metadata.nonce
      local ef = io.open(prepared.metadata.event_file, 'w')
      ef:write('\30ITCHY:' .. nonce .. ':{"kind":"stdout","line":3,"message":"hi"}\n')
      ef:close()
      local events = zsh.decode(ctx, prepared, { code = 0, signal = 0, stdout = 'hi\n', stderr = '' })
      eq(#events, 1)
      eq(events[1].kind, 'stdout')
      eq(events[1].line, 3)
      eq(events[1].message, 'hi')
    end)
  end)

  it('parses native zsh diagnostics to the user file', function()
    local ctx = ctx_for('')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local user_file = prepared.metadata.user_file
      local result = {
        code = 1,
        signal = 0,
        stdout = '',
        stderr = user_file .. ':4: command not found: nope\n',
      }
      local events = zsh.decode(ctx, prepared, result)
      eq(#events, 1)
      eq(events[1].kind, 'error')
      eq(events[1].line, 4)
      truthy(events[1].message:find('command not found', 1, true) ~= nil)
    end)
  end)

  it('executes end to end with exact source-line mapping', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local src = table.concat({
      'echo hello',
      'printf "%s\\n" world',
      'greet() {',
      '  echo inside-func',
      '}',
      'greet',
      'if true; then',
      '  echo in-if',
      'fi',
      '',
    }, '\n')
    local ctx = ctx_for(src)
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events = run_decode(ctx, prepared)
      local by_line = events_by_line(events)
      eq(by_line[1][1].message, 'hello')
      eq(by_line[2][1].message, 'world')
      -- funcfiletrace resolves inside functions to the user call site,
      -- not the instrumentation helper.
      eq(by_line[4][1].message, 'inside-func')
      eq(by_line[8][1].message, 'in-if')
    end)
  end)

  it('preserves redirections without polluting files', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local redir = vim.fn.tempname() .. '_itchy_redir'
    local ctx = ctx_for('echo "redir-target" > ' .. redir .. '\necho after\n')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, function()
      vim.fn.delete(redir)
    end, function()
      local events, out = run_decode(ctx, prepared)
      falsy(out.stdout:find('redir%-target', 1) ~= nil)
      local f = io.open(redir, 'r')
      truthy(f ~= nil)
      local content = f:read '*a'
      f:close()
      truthy(content:find('redir-target', 1, true) ~= nil)
      local by_line = events_by_line(events)
      eq(by_line[1][1].message, 'redir-target')
      eq(by_line[2][1].message, 'after')
    end)
  end)

  it('keeps pipelines intact without metadata leaks', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local ctx = ctx_for("printf '%s\\n' piped | cat\necho pipe-test | cat\n")
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events, out = run_decode(ctx, prepared)
      falsy(out.stdout:find('ITCHY', 1, true) ~= nil)
      local by_line = events_by_line(events)
      eq(by_line[1][1].message, 'piped')
      eq(by_line[2][1].message, 'pipe-test')
    end)
  end)

  it('leaves command/builtin prefixes working without recursion', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local ctx = ctx_for('command echo via-command\nbuiltin echo via-builtin\necho plain\n')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events, out = run_decode(ctx, prepared)
      truthy(out.stdout:find('via%-command', 1) ~= nil)
      truthy(out.stdout:find('via%-builtin', 1) ~= nil)
      local by_line = events_by_line(events)
      eq(by_line[3][1].message, 'plain')
    end)
  end)

  it('preserves printf -v semantics with no stdout event', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local ctx = ctx_for('printf -v myvar "%s" hello\necho "myvar=$myvar"\n')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events = run_decode(ctx, prepared)
      eq(#events, 1)
      eq(events[1].line, 2)
      eq(events[1].message, 'myvar=hello')
    end)
  end)

  it('reports syntax errors with native locations', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local ctx = ctx_for('echo hello\nfi\necho after\n')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events = run_decode(ctx, prepared)
      local found_err = nil
      for _, e in ipairs(events) do
        if e.kind == 'error' then
          found_err = e
        end
      end
      assert(found_err ~= nil)
      eq(found_err.line, 2)
    end)
  end)

  it('reports command-not-found with native locations', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local ctx = ctx_for('echo before\nnonexistent-cmd-xyz\necho after\n')
    local prepared = zsh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local events = run_decode(ctx, prepared)
      local found_err = nil
      for _, e in ipairs(events) do
        if e.kind == 'error' then
          found_err = e
        end
      end
      assert(found_err ~= nil)
      eq(found_err.line, 2)
      truthy(found_err.message:find('command not found', 1, true) ~= nil)
    end)
  end)

  it('renders padded selection sources on original buffer lines', function()
    if vim.fn.executable('zsh') ~= 1 then
      return
    end
    local renderer = require('itchy.renderer')
    local ctx = ctx_for('\n\necho "sel"\n')
    local prepared = zsh.prepare(ctx)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '', 'echo "sel"' })
    with_cleanup(prepared, function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end, function()
      local events = run_decode(ctx, prepared)
      eq(#events, 1)
      eq(events[1].line, 3)
      local ns = vim.api.nvim_create_namespace('itchy_zsh_sel_' .. tostring(buf))
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
