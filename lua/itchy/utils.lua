local M = {}

local config = require 'itchy.config'

local filetype_to_extension = {
  javascript = 'js',
  typescript = 'ts',
}

--- Return the extension for a filetype
---@param ft string
---@return string
function M.ft_to_ext(ft)
  return filetype_to_extension[ft] or ft
end

--- Print debug messages
---@vararg any
function M.debug_print(...)
  if config.cfg.debug_mode then
    print(...)
  end
end

--- Clean error messages by removing ANSI escape codes.
---@param err string
---@return string
function M.clean_error_message(err)
  return (err:gsub('\27%[[%d;]*m', ''))
end


--- Generate a run-unique leaf name for temp files.
---@return string
local leaf_counter = 0
function M._project_leaf()
  leaf_counter = leaf_counter + 1
  return string.format('itchy-%d-%x-%x', vim.fn.getpid(), math.floor(vim.uv.hrtime() % 4294967295), leaf_counter)
end

--- Check whether vim.uv supports exclusive-create ("wx") open mode.
---@return boolean
local function supports_wx()
  if M._wx_supported == nil then
    M._wx_supported = false
    local probe = vim.fn.tempname() .. '.itchy-wx-probe'
    local ok, fd = pcall(vim.uv.fs_open, probe, 'wx', 384)
    if ok and type(fd) == 'number' then
      pcall(vim.uv.fs_close, fd)
      M._wx_supported = true
    end
    pcall(os.remove, probe)
  end
  return M._wx_supported
end

--- Sentinel indicating that the project directory is not writable.
local FALLBACK = {}

--- Atomically create a project-local temp file using exclusive create (O_EXCL).
--- Falls back to existence check when wx open mode is unsupported.
---@param dir string project directory (must exist)
---@param extension string file extension without dot
---@param content string file content
---@return string? path
---@return string?|table? err message, or FALLBACK when the dir is unusable
local function create_project_file(dir, extension, content)
  local use_wx = supports_wx()
  for _ = 1, 32 do
    local path = dir .. '/' .. M._project_leaf() .. '.' .. extension
    if use_wx then
      local fd, open_err = vim.uv.fs_open(path, 'wx', 384)
      if fd ~= nil then
        local _, write_err = vim.uv.fs_write(fd, content, -1)
        local _, close_err = vim.uv.fs_close(fd)
        if write_err == nil and close_err == nil then
          return path, nil
        end
        pcall(os.remove, path)
        return nil, tostring(write_err or close_err)
      end
      local msg = tostring(open_err or '')
      if msg:match('[Mm]ode') then
        use_wx = false -- retry this name via the fallback below
      elseif msg:match('[Ee]xist') then
        -- Name collision: try the next unique name.
      else
        return nil, FALLBACK -- EACCES etc: dir unusable
      end
    end
    if not use_wx then
      if vim.fn.filereadable(path) == 0 and vim.fn.isdirectory(path) == 0 then
        local file, open_err = io.open(path, 'w')
        if file then
          file:write(content)
          file:close()
          return path, nil
        end
        return nil, FALLBACK
      end
      -- Exists: try the next unique name.
    end
  end
  return nil, 'could not create a unique temp file in ' .. dir
end

--- Create a temporary source file for runtimes that require one.
--- Prefers project directory for relative import resolution; falls back
--- to the OS temp directory if unwritable.
---@param ft string
---@param code string
---@param dir? string preferred parent directory (e.g. the run cwd)
---@return string? path returns nil + error on failure
---@return string? err
function M.create_temp_code_file(ft, code, dir)
  local extension = M.ft_to_ext(ft)
  if type(dir) == 'string' and dir ~= '' and vim.fn.isdirectory(dir) == 1 then
    local path, err = create_project_file(dir:gsub('[/\\]$', ''), extension, code)
    if path then
      return path, nil
    end
    if err ~= FALLBACK then
      -- Exhaustion or write failure: propagate, never silently downgrade.
      return nil, err
    end
    -- Project dir unusable: OS temp dir fallback below.
  end
  local code_file = vim.fn.tempname() .. '.' .. extension
  local file, open_err = io.open(code_file, 'w')
  if not file then
    return nil, open_err or ('failed to create temp file: ' .. code_file)
  end
  file:write(code)
  file:close()
  return code_file, nil
end

