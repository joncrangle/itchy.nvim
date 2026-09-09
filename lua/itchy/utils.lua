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

--- Get the appropriate wrapper for the filetype.
---@deprecated Prefer `require('itchy.adapters.legacy').prepare()` via
---`require('itchy.adapters').resolve(runtime)`. Kept for backward compatibility.
---@param runtime itchy.Runtime
---@param code string
---@return string
function M.get_wrapped_code(runtime, code)
  if runtime and runtime.wrapper then
    return runtime.wrapper(code, runtime.offset)
  end
  return code
end

--- Clean error messages by removing ANSI escape codes.
---Canonical implementation lives in `itchy.adapters.legacy`.
---@param err string
---@return string,_
function M.clean_error_message(err)
  return require('itchy.adapters.legacy').clean_error_message(err)
end

--- Parse line-prefixed output to get line number and message.
---Legacy wrapper protocol ("LINE<n>: ..."). Implementation lives in
---itchy.adapters.legacy; kept here as a backward-compatible alias.
---Returns the raw 0-based LINE number. Use
---`require('itchy.adapters.legacy').to_source_line(raw)` to get the
---1-based `itchy.Event` line.
---@param line string
---@return integer|nil, string|nil
function M.parse_line_output(line)
  return require('itchy.adapters.legacy').parse_line_output(line)
end

--- Process error output to get line number and message.
---Implementation lives in itchy.adapters.legacy; kept here as a
---backward-compatible alias. Contains no filetype branching itself.
---Returns a 1-based `itchy.Event` line (nil = locationless). This is a
---breaking change from the pre-adapter 0-based rows; use
---`require('itchy.event').is_valid_line` to validate and subtract 1 for
---0-based extmark rows.
---@param ft string
---@param err string
---@return integer?, string?
function M.parse_error_output(ft, err)
  return require('itchy.adapters.legacy').parse_error_output(ft, err)
end

--- Check if a line should be filtered based on noise patterns.
---Canonical implementation lives in `itchy.adapters.legacy`.
---@param line string
---@return boolean
function M.should_filter_line(line)
  return require('itchy.adapters.legacy').should_filter_line(line)
end

--- Leaf-name generator for project-local temp files. Unique by construction
---(pid + nanosecond clock + per-process monotonic counter) without touching
---the process-global RNG, so other plugins using math.random are unaffected.
---Never derived from tempname(), so a generated name cannot equal a
---pre-existing user file except by adversarial collision; the exclusive
---create loop is the actual safety net. Indirection point so tests can
---force collisions deterministically.
---@return string
local leaf_counter = 0
function M._project_leaf()
  leaf_counter = leaf_counter + 1
  return string.format('itchy-%d-%x-%x', vim.fn.getpid(), math.floor(vim.uv.hrtime() % 4294967295), leaf_counter)
end

--- Whether luv supports exclusive-create ("wx") open mode. Probed once per
---process against a fresh temp path.
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

--- Sentinel: the project dir is unusable (unwritable); the caller should
---fall back to the OS temp directory. Any other error propagates.
local FALLBACK = {}

--- Atomically create a project-local temp file with content. The leaf name
---is run-unique and creation uses O_EXCL ("wx") semantics, retrying on
---collision: an existing user file is never truncated. Falls back to an
---existence-checked plain create on runtimes whose luv predates "wx".
---@param dir string project directory (must exist)
---@param extension string file extension without dot
---@param content string file content
---@return string? path
---@return string?|table err message, or FALLBACK when the dir is unusable
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

--- Create a temporary source-code file for runtimes requiring a file.
---Only the source file is created; stdout/stderr are captured via vim.system.
---When `dir` is a writable directory, the file is created inside it so
---project-relative module resolution (Node relative imports, Python
---sibling imports via sys.path) keeps working; otherwise falls back to
---the OS temp directory (imports then resolve away from the project).
---Project-local creation is exclusive: pre-existing files are never
---truncated, even on leaf-name collision.
---@param ft string
---@param wrapped_code string
---@param dir? string preferred parent directory (e.g. the run cwd)
---@return string? path returns nil + error on failure
---@return string? err
function M.create_temp_code_file(ft, wrapped_code, dir)
  local extension = M.ft_to_ext(ft)
  if type(dir) == 'string' and dir ~= '' and vim.fn.isdirectory(dir) == 1 then
    local path, err = create_project_file(dir:gsub('[/\\]$', ''), extension, wrapped_code)
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
  file:write(wrapped_code)
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

--- Iterate every non-empty line of captured process output, including a
---final line without a trailing newline. Normalizes CRLF/CR.
---Canonical implementation is `itchy.adapters.legacy.each_line`.
---@param text string?
---@param fn fun(line: string)
function M.process_output_text(text, fn)
  return require('itchy.adapters.legacy').each_line(text, fn)
end

