local assert = require 'luassert'
local shell_common = require 'itchy.adapters.shell_common'
local renderer = require 'itchy.renderer'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local pending = pending or function(message)
  print('SKIPPED: ' .. tostring(message))
  io.stdout:flush()
  return true
end

local api = vim.api

local shells = {
  { name = 'bash', adapter = require 'itchy.adapters.bash', cmd = 'bash', filetype = 'bash' },
  { name = 'zsh', adapter = require 'itchy.adapters.zsh', cmd = 'zsh', filetype = 'zsh' },
  { name = 'sh', adapter = require 'itchy.adapters.sh', cmd = 'sh', filetype = 'sh' },
}

local function ctx_for(shell, source, cmd)
  return {
    runtime = { cmd = cmd or shell.cmd, args = {} },
    filetype = shell.filetype,
    source = source,
    buf = 1,
    cwd = '.',
  }
end

local function with_cleanup(prepared, extra, fn)
  local ok, err = pcall(fn)
  pcall(prepared.cleanup)
  if extra then
    pcall(extra)
  end
  if not ok then
    error(err, 0)
  end
end

local function executable_or_pending(cmd)
  if vim.fn.executable(cmd) ~= 1 then
    pending(cmd .. ' is required for this shell integration case')
    return false
  end
  return true
end

local function run_decode(shell, ctx, prepared)
  local out = vim.system(prepared.cmd, { text = true, timeout = 20000 }):wait()
  local result = { code = out.code, signal = out.signal or 0, stdout = out.stdout, stderr = out.stderr }
  return shell.adapter.decode(ctx, prepared, result), out
end

local function events_by_line(events)
  local rows = {}
  for _, event in ipairs(events) do
    if event.line ~= nil then
      rows[event.line] = rows[event.line] or {}
      table.insert(rows[event.line], event)
    end
  end
  return rows
end

