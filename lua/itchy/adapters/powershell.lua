--- PowerShell/pwsh adapter with native invocation metadata (issue #13).
---
--- The user's source runs from a temp file with a same-scope resilience
--- trap appended AFTER the code (existing lines never shift, so native
--- ScriptLineNumber values keep matching buffer lines); a separate launcher
--- defines proxy functions for `Write-Output`, `Write-Host`,
--- `Write-Warning` and `Write-Error`. Each proxy captures its call site
--- inline with native call-stack metadata (`Get-PSCallStack` line/column via
--- `Position`, file via `ScriptName`) BEFORE emitting, so helper frames never
--- replace the user location, then reports a nonce-framed structured event through
--- `[Console]::Out` (bypassing PowerShell streams, so files and pipes are
--- never polluted with metadata). No per-line `currentLine` tracking, no
--- source rewriting: comments and strings naming output commands never
--- invoke them, so they can never match.
---
--- Uncaught errors (throw, command-not-found, parse errors) keep their
--- native stderr diagnostics; the adapter selects the `path.ps1:LINE`
--- frame belonging to the user's file. No manufactured `LINE<n>` errors.
--- One adapter serves `pwsh` and Windows PowerShell (`powershell`) where
--- behavior is compatible; syntax stays within their common subset.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local legacy = require("itchy.adapters.legacy")
local utils = require("itchy.utils")

M.name = "powershell"

--- Escape a path for a single-quoted PowerShell string ('' = literal ').
---@param path string
---@return string
local function ps_escape(path)
	return (path:gsub("'", "''"))
end

-- Launcher: proxy output commands with native caller metadata, then invoke
-- the unchanged user file so ScriptLineNumber values are user lines.
local PS_HELPER = [=[
$__itchyNonce = '__ITCHY_NONCE__'
$__itchyUserFile = '__ITCHY_USER_FILE__'
# Normalized (slash) form for caller-file comparison: the launcher receives
# an absolute path, while ScriptName may differ in separators. PowerShell
# -eq is already case-insensitive, so no case folding is needed.
$__itchyUserNorm = ($__itchyUserFile -replace '\\','/')
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

function __itchy_Emit($kind, $message, $line, $column) {
	$evt = @{ kind = "$kind"; message = "$message" }
	if ($line) { $evt['line'] = [int]$line }
	if ($column) { $evt['column'] = [int]$column }
	$json = $evt | ConvertTo-Json -Compress
	[Console]::Out.WriteLine([char]0x1E + 'ITCHY:' + $__itchyNonce + ':' + $json)
}

# Whether a ScriptName belongs to the user file. Takes only strings, never
# inspects the stack, so proxies may safely call it after capturing. An empty
# name (dynamic code with no file) is attributed to the user run rather than
# dropped: the only code executing here is the user file and this launcher.
function __itchy_IsUserFile($name) {
	if (-not $name) { return $true }
	return (("$name" -replace '\\','/') -eq $__itchyUserNorm)
}

function Write-Output {
	# Capture the user call site HERE, before any helper call: [0] is this
	# proxy, [1] the user location. A nested helper would see this proxy
	# frame instead, so the capture must stay inline in every proxy.
	$__itchy_line = $null
	$__itchy_col = $null
	try {
		$__itchy_cs = Get-PSCallStack
		if ($__itchy_cs.Count -ge 2 -and $__itchy_cs[1].ScriptLineNumber -gt 0) {
			if (__itchy_IsUserFile $__itchy_cs[1].ScriptName) {
				$__itchy_line = $__itchy_cs[1].ScriptLineNumber
				try { $__itchy_col = $__itchy_cs[1].Position.StartColumnNumber } catch {}
				if ($__itchy_col -and $__itchy_col -lt 1) { $__itchy_col = $null }
			}
		}
	} catch {}
	$items = @()
	foreach ($a in $args) { $items += $a }
	foreach ($i in $input) { $items += $i }
	$text = ($items | ForEach-Object { "$_" }) -join ' '
	__itchy_Emit 'stdout' $text $__itchy_line $__itchy_col
}

function Write-Host {
	param(
		[Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
		$ForegroundColor,
		$BackgroundColor,
		$Separator,
		[switch]$NoNewline
	)
	$__itchy_line = $null
	$__itchy_col = $null
	try {
		$__itchy_cs = Get-PSCallStack
		if ($__itchy_cs.Count -ge 2 -and $__itchy_cs[1].ScriptLineNumber -gt 0) {
			if (__itchy_IsUserFile $__itchy_cs[1].ScriptName) {
				$__itchy_line = $__itchy_cs[1].ScriptLineNumber
				try { $__itchy_col = $__itchy_cs[1].Position.StartColumnNumber } catch {}
				if ($__itchy_col -and $__itchy_col -lt 1) { $__itchy_col = $null }
			}
		}
	} catch {}
	$sep = ' '
	if ($Separator -is [string]) { $sep = $Separator }
	$text = ($Object | ForEach-Object { "$_" }) -join $sep
	__itchy_Emit 'stdout' $text $__itchy_line $__itchy_col
}

function Write-Warning {
	param([Parameter(Position = 0)]$Message, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
	$__itchy_line = $null
	$__itchy_col = $null
	try {
		$__itchy_cs = Get-PSCallStack
		if ($__itchy_cs.Count -ge 2 -and $__itchy_cs[1].ScriptLineNumber -gt 0) {
			if (__itchy_IsUserFile $__itchy_cs[1].ScriptName) {
				$__itchy_line = $__itchy_cs[1].ScriptLineNumber
				try { $__itchy_col = $__itchy_cs[1].Position.StartColumnNumber } catch {}
				if ($__itchy_col -and $__itchy_col -lt 1) { $__itchy_col = $null }
			}
		}
	} catch {}
	$parts = @()
	if ($null -ne $Message) { $parts += $Message }
	foreach ($r in $Rest) { $parts += $r }
	$text = ($parts | ForEach-Object { "$_" }) -join ' '
	__itchy_Emit 'warning' $text $__itchy_line $__itchy_col
}

function Write-Error {
	param([Parameter(Position = 0)]$Message, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
	$__itchy_line = $null
	$__itchy_col = $null
	try {
		$__itchy_cs = Get-PSCallStack
		if ($__itchy_cs.Count -ge 2 -and $__itchy_cs[1].ScriptLineNumber -gt 0) {
			if (__itchy_IsUserFile $__itchy_cs[1].ScriptName) {
				$__itchy_line = $__itchy_cs[1].ScriptLineNumber
				try { $__itchy_col = $__itchy_cs[1].Position.StartColumnNumber } catch {}
				if ($__itchy_col -and $__itchy_col -lt 1) { $__itchy_col = $null }
			}
		}
	} catch {}
	$parts = @()
	if ($null -ne $Message) { $parts += $Message }
	foreach ($r in $Rest) { $parts += $r }
	$text = ($parts | ForEach-Object { "$_" }) -join ' '
	__itchy_Emit 'error' $text $__itchy_line $__itchy_col
}

& "$__itchyUserFile"
]=]

-- Same-scope resilience trap, appended AFTER the user code in the temp user
-- file. Appending never shifts existing lines, so native ScriptLineNumber
-- values keep matching buffer lines. PowerShell registers scope traps
-- upfront, so position is irrelevant; `continue` resumes with the next user
-- statement. Errors already handled by user try/catch never reach it.
-- Locations come from InvocationInfo -- never manufactured.
local PS_TRAP = [=[

# itchy.nvim resilience trap (managed, do not edit).
trap {
	$__itchy_trap_line = $null
	try {
		$__itchy_trap_inv = $_.InvocationInfo
		if ($__itchy_trap_inv -and $__itchy_trap_inv.ScriptLineNumber -gt 0 -and (__itchy_IsUserFile $__itchy_trap_inv.ScriptName)) {
			$__itchy_trap_line = $__itchy_trap_inv.ScriptLineNumber
		}
	} catch {}
	$__itchy_trap_msg = 'Error'
	try {
		$__itchy_trap_msg = "$($_.Exception.Message)"
		if (-not $__itchy_trap_msg) { $__itchy_trap_msg = "$_" }
	} catch {}
	__itchy_Emit 'error' $__itchy_trap_msg $__itchy_trap_line
	continue
}
]=]

--- Parse native PowerShell stderr: the `path.ps1:LINE` frame belonging to
--- the user file plus the `|` detail lines carrying the message.
---@param stderr_text string
---@param user_file string
---@return integer?, string?
local function parse_ps_error(stderr_text, user_file)
	local found_line = nil
	framed.each_line(stderr_text, function(raw)
		if found_line ~= nil then
			return
		end
		local line = legacy.clean_error_message(raw)
		-- `Exception: C:\path\file.ps1:2` / `ParserError: ...ps1:2` headers.
		local path, lnum = line:match("^(.-%.ps1):(%d+)")
		if path == nil then
			path, lnum = line:match("(%S-%.ps1):(%d+)")
		end
		if path ~= nil and utils.is_user_file(path, user_file, "itchy_launcher.ps1") then
			found_line = tonumber(lnum)
		end
	end)
	local details = {}
	framed.each_line(stderr_text, function(raw)
		local line = legacy.clean_error_message(raw)
		-- Detail rows render as `     | <text>`; the `Line |` header itself
		-- never matches this anchor. Caret/tilde excerpt markers carry no
		-- message text and are skipped.
		local text = line:match("^%s*|%s*(.-)%s*$")
		if text ~= nil and text ~= "" and text:match("^[~^%s]+$") == nil then
			table.insert(details, text)
		end
	end)
	local message = nil
	if #details > 0 then
		message = table.concat(details, " ")
	else
		-- Fallback: first meaningful line (e.g. `Write-Error: oops` when a
		-- proxy missed a form). Skip frame/excerpt decoration.
		framed.each_line(stderr_text, function(raw)
			if message ~= nil then
				return
			end
			local line = legacy.clean_error_message(raw):match("^%s*(.-)%s*$")
			if line == "" or line:match("^Line%s*|") or line:match("%.ps1:%d+") or line:match("^[~^%s]+$") then
				return
			end
			message = line
		end)
	end
	if message == nil or message == "" then
		return found_line, nil
	end
	return found_line, message
end

--- Prepare execution: user file (source + appended same-scope trap) and a
--- separate launcher with the output proxies.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "powershell adapter requires a context")
	assert(ctx.runtime ~= nil, "powershell adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local nonce = framed.create_nonce()

	local tmpdir = utils.make_adapter_tmpdir(utils.project_dir(ctx), "itchy-ps", nonce)

	local user_path = tmpdir .. "/itchy-user-" .. nonce .. ".ps1"
	local launcher_path = tmpdir .. "/itchy_launcher.ps1"
	-- The trap is appended after the user code: existing lines never shift,
	-- so native locations keep matching buffer lines byte for byte.
	local user_content = source
	if user_content ~= "" and user_content:sub(-1) ~= "\n" then
		user_content = user_content .. "\n"
	end
	user_content = user_content .. PS_TRAP
	local uf, uerr = io.open(user_path, "w")
	if not uf then
		error("powershell adapter: failed to create source file: " .. tostring(uerr))
	end
	uf:write(user_content)
	uf:close()

	local helper_src = PS_HELPER
	helper_src = helper_src:gsub("__ITCHY_NONCE__", function()
		return nonce
	end)
	helper_src = helper_src:gsub("__ITCHY_USER_FILE__", function()
		return ps_escape(user_path)
	end)
	local lf, lerr = io.open(launcher_path, "w")
	if not lf then
		utils.remove_temp_file(user_path)
		error("powershell adapter: failed to create launcher file: " .. tostring(lerr))
	end
	lf:write(helper_src)
	lf:close()

	-- Keep runtime launcher flags but run the launcher file: inline
	-- `-Command` becomes `-File`.
	local cmd = { runtime.cmd }
	for _, arg in ipairs(runtime.args or {}) do
		if arg ~= "-Command" then
			table.insert(cmd, arg)
		end
	end
	table.insert(cmd, "-File")
	table.insert(cmd, launcher_path)

	local function cleanup()
		utils.remove_temp_file(user_path)
		utils.remove_temp_file(launcher_path)
		pcall(vim.fn.delete, tmpdir, "d")
	end

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = cleanup,
		metadata = { nonce = nonce, user_file = user_path, filetype = ctx.filetype },
	}
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	local metadata = (prepared and prepared.metadata) or {}
	local nonce = metadata.nonce
	local user_file = metadata.user_file or ""
	---@type itchy.Event[]
	local events = {}

	framed.each_line(result.stdout, function(line)
		local record = framed.decode_line(line, nonce)
		if record then
			table.insert(events, event.create(record.kind, record.message, record.line, record.column))
			return
		end
		if legacy.should_filter_line(line) then
			return
		end
		if line ~= "" then
			table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
		end
	end)

	local stderr_text = type(result.stderr) == "string" and result.stderr or ""
	local has_stderr = false
	framed.each_line(stderr_text, function(line)
		if line ~= "" and not legacy.should_filter_line(line) then
			has_stderr = true
		end
	end)
	if has_stderr then
		local eline, message = parse_ps_error(stderr_text, user_file)
		if message ~= nil and message ~= "" then
			if eline ~= nil and eline >= 1 then
				table.insert(events, event.create("error", framed.sanitize_message(message), eline))
			else
				table.insert(events, event.create("error", framed.sanitize_message(message), nil))
			end
		end
	end

	return events
end

return M
