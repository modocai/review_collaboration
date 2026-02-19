#!/usr/bin/env bash
# Self-review sub-loop for mr-overkill scripts.
# Source this file for library use, or run standalone for ad-hoc self-review.
# Requires: caller must set -euo pipefail before sourcing.
# Requires: common.sh must be sourced before this file (library mode).
#
# Library usage:
#   source "$SCRIPT_DIR/lib/self-review.sh"
#   SELF_REVIEW_SUMMARY=$(_self_review_subloop \
#     "$PRE_FIX_STATE" "$MAX_SUBLOOP" "$LOG_DIR" "$i" "$REVIEW_JSON")
#
# Standalone usage:
#   bin/lib/self-review.sh --max-subloop 4

[[ -n "${_SELF_REVIEW_SH_LOADED:-}" ]] && return 0
_SELF_REVIEW_SH_LOADED=1

# ── JSON Hook: inject refactoring_plan ───────────────────────────────
# Pipes: stdin = self-review JSON, $1 = original review JSON.
# Injects refactoring_plan from original into self-review output.
_sr_inject_refactoring_plan() {
  local _orig_json="$1"
  jq --argjson plan \
    "$(printf '%s' "$_orig_json" | jq '.refactoring_plan // null')" \
    'if $plan then . + {refactoring_plan: $plan} else . end'
}

# ── Self-Review Sub-Loop ─────────────────────────────────────────────
# $1 = pre_fix_state    snapshot file path (_snapshot_worktree result)
# $2 = max_subloop      maximum sub-iterations
# $3 = log_dir          log output directory
# $4 = iteration        outer iteration number (for log filenames)
# $5 = original_review_json  original Codex findings JSON string
#
# Optional env vars (override defaults):
#   SR_OPINION_PROMPT    re-fix opinion prompt filename (default: claude-fix.prompt.md)
#   SR_EXECUTE_PROMPT    re-fix execute prompt filename (default: claude-fix-execute.prompt.md)
#   SR_REFIX_JSON_HOOK   re-fix JSON transform function name (stdin=self_review_json, $1=original_json)
#   SR_DRY_RUN           if "true", review only — skip re-fix
#
# Required globals (read-only): CURRENT_BRANCH, TARGET_BRANCH, PROMPTS_DIR
#
# stdout → SELF_REVIEW_SUMMARY string (caller captures with $())
# stderr → progress messages (displayed on terminal)
# return 0 always (individual failures are recorded in summary)
_self_review_subloop() {
  local _pre_fix_state="$1"
  local _max_subloop="$2"
  local _log_dir="$3"
  local _iteration="$4"
  local _original_review_json="$5"

  local _opinion_prompt="${SR_OPINION_PROMPT:-claude-fix.prompt.md}"
  local _execute_prompt="${SR_EXECUTE_PROMPT:-claude-fix-execute.prompt.md}"
  local _refix_json_hook="${SR_REFIX_JSON_HOOK:-}"
  local _dry_run="${SR_DRY_RUN:-false}"

  local _summary="" _j _fix_files_tmp _self_review_file _self_review_prompt
  local _rc _self_review_json _sr_findings _sr_overall
  local _refix_file _refix_opinion_file _refix_input_json

  export ITERATION="$_iteration"

  for (( _j=1; _j<=_max_subloop; _j++ )); do
    # Check if fix produced any changes vs pre-fix snapshot
    if ! _fix_files_tmp=$(_changed_files_since_snapshot "$_pre_fix_state"); then
      echo "  No working tree changes from fix — skipping self-review." >&2
      break
    fi

    echo "[$(date +%H:%M:%S)] Running Claude self-review (sub-iteration $_j/$_max_subloop)..." >&2
    _self_review_file="$_log_dir/self-review-${_iteration}-${_j}.json"

    # Dump diff for only files changed by the fix (exclude pre-existing dirty files)
    # Stage untracked files as intent-to-add so git diff HEAD can see them
    xargs -0 git add --intent-to-add -- < "$_fix_files_tmp" 2>/dev/null || true
    export DIFF_FILE="$_log_dir/diff-${_iteration}-${_j}.diff"
    xargs -0 git diff HEAD -- < "$_fix_files_tmp" > "$DIFF_FILE"
    # Immediately undo intent-to-add so we never clobber pre-existing staged state
    xargs -0 git reset --quiet -- < "$_fix_files_tmp" 2>/dev/null || true
    rm -f "$_fix_files_tmp"

    # Self-review prompt always references the original Codex findings
    export REVIEW_JSON="$_original_review_json"
    _self_review_prompt=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION $REVIEW_JSON $DIFF_FILE' < "$PROMPTS_DIR/claude-self-review.prompt.md")

    # Claude self-review — tool access for git diff, file reading, etc.
    if ! printf '%s' "$_self_review_prompt" | claude -p - \
      --allowedTools "Read,Glob,Grep" \
      > "$_self_review_file" 2>&1; then
      echo "  Warning: self-review failed (sub-iteration $_j). Continuing with current fixes." >&2
      _summary="${_summary}Sub-iteration $_j: self-review failed\n"
      break
    fi

    # JSON parsing (same logic as codex review)
    if [[ ! -s "$_self_review_file" ]]; then
      echo "  Warning: self-review produced empty output (sub-iteration $_j). Continuing with current fixes." >&2
      _summary="${_summary}Sub-iteration $_j: empty output\n"
      break
    fi
    _rc=0
    _self_review_json=$(_extract_json_from_file "$_self_review_file") || _rc=$?
    if [[ $_rc -ne 0 ]]; then
      if [[ $_rc -eq 2 ]]; then
        echo "  Warning: self-review output file not found ($_self_review_file)." >&2
      else
        echo "  Warning: could not parse self-review output." >&2
      fi
      echo "  Continuing with current fixes." >&2
      _summary="${_summary}Sub-iteration $_j: parse error\n"
      break
    fi

    _sr_findings=$(printf '%s' "$_self_review_json" | jq '.findings | length')
    _sr_overall=$(printf '%s' "$_self_review_json" | jq -r '.overall_correctness')
    echo "  Self-review: $_sr_findings findings | $_sr_overall" >&2

    if [[ "$_sr_findings" -eq 0 ]] && [[ "$_sr_overall" == "patch is correct" ]]; then
      echo "  Self-review passed — fixes are clean." >&2
      _summary="${_summary}Sub-iteration $_j: 0 findings — passed\n"
      break
    fi

    # Dry-run: report findings but skip re-fix
    if [[ "$_dry_run" == true ]]; then
      echo "  Self-review dry-run — skipping re-fix." >&2
      _summary="${_summary}Sub-iteration $_j: $_sr_findings findings — dry-run\n"
      break
    fi

    # Claude re-fix (two-step: opinion → execute)
    _refix_file="$_log_dir/refix-${_iteration}-${_j}.md"
    _refix_opinion_file="$_log_dir/refix-opinion-${_iteration}-${_j}.md"

    # Apply JSON hook if configured (e.g. inject refactoring_plan)
    _refix_input_json="$_self_review_json"
    if [[ -n "$_refix_json_hook" ]]; then
      if ! declare -F "$_refix_json_hook" >/dev/null 2>&1; then
        echo "  Warning: SR_REFIX_JSON_HOOK='$_refix_json_hook' is not a defined function — skipping hook." >&2
      else
        _refix_input_json=$(printf '%s' "$_self_review_json" | "$_refix_json_hook" "$_original_review_json")
      fi
    fi

    if ! _claude_two_step_fix "$_refix_input_json" "$_refix_opinion_file" "$_refix_file" "re-fix" \
      "$_opinion_prompt" "$_execute_prompt" >&2; then
      _summary="${_summary}Sub-iteration $_j: $_sr_findings findings — re-fix failed\n"
      break
    fi
    _summary="${_summary}Sub-iteration $_j: $_sr_findings findings — re-fixed\n"
  done

  printf '%s' "$_summary"
}

