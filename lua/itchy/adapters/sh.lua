--- POSIX sh adapter. Prepends a POSIX helper header and rewrites echo and printf
--- calls with explicit line arguments. Diagnostics from native stderr are
--- mapped back to user lines by subtracting the header length.
local M = {}

local framed = require("itchy.adapters.framed")
local shell_common = require("itchy.adapters.shell_common")

M.name = "sh"

M.HELPER_LEAF = "itchy-launcher"

--- Fixed helper header. `__ITCHY_*` placeholders are substituted per run.
--- The rendered header line count is the decode offset for native
--- diagnostics; rewritten call sites already carry absolute coordinates.
local SH_HEADER = [=[
# itchy.nvim sh compatibility header (managed, do not edit).
# POSIX sh only: portable constructs (no arrays, no BASH_*, no `local`).
__ITCHY_NONCE="__ITCHY_NONCE__"
__ITCHY_EVENT_FILE="__ITCHY_EVENT_FILE__"
__itchy_output_seq=0
__itchy_frame_active=0
__itchy_newline=$(printf '\012x')
__itchy_newline=${__itchy_newline%x}

__itchy_begin_output() {
  if [ "$__itchy_frame_active" -eq 1 ]; then
    return
  fi
  while :; do
    __itchy_output_seq=$((__itchy_output_seq + 1))
    __itchy_output_marker="$__ITCHY_EVENT_FILE.marker.$__itchy_output_seq"
    if command mkdir "$__itchy_output_marker" 2>/dev/null; then
      break
    fi
  done
  printf '\036\037%s:%s:' "$__ITCHY_NONCE" "$__itchy_output_seq"
  __itchy_frame_active=1
}

__itchy_end_output() {
  if [ "$__itchy_frame_active" -ne 1 ]; then
    return
  fi
  printf '\036\035%s:%s\n' "$__ITCHY_NONCE" "$__itchy_output_seq"
  command rmdir "$__itchy_output_marker" 2>/dev/null || true
  __itchy_frame_active=0
}

__itchy_should_frame() {
  # A function-level redirection replaces fd 1 before the helper runs. Do not
  # write transport bytes into a user-owned regular file; the side-channel
  # record still preserves the mapped output event.
  if [ -f /dev/fd/1 ]; then
    return 1
  fi
  return 0
}

__itchy_emit() {
  __itchy_kind="$1"
  __itchy_line="$2"
  __itchy_msg="$3"
  __itchy_esc=$(printf '%s' "$__itchy_msg" | awk '
BEGIN {
  __itchy_controls = ""
  for (__itchy_i = 1; __itchy_i < 32; __itchy_i++) {
    __itchy_controls = __itchy_controls sprintf("%c", __itchy_i)
  }
}
{
  if (__itchy_seen) {
    printf "%s", "\\n"
  }
  __itchy_seen = 1
  for (__itchy_i = 1; __itchy_i <= length($0); __itchy_i++) {
    __itchy_c = substr($0, __itchy_i, 1)
    if (__itchy_c == "\\") {
      printf "%s", "\\\\"
    } else if (__itchy_c == "\"") {
      printf "%s", "\\\""
    } else {
      __itchy_code = index(__itchy_controls, __itchy_c)
      if (__itchy_code == 8) {
        printf "%s", "\\b"
      } else if (__itchy_code == 9) {
        printf "%s", "\\t"
      } else if (__itchy_code == 12) {
        printf "%s", "\\f"
      } else if (__itchy_code == 13) {
        printf "%s", "\\r"
      } else if (__itchy_code != 0) {
        printf "%s%02x", "\\u00", __itchy_code
      } else {
        printf "%s", __itchy_c
      }
    }
  }
}
')
  if [ -n "$__itchy_line" ]; then
    __itchy_json="{\"kind\":\"$__itchy_kind\",\"line\":$__itchy_line,\"message\":\"$__itchy_esc\"}"
  else
    __itchy_json="{\"kind\":\"$__itchy_kind\",\"message\":\"$__itchy_esc\"}"
  fi
  printf '\036ITCHY:%s:%s\n' "$__ITCHY_NONCE" "$__itchy_json" >> "$__ITCHY_EVENT_FILE" || true
}

__itchy_echo() {
  __itchy_line="$1"
  shift || true
  __itchy_out=$( (echo "$@"; __itchy_status=$?; printf '\001'; exit "$__itchy_status") 2>/dev/null)
  __itchy_status=$?
  __itchy_out=${__itchy_out%?}
  __itchy_had_newline=0
  case "$__itchy_out" in
    *"$__itchy_newline")
      __itchy_had_newline=1
      while :; do
        case "$__itchy_out" in
          *"$__itchy_newline") __itchy_out=${__itchy_out%"$__itchy_newline"} ;;
          *) break ;;
        esac
      done
      ;;
  esac
  if [ "$__itchy_status" -eq 0 ] && [ -n "$__itchy_out" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_out" || true
    if __itchy_should_frame; then
      __itchy_begin_output
      echo "$@"
      __itchy_output_status=$?
      if [ "$__itchy_had_newline" -eq 1 ]; then
        __itchy_end_output
      fi
      return $__itchy_output_status
    fi
  fi
  echo "$@"
}

__itchy_printf() {
  __itchy_line="$1"
  shift || true
  __itchy_out=$( (printf "$@"; __itchy_status=$?; printf '\001'; exit "$__itchy_status") 2>/dev/null)
  __itchy_status=$?
  __itchy_out=${__itchy_out%?}
  __itchy_had_newline=0
  case "$__itchy_out" in
    *"$__itchy_newline")
      __itchy_had_newline=1
      while :; do
        case "$__itchy_out" in
          *"$__itchy_newline") __itchy_out=${__itchy_out%"$__itchy_newline"} ;;
          *) break ;;
        esac
      done
      ;;
  esac
  if [ "$__itchy_status" -eq 0 ] && [ -n "$__itchy_out" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_out" || true
    if __itchy_should_frame; then
      __itchy_begin_output
      printf "$@"
      __itchy_output_status=$?
      if [ "$__itchy_had_newline" -eq 1 ]; then
        __itchy_end_output
      fi
      return $__itchy_output_status
    fi
  fi
  printf "$@"
}

