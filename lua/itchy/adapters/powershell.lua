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
--- never polluted with metadata), and finally delegates to the real cmdlet
--- (`Microsoft.PowerShell.Utility\...`) so stream behavior is preserved:
--- `Write-Output` still feeds the success pipeline (`$x = Write-Output 123`,
--- `Write-Output 1 | ForEach-Object { $_ + 1 }`), `Write-Error` still writes
--- error records to the error stream and `$Error` and honors `-ErrorAction` /
--- `$ErrorActionPreference`, and likewise for warning/information streams.
--- No per-line `currentLine` tracking, no source rewriting: comments and
--- strings naming output commands never invoke them, so they can never match.
---
--- Uncaught errors (throw, command-not-found, parse errors) keep their
--- native stderr diagnostics; the adapter selects the `path.ps1:LINE`
--- frame belonging to the user's file. No manufactured `LINE<n>` errors.
--- One adapter serves `pwsh` and Windows PowerShell (`powershell`) where
--- behavior is compatible; syntax stays within their common subset
--- (no `?.`, `??`, ternaries; module-qualified cmdlet names exist on both).
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

# Forward the caller's preference/variable common parameters to a delegated
# native call so `-ErrorAction Stop`, `-WarningAction`, `-OutVariable` and
# friends keep working through the proxy. $bound is the proxy's
# $PSBoundParameters (passed explicitly: it is caller-scoped).
# -PipelineVariable is intentionally NOT forwarded: it names the caller's
# pipeline, which the inner call cannot see.
function __itchy_CommonSplat($bound) {
	$s = @{}
	foreach ($k in @('ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','Verbose','Debug')) {
		try { if ($bound.ContainsKey($k)) { $s[$k] = $bound[$k] } } catch {}
	}
	return $s
}

function Write-Output {
	# Like the native cmdlet, InputObject gathers every remaining positional
	# (`Write-Output a b c`): a plain Position=0 array binds only the first
	# positional, so ValueFromRemainingArguments is required on top of
	# ValueFromPipeline.
	[CmdletBinding()] param(
		[Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)][object[]]$InputObject,
		[switch]$NoEnumerate
	)
	begin {
		# Capture the user call site HERE, before any helper call: [0] is
		# this proxy, [1] the user location. A nested helper would see this
		# proxy frame instead, so the capture stays inline in every proxy.
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
		$__itchy_items = @()
		$__itchy_piped = $false
	}
	process {
		if ($MyInvocation.ExpectingInput) { $__itchy_piped = $true }
		foreach ($o in $InputObject) { $__itchy_items += $o }
	}
	end {
		$__itchy_bound = $PSBoundParameters.ContainsKey('InputObject')
		if ((-not $__itchy_bound) -and $__itchy_items.Count -eq 0) { return }
		$text = ($__itchy_items | ForEach-Object { "$_" }) -join ' '
		__itchy_Emit 'stdout' $text $__itchy_line $__itchy_col
		$__itchy_splat = __itchy_CommonSplat $PSBoundParameters
		if ($NoEnumerate -and (-not $__itchy_piped)) {
			Microsoft.PowerShell.Utility\Write-Output -NoEnumerate $__itchy_items @__itchy_splat
		} elseif ($__itchy_items.Count -gt 0) {
			foreach ($o in $__itchy_items) { Microsoft.PowerShell.Utility\Write-Output $o @__itchy_splat }
		} else {
			Microsoft.PowerShell.Utility\Write-Output $null @__itchy_splat
		}
	}
}

