#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROMPTS_DIR="$SCRIPT_DIR/../prompts/active"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/self-review.sh"

# ── Defaults ──────────────────────────────────────────────────────────
TARGET_BRANCH="develop"
MAX_LOOP=""
MAX_SUBLOOP=4
DRY_RUN=false
AUTO_COMMIT=true
RESUME=false
_MAX_LOOP_EXPLICIT=false
_TARGET_BRANCH_EXPLICIT=false
RETRY_MAX_WAIT=600
RETRY_INITIAL_WAIT=30
BUDGET_SCOPE="module"
DIAGNOSTIC_LOG=false

# ── Load .reviewlooprc (if present) ──────────────────────────────────
# Project-level config file can override defaults above.
# CLI arguments take precedence over .reviewlooprc values.
# SECURITY: parse only whitelisted KEY=VALUE lines; never source the file.
REVIEWLOOPRC=".reviewlooprc"
_GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$_GIT_ROOT" && -f "$_GIT_ROOT/$REVIEWLOOPRC" ]]; then
  while IFS= read -r _rc_line || [[ -n "$_rc_line" ]]; do
    # Skip blank lines and comments
    [[ -z "$_rc_line" || "$_rc_line" =~ ^[[:space:]]*# ]] && continue
    # Match KEY=VALUE (optionally quoted value); reject anything else
    if [[ "$_rc_line" =~ ^[[:space:]]*(TARGET_BRANCH|MAX_LOOP|MAX_SUBLOOP|DRY_RUN|AUTO_COMMIT|PROMPTS_DIR|RETRY_MAX_WAIT|RETRY_INITIAL_WAIT|BUDGET_SCOPE|DIAGNOSTIC_LOG)=[\"\']?([^\"\']*)[\"\']?[[:space:]]*$ ]]; then
      _rc_val="${BASH_REMATCH[2]}"
      _rc_key="${BASH_REMATCH[1]}"
      # Trim trailing whitespace from unquoted values
      _rc_val="${_rc_val%"${_rc_val##*[![:space:]]}"}"
      # Validate boolean values
      if [[ "$_rc_key" == "DRY_RUN" || "$_rc_key" == "AUTO_COMMIT" || "$_rc_key" == "DIAGNOSTIC_LOG" ]]; then
        if [[ "$_rc_val" != "true" && "$_rc_val" != "false" ]]; then
          echo "Error: $_rc_key must be 'true' or 'false', got '$_rc_val'." >&2
          exit 1
        fi
      fi
      # Validate numeric retry values
      if [[ "$_rc_key" == "RETRY_MAX_WAIT" || "$_rc_key" == "RETRY_INITIAL_WAIT" ]]; then
        if ! [[ "$_rc_val" =~ ^[1-9][0-9]*$ ]]; then
          echo "Error: $_rc_key must be a positive integer, got '$_rc_val'." >&2
          exit 1
        fi
      fi
      # Validate BUDGET_SCOPE
      if [[ "$_rc_key" == "BUDGET_SCOPE" ]]; then
        case "$_rc_val" in
          micro|module) ;;
          *) echo "Error: BUDGET_SCOPE must be 'micro' or 'module', got '$_rc_val'." >&2; exit 1 ;;
        esac
      fi
      declare "${_rc_key}=${_rc_val}"
    else
      echo "Warning: ignoring unrecognised .reviewlooprc line: $_rc_line" >&2
    fi
  done < "$_GIT_ROOT/$REVIEWLOOPRC"
  unset _rc_line _rc_key _rc_val
fi

# Resolve relative PROMPTS_DIR against git root so the script works from any cwd
if [[ -n "$_GIT_ROOT" && "$PROMPTS_DIR" != /* ]]; then
  PROMPTS_DIR="$_GIT_ROOT/$PROMPTS_DIR"
fi
unset _GIT_ROOT

# ── Usage ─────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: review-loop.sh [OPTIONS]

Options:
  -t, --target <branch>    Target branch to diff against (default: develop)
  -n, --max-loop <N>       Maximum review-fix iterations (required)
  --max-subloop <N>        Maximum self-review sub-iterations per fix (default: 4)
  --no-self-review         Disable self-review (equivalent to --max-subloop 0)
  --dry-run                Run review only, do not fix
  --no-dry-run             Force fixes even if .reviewlooprc sets DRY_RUN=true
  --no-auto-commit         Fix but do not commit/push (single iteration)
  --auto-commit            Force commit/push even if .reviewlooprc sets AUTO_COMMIT=false
  --resume                 Resume from a previously interrupted run (reuses existing logs)
  --diagnostic-log         Save full Claude event stream to .stream.jsonl sidecar files
  -V, --version            Show version
  -h, --help               Show this help message

Flow:
  1. Codex reviews diff (target...current)
  2. Claude fixes all issues (P0-P3)
  3. Claude self-reviews fixes, re-fixes if needed (up to --max-subloop times)
  4. Auto-commit & push fixes to update PR
  5. Post review/fix/self-review summary as PR comment
  6. Repeat until clean or max iterations

Examples:
  review-loop.sh -t main -n 3          # diff against main, max 3 loops
  review-loop.sh -n 5                  # diff against develop, max 5 loops
  review-loop.sh -n 1 --dry-run        # single review, no fixes
  review-loop.sh -n 3 --no-self-review # disable self-review sub-loop
EOF
  exit "${1:-0}"
}

# ── Argument parsing ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      TARGET_BRANCH="$2"; _TARGET_BRANCH_EXPLICIT=true; shift 2 ;;
    -n|--max-loop)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      MAX_LOOP="$2"; _MAX_LOOP_EXPLICIT=true; shift 2 ;;
    --max-subloop)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      MAX_SUBLOOP="$2"; shift 2 ;;
    --no-self-review)  MAX_SUBLOOP=0; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --no-dry-run)      DRY_RUN=false; shift ;;
    --no-auto-commit)  AUTO_COMMIT=false; shift ;;
    --auto-commit)     AUTO_COMMIT=true; shift ;;
    --resume)          RESUME=true; shift ;;
    --diagnostic-log)  DIAGNOSTIC_LOG=true; shift ;;
    -V|--version) echo "review-loop v$VERSION"; exit 0 ;;
    -h|--help)    usage ;;
    *)            echo "Error: unknown option '$1'"; usage 1 ;;
  esac
done

if [[ -z "$MAX_LOOP" ]] && [[ "$RESUME" != true ]]; then
  echo "Error: -n / --max-loop is required."
  echo ""
  usage 1
fi

[[ -n "$MAX_LOOP" ]] && _require_pos_int "--max-loop" "$MAX_LOOP"
_require_nonneg_int "--max-subloop" "$MAX_SUBLOOP"

# ── Prerequisite checks ──────────────────────────────────────────────
_require_core
check_cmd codex
if [[ "$DRY_RUN" == false ]]; then
  check_cmd claude
fi

if [[ "$HAS_GH" == false ]]; then
  echo "Warning: 'gh' is not installed — PR commenting will be disabled."
fi

if [[ "$RESUME" != true ]]; then
  if ! git rev-parse --verify "$TARGET_BRANCH" &>/dev/null; then
    echo "Error: target branch '$TARGET_BRANCH' does not exist."
    exit 1
  fi
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ── Resume: validate branch & reset partial edits ─────────────────
if [[ "$RESUME" == true ]]; then
  _early_log_dir="$SCRIPT_DIR/../logs"
  _expected_branch=$(cat "$_early_log_dir/branch.txt" 2>/dev/null || true)
  if [[ -z "$_expected_branch" ]]; then
    echo "Error: no prior run logs found. Cannot resume (missing branch.txt)."
    exit 1
  fi
  if [[ "$CURRENT_BRANCH" != "$_expected_branch" ]]; then
    echo "Error: resume expects branch '$_expected_branch' but currently on '$CURRENT_BRANCH'."
    echo "  git checkout $_expected_branch"
    exit 1
  fi
  # Skip destructive stash/reset if previous run already completed
  if [[ -f "$_early_log_dir/summary.md" ]]; then
    _quick_status=$(sed -n 's/.*\*\*Final status\*\*: //p' "$_early_log_dir/summary.md" | head -1)
    case "$_quick_status" in
      all_clear|no_diff|dry_run|max_iterations_reached|auto_commit_disabled)
        echo "Previous run already completed (status: $_quick_status). Nothing to resume."
        exit 0 ;;
    esac
  fi
  _saved_target=$(cat "$_early_log_dir/target-branch.txt" 2>/dev/null || true)
  if [[ -n "$_saved_target" ]] && ! git rev-parse --verify "$_saved_target" &>/dev/null; then
    echo "Error: saved target branch '$_saved_target' does not exist." >&2; exit 1
  fi
  unset _early_log_dir _expected_branch

  # Destructive stash/reset only when applying fixes (non-dry-run)
  if [[ "$DRY_RUN" == false ]]; then
    # Safety: stash any uncommitted changes before destructive reset so the user
    # can recover them via `git stash list` if they were not from the interrupted run.
    if ! git diff --quiet || ! git diff --cached --quiet \
       || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
      echo "Stashing uncommitted changes before resume reset..."
      if ! git stash push --include-untracked -m "review-loop: pre-resume safety stash"; then
        echo "Error: failed to stash uncommitted changes. Aborting resume to prevent data loss."
        exit 1
      fi
    fi
    echo "Resetting partial edits from interrupted run..."
    _resume_reset_working_tree
  fi
fi

# ── Clean working tree check ────────────────────────────────────────
# Allow .gitignore/.reviewlooprc/.refactorsuggestrc to be dirty — the installer
# modifies .gitignore, and the user may have an untracked .reviewlooprc or
# .refactorsuggestrc.  Pre-existing dirty files are snapshot-ed before each fix
# and excluded from commits (see step h).
_dirty_non_gitignore=$(git diff --name-only | grep -v -E '^(\.gitignore|\.reviewlooprc|\.refactorsuggestrc)$' || true)
_untracked_non_gitignore=$(git ls-files --others --exclude-standard | grep -v -E '^(\.gitignore|\.reviewlooprc|\.refactorsuggestrc)$' || true)
_staged_non_gitignore=$(git diff --cached --name-only | grep -v -E '^(\.gitignore|\.reviewlooprc|\.refactorsuggestrc)$' || true)
if [[ "$DRY_RUN" == false ]]; then
  if [[ -n "$_dirty_non_gitignore" ]] || [[ -n "$_staged_non_gitignore" ]] || [[ -n "$_untracked_non_gitignore" ]]; then
    echo "Error: working tree is not clean. Commit or stash your changes before running review-loop."
    echo ""
    echo "  git stash        # stash changes"
    echo "  git commit -am …  # or commit them"
    echo ""
    exit 1
  fi
fi
unset _dirty_non_gitignore _staged_non_gitignore _untracked_non_gitignore

LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
# Remove stale logs from previous runs so the summary only reflects this execution
if [[ "$RESUME" == false ]]; then
  rm -f "$LOG_DIR"/review-*.json "$LOG_DIR"/fix-*.md "$LOG_DIR"/opinion-*.md "$LOG_DIR"/self-review-*.json "$LOG_DIR"/refix-*.md "$LOG_DIR"/refix-opinion-*.md "$LOG_DIR"/summary.md "$LOG_DIR"/*.stream.jsonl
  echo "$CURRENT_BRANCH" > "$LOG_DIR/branch.txt"
  git rev-parse HEAD > "$LOG_DIR/start-commit.txt"
  echo "$MAX_LOOP" > "$LOG_DIR/max-loop.txt"
  echo "$TARGET_BRANCH" > "$LOG_DIR/target-branch.txt"
fi

export CURRENT_BRANCH TARGET_BRANCH DIAGNOSTIC_LOG

# Detect open PR for current branch (if any)
PR_NUMBER=""
if [[ "$HAS_GH" == true ]]; then
  PR_NUMBER=$(gh pr view "$CURRENT_BRANCH" --json number -q .number 2>/dev/null || true)
fi
if [[ -n "$PR_NUMBER" ]]; then
  echo "Detected PR #$PR_NUMBER for branch $CURRENT_BRANCH"
else
  echo "No open PR detected — PR comments will be skipped."
fi

# ── Pre-loop validation ───────────────────────────────────────────────
if [[ "$DRY_RUN" == false ]] && [[ ! -f "$PROMPTS_DIR/claude-fix-execute.prompt.md" ]]; then
  echo "Error: required prompt not found: $PROMPTS_DIR/claude-fix-execute.prompt.md" >&2
  exit 1
fi
if [[ "$MAX_SUBLOOP" -gt 0 ]] && [[ ! -f "$PROMPTS_DIR/claude-self-review.prompt.md" ]]; then
  echo "Warning: self-review prompt not found at $PROMPTS_DIR/claude-self-review.prompt.md — disabling self-review."
  MAX_SUBLOOP=0
fi

# ── PR Commenting ────────────────────────────────────────────────────
# Post iteration summary as PR comment.
# Reads globals: PR_NUMBER, REVIEW_JSON, OVERALL, FINDINGS_COUNT,
#   FIX_FILE, OPINION_FILE, SELF_REVIEW_SUMMARY, MAX_SUBLOOP, MAX_LOOP, i
_post_pr_comment() {
  [[ -n "$PR_NUMBER" ]] || return 0
  echo "[$(date +%H:%M:%S)] Posting PR comment..."

  local FINDINGS_TABLE FIX_SUMMARY COMMENT_BODY_FILE

  FINDINGS_TABLE=$(printf '%s' "$REVIEW_JSON" | jq -r '
    .findings[] |
    "| \(.title) | \(.confidence_score) | `\(.code_location.file_path):\(.code_location.line_range.start)` |"
  ')

  FIX_SUMMARY=""
  if [[ -f "$FIX_FILE" ]]; then
    FIX_SUMMARY=$(sed -n '/^## Fix Summary/,/^## /{ /^## Fix Summary/d; /^## /d; p; }' "$FIX_FILE")
    if [[ -z "$FIX_SUMMARY" ]]; then
      FIX_SUMMARY=$(sed -n '/^## Fix Summary/,${ /^## Fix Summary/d; p; }' "$FIX_FILE")
    fi
  fi

  COMMENT_BODY_FILE=$(mktemp)

  printf '### AI Review — Iteration %d / %d\n\n' "$i" "$MAX_LOOP" > "$COMMENT_BODY_FILE"
  printf '**Overall**: %s (%s findings)\n\n' "$OVERALL" "$FINDINGS_COUNT" >> "$COMMENT_BODY_FILE"

  printf '<details>\n<summary>Review Findings</summary>\n\n' >> "$COMMENT_BODY_FILE"
  printf '| Finding | Confidence | Location |\n' >> "$COMMENT_BODY_FILE"
  printf '|---------|-----------|----------|\n' >> "$COMMENT_BODY_FILE"
  printf '%s\n' "$FINDINGS_TABLE" >> "$COMMENT_BODY_FILE"
  printf '\n</details>\n\n' >> "$COMMENT_BODY_FILE"

  printf '<details>\n<summary>Fix Actions</summary>\n\n' >> "$COMMENT_BODY_FILE"
  printf '%s\n' "$FIX_SUMMARY" >> "$COMMENT_BODY_FILE"
  printf '\n</details>\n' >> "$COMMENT_BODY_FILE"

  if [[ -f "$OPINION_FILE" ]] && [[ -s "$OPINION_FILE" ]]; then
    printf '\n<details>\n<summary>Claude Opinion</summary>\n\n' >> "$COMMENT_BODY_FILE"
    head -c 2000 "$OPINION_FILE" >> "$COMMENT_BODY_FILE"
    printf '\n\n</details>\n' >> "$COMMENT_BODY_FILE"
  fi

  if [[ -n "$SELF_REVIEW_SUMMARY" ]]; then
    printf '\n<details>\n<summary>Self-Review (%d max sub-iterations)</summary>\n\n' "$MAX_SUBLOOP" >> "$COMMENT_BODY_FILE"
    printf '%b\n' "$SELF_REVIEW_SUMMARY" >> "$COMMENT_BODY_FILE"
    printf '</details>\n' >> "$COMMENT_BODY_FILE"
  fi

  if gh pr comment "$PR_NUMBER" --body-file "$COMMENT_BODY_FILE"; then
    echo "  PR comment posted."
  else
    echo "  Warning: failed to post PR comment (non-fatal)."
  fi
  rm -f "$COMMENT_BODY_FILE"
}

# ── Cleanup trap ──────────────────────────────────────────────────────
# Restore allowlisted stash on any exit (set -e, signals, etc.) so that
# user-local .gitignore/.reviewlooprc edits are never stranded.
_cleanup() {
  rm -f "${PRE_FIX_STATE:-}"
  if [[ "${_allowed_dirty_stashed:-false}" == true ]]; then
    if ! _unstash_allowlisted; then
      echo "  Error: failed to restore stashed .gitignore/.reviewlooprc edits. Check 'git stash list'." >&2
      FINAL_STATUS="stash_conflict"
    fi
    _allowed_dirty_stashed=false
  fi
}
trap _cleanup EXIT

# ── Resume detection ──────────────────────────────────────────────────
_RESUME_FROM=1
_REUSE_REVIEW=false

if [[ "$RESUME" == true ]]; then
  # Branch validation already performed in the early resume block.

  _saved_target=$(cat "$LOG_DIR/target-branch.txt" 2>/dev/null || true)
  if [[ -n "$_saved_target" ]] && [[ "$_TARGET_BRANCH_EXPLICIT" == true ]] \
     && [[ "$TARGET_BRANCH" != "$_saved_target" ]]; then
    echo "Error: --target '$TARGET_BRANCH' differs from saved target '$_saved_target'." >&2
    echo "  Remove logs/ directory to start fresh, or omit --target to use the saved value." >&2
    exit 1
  elif [[ -n "$_saved_target" ]] && [[ "$_TARGET_BRANCH_EXPLICIT" == false ]]; then
    TARGET_BRANCH="$_saved_target"
  fi
  if ! git rev-parse --verify "$TARGET_BRANCH" &>/dev/null; then
    echo "Error: saved target branch '$TARGET_BRANCH' does not exist." >&2; exit 1
  fi

  _saved_max_loop=$(cat "$LOG_DIR/max-loop.txt" 2>/dev/null || true)
  if [[ -n "$_saved_max_loop" ]] && [[ "$_MAX_LOOP_EXPLICIT" == false ]]; then
    MAX_LOOP="$_saved_max_loop"
  fi
  if [[ -n "$MAX_LOOP" ]] && ! [[ "$MAX_LOOP" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: saved max-loop is invalid: '$MAX_LOOP'." >&2; exit 1
  fi

  _resume_json=$(_resume_detect_state "$LOG_DIR" "fix(ai-review): apply iteration")
  _resume_status=$(printf '%s' "$_resume_json" | jq -r '.status')
  _RESUME_FROM=$(printf '%s' "$_resume_json" | jq -r '.resume_from')
  _REUSE_REVIEW=$(printf '%s' "$_resume_json" | jq -r '.reuse_review')

  case "$_resume_status" in
    completed)
      _prev=$(printf '%s' "$_resume_json" | jq -r '.prev_status')
      echo "Previous run completed with status: $_prev. Nothing to resume."
      FINAL_STATUS="$_prev"
      SUMMARY_FILE=$(_generate_summary "Review Loop Summary")
      echo ""
      echo "═══════════════════════════════════════════════════════"
      echo " Done. Status: $FINAL_STATUS"
      echo " Summary: $SUMMARY_FILE"
      echo "═══════════════════════════════════════════════════════"
      exit 0
      ;;
    no_logs)
      echo "Error: no previous logs found in $LOG_DIR. Nothing to resume."
      exit 1
      ;;
    resumable)
      echo "Resuming from iteration $_RESUME_FROM (reuse_review=$_REUSE_REVIEW)"
      ;;
  esac
fi

echo "═══════════════════════════════════════════════════════"
echo " Review Loop: $CURRENT_BRANCH → $TARGET_BRANCH"
echo " Max iterations: $MAX_LOOP | Sub-loops: $MAX_SUBLOOP | Dry-run: $DRY_RUN"
echo "═══════════════════════════════════════════════════════"
echo ""

if [[ -z "$MAX_LOOP" ]]; then
  echo "Error: could not determine max-loop (missing logs/max-loop.txt)."
  echo "  Use: -n / --max-loop to specify."
  exit 1
fi

if [[ "$_RESUME_FROM" -gt "$MAX_LOOP" ]]; then
  echo "Error: resume point ($_RESUME_FROM) exceeds max-loop ($MAX_LOOP)."
  echo "  Use: --max-loop N --resume (where N >= $_RESUME_FROM)"
  exit 1
fi

# ── Loop ──────────────────────────────────────────────────────────────
FINAL_STATUS="max_iterations_reached"

for (( i=1; i<=MAX_LOOP; i++ )); do
  echo "───────────────────────────────────────────────────────"
  echo " Iteration $i / $MAX_LOOP"
  echo "───────────────────────────────────────────────────────"

  export ITERATION="$i"

  # ── Resume: skip completed iterations ──────────────────────────
  if [[ "$i" -lt "$_RESUME_FROM" ]]; then
    echo "  [resume] Skipping iteration $i (already completed)."
    continue
  fi

  # ── a. Check diff ───────────────────────────────────────────────
  if git diff --quiet "$TARGET_BRANCH...$CURRENT_BRANCH"; then
    echo "No diff between $TARGET_BRANCH and $CURRENT_BRANCH. Nothing to review."
    FINAL_STATUS="no_diff"
    break
  fi

  # ── c. Codex review ──────────────────────────────────────────────
  REVIEW_FILE="$LOG_DIR/review-${i}.json"

  # Invalidate review reuse if the diff changed since the review was generated
  if [[ "$_REUSE_REVIEW" == true ]] && [[ "$i" -eq "$_RESUME_FROM" ]]; then
    _saved_hash=$(cat "$LOG_DIR/diff-hash-${i}.txt" 2>/dev/null || true)
    _curr_hash=$(git diff "$TARGET_BRANCH...$CURRENT_BRANCH" | sha256 | cut -d' ' -f1)
    if [[ -z "$_saved_hash" ]] || [[ "$_saved_hash" != "$_curr_hash" ]]; then
      echo "  [resume] Diff changed since last review; re-running Codex."
      _REUSE_REVIEW=false
    fi
  fi

  if [[ "$RESUME" == true ]] && [[ "$_REUSE_REVIEW" == true ]] \
     && [[ "$i" -eq "$_RESUME_FROM" ]] && [[ -f "$REVIEW_FILE" ]]; then
    echo "  [resume] Reusing saved review: $REVIEW_FILE"
  else
    rm -f "$REVIEW_FILE"
    echo "[$(date +%H:%M:%S)] Running Codex review..."

    REVIEW_PROMPT=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION' < "$PROMPTS_DIR/codex-review.prompt.md")

    # Pre-flight budget check
    if ! _wait_for_budget "codex" "${BUDGET_SCOPE:-module}"; then
      echo "Error: Codex budget timeout (iteration $i)."
      FINAL_STATUS="codex_budget_timeout"
      break
    fi

    CODEX_STDERR=$(mktemp)
    if ! _retry_codex_cmd "$CODEX_STDERR" "Codex review" \
      codex exec --sandbox read-only -o "$REVIEW_FILE" "$REVIEW_PROMPT"; then
      echo "Error: Codex review failed (iteration $i). Skipping this iteration."
      FINAL_STATUS="codex_error"
      rm -f "$CODEX_STDERR"
      break
    fi
    rm -f "$CODEX_STDERR"
    git diff "$TARGET_BRANCH...$CURRENT_BRANCH" | sha256 | cut -d' ' -f1 > "$LOG_DIR/diff-hash-${i}.txt"
  fi

  # ── d. Extract JSON from response ────────────────────────────────
  if ! REVIEW_JSON=$(_parse_review_json "$REVIEW_FILE" "review"); then
    FINAL_STATUS="parse_error"
    break
  fi

  # Normalize absolute paths to repo-relative
  REVIEW_JSON=$(printf '%s' "$REVIEW_JSON" | jq --arg root "$(git rev-parse --show-toplevel)/" '
    if .findings then
      .findings |= map(
        .code_location.file_path = (.code_location.file_path // .code_location.absolute_file_path | ltrimstr($root))
        | del(.code_location.absolute_file_path)
      )
    else . end
  ')

  # ── e. Check findings ────────────────────────────────────────────
  FINDINGS_COUNT=$(printf '%s' "$REVIEW_JSON" | jq '.findings | length')
  OVERALL=$(printf '%s' "$REVIEW_JSON" | jq -r '.overall_correctness')

  echo "  Findings: $FINDINGS_COUNT | Overall: $OVERALL"

  if [[ "$FINDINGS_COUNT" -eq 0 ]] && [[ "$OVERALL" == "patch is correct" ]]; then
    echo "  All clear — no issues found."
    # Post all-clear comment to PR
    if [[ -n "$PR_NUMBER" ]]; then
      if gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
### AI Review — Iteration $i ✅

No issues found. Patch is correct.
EOF
)"; then
        echo "  PR comment posted."
      else
        echo "  Warning: failed to post PR comment (non-fatal)."
      fi
    fi
    FINAL_STATUS="all_clear"
    break
  fi

  # ── f. Dry-run check ─────────────────────────────────────────────
  if [[ "$DRY_RUN" == true ]]; then
    echo "  Dry-run mode — skipping fixes."
    FINAL_STATUS="dry_run"
    break
  fi

  # ── Stash allowed dirty files (.gitignore/.reviewlooprc/.refactorsuggestrc)
  # These files may be dirty from the installer or user edits.  Stash them
  # before snapshotting so they are excluded from Claude's commit even if
  # Claude happens to modify the same file.
  _allowed_dirty_stashed=false
  if _stash_allowlisted .gitignore .reviewlooprc .refactorsuggestrc; then
    _allowed_dirty_stashed=true
  fi

  # ── Snapshot pre-fix working tree state ──────────────────────────
  PRE_FIX_STATE=$(_snapshot_worktree)

  # ── g. Claude fix (two-step: opinion → execute) ─────────────────
  FIX_FILE="$LOG_DIR/fix-${i}.md"
  OPINION_FILE="$LOG_DIR/opinion-${i}.md"

  if ! _claude_two_step_fix "$REVIEW_JSON" "$OPINION_FILE" "$FIX_FILE" "fix"; then
    FINAL_STATUS="claude_error"
    _cleanup
    break
  fi

  # ── g2. Claude self-review sub-loop ─────────────────────────────
  SELF_REVIEW_SUMMARY=""
  if [[ "$MAX_SUBLOOP" -gt 0 ]]; then
    SELF_REVIEW_SUMMARY=$(_self_review_subloop \
      "$PRE_FIX_STATE" "$MAX_SUBLOOP" "$LOG_DIR" "$i" "$REVIEW_JSON")
  fi

  # ── h. Commit & push fixes ──────────────────────────────────────
  if [[ "$AUTO_COMMIT" == true ]]; then
    COMMIT_MSG="fix(ai-review): apply iteration $i fixes

Auto-generated by review-loop.sh (iteration $i/$MAX_LOOP)"
    if [[ -n "$SELF_REVIEW_SUMMARY" ]]; then
      COMMIT_MSG="${COMMIT_MSG}
Self-review: $(printf '%b' "$SELF_REVIEW_SUMMARY" | tr '\n' '; ' | sed 's/; $//')"
    fi
    _commit_and_push "$PRE_FIX_STATE" "$COMMIT_MSG" "$CURRENT_BRANCH"
  else
    echo "  AUTO_COMMIT is disabled — skipping commit and push."
  fi
  rm -f "$PRE_FIX_STATE"
  PRE_FIX_STATE=""
  _cleanup
  [[ "$FINAL_STATUS" == "stash_conflict" ]] && break

  # Stop after first iteration when auto-commit is off (fixes applied but not committed)
  if [[ "$AUTO_COMMIT" != true ]]; then
    FINAL_STATUS="auto_commit_disabled"
    break
  fi

  # ── i. Post iteration summary as PR comment ─────────────────────
  _post_pr_comment

  echo ""
done

# ── Summary ───────────────────────────────────────────────────────────
SUMMARY_FILE=$(_generate_summary "Review Loop Summary")

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Done. Status: $FINAL_STATUS"
echo " Summary: $SUMMARY_FILE"
echo "═══════════════════════════════════════════════════════"

case "$FINAL_STATUS" in
  all_clear|dry_run|auto_commit_disabled|no_diff|max_iterations_reached) exit 0 ;;
  *) exit 1 ;;
esac
