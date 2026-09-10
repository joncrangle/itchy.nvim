local adapters = require 'itchy.adapters'
local runtimes = require 'itchy.runtimes'
local assert = require 'luassert'

local eq = assert.are.equal
local same = assert.are.same
local has_error = assert.has_error
local truthy = assert.is_true

describe('itchy.adapters registry', function()
  it('resolves all built-in adapters and runtimes', function()
    local names = { 'bash', 'zsh', 'sh', 'go', 'javascript', 'python', 'powershell' }
    for _, name in ipairs(names) do
      local adapter = adapters.resolve { cmd = name, args = {}, adapter = name }
      eq(adapter.name, name)
      eq(type(adapter.prepare), 'function')
      eq(type(adapter.decode), 'function')
    end

    for ft, rts in pairs(runtimes.available_runtimes) do
      for rt_name, rt in pairs(rts) do
        assert(rt.adapter ~= nil, string.format('runtime %s.%s must specify an adapter', ft, rt_name))
        local resolved = adapters.resolve(rt)
        eq(type(resolved.prepare), 'function')
        eq(type(resolved.decode), 'function')
      end
    end
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
    local snacks_run_opts
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
        run = function(opts)
          ran_snacks = true
          snacks_run_opts = opts
        end,
      },
    }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'lua'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'print("hello")' })

    itchy.run(nil, buf)

    eq(ran_snacks, true)
    same(snacks_run_opts, { buf = buf })
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

  it('Snacks clear is safe before the debug namespace is initialized', function()
    local itchy = require 'itchy'
    local cfg = require 'itchy.config'
    local orig_did_setup = itchy.did_setup
    local orig_snacks_cfg = cfg.cfg.integrations.snacks
    local orig_loaded_snacks = package.loaded['snacks']
    local orig_get_namespaces = vim.api.nvim_get_namespaces
    local merged

    local snacks_config = {}
    function snacks_config:merge(opts)
      if opts.scratch and opts.scratch.win_by_ft and opts.scratch.win_by_ft.lua then
        merged = opts
      end
    end

    package.loaded['snacks'] = {
      config = snacks_config,
      debug = { run = function() end },
    }
    cfg.cfg.integrations.snacks = true
    itchy.did_setup = nil
    itchy.setup {}

    vim.api.nvim_get_namespaces = function()
      local namespaces = orig_get_namespaces()
      namespaces.snacks_debug = nil
      return namespaces
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'lua'
    assert(merged ~= nil)
    local clear = merged.scratch.win_by_ft.lua.keys.clear[2]
    local run = merged.scratch.win_by_ft.lua.keys.run[2]
    local ok, err = pcall(clear, { buf = buf })

    vim.api.nvim_get_namespaces = orig_get_namespaces
    local snacks_ns = vim.api.nvim_create_namespace('snacks_debug')
    vim.api.nvim_buf_set_extmark(buf, snacks_ns, 0, 0, { virt_text = { { 'output', 'Comment' } } })
    eq(#vim.api.nvim_buf_get_extmarks(buf, snacks_ns, 0, -1, {}), 1)
    local after_ok, after_err = pcall(clear, { buf = buf })
    eq(#vim.api.nvim_buf_get_extmarks(buf, snacks_ns, 0, -1, {}), 0)

    local ran_buf
    local old_run = package.loaded['snacks'].debug.run
    package.loaded['snacks'].debug.run = function(opts)
      ran_buf = opts.buf
    end
    local run_ok, run_err = pcall(run, { buf = buf })
    package.loaded['snacks'].debug.run = old_run

    itchy.did_setup = orig_did_setup
    cfg.cfg.integrations.snacks = orig_snacks_cfg
    package.loaded['snacks'] = orig_loaded_snacks
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    truthy(merged ~= nil)
    truthy(ok, tostring(err))
    truthy(after_ok, tostring(after_err))
    truthy(run_ok, tostring(run_err))
    eq(ran_buf, buf)
  end)
end)