function Write-Host {
	[CmdletBinding()] param(
		[Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)][object[]]$Object,
		$ForegroundColor,
		$BackgroundColor,
		$Separator,
		[switch]$NoNewline
	)
	begin {
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
		$__itchy_objs = @()
	}
	process {
		foreach ($o in $Object) { $__itchy_objs += $o }
	}
	end {
		$sep = ' '
		if ($Separator -is [string]) { $sep = $Separator }
		$text = ($__itchy_objs | ForEach-Object { "$_" }) -join $sep
		__itchy_Emit 'stdout' $text $__itchy_line $__itchy_col
		$__itchy_splat = __itchy_CommonSplat $PSBoundParameters
		if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $__itchy_splat['ForegroundColor'] = $ForegroundColor }
		if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $__itchy_splat['BackgroundColor'] = $BackgroundColor }
		if ($PSBoundParameters.ContainsKey('Separator')) { $__itchy_splat['Separator'] = $Separator }
		if ($NoNewline) { $__itchy_splat['NoNewline'] = $true }
		Microsoft.PowerShell.Utility\Write-Host -Object $__itchy_objs @__itchy_splat
	}
}

function Write-Warning {
	[CmdletBinding()] param(
		[Parameter(Position = 0, ValueFromPipeline = $true)][string]$Message
	)
	begin {
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
		$__itchy_parts = @()
	}
	process {
		if ($null -ne $Message) { $__itchy_parts += $Message }
	}
	end {
		$text = ($__itchy_parts | ForEach-Object { "$_" }) -join ' '
		__itchy_Emit 'warning' $text $__itchy_line $__itchy_col
		$__itchy_splat = __itchy_CommonSplat $PSBoundParameters
		if ($__itchy_parts.Count -gt 0) {
			foreach ($m in $__itchy_parts) { Microsoft.PowerShell.Utility\Write-Warning -Message "$m" @__itchy_splat }
		} else {
			Microsoft.PowerShell.Utility\Write-Warning -Message "" @__itchy_splat
		}
	}
}

