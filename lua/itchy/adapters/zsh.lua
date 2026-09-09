--- Zsh adapter. Executes user source unchanged via a launcher that intercepts
--- echo and printf with funcfiletrace caller tracking. Uncaught errors are
--- parsed from native stderr diagnostics.
local M = {}

local framed = require("itchy.adapters.framed")
local shell_common = require("itchy.adapters.shell_common")

M.name = "zsh"

M.HELPER_LEAF = "itchy-launcher"

local ZSH_LAUNCHER = [=[
# itchy.nvim zsh launcher (managed file, do not edit).
__ITCHY_NONCE="__ITCHY_NONCE__"
__ITCHY_EVENT_FILE="__ITCHY_EVENT_FILE__"
__ITCHY_USER_FILE="__ITCHY_USER_FILE__"

zmodload zsh/parameter

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
  local __itchy_loc="${funcfiletrace[1]}"
  local __itchy_line="${__itchy_loc##*:}"
  case "$__itchy_line" in ''|*[!0-9]*) __itchy_line="";; esac
  local __itchy_msg __itchy_status
  __itchy_msg=$(builtin echo "$@" 2>/dev/null)
  __itchy_status=$?
  if [ $__itchy_status -eq 0 ] && [ -n "$__itchy_msg" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_msg" || true
  fi
  builtin echo "$@"
  return $?
}

printf() {
  local __itchy_loc="${funcfiletrace[1]}"
  local __itchy_line="${__itchy_loc##*:}"
  case "$__itchy_line" in ''|*[!0-9]*) __itchy_line="";; esac
  if [ "$1" = "-v" ]; then
    builtin printf "$@"
    return $?
  fi
  local __itchy_msg __itchy_status
  __itchy_msg=$(builtin printf "$@" 2>/dev/null)
  __itchy_status=$?
  if [ $__itchy_status -eq 0 ] && [ -n "$__itchy_msg" ]; then
    __itchy_emit stdout "$__itchy_line" "$__itchy_msg" || true
  fi
  builtin printf "$@"
  return $?
}

source "$__ITCHY_USER_FILE"
]=]

--- Render the launcher for one run. Exposed for tests.
---@param nonce string
---@param event_file string
---@param user_file string
---@return string
function M._launcher(nonce, event_file, user_file)
	return shell_common.render_template(ZSH_LAUNCHER, nonce, event_file, user_file)
end

--- Prepare execution: unchanged user source plus a managed launcher.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	return shell_common.prepare_launcher(ctx, "itchy-zsh", M._launcher, M.HELPER_LEAF)
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	return shell_common.decode_sidechannel(ctx, prepared, result)
end

return M
