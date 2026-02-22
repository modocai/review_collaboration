#!/usr/bin/env bash
# Retry-with-backoff wrappers for Claude/Codex CLI calls.
# Source this file for library use.
# Requires: caller must set -euo pipefail before sourcing.
# Requires: check-claude-limit.sh and check-codex-limit.sh sourced before this.
#
# Config (set via .reviewlooprc / .refactorsuggestrc):
#   RETRY_MAX_WAIT      — max total wait per CLI call (seconds, default 600)
#   RETRY_INITIAL_WAIT  — first backoff delay (seconds, default 30)
#   BUDGET_SCOPE        — pre-flight budget scope: micro|module (default module)

[[ -n "${_RETRY_SH_LOADED:-}" ]] && return 0
_RETRY_SH_LOADED=1

# ── Error Classification ─────────────────────────────────────────────
# Scan CLI output to classify the failure as transient, permanent, or unknown.
# $1 = output file path, $2 = exit code
# stdout: transient | permanent | unknown
_classify_cli_error() {
  local _file="$1" _exit_code="$2" _head=""

  if [[ -f "$_file" ]]; then
    _head=$(head -c 4096 "$_file" 2>/dev/null || true)
  fi

  # Combine exit code and output for pattern matching
  local _text
  _text=$(printf 'exit=%s\n%s' "$_exit_code" "$_head" | tr '[:upper:]' '[:lower:]')

  # Transient patterns (rate limits, capacity, temporary errors)
  if printf '%s' "$_text" | grep -qE 'rate.limit|too many requests|(^|[^0-9])429([^0-9]|$)|overloaded|(^|[^0-9])529([^0-9]|$)|(^|[^0-9])503([^0-9]|$)|capacity|token.*limit|quota.*exceeded|temporarily unavailable'; then
    printf 'transient'
    return 0
  fi

  # Permanent patterns (auth, permission errors)
  if printf '%s' "$_text" | grep -qE 'auth.*fail|unauthorized|(^|[^0-9])403([^0-9]|$)|forbidden|invalid.*api.key|permission denied'; then
    printf 'permanent'
    return 0
  fi

  printf 'unknown'
}

# ── ISO 8601 → seconds until reset ──────────────────────────────────
# $1 = ISO 8601 timestamp (e.g. 2025-06-01T12:00:00Z)
# stdout: seconds until that time (0 if already past)
_seconds_until_iso() {
  local _iso="$1" _target_epoch _now_epoch _diff

  # Convert ISO timestamp to epoch
  if date -v-1d +%s &>/dev/null; then
    # macOS/BSD date — strip fractional seconds and timezone suffix for -jf
    # Use -u to interpret input as UTC (API timestamps are always UTC)
    local _clean
    _clean=$(printf '%s' "$_iso" | sed 's/\.[0-9]*//; s/Z$//; s/+00:00$//')
    _target_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%S' "$_clean" +%s 2>/dev/null) || {
      printf '0'
      return 0
    }
  else
    # GNU date
    _target_epoch=$(date -d "$_iso" +%s 2>/dev/null) || {
      printf '0'
      return 0
    }
  fi

  _now_epoch=$(date +%s)
  _diff=$(( _target_epoch - _now_epoch ))

  if [[ "$_diff" -gt 0 ]]; then
    printf '%s' "$_diff"
  else
    printf '0'
  fi
}

# ── Pre-flight Budget Gate ───────────────────────────────────────────
# Wait until the tool's budget is sufficient for a CLI call.
# $1 = tool ("claude" | "codex")
# $2 = scope (micro | module)
# $3 = max_wait (seconds, optional — defaults to RETRY_MAX_WAIT)
# return 0 = budget OK, return 1 = timeout
_wait_for_budget() {
  local _tool="$1" _scope="${2:-module}" _max_wait="${3:-${RETRY_MAX_WAIT:-600}}"
  local _elapsed=0 _poll_wait=30 _budget_json _resets_at _wait_secs

  # Fetch once — reuse for both check and resets_at extraction
  _budget_json=$(_wait_for_budget_fetch "$_tool")

  if _wait_for_budget_check "$_tool" "$_scope" "$_budget_json"; then
    return 0
  fi

  echo "  Budget insufficient for $_tool (scope: $_scope). Waiting for reset..." >&2
  _resets_at=$(printf '%s' "$_budget_json" | jq -r '.resets_at // empty' 2>/dev/null)

  # If we have a valid resets_at and it's within max_wait, sleep until then
  if [[ -n "$_resets_at" ]] && [[ "$_resets_at" != "null" ]]; then
    _wait_secs=$(_seconds_until_iso "$_resets_at")
    _wait_secs=$(( _wait_secs + 10 ))  # 10-second buffer
    if [[ "$_wait_secs" -gt 0 ]] && [[ "$_wait_secs" -le "$_max_wait" ]]; then
      echo "  Sleeping ${_wait_secs}s until budget reset (${_resets_at})..." >&2
      sleep "$_wait_secs"
      _elapsed="$_wait_secs"
      if _wait_for_budget_check "$_tool" "$_scope"; then
        echo "  Budget restored for $_tool." >&2
        return 0
      fi
    fi
  fi

  # Polling fallback — check every _poll_wait seconds
  while [[ "$_elapsed" -lt "$_max_wait" ]]; do
    local _sleep_time="$_poll_wait"
    if [[ $(( _elapsed + _sleep_time )) -gt "$_max_wait" ]]; then
      _sleep_time=$(( _max_wait - _elapsed ))
    fi
    echo "  Polling budget in ${_sleep_time}s (${_elapsed}/${_max_wait}s elapsed)..." >&2
    sleep "$_sleep_time"
    _elapsed=$(( _elapsed + _sleep_time ))

    if _wait_for_budget_check "$_tool" "$_scope"; then
      echo "  Budget restored for $_tool." >&2
      return 0
    fi

    # Increase poll interval (30 → 60 → 120, cap at 120)
    if [[ "$_poll_wait" -lt 120 ]]; then
      _poll_wait=$(( _poll_wait * 2 ))
      [[ "$_poll_wait" -gt 120 ]] && _poll_wait=120
    fi
  done

  echo "  Budget wait timeout (${_max_wait}s) for $_tool." >&2
  return 1
}