trap '__itchy_exit_status=$?; __itchy_end_output; trap - 0; exit "$__itchy_exit_status"' 0
]=]

--- Render the header for one run. Exposed for tests.
---@param nonce string
---@param event_file string
---@return string
function M._header(nonce, event_file)
	local src = shell_common.render_template(SH_HEADER, nonce, event_file)
	-- Long-string margin: Lua strips the single newline after the opening
	-- bracket, so the template ends with exactly one trailing newline.
	assert(src:sub(-1) == "\n", "sh header margins changed")
	return src
end

--- Count lines in a header string ending with exactly one newline.
---@param header string
---@return integer
local function header_line_count(header)
	local n = 0
	for _ in header:gmatch("\n") do
		n = n + 1
	end
	return n
end

M._header_line_count = header_line_count

--- Split source into lines, normalizing CRLF/CR. No trailing phantom: a
--- trailing newline does not create an extra empty element, so the
--- rewrite below preserves the exact line count.
---@param source string
---@return string[]
local function split_lines(source)
	local normalized = source:gsub("\r\n", "\n"):gsub("\r", "\n")
	local lines = {}
	local start = 1
	while true do
		local nl = normalized:find("\n", start, true)
		if nl then
			table.insert(lines, normalized:sub(start, nl - 1))
			start = nl + 1
		else
			if start <= #normalized then
				table.insert(lines, normalized:sub(start))
			end
			break
		end
	end
	return lines
end

M._split_lines = split_lines

--- Collect heredoc delimiters opened on one line (`<<`, `<<-`, quoted or
--- not). Bodies are skipped verbatim so `echo` text inside heredocs is
--- never rewritten. A false positive (e.g. `<<EOF` inside a string) only
--- degrades to uninstrumented output, never broken execution.
---@param line string
---@return { delim: string, tabs: boolean }[]
local function heredoc_openers(line)
	local openers = {}
	-- Strip single-quoted spans first so `<<` inside them cannot open.
	local scrubbed = line:gsub("'[^']*'", "''")
	for dash, delim in scrubbed:gmatch("<<(%-?)%s*[\"'\\]*([%a_][%w_]*)") do
		table.insert(openers, { delim = delim, tabs = dash == "-" })
	end
	return openers
end

--- Whether the remainder after a command word continues the same simple
--- command (`echo hi`, `echo;...`) rather than forming a longer word
--- (`echofoo`, `echo(`).
---@param after string
---@return boolean
local function continues(after)
	if after == "" then
		return true
	end
	local first = after:sub(1, 1)
	return first == " " or first == "\t" or first == ";"
end

