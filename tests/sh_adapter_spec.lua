local sh = require 'itchy.adapters.sh'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local function ctx_for(source, cmd)
  return {
    runtime = { cmd = cmd or 'sh', args = {} },
    filetype = 'sh',
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

--- Execute a prepared run with the given shell and decode the result.
local function run_decode(ctx, prepared)
  local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
  return sh.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr }), out
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

--- Shells under test: the system sh plus a non-Bash sh where available.
local function shells()
  local found = {}
  if vim.fn.executable('sh') == 1 then
    table.insert(found, 'sh')
  end
  if vim.fn.executable('dash') == 1 and vim.fn.exepath('dash') ~= vim.fn.exepath('sh') then
    table.insert(found, 'dash')
  end
  return found
end

describe('itchy.adapters.sh', function()
  it('resolves by name through the registry', function()
    eq(adapters.resolve({ adapter = 'sh' }).name, 'sh')
  end)

  it('prepare() executes a single file with a header offset', function()
    local source = 'echo hello\n'
    local prepared = sh.prepare(ctx_for(source))
    with_cleanup(prepared, nil, function()
      eq(prepared.cmd[1], 'sh')
      eq(prepared.cmd[2], prepared.metadata.user_file)
      truthy(prepared.metadata.line_offset >= 1)
      local f = io.open(prepared.metadata.user_file, 'r')
      truthy(f ~= nil)
      local content = f:read '*a'
      f:close()
      truthy(content:find('__itchy_echo 1 hello', 1, true) ~= nil)
    end)
  end)

  it('prepare() preserves custom runtime.args while filtering -c', function()
    local ctx = ctx_for('echo hello\n')
    ctx.runtime.args = { '-c', '-u' }
    local prepared = sh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      eq(prepared.cmd[1], 'sh')
      eq(prepared.cmd[2], '-u')
      eq(prepared.cmd[3], prepared.metadata.user_file)
    end)
  end)

  it('instrument() rewrites only output commands, preserving line count', function()
    local src = table.concat({
      '#!/bin/sh',
      '# a comment',
      '',
      'echo hello',
      '  printf "%s\\n" world',
      'echofoo kept',
      'VAR=1 echo kept',
      'command echo via',
      'builtin printf "%s" x',
      'echo hi; echo bye',
      'cat <<EOF',
      'inner echo kept',
      'EOF',
      'echo after',
    }, '\n') .. '\n'
    local out = sh.instrument(src)
    eq(#vim.split(out, '\n', { plain = true }), #vim.split(src, '\n', { plain = true }))
    truthy(out:find('__itchy_echo 4 hello', 1, true) ~= nil)
    truthy(out:find('__itchy_printf 5', 1, true) ~= nil)
    truthy(out:find('echofoo kept', 1, true) ~= nil)
    truthy(out:find('VAR=1 echo kept', 1, true) ~= nil)
    truthy(out:find('__itchy_echo 8 via', 1, true) ~= nil)
    truthy(out:find('__itchy_printf 9', 1, true) ~= nil)
    truthy(out:find('inner echo kept', 1, true) ~= nil)
    falsy(out:find('__itchy_echo 12', 1, true) ~= nil)
    truthy(out:find('__itchy_echo 14 after', 1, true) ~= nil)
  end)

  it('prepared code is POSIX-safe (no Bash/Zsh-only constructs)', function()
    local source = 'echo hello\nprintf "%s\\n" world\n'
    local prepared = sh.prepare(ctx_for(source))
    with_cleanup(prepared, nil, function()
      local f = io.open(prepared.metadata.user_file, 'r')
      truthy(f ~= nil)
      local content = f:read '*a'
      f:close()
      -- Regression gate: the compatibility path must not depend on
      -- Bash/Zsh-specific facilities.
      local forbidden = {
        'function%s+%w+%s*%(',
        'trap%s+ERR',
        'BASH_SOURCE',
        'BASH_LINENO',
        'BASH_REMATCH',
        'pipefail',
        'funcfiletrace',
        'funcsourcetrace',
        'zmodload',
        '%[%[',
        '%$%{[^}]*//',
        "%$'",
        'local%s',
        'caller%s',
        '%&>',
        'declare%s',
      }
      for _, pattern in ipairs(forbidden) do
        falsy(content:find(pattern) ~= nil, 'forbidden construct: ' .. pattern)
      end
    end)
  end)

  it('maps header-shifted native diagnostics back to source lines', function()
    local ctx = ctx_for('')
    local prepared = sh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local user_file = prepared.metadata.user_file
      local offset = prepared.metadata.line_offset
      local result = {
        code = 1,
        signal = 0,
        stdout = '',
        stderr = user_file .. ': ' .. tostring(offset + 3) .. ': boom-cmd: not found\n',
      }
      local events = sh.decode(ctx, prepared, result)
      eq(#events, 1)
      eq(events[1].kind, 'error')
      eq(events[1].line, 3)
    end)
  end)

  it('never invents locations for external-command stderr', function()
    local ctx = ctx_for('')
    local prepared = sh.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local result = {
        code = 1,
        signal = 0,
        stdout = '',
        stderr = 'ls: cannot access /nonexistent: No such file or directory\n',
      }
      local events = sh.decode(ctx, prepared, result)
      eq(#events, 1)
      eq(events[1].kind, 'error')
      eq(events[1].line, nil)
      truthy(events[1].message:find('No such file', 1, true) ~= nil)
    end)
  end)

  for _, shell in ipairs(shells()) do
    it('executes end to end under ' .. shell .. ' with source-line mapping', function()
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
      local ctx = ctx_for(src, shell)
      local prepared = sh.prepare(ctx)
      with_cleanup(prepared, nil, function()
        local events = run_decode(ctx, prepared)
        local by_line = events_by_line(events)
        eq(by_line[1][1].message, 'hello')
        eq(by_line[2][1].message, 'world')
        eq(by_line[4][1].message, 'inside-func')
        eq(by_line[8][1].message, 'in-if')
      end)
    end)

    it('preserves redirections under ' .. shell, function()
      local redir = vim.fn.tempname() .. '_itchy_redir'
      local ctx = ctx_for('echo "redir-target" > ' .. redir .. '\necho after\n', shell)
      local prepared = sh.prepare(ctx)
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

    it('keeps pipelines intact under ' .. shell, function()
      local ctx = ctx_for("printf '%s\\n' piped | cat\necho pipe-test | cat\n", shell)
      local prepared = sh.prepare(ctx)
      with_cleanup(prepared, nil, function()
        local events, out = run_decode(ctx, prepared)
        falsy(out.stdout:find('ITCHY', 1, true) ~= nil)
        local by_line = events_by_line(events)
        eq(by_line[1][1].message, 'piped')
        eq(by_line[2][1].message, 'pipe-test')
      end)
    end)

    it('reports syntax errors under ' .. shell .. ' with source locations', function()
      local ctx = ctx_for('echo hello\nif [ ; then\necho broken\n', shell)
      local prepared = sh.prepare(ctx)
      with_cleanup(prepared, nil, function()
        local events = run_decode(ctx, prepared)
        local found_err = nil
        for _, e in ipairs(events) do
          if e.kind == 'error' then
            found_err = e
          end
        end
        assert(found_err ~= nil)
        eq(found_err.line, 4)
      end)
    end)

    it('reports command-not-found under ' .. shell .. ' with source locations', function()
      local ctx = ctx_for('echo before\nnonexistent-cmd-xyz\necho after\n', shell)
      local prepared = sh.prepare(ctx)
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

    it('renders padded selections on original lines under ' .. shell, function()
      local renderer = require('itchy.renderer')
      local ctx = ctx_for('\n\necho "sel"\n', shell)
      local prepared = sh.prepare(ctx)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '', 'echo "sel"' })
      with_cleanup(prepared, function()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end, function()
        local events = run_decode(ctx, prepared)
        eq(#events, 1)
        eq(events[1].line, 3)
        local ns = vim.api.nvim_create_namespace('itchy_sh_sel_' .. shell .. '_' .. tostring(buf))
        renderer.render(buf, ns, events, { line_count = 3 })
        vim.wait(2000, function()
          return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0
        end, 50)
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        eq(#marks, 1)
        eq(marks[1][2], 2)
      end)
    end)
  end
end)