--- Process a single output line.
---@deprecated Prefer the adapter pipeline
---(`adapter.decode` -> `renderer.render`). Kept for backward compatibility.
---`parse_line_output` returns a raw 0-based LINE number; this helper clamps
---it to a 0-based extmark row.
---@param line string
---@param outputs_by_line table 0-based row -> text
---@param line_count integer
---@param line_mapping table optional 0-based row remapping
function M.process_output(line, outputs_by_line, line_count, line_mapping)
  if not line or line == '' or M.should_filter_line(line) then
    return
  end

  local row, msg = M.parse_line_output(line)
  row = row and math.max(0, math.min(line_count - 1, row)) or 0
  msg = msg or ''

  if row and line_mapping and line_mapping[row] then
    row = line_mapping[row]
  end

  outputs_by_line[row] = outputs_by_line[row] and (outputs_by_line[row] .. ' | ' .. msg) or msg
end

--- Cache check for neovim headless mode
local is_headless = not vim.env.DISPLAY and #vim.api.nvim_list_uis() == 0

--- Process a single error line.
---@deprecated Prefer the adapter pipeline
---(`adapter.decode` -> `renderer.render`). Kept for backward compatibility.
---`parse_error_output` returns a 1-based event line; this helper converts it
---to a 0-based extmark row before inserting into `errors_by_line`.
---@param line string
---@param errors_by_line table 0-based row -> text
---@param ft string
---@param line_count integer
---@param line_mapping table optional mapping; 1-based source lines take
---precedence, 0-based rows are honored as a legacy fallback
function M.process_error(line, errors_by_line, ft, line_count, line_mapping)
  if not line or line == '' then
    return
  end

  local cleaned_err = M.clean_error_message(line)
  M.debug_print('stderr data:', cleaned_err)

  if M.should_filter_line(cleaned_err) then
    return
  end

  local src_line, error_msg = M.parse_error_output(ft, cleaned_err)

  -- Legacy (-1) and normalized (nil) locationless diagnostics both notify.
  if src_line == -1 or (src_line == nil and error_msg ~= nil) then
    local msg = error_msg or 'Unknown error.'
    if not is_headless then
      vim.schedule(function()
        vim.notify(msg, vim.log.levels.ERROR, { title = 'itchy' })
      end)
    else
      vim.schedule(function()
        vim.notify('itchy error: ' .. msg, vim.log.levels.ERROR, { title = 'itchy' })
      end)
    end
  elseif src_line and error_msg then
    -- Convert the 1-based event line to a 0-based extmark row.
    local row = src_line - 1
    if line_mapping and line_mapping[src_line] ~= nil then
      -- Explicit 1-based source mapping (adapter-style source_map).
      local mapped = line_mapping[src_line]
      row = type(mapped) == 'number' and (mapped >= 1 and mapped - 1 or mapped) or row
    elseif line_mapping and line_mapping[row] ~= nil then
      -- Legacy 0-based row mapping fallback.
      row = line_mapping[row]
    else
      -- Ensure row is valid
      row = math.max(0, math.min(line_count - 1, row))
    end
    errors_by_line[row] = errors_by_line[row] and (errors_by_line[row] .. ' | ' .. error_msg) or error_msg
  end
end

--- Apply collected outputs and errors as extmarks.
---@deprecated Prefer `require('itchy.renderer').render(buf, ns, events, opts)`.
---Kept for backward compatibility. Expects 0-based rows.
---Stale/current-run validity is checked inside the scheduled callback so a
---run that becomes stale between scheduling and rendering cannot publish.
---@param buf integer
---@param namespace integer
---@param outputs_by_line table 0-based row -> text
---@param errors_by_line table 0-based row -> text
---@param is_current? fun(): boolean guard; when provided and returns false, rendering is skipped
function M.apply_extmarks(buf, namespace, outputs_by_line, errors_by_line, is_current)
  local hl_stdout = config.cfg.highlights.stdout
  local hl_stderr = config.cfg.highlights.stderr
  vim.schedule(function()
    if type(is_current) == 'function' then
      local ok, current = pcall(is_current)
      if not ok or not current then
        return
      end
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    for row, output in pairs(outputs_by_line) do
      local is_error = output:match 'ItchyError'
      local cleaned_output = is_error and output:gsub('ItchyError: ', '') or output
      local hl_group = is_error and hl_stderr or hl_stdout
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        virt_lines = { { { '  │ ', hl_group }, { cleaned_output, hl_group } } },
      })
    end

    for row, err_msg in pairs(errors_by_line) do
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        virt_lines = { { { '  │ ', hl_stderr }, { err_msg, hl_stderr } } },
      })
    end
  end)
end

--- Setup snacks integration for a specific filetype.
---@param ft string
function M.setup_snacks_for_ft(ft)
  local snacks = package.loaded['snacks'] and package.loaded['snacks'].config
  if not (config.cfg.integrations.snacks and snacks) then
    return
  end

  local snacks_opts = { scratch = { win_by_ft = {} } }
  snacks_opts.scratch.win_by_ft[ft] = {
    keys = {
      ['clear'] = {
        config.cfg.integrations.snacks.keys.clear,
        function(self)
          require('itchy').clear(self.buf)
        end,
        desc = 'Clear',
        mode = { 'n', 'x' },
      },
      ['run'] = {
        config.cfg.integrations.snacks.keys.run,
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
