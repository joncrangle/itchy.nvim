--- Bash adapter. Executes user source unchanged via a launcher that intercepts
--- echo and printf with BASH_LINENO caller tracking. Uncaught errors are
--- parsed from native stderr diagnostics.
local M = {}

local framed = require("itchy.adapters.framed")
local shell_common = require("itchy.adapters.shell_common")

M.name = "bash"

M.HELPER_LEAF = "itchy-launcher"

-- Managed launcher. `__ITCHY_*` placeholders are substituted at prepare
-- time; paths are embedded double-quoted (see shell_common.shell_dquote).
local BASH_LAUNCHER = [=[
# itchy.nvim bash launcher (managed file, do not edit).
__ITCHY_NONCE="__ITCHY_NONCE__"
__ITCHY_EVENT_FILE="__ITCHY_EVENT_FILE__"
__ITCHY_USER_FILE="__ITCHY_USER_FILE__"
__itchy_output_seq=0
__itchy_frame_active=0

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
  builtin printf '\036\037%s:%s:' "$__ITCHY_NONCE" "$__itchy_output_seq"
  __itchy_frame_active=1
}

__itchy_end_output() {
  if [ "$__itchy_frame_active" -ne 1 ]; then
    return
  fi
  builtin printf '\036\035%s:%s\n' "$__ITCHY_NONCE" "$__itchy_output_seq"
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
  local __itchy_kind="$1"
  local __itchy_line="$2"
  shift 2
  local __itchy_msg="$1"
  __itchy_msg="${__itchy_msg//\\/\\\\}"
  __itchy_msg="${__itchy_msg//\"/\\\"}"
  __itchy_msg="${__itchy_msg//$'\n'/\\n}"
  __itchy_msg="${__itchy_msg//$'\t'/\\t}"
  __itchy_msg="${__itchy_msg//$'\r'/\\r}"
  local __itchy_json
  if [ -n "$__itchy_line" ]; then
    __itchy_json="{\"kind\":\"$__itchy_kind\",\"line\":$__itchy_line,\"message\":\"$__itchy_msg\"}"
  else
    __itchy_json="{\"kind\":\"$__itchy_kind\",\"message\":\"$__itchy_msg\"}"
  fi
  builtin printf '\036ITCHY:%s:%s\n' "$__ITCHY_NONCE" "$__itchy_json" >> "$__ITCHY_EVENT_FILE" || true
}

echo() {
  local __itchy_line="${BASH_LINENO[0]:-}"
  case "$__itchy_line" in ''|*[!0-9]*) __itchy_line="";; esac
  local __itchy_msg __itchy_raw __itchy_status __itchy_had_newline
  __itchy_raw=$( { builtin echo "$@"; __itchy_status=$?; builtin printf '\001'; exit $__itchy_status; } 2>/dev/null)
  __itchy_status=$?
  __itchy_raw="${__itchy_raw%$'\001'}"
  __itchy_msg="$__itchy_raw"
  __itchy_had_newline=0
  while [[ "$__itchy_msg" == *$'\n' ]]; do
    __itchy_had_newline=1
    __itchy_msg="${__itchy_msg%$'\n'}"
  done
  if [ $__itchy_status -eq 0 ] && [ -n "$__itchy_msg" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_msg" || true
    if __itchy_should_frame; then
      __itchy_begin_output
      builtin echo "$@"
      local __itchy_output_status=$?
      if [ "$__itchy_had_newline" -eq 1 ]; then
        __itchy_end_output
      fi
      return $__itchy_output_status
    fi
  fi
  builtin echo "$@"
  return $?
}

printf() {
  local __itchy_line="${BASH_LINENO[0]:-}"
  case "$__itchy_line" in ''|*[!0-9]*) __itchy_line="";; esac
  if [ "$1" = "-v" ]; then
    builtin printf "$@"
    return $?
  fi
  local __itchy_msg __itchy_raw __itchy_status __itchy_had_newline
  __itchy_raw=$( { builtin printf "$@"; __itchy_status=$?; builtin printf '\001'; exit $__itchy_status; } 2>/dev/null)
  __itchy_status=$?
  __itchy_raw="${__itchy_raw%$'\001'}"
  __itchy_msg="$__itchy_raw"
  __itchy_had_newline=0
  while [[ "$__itchy_msg" == *$'\n' ]]; do
    __itchy_had_newline=1
    __itchy_msg="${__itchy_msg%$'\n'}"
  done
  if [ $__itchy_status -eq 0 ] && [ -n "$__itchy_msg" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_msg" || true
    if __itchy_should_frame; then
      __itchy_begin_output
      builtin printf "$@"
      local __itchy_output_status=$?
      if [ "$__itchy_had_newline" -eq 1 ]; then
        __itchy_end_output
      fi
      return $__itchy_output_status
    fi
  fi
  builtin printf "$@"
  return $?
}

trap '__itchy_exit_status=$?; __itchy_end_output; trap - EXIT; exit $__itchy_exit_status' EXIT
source "$__ITCHY_USER_FILE"
]=]

--- Render the launcher for one run. Exposed for tests.
---@param nonce string
---@param event_file string
---@param user_file string
---@return string
function M._launcher(nonce, event_file, user_file)
	return shell_common.render_template(BASH_LAUNCHER, nonce, event_file, user_file)
end

--- Prepare execution: unchanged user source plus a managed launcher.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	return shell_common.prepare_launcher(ctx, "itchy-bash", M._launcher, M.HELPER_LEAF)
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	-- Bash normally reports the absolute source line even when the
	-- diagnostic label is a function name. Older Bash releases report a
	-- function-relative line instead; only that unambiguous short form needs
	-- conversion, while ordinary file diagnostics remain untouched.
	local function map_native_line(line, origin)
		if type(origin) == "table"
			and origin.kind == "function"
			and type(origin.start_line) == "number"
			and line < origin.start_line
		then
			return origin.start_line + line
		end
		return line
	end
	return shell_common.decode_sidechannel(ctx, prepared, result, map_native_line)
end

return M
