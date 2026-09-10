local itchy = require 'itchy'
local runtimes = require 'itchy.runtimes'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true

local pending = pending or function(message)
  print('SKIPPED: ' .. tostring(message))
  io.stdout:flush()
  return true
end

local api = vim.api

---@class itchy.RuntimeExpectation
---@field text string exact rendered virtual-line text
---@field row integer 0-based extmark row
---@field highlight string exact content highlight group

---@class itchy.TestCase
---@field path string
---@field runtimes string[]
---@field expected itchy.RuntimeExpectation[]

---@type table<string, itchy.TestCase>
local test_cases = {
  python = {
    runtimes = { 'python', 'uv' },
    path = 'tests/test_files/python.py',
    expected = {
      { text = 'Hello from Python', row = 2, highlight = 'Comment' },
      { text = 'Caught runtime error: division by zero', row = 14, highlight = 'DiagnosticError' },
      { text = 'Caught file error: No such file or directory', row = 33, highlight = 'DiagnosticError' },
      { text = 'Async operation complete', row = 20, highlight = 'Comment' },
      { text = 'Caught async error: division by zero', row = 24, highlight = 'DiagnosticError' },
    },
  },
  javascript = {
    runtimes = { 'deno', 'bun', 'node' },
    path = 'tests/test_files/javascript.js',
    expected = {
      { text = 'Hello from JavaScript', row = 0, highlight = 'Comment' },
      { text = 'Error: Cannot divide by zero', row = 11, highlight = 'DiagnosticError' },
      { text = 'Async operation complete', row = 16, highlight = 'Comment' },
      { text = 'Async error: Cannot divide by zero', row = 20, highlight = 'DiagnosticError' },
      { text = 'File error: no such file or directory', row = 31, highlight = 'DiagnosticError' },
    },
  },
  typescript = {
    runtimes = { 'deno', 'bun', 'node' },
    path = 'tests/test_files/typescript.ts',
    expected = {
      { text = 'Hello from TypeScript', row = 0, highlight = 'Comment' },
      { text = 'Error: Cannot divide by zero', row = 11, highlight = 'DiagnosticError' },
      { text = 'Async operation complete', row = 17, highlight = 'Comment' },
      { text = 'Async error: Cannot divide by zero', row = 21, highlight = 'DiagnosticError' },
      { text = 'File error: No such file or directory', row = 30, highlight = 'DiagnosticError' },
    },
  },
  go = {
    runtimes = { 'go' },
    path = 'tests/test_files/go.go',
    expected = {
      { text = 'Hello from Go', row = 16, highlight = 'Comment' },
      { text = 'Formatted number: 42', row = 17, highlight = 'Comment' },
      { text = 'This is a log message', row = 20, highlight = 'Comment' },
      { text = 'Async operation complete', row = 28, highlight = 'Comment' },
      { text = 'File error: open non_existent_file.txt: no such file or directory', row = 36, highlight = 'Comment' },
      { text = 'panic: runtime error: integer divide by zero', row = 11, highlight = 'DiagnosticError' },
    },
  },
  bash = {
    runtimes = { 'bash' },
    path = 'tests/test_files/bash.sh',
    expected = {
      { text = 'Hello from Bash', row = 2, highlight = 'Comment' },
      { text = 'Async operation complete', row = 12, highlight = 'Comment' },
      { text = '1 / 0: division by 0', row = 6, highlight = 'DiagnosticError' },
    },
  },
  sh = {
    runtimes = { 'sh' },
    path = 'tests/test_files/bash.sh',
    expected = {
      { text = 'Hello from Bash', row = 2, highlight = 'Comment' },
      { text = 'Async operation complete', row = 12, highlight = 'Comment' },
      -- `/bin/sh` on the supported Unix clients is either Bash-as-sh or
      -- dash. Both keep the native source row; their wording differs only in
      -- the final zero token.
      { text = '1 / 0: division by 0', row = 6, highlight = 'DiagnosticError' },
    },
  },
  zsh = {
    runtimes = { 'zsh' },
    path = 'tests/test_files/bash.sh',
    expected = {
      { text = 'Hello from Bash', row = 2, highlight = 'Comment' },
      { text = 'Async operation complete', row = 12, highlight = 'Comment' },
      { text = 'division by zero', row = 6, highlight = 'DiagnosticError' },
    },
  },
  ps1 = {
    runtimes = { 'pwsh', 'powershell' },
    path = 'tests/test_files/pwsh.ps1',
    expected = {
      { text = 'Hello from PowerShell', row = 0, highlight = 'Comment' },
      { text = 'Echo from PowerShell', row = 1, highlight = 'Comment' },
      { text = 'Caught division error: Attempted to divide by zero', row = 17, highlight = 'Comment' },
      { text = 'Starting async operation...', row = 25, highlight = 'Comment' },
      { text = 'Async operation complete', row = 27, highlight = 'Comment' },
      { text = 'Caught async error: division by zero', row = 34, highlight = 'Comment' },
      { text = 'Caught file error: path not found', row = 47, highlight = 'Comment' },
      { text = 'Running division test...', row = 52, highlight = 'Comment' },
      { text = 'Result: 5', row = 54, highlight = 'Comment' },
      { text = 'Running division by zero test with catch...', row = 56, highlight = 'Comment' },
      { text = 'Result: ', row = 58, highlight = 'Comment' },
      { text = 'Running division by zero test...', row = 60, highlight = 'Comment' },
      { text = 'Caught direct division error: division by zero', row = 61, highlight = 'Comment' },
      { text = 'Result: ', row = 62, highlight = 'Comment' },
      { text = 'Running file error test...', row = 64, highlight = 'Comment' },
      { text = 'Running async test...', row = 67, highlight = 'Comment' },
      { text = 'All tests completed', row = 70, highlight = 'Comment' },
    },
  },
}