# ── Standalone mode ──────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail

  _SELF_REVIEW_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  source "$_SELF_REVIEW_SCRIPT_DIR/common.sh"

  # Defaults
  _MAX_SUBLOOP=4
  _DRY_RUN=false
  _REFACTORING_PLAN_FILE=""
  _LOG_DIR=""
  _ITERATION=1
  _TARGET=""

  usage() {
    cat <<'EOF'
Usage: self-review.sh [OPTIONS]

Self-review current working tree changes and optionally re-fix issues found.
Requires a dirty working tree (uncommitted changes to review).

Options:
  --max-subloop <N>         Maximum sub-iterations (default: 4)
  --dry-run                 Review only, do not apply re-fixes
  --refactoring-plan <file> Load refactoring_plan from JSON file (scope context)
  --log-dir <dir>           Log directory (default: temporary directory)
  --iteration <N>           Iteration number for log filenames (default: 1)
  -t, --target <branch>     Target branch for diff context (default: current branch)
  -h, --help                Show this help message

Examples:
  self-review.sh                             # self-review with defaults
  self-review.sh --max-subloop 2             # limit to 2 sub-iterations
  self-review.sh --dry-run                   # review only, no re-fixes
  self-review.sh --refactoring-plan plan.json # include refactoring plan context
EOF
    exit "${1:-0}"
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-subloop)
        if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
        _MAX_SUBLOOP="$2"; shift 2 ;;
      --dry-run)         _DRY_RUN=true; shift ;;
      --refactoring-plan)
        if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
        _REFACTORING_PLAN_FILE="$2"; shift 2 ;;
      --log-dir)
        if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
        _LOG_DIR="$2"; shift 2 ;;
      --iteration)
        if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
        _ITERATION="$2"; shift 2 ;;
      -t|--target)
        if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
        _TARGET="$2"; shift 2 ;;
      -h|--help) usage ;;
      *)         echo "Error: unknown option '$1'"; usage 1 ;;
    esac
  done

  # Validation
  if ! [[ "$_MAX_SUBLOOP" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --max-subloop must be a positive integer, got '$_MAX_SUBLOOP'."
    exit 1
  fi

  if ! [[ "$_ITERATION" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --iteration must be a positive integer, got '$_ITERATION'."
    exit 1
  fi

  if [[ -n "$_REFACTORING_PLAN_FILE" ]] && [[ ! -f "$_REFACTORING_PLAN_FILE" ]]; then
    echo "Error: refactoring plan file not found: $_REFACTORING_PLAN_FILE"
    exit 1
  fi

  # Prerequisites
  check_cmd git
  check_cmd claude
  check_cmd jq
  check_cmd envsubst
  check_cmd perl

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository."
    exit 1
  fi

  # Check dirty working tree (must have changes to review)
  if git diff --quiet && git diff --cached --quiet \
     && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Error: working tree is clean — nothing to self-review."
    echo "Make changes first, then run self-review."
    exit 1
  fi

  # Set globals
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  TARGET_BRANCH="${_TARGET:-$CURRENT_BRANCH}"
  export CURRENT_BRANCH TARGET_BRANCH

  PROMPTS_DIR="${PROMPTS_DIR:-$_SELF_REVIEW_SCRIPT_DIR/../../prompts/active}"
  if [[ ! -d "$PROMPTS_DIR" ]]; then
    echo "Error: prompts directory not found: $PROMPTS_DIR" >&2
    exit 1
  fi

  if [[ ! -f "$PROMPTS_DIR/claude-self-review.prompt.md" ]]; then
    echo "Error: self-review prompt not found: $PROMPTS_DIR/claude-self-review.prompt.md" >&2
    exit 1
  fi

  # Log directory
  _AUTO_LOG_DIR=false
  if [[ -z "$_LOG_DIR" ]]; then
    _LOG_DIR=$(mktemp -d)
    _AUTO_LOG_DIR=true
    echo "Using temporary log directory: $_LOG_DIR"
  else
    mkdir -p "$_LOG_DIR"
  fi

  # Snapshot pre-fix state
  PRE_FIX_STATE=$(_snapshot_worktree)
  _standalone_cleanup() {
    rm -f "$PRE_FIX_STATE"
    if [[ "$_AUTO_LOG_DIR" == true ]] && [[ -d "$_LOG_DIR" ]]; then
      rm -rf "$_LOG_DIR"
    fi
  }
  trap _standalone_cleanup EXIT

  # Build synthetic REVIEW_JSON
  _REVIEW_JSON='{"findings":[],"overall_correctness":"not reviewed"}'
  if [[ -n "$_REFACTORING_PLAN_FILE" ]]; then
    _plan=$(jq '.' "$_REFACTORING_PLAN_FILE") || {
      echo "Error: invalid JSON in refactoring plan file: $_REFACTORING_PLAN_FILE"
      exit 1
    }
    _REVIEW_JSON=$(printf '%s' "$_REVIEW_JSON" | jq --argjson plan "$_plan" '. + {refactoring_plan: $plan}')
  fi

  echo "═══════════════════════════════════════════════════════"
  echo " Self-Review: $CURRENT_BRANCH (target: $TARGET_BRANCH)"
  echo " Max sub-iterations: $_MAX_SUBLOOP | Dry-run: $_DRY_RUN"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  # Call the sub-loop
  SUMMARY=$(
    if [[ "$_DRY_RUN" == true ]]; then SR_DRY_RUN=true; fi
    if [[ -n "$_REFACTORING_PLAN_FILE" ]]; then SR_REFIX_JSON_HOOK="_sr_inject_refactoring_plan"; fi
    _self_review_subloop \
      "$PRE_FIX_STATE" "$_MAX_SUBLOOP" "$_LOG_DIR" "$_ITERATION" "$_REVIEW_JSON"
  )

  echo ""
  echo "═══════════════════════════════════════════════════════"
  if [[ -n "$SUMMARY" ]]; then
    echo " Self-Review Summary:"
    printf '%b' "$SUMMARY" | sed 's/^/  /'
  else
    echo " No self-review iterations executed."
  fi
  echo " Logs: $_LOG_DIR"
  echo "═══════════════════════════════════════════════════════"
fi
