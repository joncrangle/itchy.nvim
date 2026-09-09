--- Bash adapter with native caller-location instrumentation (issue #16).
---
--- The user's source runs unchanged from a temp file, sourced by a managed
--- launcher that shadows `echo`/`printf` with functions. Each function
--- captures its call site inline with native Bash caller metadata
--- (`BASH_LINENO[0]`, the line in the user file where the call was made),
--- emits a nonce-framed structured record to an adapter-private event file,
--- then delegates to the real builtin -- so redirections, pipelines and
--- `command`/`builtin` prefixes behave natively and are never polluted
--- with metadata. `printf -v` assigns a variable without producing output
--- and is delegated untouched (no stdout event). Recursion is impossible:
--- helpers only ever invoke `builtin`, never themselves.
---
--- Uncaught errors keep their native stderr diagnostics (`path: line N:
--- msg`); the adapter selects frames belonging to the user's file and
--- never invents locations. No synthetic per-line state, no source
--- rewriting: comments and strings naming output commands never match.
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
  local __itchy_line="${BASH_LINENO[0]:-}"
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
	return shell_common.decode_sidechannel(ctx, prepared, result)
end

return M