local function exact_events(actual, expected)
  eq(#actual, #expected)
  local consumed = {}
  for _, wanted in ipairs(expected) do
    local found
    for index, got in ipairs(actual) do
      if not consumed[index]
        and got.kind == wanted.kind
        and got.message == wanted.text
        and got.line == wanted.row
        and got.column == wanted.column
      then
        found = index
        break
      end
    end
    truthy(found ~= nil, 'missing exact event ' .. vim.inspect(wanted))
    consumed[found] = true
  end
end

local function shell_commands(shell)
  if shell.name ~= 'sh' then
    return { shell.cmd }
  end
  local commands = { 'sh' }
  if vim.fn.has('win32') == 0 and vim.fn.executable('dash') == 1 and vim.fn.exepath('dash') ~= vim.fn.exepath('sh') then
    table.insert(commands, 'dash')
  end
  return commands
end

describe('itchy shell adapters', function()
  for _, shell in ipairs(shells) do
    describe(shell.name, function()
      it('prepares a source file and preserves runtime arguments', function()
        local source = 'echo hello\nprintf "%s\\n" world\n'
        local ctx = ctx_for(shell, source)
        ctx.runtime.args = shell.name == 'bash' and { '-c', '--norc' }
          or shell.name == 'zsh' and { '-c', '--no-rcs' }
          or { '-c', '-u' }
        local prepared = shell.adapter.prepare(ctx)
        with_cleanup(prepared, nil, function()
          eq(prepared.cmd[1], shell.cmd)
          eq(prepared.temp_file, false)
          truthy(type(prepared.cleanup) == 'function')
          local user_file = prepared.metadata.user_file
          local file = io.open(user_file, 'r')
          truthy(file ~= nil)
          local content = file:read '*a'
          file:close()
          if shell.name == 'sh' then
            truthy(content:find('__itchy_echo 1 hello', 1, true) ~= nil)
            eq(prepared.cmd[2], '-u')
          else
            eq(content, source)
            truthy(prepared.cmd[#prepared.cmd]:find('itchy%-launcher', 1) ~= nil)
            eq(prepared.cmd[2], shell.name == 'bash' and '--norc' or '--no-rcs')
          end
        end)
      end)

      it('decodes side-channel records with exact locations', function()
        local prepared = shell.adapter.prepare(ctx_for(shell, ''))
        with_cleanup(prepared, nil, function()
          local nonce = prepared.metadata.nonce
          local file = io.open(prepared.metadata.event_file, 'w')
          file:write('\30ITCHY:' .. nonce .. ':{"kind":"stdout","line":2,"message":"hello"}\n')
          file:close()
          local output = shell_common.output_start(nonce, 1) .. 'hello\n' .. shell_common.output_end(nonce, 1)
          local events = shell.adapter.decode(ctx_for(shell, ''), prepared, {
            code = 0,
            signal = 0,
            stdout = output,
            stderr = '',
          })
          exact_events(events, { { kind = 'stdout', row = 2, text = 'hello' } })
        end)
      end)

      it('maps native diagnostics to source lines', function()
        local prepared = shell.adapter.prepare(ctx_for(shell, ''))
        with_cleanup(prepared, nil, function()
          local user_file = prepared.metadata.user_file
          local stderr
          if shell.name == 'bash' then
            stderr = user_file .. ': line 3: missing-command: command not found\n'
          elseif shell.name == 'sh' then
            stderr = user_file .. ': ' .. tostring(prepared.metadata.line_offset + 3) .. ': missing-command: not found\n'
          else
            stderr = user_file .. ':3: command not found: missing-command\n'
          end
          local events = shell.adapter.decode(ctx_for(shell, ''), prepared, {
            code = 1,
            signal = 0,
            stdout = '',
            stderr = stderr,
          })
          eq(#events, 1)
          eq(events[1].kind, 'error')
          eq(events[1].line, 3)
           eq(events[1].message, shell.name == 'zsh' and 'command not found: missing-command'
             or shell.name == 'bash' and 'missing-command: command not found'
             or 'missing-command: command not found')
        end)
      end)

      if shell.name == 'zsh' then
        it('loads zsh caller metadata support in the launcher', function()
          local launcher = shell.adapter._launcher('ABCDEF12', '/tmp/events', '/tmp/user')
          truthy(launcher:find('zmodload zsh/parameter', 1, true) ~= nil)
        end)
      elseif shell.name == 'sh' then
        it('keeps the prepared source POSIX-safe', function()
          local prepared = shell.adapter.prepare(ctx_for(shell, 'echo hello\nprintf "%s\\n" world\n'))
          with_cleanup(prepared, nil, function()
            local file = io.open(prepared.metadata.user_file, 'r')
            truthy(file ~= nil)
            local content = file:read '*a'
            file:close()
            for _, forbidden in ipairs({ 'BASH_SOURCE', 'BASH_LINENO', 'funcfiletrace', 'zmodload', 'pipefail', 'local%s', '%[%[' }) do
              falsy(content:find(forbidden) ~= nil, 'forbidden construct: ' .. forbidden)
            end
          end)
        end)
        it('instruments only output commands while preserving POSIX line count', function()
          local source = table.concat({
            '#!/bin/sh',
            '# comment',
            '',
            'echo hello',
            '  printf "%s\\n" world',
            'echofoo kept',
            'VAR=1 echo kept',
            'command echo via-command',
            'cat <<EOF',
            'inner echo kept',
            'EOF',
            'echo after',
          }, '\n') .. '\n'
          local rewritten = shell.adapter.instrument(source)
          eq(#vim.split(rewritten, '\n', { plain = true }), #vim.split(source, '\n', { plain = true }))
          truthy(rewritten:find('__itchy_echo 4 hello', 1, true) ~= nil)
          truthy(rewritten:find('__itchy_printf 5', 1, true) ~= nil)
          truthy(rewritten:find('__itchy_echo 8 via-command', 1, true) ~= nil)
          falsy(rewritten:find('__itchy_echo 10', 1, true) ~= nil)
          truthy(rewritten:find('__itchy_echo 12 after', 1, true) ~= nil)
        end)
      end

      for _, command in ipairs(shell_commands(shell)) do
        it('executes exact output and source mapping under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = table.concat({
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
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events = run_decode(shell, ctx, prepared)
            exact_events(events, {
              { kind = 'stdout', row = 1, text = 'hello' },
              { kind = 'stdout', row = 2, text = 'world' },
              { kind = 'stdout', row = 4, text = 'inside-func' },
              { kind = 'stdout', row = 8, text = 'in-if' },
            })
          end)
        end)

        it('keeps external stderr locationless under ' .. command, function()
          local prepared = shell.adapter.prepare(ctx_for(shell, ''))
          with_cleanup(prepared, nil, function()
            local events = shell.adapter.decode(ctx_for(shell, ''), prepared, {
              code = 1,
              signal = 0,
              stdout = '',
              stderr = 'ls: cannot access /nonexistent: No such file or directory\n',
            })
            exact_events(events, {
              { kind = 'error', row = nil, text = 'ls: cannot access /nonexistent: No such file or directory' },
            })
          end)
        end)

        it('maps stderr-redirection output once under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = 'echo to-err >&2\necho plain\n'
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events = run_decode(shell, ctx, prepared)
            exact_events(events, {
              { kind = 'stdout', row = 1, text = 'to-err' },
              { kind = 'stdout', row = 2, text = 'plain' },
            })
          end)
        end)

        it('reports command-not-found at the native source row under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = 'echo before\nmissing-command-xyz\necho after\n'
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events = run_decode(shell, ctx, prepared)
            local rows = events_by_line(events)
            eq(rows[1][1].message, 'before')
            eq(rows[3][1].message, 'after')
            local errors = {}
            for _, event in ipairs(events) do
              if event.kind == 'error' then
                table.insert(errors, event)
              end
            end
            eq(#errors, 1)
            eq(errors[1].line, 2)
             eq(errors[1].message, shell.name == 'zsh' and 'command not found: missing-command-xyz'
               or shell.name == 'bash' and 'missing-command-xyz: command not found'
               or 'missing-command-xyz: command not found')
          end)
        end)

        it('reports native syntax errors without losing their source location under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source
          local expected_line
          if shell.name == 'zsh' then
            source = 'echo before\nfi\necho after\n'
            expected_line = 2
          else
            source = 'echo before\nif [ ; then\necho broken\n'
            expected_line = 4
          end
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events = run_decode(shell, ctx, prepared)
            local found
            for _, event in ipairs(events) do
              if event.kind == 'error' then
                found = event
                break
              end
            end
            truthy(found ~= nil)
            eq(found.line, expected_line)
            truthy(found.message ~= '')
          end)
        end)

        it('renders padded selection output on the original row under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local selection_ctx = ctx_for(shell, '\n\necho "sel"\n', command)
          local prepared = shell.adapter.prepare(selection_ctx)
          local buf = api.nvim_create_buf(false, true)
          api.nvim_buf_set_lines(buf, 0, -1, false, { '', '', 'echo "sel"' })
          with_cleanup(prepared, function()
            pcall(api.nvim_buf_delete, buf, { force = true })
          end, function()
            local events = run_decode(shell, selection_ctx, prepared)
            exact_events(events, { { kind = 'stdout', row = 3, text = 'sel' } })
            local ns = api.nvim_create_namespace('itchy_shell_selection_' .. shell.name .. '_' .. command .. '_' .. tostring(buf))
            renderer.render(buf, ns, events, { line_count = 3 })
            local ready = vim.wait(2000, function()
              return #api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) == 1
            end, 50)
            truthy(ready)
            local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
            eq(marks[1][2], 2)
          end)
        end)

        it('preserves redirections and keeps their output out of residual stdout under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local redir = shell_common.temp_path '_itchy_redir'
          local source = 'echo redir-target > ' .. redir .. '\necho after\n'
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, function()
            vim.fn.delete(redir)
          end, function()
            local events, output = run_decode(shell, ctx, prepared)
            falsy(output.stdout:find('redir%-target') ~= nil)
            local file = io.open(redir, 'r')
            truthy(file ~= nil)
            eq(file:read '*a', 'redir-target\n')
            file:close()
            exact_events(events, {
              { kind = 'stdout', row = 1, text = 'redir-target' },
              { kind = 'stdout', row = 2, text = 'after' },
            })
          end)
        end)

        it('keeps transformed pipelines free of correlation markers under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = "printf '%s\\n' lower | tr a-z A-Z\necho after\n"
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events, output = run_decode(shell, ctx, prepared)
            truthy(output.stdout:find('LOWER', 1, true) ~= nil)
            local residual = shell_common.strip_marked_output(output.stdout, prepared.metadata.nonce)
            falsy(residual:find(shell_common.output_start(prepared.metadata.nonce, 1), 1, true) ~= nil)
            falsy(residual:find(shell_common.output_end(prepared.metadata.nonce, 1), 1, true) ~= nil)
            eq(residual, '')
            exact_events(events, {
              { kind = 'stdout', row = 1, text = 'lower' },
              { kind = 'stdout', row = 2, text = 'after' },
            })
          end)
        end)

        it('preserves identical external output around framed output under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source
          if shell.name == 'sh' then
            source = table.concat({
              "awk 'BEGIN { print \"collision-output\" }'",
              'echo collision-output',
              "awk 'BEGIN { print \"collision-output\" }'",
              '',
            }, '\n')
          else
            source = table.concat({
              "command printf '%s\\n' collision-output",
              "printf '%s\\n' collision-output",
              "command printf '%s\\n' collision-output",
              '',
            }, '\n')
          end
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events, output = run_decode(shell, ctx, prepared)
            eq(shell_common.strip_marked_output(output.stdout, prepared.metadata.nonce), 'collision-output\ncollision-output\n')
            exact_events(events, {
              { kind = 'stdout', row = nil, text = 'collision-output' },
              { kind = 'stdout', row = 2, text = 'collision-output' },
              { kind = 'stdout', row = nil, text = 'collision-output' },
            })
          end)
        end)

        it('keeps concurrent nested shell output distinct under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = table.concat({
            '(',
            '  echo nested-one',
            '  ( echo nested-two )',
            ') &',
            'wait',
            'echo outer',
            '',
          }, '\n')
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events, output = run_decode(shell, ctx, prepared)
            local residual = shell_common.strip_marked_output(output.stdout, prepared.metadata.nonce)
            falsy(residual:find(shell_common.output_start(prepared.metadata.nonce, 1), 1, true) ~= nil)
            falsy(residual:find(shell_common.output_end(prepared.metadata.nonce, 1), 1, true) ~= nil)
            exact_events(events, {
              { kind = 'stdout', row = 2, text = 'nested-one' },
              { kind = 'stdout', row = 3, text = 'nested-two' },
              { kind = 'stdout', row = 6, text = 'outer' },
            })
          end)
        end)

        it('does not duplicate non-newline output under ' .. command, function()
          if not executable_or_pending(command) then
            return
          end
          local source = "printf '%s' foo\nprintf '%s\\n' bar\n"
          local ctx = ctx_for(shell, source, command)
          local prepared = shell.adapter.prepare(ctx)
          with_cleanup(prepared, nil, function()
            local events, output = run_decode(shell, ctx, prepared)
            truthy(output.stdout:find('foobar', 1, true) ~= nil)
            exact_events(events, {
              { kind = 'stdout', row = 1, text = 'foo' },
              { kind = 'stdout', row = 2, text = 'bar' },
            })
          end)
        end)

        if shell.name ~= 'sh' then
          it('keeps command and builtin prefixes from recursing under ' .. command, function()
            if not executable_or_pending(command) then
              return
            end
            local source = 'command echo via-command\nbuiltin echo via-builtin\necho plain\n'
            local ctx = ctx_for(shell, source, command)
            local prepared = shell.adapter.prepare(ctx)
            with_cleanup(prepared, nil, function()
              local events, output = run_decode(shell, ctx, prepared)
              truthy(output.stdout:find('via-command', 1, true) ~= nil)
              truthy(output.stdout:find('via-builtin', 1, true) ~= nil)
              exact_events(events, {
                { kind = 'stdout', row = nil, text = 'via-command' },
                { kind = 'stdout', row = nil, text = 'via-builtin' },
                { kind = 'stdout', row = 3, text = 'plain' },
              })
            end)
          end)

          it('preserves printf -v assignments under ' .. command, function()
            if not executable_or_pending(command) then
              return
            end
            local source = 'printf -v myvar "%s" hello\necho "myvar=$myvar"\n'
            local ctx = ctx_for(shell, source, command)
            local prepared = shell.adapter.prepare(ctx)
            with_cleanup(prepared, nil, function()
              local events = run_decode(shell, ctx, prepared)
              exact_events(events, { { kind = 'stdout', row = 2, text = 'myvar=hello' } })
            end)
          end)
        end
      end

      if shell.name == 'sh' then
        for _, command in ipairs(shell_commands(shell)) do
          it('escapes control characters under ' .. command, function()
            if not executable_or_pending(command) then
              return
            end
            local ansi = string.char(27) .. '[31mansi' .. string.char(27) .. '[0m' .. string.char(1)
            local quoted = 'quote " slash \\ backslash'
            local source = table.concat({
              "printf '%s\\n' \"$(printf '\\033[31mansi\\033[0m\\001')\"",
              [[printf '%s\n' 'quote " slash \ backslash']],
            }, '\n') .. '\n'
            local ctx = ctx_for(shell, source, command)
            local prepared = shell.adapter.prepare(ctx)
            with_cleanup(prepared, nil, function()
              local events = run_decode(shell, ctx, prepared)
              exact_events(events, {
                { kind = 'stdout', row = 1, text = ansi },
                { kind = 'stdout', row = 2, text = quoted },
              })
            end)
          end)
        end
      end
    end)
  end

  it('strips interleaved marker spans without consuming unrelated output', function()
    local nonce = 'ABCDEF12'
    local text = 'before\n'
      .. shell_common.output_start(nonce, 1)
      .. 'one'
      .. shell_common.output_start(nonce, 2)
      .. 'two'
      .. shell_common.output_end(nonce, 1)
      .. 'tail'
      .. shell_common.output_end(nonce, 2)
      .. 'after\n'
    eq(shell_common.strip_marked_output(text, nonce), 'before\nafter\n')
  end)
end)
