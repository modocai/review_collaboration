#!/usr/bin/env bash
# Codex CLI token-budget checker.
# Source this file for library use, or run standalone for human-readable output.
# Requires: caller must set -euo pipefail before sourcing.
# Requires: jq
# Usage:
#   source "$SCRIPT_DIR/lib/check-codex-limit.sh"
#   _check_codex_token_budget   # → JSON to stdout
#   _codex_budget_sufficient full && echo "GO" || echo "NO-GO"

[[ -n "${_CHECK_CODEX_LIMIT_SH_LOADED:-}" ]] && return 0
_CHECK_CODEX_LIMIT_SH_LOADED=1

# ── Internal: Find latest token_count event ──────────────────────────
# Scans Codex session logs (newest first) for the most recent
# token_count event within the last 7 days.
# stdout: single JSON line (the event)
_codex_limit_find_latest_token_count() {
  local _sessions_dir="$HOME/.codex/sessions"
  [[ -d "$_sessions_dir" ]] || return 1

  local _offset _day_dir _dir _files _f _result
  for _offset in {0..6}; do
    # macOS/BSD vs GNU date
    if date -v-1d +%s &>/dev/null; then
      _day_dir=$(date -v-"${_offset}d" +%Y/%m/%d)
    else
      _day_dir=$(date -d "$_offset days ago" +%Y/%m/%d)
    fi

    _dir="$_sessions_dir/$_day_dir"
    [[ -d "$_dir" ]] || continue

    # List .jsonl files in reverse alphabetical order (newest first)
    _files=$(ls -1r "$_dir"/*.jsonl 2>/dev/null) || continue
    [[ -n "$_files" ]] || continue

    while IFS= read -r _f; do
      [[ -f "$_f" ]] || continue
      _result=$(jq -c '
        select(.type == "event_msg" and .payload.type == "token_count")
      ' "$_f" 2>/dev/null | tail -1)
      if [[ -n "$_result" ]]; then
        printf '%s' "$_result"
        return 0
      fi
    done < <(printf '%s\n' "$_files")
  done

  return 1
}

# ── Internal: Convert Unix timestamp to ISO 8601 ────────────────────
_codex_limit_ts_to_iso() {
  local _ts="$1"
  if date -v-1d +%s &>/dev/null; then
    # macOS/BSD date
    date -u -r "$_ts" +%Y-%m-%dT%H:%M:%SZ
  else
    # GNU date
    date -u -d "@$_ts" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# ── Internal: Extract pct/resets from a rate_limits window ───────────
# $1 = window JSON (primary or secondary object)
# $2 = current epoch
# $3 = default pct when window is absent ("0" or "")
# stdout: "pct resets_iso" (space-separated, resets_iso may be empty)
_codex_limit_parse_window() {
  local _win="$1" _now="$2" _default_pct="$3"
  local _resets _pct

  if [[ -z "$_win" ]]; then
    printf '%s ' "$_default_pct"
    return 0
  fi

  _resets=$(printf '%s' "$_win" | jq -r '.resets_at')

  # Window has expired
  if [[ "$_resets" != "null" ]] && [[ "$_resets" =~ ^[0-9]+$ ]] && [[ "$_resets" -le "$_now" ]]; then
    printf '0 '
    return 0
  fi

  _pct=$(printf '%s' "$_win" | jq -r '.used_percent | round')
  if [[ "$_resets" =~ ^[0-9]+$ ]]; then
    printf '%s %s' "$_pct" "$(_codex_limit_ts_to_iso "$_resets")"
  else
    printf '%s ' "$_pct"
  fi
}

# ── Public: Get token budget status ──────────────────────────────────
# Reads the latest token_count event from Codex session logs.
# stdout: JSON
_check_codex_token_budget() {
  local _event _now _primary _secondary
  local _5h_pct _5h_resets _7d_pct _7d_resets

  _event=$(_codex_limit_find_latest_token_count 2>/dev/null) || true

  if [[ -z "$_event" ]]; then
    printf '{"five_hour_used_pct":null,"seven_day_used_pct":null,"mode":"no_data","resets_at":null,"seven_day_resets_at":null}'
    return 0
  fi

  _now=$(date +%s)

  _primary=$(printf '%s' "$_event" | jq -c '.payload.rate_limits.primary // empty' 2>/dev/null)
  read -r _5h_pct _5h_resets <<< "$(_codex_limit_parse_window "$_primary" "$_now" "")"

  _secondary=$(printf '%s' "$_event" | jq -c '.payload.rate_limits.secondary // empty' 2>/dev/null)
  read -r _7d_pct _7d_resets <<< "$(_codex_limit_parse_window "$_secondary" "$_now" "")"

  jq -n -c \
    --arg five_pct "${_5h_pct}" \
    --arg five_resets "${_5h_resets}" \
    --arg seven_pct "${_7d_pct}" \
    --arg seven_resets "${_7d_resets}" \
    '{
      five_hour_used_pct: (if $five_pct == "" then null else ($five_pct | tonumber) end),
      seven_day_used_pct: (if $seven_pct == "" then null else ($seven_pct | tonumber) end),
      mode: "session_log",
      resets_at: (if $five_resets == "" then null else $five_resets end),
      seven_day_resets_at: (if $seven_resets == "" then null else $seven_resets end)
    }'
}

# ── Public: Go/no-go decision ────────────────────────────────────────
# $1 = scope: micro, module, layer, full
# $2 = (optional) pre-fetched JSON from _check_codex_token_budget
# return 0 = go, return 1 = no-go
_codex_budget_sufficient() {
  local _scope="${1:-module}" _threshold _budget_json _pct

  case "$_scope" in
    micro)  _threshold=90 ;;
    module) _threshold=75 ;;
    layer|full)
      echo "Warning: no established threshold for '$_scope' — skipping budget check" >&2
      return 0
      ;;
    *)
      echo "Error: unknown scope '$_scope'. Use: micro, module, layer, full" >&2
      return 1
      ;;
  esac

  _budget_json="${2:-$(_check_codex_token_budget)}"
  _pct=$(printf '%s' "$_budget_json" | jq -r '.five_hour_used_pct')

  if [[ "$_pct" == "null" ]]; then
    echo "Warning: no budget data available — failing closed" >&2
    return 1
  fi

  if [[ "$_pct" -lt "$_threshold" ]]; then
    return 0
  else
    echo "Budget check failed: ${_pct}% used (threshold for '$_scope' is <${_threshold}%)" >&2
    return 1
  fi
}

# ── Standalone mode ──────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail

  if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is not installed or not in PATH." >&2
    exit 1
  fi

  _json=$(_check_codex_token_budget)
  _pct=$(printf '%s' "$_json" | jq -r '.five_hour_used_pct')
  _mode=$(printf '%s' "$_json" | jq -r '.mode')
  _resets=$(printf '%s' "$_json" | jq -r '.resets_at // "n/a"')
  _weekly_pct=$(printf '%s' "$_json" | jq -r '.seven_day_used_pct | tostring')
  _weekly_resets=$(printf '%s' "$_json" | jq -r '.seven_day_resets_at // "n/a"')

  echo "Codex CLI Token Budget"
  echo "========================"
  echo "  Mode:       $_mode"
  if [[ "$_pct" == "null" ]]; then
    echo "  5h used:    n/a (no session data)"
  elif [[ "$_resets" != "n/a" ]] && [[ "$_resets" != "null" ]]; then
    echo "  5h used:    ${_pct}%    (resets $_resets)"
  else
    echo "  5h used:    ${_pct}%"
  fi
  if [[ "$_weekly_pct" != "null" ]]; then
    if [[ "$_weekly_resets" != "n/a" ]] && [[ "$_weekly_resets" != "null" ]]; then
      echo "  7d used:    ${_weekly_pct}%    (resets $_weekly_resets)"
    else
      echo "  7d used:    ${_weekly_pct}%"
    fi
  else
    echo "  7d used:    n/a"
  fi
  echo ""
  echo "Scope thresholds (go if used% < threshold):"
  echo "  micro:  <90%   module: <75%   layer: TBD    full: TBD"
  echo ""

  # Show go/no-go for each scope (reuse _pct to avoid redundant calls)
  _thresholds="micro:90 module:75"
  for _entry in $_thresholds; do
    _s="${_entry%%:*}"
    _thr="${_entry##*:}"
    if [[ "$_pct" == "null" ]]; then
      printf '  %-8s NO-GO (no data)\n' "$_s:"
    elif [[ "$_pct" -lt "$_thr" ]]; then
      printf '  %-8s GO\n' "$_s:"
    else
      printf '  %-8s NO-GO\n' "$_s:"
    fi
  done
  printf '  %-8s (no threshold set)\n' "layer:"
  printf '  %-8s (no threshold set)\n' "full:"
fi
