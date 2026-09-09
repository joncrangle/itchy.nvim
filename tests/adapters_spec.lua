local adapters = require 'itchy.adapters'
local runtimes = require 'itchy.runtimes'
local assert = require 'luassert'

local eq = assert.are.equal
local has_error = assert.has_error

describe('itchy.adapters registry', function()
  it('resolves built-in adapters by name', function()
    local names = { 'bash', 'zsh', 'sh', 'go', 'javascript', 'python', 'powershell' }
    for _, name in ipairs(names) do
      local adapter = adapters.resolve { cmd = name, args = {}, adapter = name }
      eq(adapter.name, name)
      eq(type(adapter.prepare), 'function')
      eq(type(adapter.decode), 'function')
    end
  end)

  it('resolves every built-in runtime successfully', function()
    for ft, rts in pairs(runtimes.available_runtimes) do
      for rt_name, rt in pairs(rts) do
        assert(rt.adapter ~= nil, string.format('runtime %s.%s must specify an adapter', ft, rt_name))
        local resolved = adapters.resolve(rt)
        eq(type(resolved.prepare), 'function')
        eq(type(resolved.decode), 'function')
      end
    end
  end)

  it('accepts a custom adapter table implementing prepare and decode', function()
    local custom = {
      name = 'custom',
      prepare = function(ctx)
        return { source = ctx.source }
      end,
      decode = function(_, _, _)
        return {}
      end,
    }
    local resolved = adapters.resolve { cmd = 'custom', args = {}, adapter = custom }
    eq(resolved, custom)
  end)

  it('fails explicitly when runtime is nil or missing an adapter', function()
    has_error(function()
      adapters.resolve(nil)
    end)
    has_error(function()
      adapters.resolve {}
    end)
    has_error(function()
      adapters.resolve { cmd = 'fake', args = {} }
    end)
  end)

  it('fails explicitly for unknown adapter names', function()
    has_error(function()
      adapters.resolve { cmd = 'fake', args = {}, adapter = 'nonexistent' }
    end)
  end)

  it('no dosbatch runtime remains in available_runtimes', function()
    eq(runtimes.available_runtimes.dosbatch, nil)
  end)

  it('runtimes.create_runtime does not populate offset or wrapper', function()
    local rt = runtimes.create_runtime('echo', {}, 'sh')
    eq(rt.offset, nil)
    eq(rt.wrapper, nil)
    eq(rt.adapter, 'sh')
  end)

  local function find_lua_files(dir)
    local files = {}
    local function scan(current_dir)
      local handle = vim.uv.fs_scandir(current_dir)
      if not handle then
        return
      end
      while true do
        local name, type_ = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        local path = current_dir .. '/' .. name
        if type_ == 'directory' then
          scan(path)
        elseif type_ == 'file' and name:match '%.lua$' then
          table.insert(files, path)
        end
      end
    end
    scan(dir)
    return files
  end

  it('no production module imports itchy.adapters.legacy or itchy.wrappers', function()
    local files = find_lua_files 'lua/itchy'
    assert(#files > 0, 'expected to find lua files in lua/itchy')
    for _, file in ipairs(files) do
      local f = io.open(file, 'r')
      assert(f ~= nil, 'cannot open ' .. file)
      local content = f:read '*a'
      f:close()
      assert(
        not content:match "require%s*%(?['\"]itchy%.adapters%.legacy['\"]%)?",
        string.format('%s imports itchy.adapters.legacy', file)
      )
      assert(
        not content:match "require%s*%(?['\"]itchy%.wrappers",
        string.format('%s imports itchy.wrappers', file)
      )
    end
  end)

  it('repository audit finds no stale migration issue-number comments in production Lua', function()
    local files = find_lua_files 'lua/itchy'
    assert(#files > 0, 'expected to find lua files in lua/itchy')
    for _, file in ipairs(files) do
      local f = io.open(file, 'r')
      assert(f ~= nil, 'cannot open ' .. file)
      local content = f:read '*a'
      f:close()
      local match = content:match '#%d+'
      eq(match, nil, string.format('%s contains stale migration issue reference: %s', file, tostring(match)))
    end
  end)
end)

describe('Lua and Snacks integration', function()
  it('Lua is intentionally not an itchy runtime', function()
    eq(runtimes.available_runtimes.lua, nil)
  end)

  it('delegates to Snacks.debug.run() when Snacks is enabled and loaded, bypassing adapter resolution', function()
    local itchy = require 'itchy'
    local cfg = require 'itchy.config'
    local orig_snacks_cfg = cfg.cfg.integrations.snacks
    local orig_loaded_snacks = package.loaded['snacks']
    local orig_resolve = adapters.resolve
    local orig_load_runtimes = runtimes.load_runtimes

    local ran_snacks = false
    local resolve_called = false
    local load_runtimes_called = false

    adapters.resolve = function(...)
      resolve_called = true
      return orig_resolve(...)
    end
    runtimes.load_runtimes = function(...)
      load_runtimes_called = true
      return orig_load_runtimes(...)
    end

    cfg.cfg.integrations.snacks = true
    package.loaded['snacks'] = {
      debug = {
        run = function()
          ran_snacks = true
        end,
      },
    }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'lua'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'print("hello")' })

    itchy.run(nil, buf)

    eq(ran_snacks, true)
    eq(resolve_called, false)
    eq(load_runtimes_called, false)

    -- Cleanup
    cfg.cfg.integrations.snacks = orig_snacks_cfg
    package.loaded['snacks'] = orig_loaded_snacks
    adapters.resolve = orig_resolve
    runtimes.load_runtimes = orig_load_runtimes
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('fails with notification and bypasses adapter resolution when Snacks is unavailable or disabled', function()
    local itchy = require 'itchy'
    local cfg = require 'itchy.config'
    local orig_snacks_cfg = cfg.cfg.integrations.snacks
    local orig_loaded_snacks = package.loaded['snacks']
    local orig_resolve = adapters.resolve
    local orig_notify = vim.notify

    local resolve_called = false
    adapters.resolve = function(...)
      resolve_called = true
      return orig_resolve(...)
    end

    local notified_errors = {}
    vim.notify = function(msg, level, ...)
      table.insert(notified_errors, { msg = tostring(msg), level = level })
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'lua'

    -- Case A: snacks integration disabled via boolean false
    cfg.cfg.integrations.snacks = false
    package.loaded['snacks'] = {
      debug = {
        run = function() end,
      },
    }

    itchy.run(nil, buf)

    eq(resolve_called, false)
    eq(#notified_errors, 1)
    eq(notified_errors[1].msg, 'No runtimes available for lua')

    -- Case B: snacks integration disabled via table { enabled = false }
    cfg.cfg.integrations.snacks = { enabled = false }
    notified_errors = {}

    itchy.run(nil, buf)

    eq(resolve_called, false)
    eq(#notified_errors, 1)
    eq(notified_errors[1].msg, 'No runtimes available for lua')

    -- Case C: snacks package not loaded
    cfg.cfg.integrations.snacks = true
    package.loaded['snacks'] = nil
    notified_errors = {}

    itchy.run(nil, buf)

    eq(resolve_called, false)
    eq(#notified_errors, 1)
    eq(notified_errors[1].msg, 'No runtimes available for lua')

    -- Cleanup
    cfg.cfg.integrations.snacks = orig_snacks_cfg
    package.loaded['snacks'] = orig_loaded_snacks
    adapters.resolve = orig_resolve
    vim.notify = orig_notify
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('itchy.clear() on a Lua buffer clears snacks_debug namespace', function()
    local itchy = require 'itchy'
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'lua'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'print(1)' })

    local snacks_ns = vim.api.nvim_create_namespace('snacks_debug')
    vim.api.nvim_buf_set_extmark(buf, snacks_ns, 0, 0, { virt_text = { { 'output', 'Comment' } } })
    local before = vim.api.nvim_buf_get_extmarks(buf, snacks_ns, 0, -1, {})
    eq(#before, 1)

    itchy.clear(buf)

    local after = vim.api.nvim_buf_get_extmarks(buf, snacks_ns, 0, -1, {})
    eq(#after, 0)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)