function Write-Error {
	[CmdletBinding()] param(
		[Parameter(Position = 0, ValueFromPipeline = $true)][object]$Message,
		[Parameter(Position = 1)][string]$ErrorId,
		[Parameter(Position = 2)][System.Management.Automation.ErrorCategory]$Category,
		[Parameter(Position = 3)][object]$TargetObject,
		[string]$RecommendedAction,
		[string]$CategoryActivity,
		[string]$CategoryReason,
		[string]$CategoryTargetName,
		[string]$CategoryTargetType,
		[System.Exception]$Exception
	)
	begin {
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
		$__itchy_parts = @()
	}
	process {
		if ($null -ne $Message) { $__itchy_parts += $Message }
	}
	end {
		$text = ($__itchy_parts | ForEach-Object { "$_" }) -join ' '
		__itchy_Emit 'error' $text $__itchy_line $__itchy_col
		$__itchy_splat = __itchy_CommonSplat $PSBoundParameters
		foreach ($k in @('ErrorId','Category','TargetObject','RecommendedAction','CategoryActivity','CategoryReason','CategoryTargetName','CategoryTargetType','Exception')) {
			try { if ($PSBoundParameters.ContainsKey($k)) { $__itchy_splat[$k] = $PSBoundParameters[$k] } } catch {}
		}
		if ($__itchy_parts.Count -gt 0) {
			foreach ($m in $__itchy_parts) { Microsoft.PowerShell.Utility\Write-Error -Message "$m" @__itchy_splat }
		} else {
			Microsoft.PowerShell.Utility\Write-Error -Message "" @__itchy_splat
		}
	}
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
--- Also understands the Windows PowerShell 5.1 classic format (`At
--- path.ps1:LINE char:COL` headers, `+ CategoryInfo` metadata rows), which
--- carries no `|` details: those diagnostics stay locationless-or-`At`-located
--- rather than vanishing.
---@param stderr_text string
---@param user_file string
---@return integer? line
---@return integer? column (only from 5.1 `At ... char:` headers)
---@return string? message
---@return string[] details (`|` rows, sanitized)
local function parse_ps_error(stderr_text, user_file)
	local found_line, found_col = nil, nil
	framed.each_line(stderr_text, function(raw)
		if found_line ~= nil then
			return
		end
		local line = legacy.clean_error_message(raw)
		-- `At C:\path\file.ps1:2 char:11` (Windows PowerShell 5.1).
		local at_path, at_lnum, at_col = line:match("^[Aa]t%s+(.-%.ps1):(%d+)%s+[Cc]har:%s*(%d+)")
		if at_path ~= nil and utils.is_user_file(at_path, user_file, "itchy_launcher.ps1") then
			found_line, found_col = tonumber(at_lnum), tonumber(at_col)
			return
		end
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
			table.insert(details, framed.sanitize_message(text))
		end
	end)
	local message = nil
	if #details > 0 then
		message = table.concat(details, " ")
	else
		-- Fallback: first meaningful line (e.g. `Write-Error: oops` when a
		-- proxy missed a form). Skip frame/excerpt decoration and 5.1
		-- `+ CategoryInfo` metadata rows; strip `Write-Error:`/`WARNING:`
		-- headers down to the message itself.
		framed.each_line(stderr_text, function(raw)
			if message ~= nil then
				return
			end
			local line = legacy.clean_error_message(raw):match("^%s*(.-)%s*$")
			if line == "" or line:match("^Line%s*|") or line:match("%.ps1:%d+") or line:match("^[~^%s]+$") or line:match("^%+") then
				return
			end
			line = line:gsub("^[Ww]rite%-Error%s*:%s*", ""):gsub("^[Ww][Aa][Rr][Nn][Ii][Nn][Gg]%s*:%s*", "")
			if line ~= "" then
				message = line
			end
		end)
	end
	if message == nil or message == "" then
		return found_line, found_col, nil, details
	end
	return found_line, found_col, framed.sanitize_message(message), details
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
---
--- Delegation awareness: because the proxies now forward to the real cmdlets,
--- native output also reaches the host (`Write-Output "hi"` prints `hi` to
--- the success stream, `Write-Warning` prints `WARNING: ...`, `Write-Error`
--- prints its record to stderr). That native echo duplicates the precise
--- framed event, so it is folded away: raw stdout lines equal to a framed
--- stdout message are dropped, `WARNING:` lines matching a framed warning
--- are dropped, and a stderr diagnostic whose every detail already arrived
--- framed (and which adds no uncovered user line) is dropped. Genuine native
--- diagnostics (command-not-found, parse errors, direct cmdlet calls that
--- bypass the proxies) match nothing framed and are always kept.
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
	-- Remaining framed message counts per kind for duplicate folding.
	local stdout_counts, warning_counts, error_counts = {}, {}, {}
	-- User lines already carrying framed errors.
	local framed_err_lines = {}
	-- Exact-duplicate framed errors already added: a proxy-delegated
	-- terminating error (`-ErrorAction Stop`) is reported twice for the same
	-- instance, once by the proxy before delegating and once by the
	-- same-scope resilience trap that catches the throw. The trap never
	-- emits stdout/warning, so only error kinds fold.
	local seen_err = {}
	---@type string[]
	local raw_lines = {}

	local function count_into(counts, message)
		counts[message] = (counts[message] or 0) + 1
	end
	local function consume(counts, message)
		if (counts[message] or 0) > 0 then
			counts[message] = counts[message] - 1
			return true
		end
		return false
	end
	local function add_framed(record)
		if record.kind == "warning" then
			count_into(warning_counts, record.message)
			table.insert(events, event.create(record.kind, record.message, record.line, record.column))
		elseif record.kind == "error" or record.kind == "stderr" then
			-- Count every emission (stderr folding matches per-instance),
			-- but add an identical diagnostic once: same kind, line and
			-- message renders the same virtual line either way.
			count_into(error_counts, record.message)
			if record.line ~= nil then
				framed_err_lines[record.line] = true
			end
			local key = record.kind .. ":" .. tostring(record.line) .. ":" .. record.message
			if not seen_err[key] then
				seen_err[key] = true
				table.insert(events, event.create(record.kind, record.message, record.line, record.column))
			end
		else
			count_into(stdout_counts, record.message)
			table.insert(events, event.create(record.kind, record.message, record.line, record.column))
		end
	end
	-- Run of consecutive raw lines that may jointly echo one framed message
	-- (see the raw pass below). Emptied on match or when proven homeless.
	local pending_run = {}
	local function flush_pending()
		for _, pline in ipairs(pending_run) do
			if pline ~= "" then
				table.insert(events, event.create("stdout", pline, nil))
			end
		end
		pending_run = {}
	end
	-- One stdout line, possibly with a raw prefix glued onto a framed record
	-- by a native write without trailing newline (`Write-Host -NoNewline`).
	local function handle_stdout_line(line)
		if line:sub(1, 1) == framed.RS then
			local record = framed.decode_line(line, nonce)
			if record then
				add_framed(record)
				return
			end
			-- Foreign record separator: keep legacy behavior (raw event).
			if not legacy.should_filter_line(line) and line ~= "" then
				table.insert(raw_lines, line)
			end
			return
		end
		local rs_at = line:find(framed.RS, 1, true)
		if rs_at ~= nil then
			local prefix = line:sub(1, rs_at - 1)
			if prefix ~= "" and not legacy.should_filter_line(prefix) then
				table.insert(raw_lines, prefix)
			end
			handle_stdout_line(line:sub(rs_at))
			return
		end
		if not legacy.should_filter_line(line) and line ~= "" then
			table.insert(raw_lines, line)
		end
	end

	framed.each_line(result.stdout, handle_stdout_line)

	for _, line in ipairs(raw_lines) do
		local warn_msg = line:match("^WARNING:%s*(.-)%s*$")
		if warn_msg ~= nil then
			flush_pending()
			warn_msg = framed.sanitize_message(warn_msg)
			if warn_msg ~= "" and not consume(warning_counts, warn_msg) then
				-- A direct native warning call bypassing the proxy: keep it
				-- visible rather than dropping provider output.
				table.insert(events, event.create("warning", warn_msg, nil))
			end
		elseif consume(stdout_counts, framed.sanitize_message(line)) then
			-- Exact echo of one framed message: any open run ended before
			-- this line, so it can never complete; emit it homeless.
			flush_pending()
		else
			-- Maybe the tail of a multi-object echo (`Write-Output a b c`
			-- reports once as "a b c" while the delegation prints three
			-- success-stream lines). Runs are contiguous by construction
			-- (synchronous delegation), so an open run stays open until it
			-- matches, an exact/warning line ends it, or input ends.
			table.insert(pending_run, framed.sanitize_message(line))
			if consume(stdout_counts, table.concat(pending_run, " ")) then
				pending_run = {}
			elseif #pending_run > 64 then
				flush_pending()
			end
		end
	end
	flush_pending()

	local stderr_text = type(result.stderr) == "string" and result.stderr or ""
	local has_stderr = false
	framed.each_line(stderr_text, function(line)
		if line ~= "" and not legacy.should_filter_line(line) then
			has_stderr = true
		end
	end)
	if has_stderr then
		local eline, ecol, message, details = parse_ps_error(stderr_text, user_file)
		if message ~= nil and message ~= "" then
			-- Fold delegated duplicates: every detail (or the fallback
			-- message) already arrived framed, and the parsed line adds no
			-- uncovered user location.
			local dup = true
			local parts = #details > 0 and details or { message }
			local pool = {}
			for msg, c in pairs(error_counts) do
				pool[msg] = c
			end
			for _, d in ipairs(parts) do
				if (pool[d] or 0) > 0 then
					pool[d] = pool[d] - 1
				else
					dup = false
					break
				end
			end
			if eline ~= nil and framed_err_lines[eline] == nil then
				dup = false
			end
			if not dup then
				if eline ~= nil and eline >= 1 then
					-- event.create asserts 1-based columns; drop a bogus one.
					local col = (ecol ~= nil and ecol >= 1) and ecol or nil
					table.insert(events, event.create("error", message, eline, col))
				else
					table.insert(events, event.create("error", message, nil))
				end
			end
		end
	end

	return events
end

return M
