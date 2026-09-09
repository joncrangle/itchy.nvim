local renderer = require 'itchy.renderer'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true

local api = vim.api

---@param buf integer
---@param ns integer
---@return string[]
local function get_hls(buf, ns)
  local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    if mark[4] and mark[4].virt_lines then
      for _, line in ipairs(mark[4].virt_lines) do
        for _, chunk in ipairs(line) do
          if not chunk[1]:match '^%s*│%s*$' then
            table.insert(out, chunk[2])
          end
        end
      end
    end
  end
  return out
end

---@param buf integer
---@param ns integer
---@return string[]
local function get_marks(buf, ns)
  local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    if mark[4] and mark[4].virt_lines then
      for _, line in ipairs(mark[4].virt_lines) do
        local text = ''
        for _, chunk in ipairs(line) do
          if not chunk[1]:match '^%s*│%s*$' then
            text = text .. chunk[1]
          end
        end
        table.insert(out, text)
      end
    end
  end
  return out
end

local function render_and_wait(buf, ns, events, opts)
  renderer.render(buf, ns, events, opts)
  local ok = vim.wait(2000, function()
    return #get_marks(buf, ns) > 0
  end, 50)
  return ok
end

describe('itchy.renderer', function()
  local buf
  local ns

  before_each(function()
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three', 'four', 'five' })
    ns = api.nvim_create_namespace('itchy_renderer_test_' .. tostring(buf))
  end)

  after_each(function()
    pcall(api.nvim_buf_delete, buf, { force = true })
  end)

  it('renders a single stdout event on its 1-based line', function()
    render_and_wait(buf, ns, { { kind = 'stdout', line = 2, message = 'hi' } })
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(#marks, 1)
    -- 1-based line 2 -> 0-based row 1.
    eq(marks[1][2], 1)
    truthy(get_marks(buf, ns)[1]:find('hi', 1, true) ~= nil)
  end)

  it('aggregates multiple stdout events on one line', function()
    renderer.render(buf, ns, {
      { kind = 'stdout', line = 1, message = 'a' },
      { kind = 'stdout', line = 1, message = 'b' },
    })
    vim.wait(2000, function()
      return #get_marks(buf, ns) > 0
    end, 50)
    local texts = get_marks(buf, ns)
    eq(#texts, 1)
    truthy(texts[1]:find('a | b', 1, true) ~= nil)
  end)

  it('renders error events with error highlighting', function()
    render_and_wait(buf, ns, { { kind = 'error', line = 3, message = 'boom' } })
    local texts = get_marks(buf, ns)
    eq(#texts, 1)
    truthy(texts[1]:find('boom', 1, true) ~= nil)
    local hls = get_hls(buf, ns)
    eq(#hls, 1)
    eq(hls[1], 'DiagnosticError')
  end)

  it('renders stderr events with error highlighting', function()
    render_and_wait(buf, ns, { { kind = 'stderr', line = 3, message = 'to-err' } })
    local hls = get_hls(buf, ns)
    eq(#hls, 1)
    eq(hls[1], 'DiagnosticError')
  end)

  it('renders stdout events with stdout highlighting', function()
    render_and_wait(buf, ns, { { kind = 'stdout', line = 2, message = 'hi' } })
    local hls = get_hls(buf, ns)
    eq(#hls, 1)
    eq(hls[1], 'Comment')
  end)

  it('renders warning events alongside errors', function()
    renderer.render(buf, ns, {
      { kind = 'warning', line = 2, message = 'careful' },
    })
    vim.wait(2000, function()
      return #get_marks(buf, ns) > 0
    end, 50)
    local texts = get_marks(buf, ns)
    eq(#texts, 1)
    truthy(texts[1]:find('careful', 1, true) ~= nil)
    local hls = get_hls(buf, ns)
    eq(#hls, 1)
    eq(hls[1], 'DiagnosticWarn')
  end)

  it('ignores the optional column when rendering', function()
    render_and_wait(buf, ns, { { kind = 'stdout', line = 2, message = 'hi', column = 7 } })
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(#marks, 1)
    eq(marks[1][2], 1)
  end)

  it('renders stdout and error on the same source line separately', function()
    renderer.render(buf, ns, {
      { kind = 'stdout', line = 4, message = 'out' },
      { kind = 'error', line = 4, message = 'err' },
    })
    vim.wait(2000, function()
      return #get_marks(buf, ns) >= 2
    end, 50)
    local texts = get_marks(buf, ns)
    eq(#texts, 2)
    local hls = get_hls(buf, ns)
    eq(#hls, 2)
    local seen = {}
    for _, hl in ipairs(hls) do
      seen[hl] = true
    end
    truthy(seen['Comment'])
    truthy(seen['DiagnosticError'])
  end)

  it('routes locationless errors to on_locationless instead of an extmark', function()
    local seen = {}
    renderer.render(buf, ns, { { kind = 'error', line = nil, message = 'nowhere' } }, {
      on_locationless = function(e)
        table.insert(seen, e)
      end,
    })
    vim.wait(500, function()
      return false
    end, 50)
    eq(#seen, 1)
    eq(seen[1].message, 'nowhere')
    eq(#get_marks(buf, ns), 0)
  end)

  it('clamps out-of-range lines to the last line (legacy compat)', function()
    renderer.render(buf, ns, { { kind = 'stdout', line = 99, message = 'far' } })
    local ok = vim.wait(2000, function()
      return #get_marks(buf, ns) > 0
    end, 50)
    truthy(ok)
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(#marks, 1)
    -- 5-line buffer: clamped to 0-based row 4.
    eq(marks[1][2], 4)
  end)

  it('clamps out-of-range errors to the last line instead of notifying', function()
    local seen = {}
    renderer.render(buf, ns, { { kind = 'error', line = 99, message = 'far boom' } }, {
      on_locationless = function(e)
        table.insert(seen, e)
      end,
    })
    local ok = vim.wait(2000, function()
      return #get_marks(buf, ns) > 0
    end, 50)
    truthy(ok)
    eq(#seen, 0)
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(marks[1][2], 4)
  end)

  it('drops malformed events without rendering', function()
    local seen = {}
    renderer.render(buf, ns, { { kind = 'error', line = 1 } }, {
      on_locationless = function(e)
        table.insert(seen, e)
      end,
    })
    vim.wait(500, function()
      return false
    end, 50)
    eq(#get_marks(buf, ns), 0)
    eq(#seen, 0)
  end)

  it('honors the stale-run guard', function()
    renderer.render(buf, ns, { { kind = 'stdout', line = 1, message = 'stale' } }, {
      is_current = function()
        return false
      end,
    })
    vim.wait(500, function()
      return false
    end, 50)
    eq(#get_marks(buf, ns), 0)
  end)

  it('ignores invalid buffers without error', function()
    local ok = pcall(renderer.render, 999999, ns, { { kind = 'stdout', line = 1, message = 'x' } })
    truthy(ok)
    vim.wait(300, function()
      return false
    end, 50)
  end)
end)
