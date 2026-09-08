local executor = require('itchy.executor')
local system_backend = require('itchy.executor.system')
local utils = require('itchy.utils')
local runtimes = require('itchy.runtimes')
local itchy = require('itchy')
local api = vim.api
local assert = require('luassert')

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local pending = pending or function(message)
  print('SKIPPED: ' .. tostring(message))
  io.stdout:flush()
  return true
end

---@param cmd string[]
---@param env? table<string,string>
---@return any err
---@return itchy.ExecutionResult? result
local function run_system(cmd, env)
  local done = false
  local got_err, got_result = nil, nil
  system_backend.execute({ cmd = cmd, cwd = vim.fn.getcwd(), env = env }, function(err, result)
    got_err = err
    got_result = result
    done = true
  end)
  local ok = vim.wait(15000, function()
    return done
  end, 50)
  assert(ok, 'system backend timed out for: ' .. table.concat(cmd, ' '))
  return got_err, got_result
end

describe('itchy.executor backend selection', function()
  after_each(function()
    executor._backend_override = nil
  end)

  it('selects the callback system backend on Neovim < 0.13', function()
    if executor.supports_vim_async() then
      pending('running on Neovim 0.13+, fallback selection covered by CI 0.11 job')
      return
    end
    falsy(executor.supports_vim_async())
    eq(executor.backend_name(), 'itchy.executor.system')
    -- Plugin loads without touching the async backend.
    assert(require('itchy') ~= nil)
    assert(package.loaded['itchy.executor.async'] == nil)
  end)

  it('uses the async backend when 0.13 API is available', function()
    if not executor.supports_vim_async() then
      pending('requires Neovim 0.13+ with vim.async; exercised by CI nightly job')
      return
    end
    truthy(executor.supports_vim_async())
    eq(executor.backend_name(), 'itchy.executor.async')
    local ok, mod = pcall(require, 'itchy.executor.async')
    truthy(ok)
    assert(type(mod.execute) == 'function')
  end)

  it('falls back to system backend when the selected backend cannot load', function()
    executor._backend_override = 'itchy.executor.nonexistent_xyz'
    local done = false
    local handle = executor.execute({ cmd = { 'python', '-c', 'print(1)' }, cwd = vim.fn.getcwd() }, function()
      done = true
    end)
    assert(handle ~= nil)
    vim.wait(15000, function()
      return done
    end, 50)
    truthy(done)
  end)
end)

