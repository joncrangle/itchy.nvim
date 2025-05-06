local itchy = require 'itchy'
local assert = require 'luassert'

local pending = pending or function(message)
  print('SKIPPED: ' .. message)
  io.stdout:flush()
  return true
end

local api = vim.api

---@class itchy.TestCase
---@field path string
---@field runtimes string[]
---@field expected string[]
---@field pass_min? integer

---@type table<string, itchy.TestCase>
local test_cases = {
  python = {
    runtimes = { 'python', 'uv' },
    path = 'tests/test_files/python.py',
    expected = {
      'Hello from Python',
      'division by zero',
      'Async operation complete',
      'No such file or directory',
    },
  },
  javascript = {
    runtimes = { 'deno', 'bun', 'node' },
    path = 'tests/test_files/javascript.js',
    expected = {
      'Hello from JavaScript',
      'Async operation complete',
      'no such file or directory',
      'require is not defined',
    },
    pass_min = 3,
  },
  typescript = {
    runtimes = { 'deno', 'bun', 'node' },
    path = 'tests/test_files/typescript.ts',
    expected = {
      'Hello from TypeScript',
      'Cannot divide by zero',
      'Async operation complete',
      'Async error: Cannot divide by zero',
      'no such file or directory',
      'Relative import path',
    },
    pass_min = 4,
  },
  go = {
    runtimes = { 'go' },
    path = 'tests/test_files/go.go',
    expected = {
      'Hello from Go',
      'Formatted number: 42',
      'This is a log message',
      'Async operation complete',
      'File error:',
      'Panic occurred',
    },
  },
  bash = {
    runtimes = { 'bash' },
    path = 'tests/test_files/bash.sh',
    expected = {
      'Hello from Bash',
      'Async operation complete',
      'division by 0',
    },
  },
  sh = {
    runtimes = { 'sh' },
    path = 'tests/test_files/bash.sh',
    expected = {
      'Hello from Bash',
      'Async operation complete',
      'division by 0',
    },
  },
  zsh = {
    runtimes = { 'zsh' },
    path = 'tests/test_files/bash.sh',
    expected = {
      'Hello from Bash',
      'Async operation complete',
      'division by 0',
    },
    pass_min = 2,
  },
  ps1 = {
    runtimes = { 'pwsh', 'powershell' },
    path = 'tests/test_files/pwsh.ps1',
    expected = {
      'Hello from PowerShell',
      'Echo from PowerShell',
      'Caught division error',
      'Starting async operation',
      'Async operation complete',
      'Caught async error',
      'Caught file error',
      'Result: 5',
      'Attempted to divide by zero',
    },
  },
}

--- Normalize whitespace and remove extra spaces
---@param str string
---@return string
local function normalize(str)
  return str:match('^%s*(.-)%s*$'):gsub('%s+', ' ')
end

--- Check if the expected string is contained within the actual string
---@param actual string
---@param expected string
---@return boolean
local function fuzzy_match(actual, expected)
  local actual_norm = normalize(actual)
  local expected_norm = normalize(expected)
  return actual_norm:find(expected_norm, 1, true) ~= nil
end

--- Read a file and split it by lines
---@param path string
---@return string[]
local function read_file(path)
  local file = io.open(path, 'r')
  if not file then
    return {}
  end
  local content = file:read '*a'
  file:close()
  return vim.split(content, '\n')
end

--- Create a test buffer with the given filetype and content
---@param filetype string
---@param content string[]
---@return integer
local function setup_test_buffer(filetype, content)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = filetype
  api.nvim_buf_set_lines(buf, 0, -1, false, content)
  api.nvim_set_current_buf(buf)
  return buf
end

--- Get the extmark text for a buffer and namespace
---@param buf integer
---@param namespace integer
---@return string[]
local function get_extmark_text(buf, namespace)
  local extmarks = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  local output = {}

  for _, mark in ipairs(extmarks) do
    -- Check for virt_lines
    if mark[4] and mark[4].virt_lines then
      for _, line in ipairs(mark[4].virt_lines) do
        local line_text = ''
        for _, chunk in ipairs(line) do
          -- Skip the divider/prefix ("  │ ")
          if not chunk[1]:match '^%s*│%s*$' then
            line_text = line_text .. chunk[1]
          end
        end
        table.insert(output, line_text)
      end
    end
  end

  return output
end

for ft, test_case in pairs(test_cases) do
  describe('Itchy run for ' .. ft, function()
    local buf
    local runtimes = require 'itchy.runtimes'

    before_each(function()
      local content = read_file(test_case.path)
      assert(content, 'Failed to read test file: ' .. test_case.path)

      buf = setup_test_buffer(ft, content)
      require('itchy.runtimes').load_runtimes()
    end)

    for _, rt in ipairs(test_case.runtimes) do
      it(('with runtime %s'):format(rt), function()
        if not runtimes.runtimes[ft] or not runtimes.runtimes[ft][rt] then
          pending(('Runtime %s not available for %s'):format(rt, ft))
          return
        end

        -- Get the namespace name upfront
        local namespace_name = 'itchy_' .. ft .. '_result'

        -- Run the code
        print(('Running %s with runtime %s'):format(ft, rt))
        itchy.run(rt)

        -- Wait for namespace to be created
        local ns_wait_success = vim.wait(2000, function()
          local namespaces = vim.api.nvim_get_namespaces()
          return namespaces[namespace_name] ~= nil
        end, 50)

        assert(ns_wait_success, 'Namespace was not created within timeout')
        local ns_id = vim.api.nvim_get_namespaces()[namespace_name]

        -- Wait for the extmarks
        local initial_wait_success = vim.wait(5000, function()
          local extmarks = get_extmark_text(buf, ns_id)
          return #extmarks > 0
        end, 50)

        assert(initial_wait_success, 'No extmarks appeared within initial timeout')

        -- Get the final extmarks for assertion
        local extmarks = get_extmark_text(buf, ns_id)

        local expected = test_case.expected
        local pass_min = test_case.pass_min or #test_case.expected
        local passes = 0
        for _, expected_str in ipairs(expected) do
          local found_match = false
          local missed_str
          for _, actual_str in ipairs(extmarks) do
            if fuzzy_match(actual_str, expected_str) then
              passes = passes + 1
              found_match = true
              break
            end
            missed_str = actual_str
          end
          if not found_match then
            print(('  [FAIL] Expected: %s'):format(expected_str))
            print(('  [FAIL] FOUND: %s'):format(missed_str))
          end
        end

        assert(passes >= pass_min, string.format('Expected at least %d matches, but got %d in runtime %s.', pass_min, passes, rt))
      end)
    end
  end)
end