--- Preferred directory for adapter temp source files: the run working
---directory when usable, so project-relative module resolution keeps
---working. Returns nil when unavailable; callers then fall back to the
---OS temp directory via `create_temp_code_file`.
---@param ctx itchy.AdapterContext
---@return string?
function M.project_dir(ctx)
  local dir = ctx and ctx.cwd
  if type(dir) == 'string' and dir ~= '' and vim.fn.isdirectory(dir) == 1 then
    return dir
  end
  return nil
end

--- Create a run-unique temp directory for adapter files (user source plus
---helper/launcher). Prefers the run working directory so module resolution
---keeps working; falls back to the OS temp directory. The directory is
---created before returning.
---@param dir? string preferred parent directory (e.g. the run cwd)
---@param prefix string leaf prefix, e.g. 'itchy-go'
---@param nonce string run nonce for uniqueness
---@return string tmpdir
function M.make_adapter_tmpdir(dir, prefix, nonce)
  if type(dir) == 'string' and dir ~= '' then
    dir = vim.fn.fnamemodify(dir, ':p'):gsub('[/\\]$', '')
  end
  local fallback = vim.fn.tempname() .. '_' .. prefix
  if type(dir) ~= 'string' or dir == '' then
    vim.fn.mkdir(fallback, 'p')
    return fallback
  end
  local candidate = dir .. '/' .. prefix .. '-' .. tostring(vim.fn.getpid()) .. '-' .. nonce
  if vim.fn.mkdir(candidate, 'p') == 1 then
    return candidate
  end
  vim.fn.mkdir(fallback, 'p')
  return fallback
end

--- Normalize a path for temp-file comparison: forward slashes everywhere,
--- case-insensitive on Windows where the filesystem is.
---@param path string
---@return string
function M.normalize_tmp_path(path)
  local p = path:gsub('\\', '/')
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    p = p:lower()
  end
  return p
end

--- Whether a native diagnostic path refers to an adapter's user source file.
--- Compares full normalized paths, falling back to leaf names for temp paths
--- rendered with symlinked/case variants. The user leaf must embed a run
--- nonce so it can never equal the fixed helper leaf.
---@param diag_path string? path from the diagnostic
---@param user_file string temp user source path
---@param helper_leaf string fixed helper filename to exclude, e.g. 'itchy_helper.go'
---@return boolean
function M.is_user_file(diag_path, user_file, helper_leaf)
  if type(diag_path) ~= 'string' or diag_path == '' then
    return false
  end
  if M.normalize_tmp_path(diag_path) == M.normalize_tmp_path(user_file) then
    return true
  end
  local function base(p)
    return p:gsub('\\', '/'):match('([^/]+)$') or p
  end
  if base(diag_path) == base(user_file) and base(diag_path) ~= helper_leaf then
    return true
  end
  return false
end

--- Remove a temporary file exactly once (harmless if missing).
---@param path? string
function M.remove_temp_file(path)
  if type(path) ~= 'string' or path == '' then
    return
  end
  pcall(os.remove, path)
end



--- Check whether snacks integration is enabled in config.
---@return boolean
function M.is_snacks_enabled()
  local snacks_cfg = config.cfg.integrations and config.cfg.integrations.snacks
  if not snacks_cfg then
    return false
  end
  if type(snacks_cfg) == 'table' then
    return snacks_cfg.enabled ~= false
  end
  return snacks_cfg == true
end

--- Setup snacks integration for a specific filetype.
---@param ft string
function M.setup_snacks_for_ft(ft)
  local snacks = package.loaded['snacks'] and package.loaded['snacks'].config
  if not (M.is_snacks_enabled() and snacks) then
    return
  end

  local snacks_cfg = config.cfg.integrations.snacks
  local clear_key = (type(snacks_cfg) == 'table' and snacks_cfg.keys and snacks_cfg.keys.clear) or '<BS>'
  local run_key = (type(snacks_cfg) == 'table' and snacks_cfg.keys and snacks_cfg.keys.run) or '<CR>'

  local snacks_opts = { scratch = { win_by_ft = {} } }
  snacks_opts.scratch.win_by_ft[ft] = {
    keys = {
      ['clear'] = {
        clear_key,
        function(self)
          require('itchy').clear(self.buf)
        end,
        desc = 'Clear',
        mode = { 'n', 'x' },
      },
      ['run'] = {
        run_key,
        function(self)
          require('itchy').run(self.buf)
        end,
        desc = 'Run code',
        mode = { 'n', 'x' },
      },
    },
  }

  snacks:merge(snacks_opts)

  if config.cfg.debug_mode then
    vim.notify('Added snacks integration for filetype: ' .. ft, vim.log.levels.DEBUG, { title = 'itchy' })
  end
end

return M