--- Rewrite one logical line to a helper call with its 1-based line number.
--- Returns the rewritten line, or nil when the line must run verbatim.
--- (Lua patterns have no alternation, so words are matched explicitly.)
---@param line string
---@param lnum integer
---@return string?
local function rewrite_line(line, lnum)
	-- A simple command may be the only command inside a parenthesized
	-- subshell. Preserve the delimiters while rewriting the command so nested
	-- shell output keeps its source location instead of becoming residual
	-- locationless stdout.
	local open, inner, close = line:match("^(%s*%(%s*)(.-)(%s*%)%s*)$")
	if inner ~= nil then
		local rewritten_inner = rewrite_line(inner, lnum)
		if rewritten_inner ~= nil then
			return open .. rewritten_inner .. close
		end
	end

	local indent, word, after = line:match("^(%s*)([%a_][%w_]*)(.*)$")
	if word == nil then
		return nil
	end
	if word == "echo" or word == "printf" then
		if not continues(after) then
			return nil
		end
		local helper = word == "echo" and "__itchy_echo" or "__itchy_printf"
		return indent .. helper .. " " .. tostring(lnum) .. after
	end
	if word == "command" or word == "builtin" then
		local next_word, next_after = after:match("^%s+([%a_][%w_]*)(.*)$")
		if next_word == nil then
			return nil
		end
		if (next_word == "echo" or next_word == "printf") and continues(next_after) then
			local helper = next_word == "echo" and "__itchy_echo" or "__itchy_printf"
			return indent .. helper .. " " .. tostring(lnum) .. next_after
		end
	end
	return nil
end

--- Instrument only output-producing commands, one input line to one
--- output line (coordinates never shift). Stamped numbers are 1-based
--- source lines; the header offset applies only to native diagnostics.
---@param source string
---@return string instrumented source with identical line count
function M.instrument(source)
	local lines = split_lines(source)
	---@type { delim: string, tabs: boolean }[]
	local heredocs = {}
	local out = {}
	for i, line in ipairs(lines) do
		if #heredocs > 0 then
			table.insert(out, line)
			local current = heredocs[1]
			local stripped = line
			if current.tabs then
				stripped = stripped:gsub("^\t+", "")
			end
			if stripped == current.delim then
				table.remove(heredocs, 1)
			end
		else
			for _, opener in ipairs(heredoc_openers(line)) do
				table.insert(heredocs, opener)
			end
			local trimmed = line:match("^%s*(.-)$")
			if trimmed == "" or trimmed:sub(1, 1) == "#" then
				table.insert(out, line)
			else
				-- `command`/`builtin` prefixes delegate to the same helper;
				-- anything else (assignments, `if`, `time`, `!`, longer
				-- words like `echofoo`) is left verbatim: uninstrumented
				-- but correct.
				table.insert(out, rewrite_line(line, i) or line)
			end
		end
	end
	return table.concat(out, "\n") .. (source:sub(-1) == "\n" and "\n" or "")
end

--- Prepare execution: one directly executed file (helper header plus
--- transformed user source). Native diagnostics carry header-shifted
--- coordinates; `line_offset` maps them back to source lines.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "sh adapter requires a context")
	assert(ctx.runtime ~= nil, "sh adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	-- The transport marker travels through user pipelines. Keep its nonce in
	-- the stable uppercase alphabet so transforms such as `tr a-z A-Z` cannot
	-- invalidate the marker before the decoder sees it.
	local nonce = framed.create_nonce():upper()

	local tmpdir, user_path, _, event_path = shell_common.allocate_tmp(ctx, "itchy-sh", nonce, ".sh")

	local header = M._header(nonce, event_path)
	local offset = M._header_line_count(header)
	-- Rewritten call sites carry source (1-based) coordinates; only native
	-- diagnostics need the header offset, applied at decode time.
	local ok, werr = shell_common.write_file(user_path, header .. M.instrument(source))
	if not ok then
		error("sh adapter: failed to create source file: " .. tostring(werr))
	end
	local eok, eerr = shell_common.write_file(event_path, "")
	if not eok then
		shell_common.make_cleanup(tmpdir, { user_path, event_path })()
		error("sh adapter: failed to create event file: " .. tostring(eerr))
	end

	local cmd = shell_common.build_cmd(runtime, user_path)

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = shell_common.make_cleanup(tmpdir, { user_path, event_path }),
		metadata = {
			nonce = nonce,
			user_file = user_path,
			event_file = event_path,
			helper_leaf = M.HELPER_LEAF,
			line_offset = offset,
			filetype = ctx.filetype,
		},
	}
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	local metadata = (prepared and prepared.metadata) or {}
	local line_offset = metadata.line_offset or 0
	local function map_native_line(line, origin)
		-- A shell function diagnostic is already relative to the user's
		-- function definition, unlike a diagnostic emitted by the generated
		-- header/source file. The shared parser marks only arithmetic
		-- diagnostics with a verified source function origin.
		if type(origin) == "table" and origin.kind == "function" and type(origin.start_line) == "number" then
			return origin.start_line + line
		end
		local source_line = line - line_offset
		if source_line >= 1 then
			return source_line
		end
		-- A diagnostic inside the adapter's own header is not user source.
		return nil
	end
	return shell_common.decode_sidechannel(ctx, prepared, result, map_native_line)
end

return M
