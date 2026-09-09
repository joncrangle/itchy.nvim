local itchy = require 'itchy'
local runtimes = require 'itchy.runtimes'
local config = require 'itchy.config'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true

local api = vim.api

local pending = pending or function(message)
  print('SKIPPED: ' .. message)
  io.stdout:flush()
  return true
end

--- Collect virtual-line text plus highlight groups per extmark row.
---@param buf integer
---@param namespace integer
---@return table<integer, {text: string, hls: string[]}> by_row
local function get_virt_by_row(buf, namespace)
  local by_row = {}
  local extmarks = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  for _, mark in ipairs(extmarks) do
    local virt_lines = mark[4] and mark[4].virt_lines
    if virt_lines then
      for _, line in ipairs(virt_lines) do
        local text = ''
        local hls = {}
        for _, chunk in ipairs(line) do
          -- Skip the divider/prefix ("  │ ").
          if not chunk[1]:match('^%s*│%s*$') then
            text = text .. chunk[1]
          end
          table.insert(hls, chunk[2])
        end
        by_row[mark[2]] = by_row[mark[2]] or {}
        table.insert(by_row[mark[2]], { text = text, hls = hls })
      end
    end
  end
  return by_row
end

describe('itchy.run powershell rendering', function()
  local buf

  before_each(function()
    -- Other spec files reset package.loaded between tests, which orphans
    -- module instances captured at file-load time. Re-require here so the
    -- registry below and itchy.run() observe the same live instances.
    package.loaded['itchy'] = nil
    package.loaded['itchy.runtimes'] = nil
    itchy = require 'itchy'
    runtimes = require 'itchy.runtimes'
    config = require 'itchy.config'

    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'ps1'
    runtimes.load_runtimes()
  end)

  after_each(function()
    pcall(function()
      itchy._reset_runs()
    end)
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
  end)

  local function pwsh_ready()
    if vim.fn.executable('pwsh') ~= 1 then
      pending('pwsh not available')
      return false
    end
    if not runtimes.runtimes['ps1'] or not runtimes.runtimes['ps1']['pwsh'] then
      pending('pwsh runtime not available for ps1')
      return false
    end
    return true
  end

  --- Run the buffer lines through itchy.run() and return extmark virtual
  --- lines (text AND highlight groups) by 0-based row.
  local function run_lines(lines, expected_rows)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_set_current_buf(buf)
    itchy.run('pwsh', buf)

    local namespace_name = 'itchy_ps1_result'
    local ns_wait = vim.wait(2000, function()
      return vim.api.nvim_get_namespaces()[namespace_name] ~= nil
    end, 50)
    assert(ns_wait, 'Namespace was not created within timeout')
    local ns_id = vim.api.nvim_get_namespaces()[namespace_name]

    local marks_wait = vim.wait(30000, function()
      local count = 0
      for _ in pairs(get_virt_by_row(buf, ns_id)) do
        count = count + 1
      end
      return count >= expected_rows
    end, 100)
    assert(marks_wait, 'Expected virtual lines for all buffer lines')

    -- Let any trailing scheduled render settle, then assert exact placement.
    vim.wait(1000)
    return get_virt_by_row(buf, ns_id)
  end

  it('paints a Write-Error with the error highlight (regression)', function()
    if not pwsh_ready() then
      return
    end
    -- Focused lockdown for the virtual-line regression: event.kind ==
    -- 'error' is not enough, the extmark's virt_lines themselves must carry
    -- the configured error highlight (runtimes_spec discards highlights).
    local by_row = run_lines({ 'Write-Output "normal"', 'Write-Error "failure"' }, 2)

    local hl_stdout = config.cfg.highlights.stdout
    local hl_stderr = config.cfg.highlights.stderr

    eq(by_row[0][1].text, 'normal')
    eq(by_row[0][1].hls[2], hl_stdout)

    -- Exactly one virtual line: the native error-stream echo must fold into
    -- the framed event rather than doubling it, and it must paint hl_stderr.
    eq(#by_row[1], 1)
    eq(by_row[1][1].text, 'failure')
    eq(by_row[1][1].hls[2], hl_stderr)
  end)

  it('paints stdout/warning/error with their highlight groups', function()
    if not pwsh_ready() then
      return
    end

    local by_row = run_lines({
      'Write-Output "out-hi"',
      'Write-Host "host-hi"',
      'Write-Warning "warn-hi"',
      'Write-Error "err-hi"',
      'throw "boom-hi"',
    }, 5)
    local n = 0
    for _ in pairs(by_row) do
      n = n + 1
    end
    eq(n, 5)

    local hl_stdout = config.cfg.highlights.stdout
    local hl_stderr = config.cfg.highlights.stderr
    local hl_warning = config.cfg.highlights.warning or hl_stderr

    local function single(row)
      truthy(by_row[row] ~= nil)
      eq(#by_row[row], 1)
      return by_row[row][1]
    end

    local out = single(0)
    eq(out.text, 'out-hi')
    eq(out.hls[2], hl_stdout)

    local host = single(1)
    eq(host.text, 'host-hi')
    eq(host.hls[2], hl_stdout)

    local warn = single(2)
    eq(warn.text, 'warn-hi')
    eq(warn.hls[2], hl_warning)

    -- The regression: errors rendered without the error highlight (or not
    -- at all). Both the cmdlet call and the native throw must paint
    -- hl_stderr virtual lines on their own buffer lines.
    local err = single(3)
    eq(err.text, 'err-hi')
    eq(err.hls[2], hl_stderr)

    local boom = single(4)
    truthy(boom.text:find('boom-hi', 1, true) ~= nil)
    eq(boom.hls[2], hl_stderr)
  end)
end)