local function read_file(path)
  local file = io.open(path, 'r')
  assert(file ~= nil, 'Failed to read test file: ' .. path)
  local content = file:read '*a'
  file:close()
  return vim.split(content, '\n')
end

local function setup_test_buffer(filetype, content)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = filetype
  api.nvim_buf_set_lines(buf, 0, -1, false, content)
  api.nvim_set_current_buf(buf)
  return buf
end

local function expected_for(ft, expected)
  if ft ~= 'sh' then
    return expected
  end
  local shell_kind = vim.fn.system({
    'sh',
    '-c',
    'if [ -n "$BASH_VERSION" ]; then printf bash; else printf posix; fi',
  })
  local adjusted = vim.deepcopy(expected)
  adjusted[3].text = shell_kind == 'bash'
    and '1 / 0: division by 0'
    or 'arithmetic expression: division by zero: " 1 / 0 "'
  return adjusted
end

---@param buf integer
---@param namespace integer
---@return itchy.RuntimeExpectation[]
local function get_extmark_details(buf, namespace)
  local output = {}
  local extmarks = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  for _, mark in ipairs(extmarks) do
    local row = mark[2]
    if mark[4] and mark[4].virt_lines then
      for _, line in ipairs(mark[4].virt_lines) do
        local text, highlight = '', nil
        for _, chunk in ipairs(line) do
          if not chunk[1]:match '^%s*│%s*$' then
            text = text .. chunk[1]
            highlight = highlight or chunk[2]
          end
        end
        if text ~= '' then
          table.insert(output, { text = text, row = row, highlight = highlight })
        end
      end
    end
  end
  return output
end

local function assert_exact_extmarks(actual, expected, ft, runtime)
  eq(#actual, #expected, ('[%s/%s] exact extmark count'):format(ft, runtime))
  local consumed = {}
  for _, wanted in ipairs(expected) do
    local match
    for index, got in ipairs(actual) do
      if not consumed[index]
        and got.text == wanted.text
        and got.row == wanted.row
        and got.highlight == wanted.highlight
      then
        match = index
        break
      end
    end
    truthy(match ~= nil, ('[%s/%s] missing exact extmark %s'):format(ft, runtime, vim.inspect(wanted)))
    consumed[match] = true
  end
end

for ft, test_case in pairs(test_cases) do
  describe('Itchy run for ' .. ft, function()
    local buf

    before_each(function()
      -- Refresh modules because the lifecycle specs deliberately reset module
      -- instances while exercising cleanup boundaries.
      package.loaded['itchy'] = nil
      package.loaded['itchy.runtimes'] = nil
      itchy = require 'itchy'
      runtimes = require 'itchy.runtimes'
      buf = setup_test_buffer(ft, read_file(test_case.path))
      runtimes.load_runtimes()
    end)

    after_each(function()
      pcall(itchy._reset_runs)
      if buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
      buf = nil
    end)

    for _, runtime_name in ipairs(test_case.runtimes) do
      it('with runtime ' .. runtime_name, function()
        if not runtimes.runtimes[ft] or not runtimes.runtimes[ft][runtime_name] then
          pending(('Runtime %s is unavailable for supported filetype %s'):format(runtime_name, ft))
          return
        end

        local namespace_name = 'itchy_' .. ft .. '_result'
        local expected = expected_for(ft, test_case.expected)
        local notifications = {}
        local original_notify
        if ft == 'javascript' or ft == 'typescript' then
          original_notify = vim.notify
          vim.notify = function(message, level, opts)
            table.insert(notifications, { message = message, level = level, opts = opts })
          end
        end
        local run_ok, run_err = pcall(itchy.run, runtime_name, buf)
        if not run_ok then
          if original_notify then
            vim.notify = original_notify
          end
          error(run_err, 0)
        end
        local ok, err = pcall(function()
          local namespace_ready = vim.wait(2000, function()
            return api.nvim_get_namespaces()[namespace_name] ~= nil
          end, 50)
          truthy(namespace_ready, ('[%s/%s] result namespace was not created'):format(ft, runtime_name))
          local namespace = api.nvim_get_namespaces()[namespace_name]
          local result_ready = vim.wait(30000, function()
            return #get_extmark_details(buf, namespace) >= #expected
          end, 50)
          truthy(result_ready, ('[%s/%s] expected extmarks did not appear'):format(ft, runtime_name))
          vim.wait(1000)
          if ft == 'javascript' or ft == 'typescript' then
            eq(#notifications, 0, ('[%s/%s] warning-free fixture'):format(ft, runtime_name))
          end
          assert_exact_extmarks(get_extmark_details(buf, namespace), expected, ft, runtime_name)
        end)
        if original_notify then
          vim.notify = original_notify
        end
        if not ok then
          error(err, 0)
        end
      end)
    end
  end)
end
