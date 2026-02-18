#!/usr/bin/env bash
# Claude Code token-budget checker.
# Source this file for library use, or run standalone for human-readable output.
# Requires: caller must set -euo pipefail before sourcing.
# Requires: jq (mandatory), curl + security (for OAuth mode, macOS only)
# Usage:
#   source "$SCRIPT_DIR/lib/check-claude-limit.sh"
#   _check_claude_token_budget   # → JSON to stdout
#   _claude_budget_sufficient full && echo "GO" || echo "NO-GO"

[[ -n "${_CHECK_CLAUDE_LIMIT_SH_LOADED:-}" ]] && return 0
_CHECK_CLAUDE_LIMIT_SH_LOADED=1

# ── Internal: Detect subscription tier ───────────────────────────────
# Reads rateLimitTier from Claude Code telemetry files.
# Picks the most recent record by client_timestamp to handle plan changes.
# stdout: tier slug (pro, max5, max20)
_claude_limit_detect_tier() {
  local _tier_raw="" _f
  # Collect all (timestamp, tier) pairs across telemetry files,
  # then pick the tier from the most recent event.
  _tier_raw=$(
    for _f in "$HOME"/.claude/telemetry/*.json; do
      [[ -e "$_f" ]] || continue
      # user_attributes may be a JSON string (needs double-parse) or an object
      jq -r '
        .event_data
        | (.user_attributes // empty
           | if type == "string" then fromjson else . end
           | .rateLimitTier // empty) as $tier
        | select($tier != "")
        | [.client_timestamp, $tier] | @tsv
      ' "$_f" 2>/dev/null
    done | sort -t$'\t' -k1,1r | head -1 | cut -f2
  )

  case "$_tier_raw" in
    default_claude_max_20x) printf 'max20' ;;
    default_claude_max_5x)  printf 'max5'  ;;
    *)                      printf 'pro'   ;;
  esac
}

# ── Internal: OAuth-based usage query ────────────────────────────────
# Reads credentials from macOS Keychain, calls Anthropic OAuth endpoint.
# stdout: JSON with five_hour_used_pct, seven_day_used_pct, tokens_used (0 for oauth), mode, tier, estimated
# Returns 1 on any failure (missing tools, bad creds, API error).
_claude_limit_oauth() {
  # Require both curl and security (macOS Keychain CLI)
  command -v curl &>/dev/null || return 1
  command -v security &>/dev/null || return 1

  local _creds _token _resp _pct

  _creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
  [[ -n "$_creds" ]] || return 1

  _token=$(printf '%s' "$_creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [[ -n "$_token" ]] || return 1

  _resp=$(curl -s --max-time 10 \
    "https://api.anthropic.com/oauth/usage" \
    -H "Authorization: Bearer $_token" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1
  [[ -n "$_resp" ]] || return 1

  # Validate response has the expected structure
  _pct=$(printf '%s' "$_resp" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
  [[ -n "$_pct" ]] || return 1

  local _tier
  _tier=$(_claude_limit_detect_tier)

  printf '%s' "$_resp" | jq -c --arg tier "$_tier" '{
    five_hour_used_pct: (.five_hour.utilization | round),
    seven_day_used_pct: (if .seven_day then (.seven_day.utilization | round) else null end),
    tokens_used: 0,
    mode: "oauth",
    tier: $tier,
    resets_at: (.five_hour.resets_at // null),
    seven_day_resets_at: (.seven_day.resets_at // null),
    estimated: false
  }'
}

# ── Internal: Local JSONL-based estimation ───────────────────────────
# Scans recent Claude Code session JSONL files, sums token usage,
# and estimates percentage based on tier.
# stdout: JSON (same schema as OAuth, but estimated: true)
_claude_limit_local() {
  local _tier _jsonl_files _total_tokens _limit _pct

  _tier=$(_claude_limit_detect_tier)

  # Rough 5-hour token limits per tier (empirical estimates).
  # These are approximations — actual limits are opaque and server-enforced.
  local _limit_pro=1000000
  local _limit_max5=5000000
  local _limit_max20=20000000

  case "$_tier" in
    max20) _limit=$_limit_max20 ;;
    max5)  _limit=$_limit_max5  ;;
    *)     _limit=$_limit_pro   ;;
  esac

  # Find JSONL files modified in the last 5 hours (300 minutes)
  _jsonl_files=$(find "$HOME/.claude/projects/" -name '*.jsonl' -mmin -300 2>/dev/null) || true

  if [[ -z "$_jsonl_files" ]]; then
    printf '{"five_hour_used_pct":0,"seven_day_used_pct":null,"tokens_used":0,"mode":"local","tier":"%s","resets_at":null,"seven_day_resets_at":null,"estimated":true}' "$_tier"
    return 0
  fi

  # Calculate the cutoff timestamp (5 hours ago) in ISO format
  local _cutoff
  if date -v-5H +%s &>/dev/null; then
    # macOS/BSD date
    _cutoff=$(date -u -v-5H +%Y-%m-%dT%H:%M:%SZ)
  else
    # GNU date
    _cutoff=$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  fi

  # Sum tokens from assistant messages within the 5-hour window.
  # Deduplicate by message.id (each API response emits multiple JSONL lines
  # for each content block; usage values are repeated/incremental, so we
  # take only the last entry per message.id to avoid overcounting).
  _total_tokens=$(printf '%s\n' "$_jsonl_files" | while IFS= read -r _f; do
    [[ -f "$_f" ]] || continue
    jq -r --arg cutoff "$_cutoff" '
      select(.type == "assistant")
      | select(.timestamp >= $cutoff)
      | select(.message.usage != null)
      | { id: .message.id, usage: .message.usage }
    ' "$_f" 2>/dev/null || true
  done | jq -s '
    group_by(.id)
    | map(last.usage)
    | map((.input_tokens // 0)
        + (.output_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.cache_read_input_tokens // 0))
    | add // 0
  ')

  [[ -n "$_total_tokens" ]] || _total_tokens=0

  # Calculate percentage (integer)
  if [[ "$_total_tokens" -gt 0 ]] && [[ "$_limit" -gt 0 ]]; then
    _pct=$(( _total_tokens * 100 / _limit ))
  else
    _pct=0
  fi

  jq -n -c \
    --argjson pct "$_pct" \
    --argjson tokens "$_total_tokens" \
    --arg tier "$_tier" '{
    five_hour_used_pct: $pct,
    seven_day_used_pct: null,
    tokens_used: $tokens,
    mode: "local",
    tier: $tier,
    resets_at: null,
    seven_day_resets_at: null,
    estimated: true
  }'
}

# ── Public: Get token budget status ──────────────────────────────────
# Tries OAuth first, falls back to local JSONL estimation.
# stdout: JSON
_check_claude_token_budget() {
  if _claude_limit_oauth 2>/dev/null; then
    return 0
  fi
  _claude_limit_local
}

# ── Public: Go/no-go decision ────────────────────────────────────────
# $1 = scope: micro, module, layer, full
# $2 = (optional) pre-fetched JSON from _check_claude_token_budget
# return 0 = go, return 1 = no-go
_claude_budget_sufficient() {
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

  _budget_json="${2:-$(_check_claude_token_budget)}"
  _pct=$(printf '%s' "$_budget_json" | jq -r '.five_hour_used_pct')

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

  _json=$(_check_claude_token_budget)
  _pct=$(printf '%s' "$_json" | jq -r '.five_hour_used_pct')
  _mode=$(printf '%s' "$_json" | jq -r '.mode')
  _tier=$(printf '%s' "$_json" | jq -r '.tier')
  _estimated=$(printf '%s' "$_json" | jq -r '.estimated')
  _tokens=$(printf '%s' "$_json" | jq -r '.tokens_used')
  _resets=$(printf '%s' "$_json" | jq -r '.resets_at // "n/a"')
  _weekly_pct=$(printf '%s' "$_json" | jq -r '.seven_day_used_pct | tostring')
  _weekly_resets=$(printf '%s' "$_json" | jq -r '.seven_day_resets_at // "n/a"')

  echo "Claude Code Token Budget"
  echo "========================"
  echo "  Mode:       $_mode"
  echo "  Tier:       $_tier"
  if [[ "$_resets" != "n/a" ]] && [[ "$_resets" != "null" ]]; then
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
    echo "  7d used:    n/a   (local mode)"
  fi
  if [[ "$_mode" == "local" ]]; then
    echo "  Tokens:     $_tokens (estimated)"
  fi
  if [[ "$_estimated" == "true" ]]; then
    echo "  (!) Local estimation — actual usage may differ"
  fi
  echo ""
  echo "Scope thresholds (go if used% < threshold):"
  echo "  micro:  <90%   module: <75%   layer: TBD    full: TBD"
  echo ""

  # Show go/no-go for each scope (reuse _pct to avoid redundant API calls)
  _thresholds="micro:90 module:75"
  for _entry in $_thresholds; do
    _s="${_entry%%:*}"
    _thr="${_entry##*:}"
    if [[ "$_pct" -lt "$_thr" ]]; then
      printf '  %-8s GO\n' "$_s:"
    else
      printf '  %-8s NO-GO\n' "$_s:"
    fi
  done
  printf '  %-8s (no threshold set)\n' "layer:"
  printf '  %-8s (no threshold set)\n' "full:"
fi