describe('itchy.executor.system execution', function()
  it('captures stdout', function()
    local err, res = run_system({ 'python', '-c', 'print("LINE0: hello")' }, nil)
    eq(err, nil)
    assert(res ~= nil)
    truthy(res.stdout:find('LINE0: hello', 1, true) ~= nil)
  end)

  it('captures stderr', function()
    local err, res = run_system({ 'python', '-c', 'import sys; sys.stderr.write("LINE1: Error: boom\\n")' }, nil)
    eq(err, nil)
    assert(res ~= nil)
    truthy(res.stderr:find('boom', 1, true) ~= nil)
  end)

  it('keeps stdout on non-zero exit', function()
    local err, res = run_system({ 'python', '-c', 'print("LINE0: out"); raise SystemExit(3)' }, nil)
    eq(err, nil)
    assert(res ~= nil)
    eq(res.code, 3)
    truthy(res.stdout:find('LINE0: out', 1, true) ~= nil)
  end)

  it('reports spawn failure', function()
    local err, res = run_system({ 'itchy-definitely-missing-binary-xyz', '--help' }, nil)
    assert(err ~= nil)
    eq(res, nil)
  end)

  it('passes env to the child without leaking into Neovim', function()
    local err, res = run_system(
      { 'python', '-c', 'import os; print(os.environ.get("ITCHY_TEST_VAR", "MISSING"))' },
      { ITCHY_TEST_VAR = 'itchy-child-value' }
    )
    eq(err, nil)
    assert(res ~= nil)
    truthy(res.stdout:find('itchy-child-value', 1, true) ~= nil)
    eq(vim.fn.getenv('ITCHY_TEST_VAR'), vim.NIL)
  end)

  it('preserves arguments containing spaces', function()
    local err, res = run_system({ 'python', '-c', 'import sys; print(sys.argv[1])', 'hello world with spaces' }, nil)
    eq(err, nil)
    assert(res ~= nil)
    truthy(res.stdout:find('hello world with spaces', 1, true) ~= nil)
  end)

  it('executes via a temporary source file', function()
    local path, terr = utils.create_temp_code_file('python', 'print("LINE0: from-tempfile")\n')
    assert(path ~= nil, tostring(terr))
    local err, res = run_system({ 'python', path }, nil)
    utils.remove_temp_file(path)
    eq(err, nil)
    assert(res ~= nil)
    truthy(res.stdout:find('from-tempfile', 1, true) ~= nil)
  end)

  it('cancellation terminates the subprocess and is idempotent', function()
    local calls = 0
    local handle = system_backend.execute(
      { cmd = { 'python', '-c', 'import time; time.sleep(30)' }, cwd = vim.fn.getcwd() },
      function()
        calls = calls + 1
      end
    )
    truthy(handle:is_running())
    handle:cancel()
    handle:cancel()
    falsy(handle:is_running())
    vim.wait(3000, function()
      return calls > 0
    end, 50)
    eq(calls, 1)
  end)

  it('temp source files are removed after cancellation', function()
    local recorded = {}
    local orig_create = utils.create_temp_code_file
    utils.create_temp_code_file = function(ft, code)
      local path, err = orig_create(ft, code)
      table.insert(recorded, path)
      return path, err
    end
    runtimes.runtimes['itchytest'] = {
      slowtemp = {
        cmd = 'python',
        args = {},
        offset = 0,
        wrapper = function(_)
          return 'import time; time.sleep(30)\n'
        end,
        temp_file = true,
        env = {},
      },
    }
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'itchytest'
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
    api.nvim_set_current_buf(buf)
    -- Real system backend (no fake installed in this suite section).
    itchy.run('slowtemp', buf)
    local started = vim.wait(5000, function()
      return #recorded == 1 and recorded[1] ~= nil and vim.fn.filereadable(recorded[1]) == 1
    end, 50)
    truthy(started)
    itchy.clear(buf)
    local gone = vim.wait(5000, function()
      return vim.fn.filereadable(recorded[1]) == 0
    end, 50)
    truthy(gone)
    eq(itchy._active_runs[buf], nil)
    utils.create_temp_code_file = orig_create
    runtimes.runtimes['itchytest'] = nil
    pcall(api.nvim_buf_delete, buf, { force = true })
  end)

  it('async backend cancellation terminates the subprocess', function()
    if not executor.supports_vim_async() then
      pending('requires Neovim 0.13+ with vim.async; exercised by CI nightly job')
      return
    end
    local async_backend = require('itchy.executor.async')
    local calls = {}
    local handle = async_backend.execute(
      { cmd = { 'python', '-c', 'import time; time.sleep(30)' }, cwd = vim.fn.getcwd() },
      function(err, result)
        table.insert(calls, { err = err, result = result })
      end
    )
    truthy(handle:is_running())
    handle:cancel()
    handle:cancel()
    falsy(handle:is_running())
    vim.wait(5000, function()
      return #calls > 0
    end, 50)
    eq(#calls, 1)
    eq(calls[1].err, 'cancelled')
    eq(calls[1].result, nil)
  end)
end)

describe('itchy buffer-owned execution lifecycle', function()
  local fake = nil

  local function install_fake()
    fake = { requests = {}, callbacks = {}, handles = {}, cancel_calls = 0 }
    local exec = require('itchy.executor')
    fake.original = exec.execute
    exec.execute = function(request, callback)
      table.insert(fake.requests, request)
      table.insert(fake.callbacks, callback)
      local handle = {}
      handle._cancelled = false
      function handle:cancel()
        if handle._cancelled then
          return
        end
        handle._cancelled = true
        fake.cancel_calls = fake.cancel_calls + 1
      end
      function handle:is_running()
        return not handle._cancelled
      end
      table.insert(fake.handles, handle)
      return handle
    end
  end

  local function uninstall_fake()
    if fake == nil then
      return
    end
    require('itchy.executor').execute = fake.original
    fake = nil
  end

  local function setup_buf(ft, lines)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = ft
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_set_current_buf(buf)
    return buf
  end

  local function get_marks(buf, ns)
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local out = {}
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].virt_lines then
        for _, line in ipairs(mark[4].virt_lines) do
          local text = ''
          for _, chunk in ipairs(line) do
            if not chunk[1]:match('^%s*│%s*$') then
              text = text .. chunk[1]
            end
          end
          table.insert(out, text)
        end
      end
    end
    return out
  end

  before_each(function()
    -- See runtimes_spec: other files reset package.loaded between tests.
    -- Refresh here so the registry below and itchy.run() share instances.
    package.loaded['itchy'] = nil
    package.loaded['itchy.runtimes'] = nil
    itchy = require 'itchy'
    runtimes = require 'itchy.runtimes'

    itchy._reset_runs()
    runtimes.runtimes['itchytest'] = {
      fake = {
        cmd = 'fake-cmd',
        args = {},
        offset = 0,
        wrapper = function(code)
          return code
        end,
        temp_file = false,
        env = {},
      },
      faketemp = {
        cmd = 'fake-cmd',
        args = {},
        offset = 0,
        wrapper = function(code)
          return code
        end,
        temp_file = true,
        env = {},
      },
    }
    install_fake()
  end)

  after_each(function()
    uninstall_fake()
    itchy._reset_runs()
    runtimes.runtimes['itchytest'] = nil
  end)

  it('latest run wins and stale completions never overwrite', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    eq(#fake.requests, 1)
    itchy.run('fake', buf)
    eq(#fake.requests, 2)
    eq(fake.cancel_calls, 1)

    -- Complete newest run first.
    fake.callbacks[2](nil, { code = 0, signal = 0, stdout = 'LINE0: from-B\n', stderr = '' })
    local ns = api.nvim_get_namespaces()['itchy_itchytest_result']
    assert(ns ~= nil)
    local ok = vim.wait(2000, function()
      return #get_marks(buf, ns) > 0
    end, 50)
    truthy(ok)
    local marks = get_marks(buf, ns)
    eq(#marks, 1)
    truthy(marks[1]:find('from-B', 1, true) ~= nil)

    -- Stale completion from A must not overwrite B.
    fake.callbacks[1](nil, { code = 0, signal = 0, stdout = 'LINE0: from-A\n', stderr = '' })
    vim.wait(300, function()
      return false
    end, 50)
    local after = get_marks(buf, ns)
    eq(#after, 1)
    truthy(after[1]:find('from-B', 1, true) ~= nil)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('clear while running cancels and blocks delayed completion', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    eq(#fake.handles, 1)
    itchy.clear(buf)
    truthy(fake.handles[1]._cancelled)
    fake.callbacks[1](nil, { code = 0, signal = 0, stdout = 'LINE0: late\n', stderr = '' })
    vim.wait(300, function()
      return false
    end, 50)
    local namespaces = api.nvim_get_namespaces()
    local ns = namespaces['itchy_itchytest_result']
    if ns then
      eq(#get_marks(buf, ns), 0)
    end
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('clear between completion and render blocks resurrection', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    -- Complete the run: schedules render + release via vim.schedule.
    fake.callbacks[1](nil, { code = 0, signal = 0, stdout = 'LINE0: late\n', stderr = '' })
    -- Clear before the scheduled render fires. Must invalidate the
    -- completed-but-pending run so it cannot resurrect extmarks.
    itchy.clear(buf)
    vim.wait(500, function()
      return false
    end, 50)
    local namespaces = api.nvim_get_namespaces()
    local ns = namespaces['itchy_itchytest_result']
    if ns and api.nvim_buf_is_valid(buf) then
      eq(#get_marks(buf, ns), 0)
    end
    eq(itchy._active_runs[buf], nil)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('edit invalidation uses the TextChanged path and suppresses stale output', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    -- Same invalidation path the TextChanged/TextChangedI autocmd uses.
    itchy._invalidate_run(buf, true)
    truthy(fake.handles[1]._cancelled)
    fake.callbacks[1](nil, { code = 0, signal = 0, stdout = 'LINE0: stale\n', stderr = '' })
    vim.wait(300, function()
      return false
    end, 50)
    local ns = api.nvim_get_namespaces()['itchy_itchytest_result']
    if ns then
      eq(#get_marks(buf, ns), 0)
    end
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('buffer deletion cleans execution state without errors', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    api.nvim_buf_delete(buf, { force = true })
    -- Lifecycle BufWipeout/BufDelete autocmd must have released the run.
    vim.wait(500, function()
      return itchy._active_runs[buf] == nil
    end, 50)
    eq(itchy._active_runs[buf], nil)
    -- Delayed completion after wipeout must not error or render.
    local ok = pcall(fake.callbacks[1], nil, { code = 0, signal = 0, stdout = 'LINE0: late\n', stderr = '' })
    truthy(ok)
    vim.wait(300, function()
      return false
    end, 50)
  end)

  it('repeated cancellation is harmless', function()
    local buf = setup_buf('itchytest', { 'code' })
    itchy.run('fake', buf)
    local ok = pcall(function()
      fake.handles[1]:cancel()
      fake.handles[1]:cancel()
      itchy.clear(buf)
      itchy.clear(buf)
    end)
    truthy(ok)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('spawn failures release state and temp files', function()
    local recorded = {}
    local orig_create = utils.create_temp_code_file
    utils.create_temp_code_file = function(ft, code)
      local path, err = orig_create(ft, code)
      table.insert(recorded, path)
      return path, err
    end
    local exec = require('itchy.executor')
    local orig_exec = exec.execute
    exec.execute = function(_, callback)
      vim.schedule(function()
        callback('boom-spawn', nil)
      end)
      return { cancel = function() end, is_running = function()
        return false
      end }
    end
    local buf = setup_buf('itchytest', { 'code' })
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, ...)
      table.insert(notified, tostring(msg))
      return orig_notify(msg, ...)
    end
    itchy.run('faketemp', buf)
    vim.wait(2000, function()
      return #notified > 0
    end, 50)
    truthy(#notified > 0)
    eq(itchy._active_runs[buf], nil)
    for _, path in ipairs(recorded) do
      if path then
        falsy(vim.fn.filereadable(path) == 1)
      end
    end
    utils.create_temp_code_file = orig_create
    exec.execute = orig_exec
    vim.notify = orig_notify
    api.nvim_buf_delete(buf, { force = true })
  end)

  it('temp source files are removed after success', function()
    uninstall_fake()
    local recorded = {}
    local orig_create = utils.create_temp_code_file
    utils.create_temp_code_file = function(ft, code)
      local path, err = orig_create(ft, code)
      table.insert(recorded, path)
      return path, err
    end
    runtimes.runtimes['itchytest'].faketemp.cmd = 'python'
    runtimes.runtimes['itchytest'].faketemp.args = {}
    runtimes.runtimes['itchytest'].faketemp.wrapper = function(code)
      return 'print("LINE0: temp-ok")\n'
    end
    local buf = setup_buf('itchytest', { 'x = 1' })
    itchy.run('faketemp', buf)
    vim.wait(15000, function()
      return itchy._active_runs[buf] == nil
    end, 50)
    eq(itchy._active_runs[buf], nil)
    assert(#recorded == 1 and recorded[1] ~= nil)
    falsy(vim.fn.filereadable(recorded[1]) == 1)
    utils.create_temp_code_file = orig_create
    api.nvim_buf_delete(buf, { force = true })
    install_fake()
  end)
end)