# Internal: run the appropriate budget-sufficient check
_wait_for_budget_check() {
  local _tool="$1" _scope="$2" _json="${3:-}"
  case "$_tool" in
    claude) _claude_budget_sufficient "$_scope" "$_json" 2>/dev/null ;;
    codex)  _codex_budget_sufficient "$_scope" "$_json" 2>/dev/null ;;
    *)      return 0 ;;
  esac
}

# Internal: fetch budget JSON for the tool
_wait_for_budget_fetch() {
  local _tool="$1"
  case "$_tool" in
    claude) _check_claude_token_budget 2>/dev/null ;;
    codex)  _check_codex_token_budget 2>/dev/null ;;
    *)      printf '{}' ;;
  esac
}

# ── Claude CLI Retry Wrapper ─────────────────────────────────────────
# Caches stdin and retries the command with exponential backoff.
# $1 = output file, $2 = label (for logging), $3... = command + args
# stdin → piped to command (cached for retries)
# return 0 = success, return 1 = permanent/unknown error or timeout
_retry_claude_cmd() {
  local _output="$1" _label="$2"; shift 2
  local _max_wait="${RETRY_MAX_WAIT:-600}"
  local _wait="${RETRY_INITIAL_WAIT:-30}"
  local _elapsed=0 _attempt=1 _rc _class

  # Cache stdin for replay on retries
  local _stdin_cache
  _stdin_cache=$(mktemp)
  trap 'rm -f "$_stdin_cache"' RETURN
  cat > "$_stdin_cache"

  while true; do
    _rc=0
    cat "$_stdin_cache" | "$@" > "$_output" 2>&1 || _rc=$?

    if [[ "$_rc" -eq 0 ]]; then
      return 0
    fi

    _class=$(_classify_cli_error "$_output" "$_rc")

    if [[ "$_class" != "transient" ]]; then
      echo "  [$_label] Non-transient error ($_class, exit=$_rc). Giving up." >&2
      return 1
    fi

    if [[ "$_elapsed" -ge "$_max_wait" ]]; then
      echo "  [$_label] Retry timeout (${_elapsed}/${_max_wait}s). Giving up." >&2
      return 1
    fi

    # Calculate sleep time (cap individual wait at 300s)
    local _sleep="$_wait"
    [[ "$_sleep" -gt 300 ]] && _sleep=300
    if [[ $(( _elapsed + _sleep )) -gt "$_max_wait" ]]; then
      _sleep=$(( _max_wait - _elapsed ))
    fi

    _attempt=$(( _attempt + 1 ))
    echo "  [$_label] Transient error (exit=$_rc). Retry #$_attempt in ${_sleep}s..." >&2
    sleep "$_sleep"
    _elapsed=$(( _elapsed + _sleep ))
    _wait=$(( _wait * 2 ))
  done
}

# ── Codex CLI Retry Wrapper ──────────────────────────────────────────
# Retries the command with exponential backoff. No stdin caching needed
# (Codex takes prompt as argument). Captures stderr only.
# $1 = stderr file, $2 = label (for logging), $3... = command + args
# return 0 = success, return 1 = permanent/unknown error or timeout
_retry_codex_cmd() {
  local _stderr_file="$1" _label="$2"; shift 2
  local _max_wait="${RETRY_MAX_WAIT:-600}"
  local _wait="${RETRY_INITIAL_WAIT:-30}"
  local _elapsed=0 _attempt=1 _rc _class

  while true; do
    _rc=0
    "$@" < /dev/null 2> >(tee "$_stderr_file" >&2) || _rc=$?
    wait  # ensure tee in process substitution flushes before reading stderr file

    if [[ "$_rc" -eq 0 ]]; then
      return 0
    fi

    _class=$(_classify_cli_error "$_stderr_file" "$_rc")

    if [[ "$_class" != "transient" ]]; then
      echo "  [$_label] Non-transient error ($_class, exit=$_rc). Giving up." >&2
      return 1
    fi

    if [[ "$_elapsed" -ge "$_max_wait" ]]; then
      echo "  [$_label] Retry timeout (${_elapsed}/${_max_wait}s). Giving up." >&2
      return 1
    fi

    local _sleep="$_wait"
    [[ "$_sleep" -gt 300 ]] && _sleep=300
    if [[ $(( _elapsed + _sleep )) -gt "$_max_wait" ]]; then
      _sleep=$(( _max_wait - _elapsed ))
    fi

    _attempt=$(( _attempt + 1 ))
    echo "  [$_label] Transient error (exit=$_rc). Retry #$_attempt in ${_sleep}s..." >&2
    sleep "$_sleep"
    _elapsed=$(( _elapsed + _sleep ))
    _wait=$(( _wait * 2 ))
  done
}
