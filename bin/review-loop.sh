#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROMPTS_DIR="$SCRIPT_DIR/../prompts/active"
source "$SCRIPT_DIR/lib/common.sh"

# ── Defaults ──────────────────────────────────────────────────────────
TARGET_BRANCH="develop"
MAX_LOOP=""
MAX_SUBLOOP=4
DRY_RUN=false
AUTO_COMMIT=true

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
    if [[ "$_rc_line" =~ ^[[:space:]]*(TARGET_BRANCH|MAX_LOOP|MAX_SUBLOOP|DRY_RUN|AUTO_COMMIT|PROMPTS_DIR)=[\"\']?([^\"\']*)[\"\']?[[:space:]]*$ ]]; then
      _rc_val="${BASH_REMATCH[2]}"
      _rc_key="${BASH_REMATCH[1]}"
      # Trim trailing whitespace from unquoted values
      _rc_val="${_rc_val%"${_rc_val##*[![:space:]]}"}"
      # Validate boolean values
      if [[ "$_rc_key" == "DRY_RUN" || "$_rc_key" == "AUTO_COMMIT" ]]; then
        if [[ "$_rc_val" != "true" && "$_rc_val" != "false" ]]; then
          echo "Error: $_rc_key must be 'true' or 'false', got '$_rc_val'." >&2
          exit 1
        fi
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
      TARGET_BRANCH="$2"; shift 2 ;;
    -n|--max-loop)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      MAX_LOOP="$2"; shift 2 ;;
    --max-subloop)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      MAX_SUBLOOP="$2"; shift 2 ;;
    --no-self-review)  MAX_SUBLOOP=0; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --no-dry-run)      DRY_RUN=false; shift ;;
    --no-auto-commit)  AUTO_COMMIT=false; shift ;;
    --auto-commit)     AUTO_COMMIT=true; shift ;;
    -V|--version) echo "review-loop v$VERSION"; exit 0 ;;
    -h|--help)    usage ;;
    *)            echo "Error: unknown option '$1'"; usage 1 ;;
  esac
done

if [[ -z "$MAX_LOOP" ]]; then
  echo "Error: -n / --max-loop is required."
  echo ""
  usage 1
fi

if ! [[ "$MAX_LOOP" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --max-loop must be a positive integer, got '$MAX_LOOP'."
  exit 1
fi

if ! [[ "$MAX_SUBLOOP" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "Error: --max-subloop must be a non-negative integer (no leading zeros), got '$MAX_SUBLOOP'."
  exit 1
fi

# ── Prerequisite checks ──────────────────────────────────────────────
check_cmd git
check_cmd codex
if [[ "$DRY_RUN" == false ]]; then
  check_cmd claude
fi
check_cmd jq
check_cmd envsubst
check_cmd perl

if [[ "$HAS_GH" == false ]]; then
  echo "Warning: 'gh' is not installed — PR commenting will be disabled."
fi


# Generate summary.md from iteration logs.
# Reads globals: LOG_DIR, CURRENT_BRANCH, TARGET_BRANCH, MAX_LOOP, FINAL_STATUS
_generate_summary() {
  local SUMMARY_FILE="$LOG_DIR/summary.md"
  {
    echo "# Review Loop Summary"
    echo ""
    echo "- **Branch**: $CURRENT_BRANCH → $TARGET_BRANCH"
    echo "- **Max iterations**: $MAX_LOOP"
    echo "- **Final status**: $FINAL_STATUS"
    echo "- **Timestamp**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "## Iteration Logs"
    echo ""
    local f iter count verdict sf sub_iter sr_count sr_verdict
    for f in "$LOG_DIR"/review-*.json; do
      [[ -e "$f" ]] || continue
      iter=$(basename "$f" | sed 's/review-//;s/.json//')
      count=$(jq '.findings | length' "$f" 2>/dev/null || echo "?")
      verdict=$(jq -r '.overall_correctness' "$f" 2>/dev/null || echo "?")
      echo "- **Iteration $iter**: $count findings, verdict: $verdict"
      for sf in "$LOG_DIR"/self-review-"${iter}"-*.json; do
        [[ -e "$sf" ]] || continue
        sub_iter=$(basename "$sf" | sed "s/self-review-${iter}-//;s/.json//")
        sr_count=$(jq '.findings | length' "$sf" 2>/dev/null || echo "?")
        sr_verdict=$(jq -r '.overall_correctness' "$sf" 2>/dev/null || echo "?")
        echo "  - Sub-iteration $sub_iter: $sr_count findings, verdict: $sr_verdict"
      done
    done
  } > "$SUMMARY_FILE"
  printf '%s' "$SUMMARY_FILE"
}

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not inside a git repository."
  exit 1
fi

if ! git rev-parse --verify "$TARGET_BRANCH" &>/dev/null; then
  echo "Error: target branch '$TARGET_BRANCH' does not exist."
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ── Clean working tree check ────────────────────────────────────────
# Allow .gitignore/.reviewlooprc to be dirty — the installer modifies .gitignore
# and the user may have an untracked .reviewlooprc.  Pre-existing dirty files
# are snapshot-ed before each fix and excluded from commits (see step h).
_dirty_non_gitignore=$(git diff --name-only | grep -v -E '^(\.gitignore|\.reviewlooprc)$' || true)
_untracked_non_gitignore=$(git ls-files --others --exclude-standard | grep -v -E '^(\.gitignore|\.reviewlooprc)$' || true)
_staged_non_gitignore=$(git diff --cached --name-only | grep -v -E '^(\.gitignore|\.reviewlooprc)$' || true)
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
rm -f "$LOG_DIR"/review-*.json "$LOG_DIR"/fix-*.md "$LOG_DIR"/opinion-*.md "$LOG_DIR"/self-review-*.json "$LOG_DIR"/refix-*.md "$LOG_DIR"/refix-opinion-*.md "$LOG_DIR"/summary.md

export CURRENT_BRANCH TARGET_BRANCH

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

echo "═══════════════════════════════════════════════════════"
echo " Review Loop: $CURRENT_BRANCH → $TARGET_BRANCH"
echo " Max iterations: $MAX_LOOP | Sub-loops: $MAX_SUBLOOP | Dry-run: $DRY_RUN"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Pre-loop validation ───────────────────────────────────────────────
if [[ "$DRY_RUN" == false ]] && [[ ! -f "$PROMPTS_DIR/claude-fix-execute.prompt.md" ]]; then
  echo "Error: required prompt not found: $PROMPTS_DIR/claude-fix-execute.prompt.md" >&2
  exit 1
fi
if [[ "$MAX_SUBLOOP" -gt 0 ]] && [[ ! -f "$PROMPTS_DIR/claude-self-review.prompt.md" ]]; then
  echo "Warning: self-review prompt not found at $PROMPTS_DIR/claude-self-review.prompt.md — disabling self-review."
  MAX_SUBLOOP=0
fi

# ── Cleanup trap ──────────────────────────────────────────────────────
# Restore allowlisted stash on any exit (set -e, signals, etc.) so that
# user-local .gitignore/.reviewlooprc edits are never stranded.
_cleanup_stash() {
  if [[ "${_allowed_dirty_stashed:-false}" == true ]]; then
    if ! git stash pop --index --quiet 2>/dev/null; then
      if ! git stash pop --quiet 2>/dev/null; then
        echo "  Error: failed to restore stashed .gitignore/.reviewlooprc edits. Check 'git stash list'." >&2
        FINAL_STATUS="stash_conflict"
      fi
    fi
    _allowed_dirty_stashed=false
  fi
}
trap _cleanup_stash EXIT

# ── Loop ──────────────────────────────────────────────────────────────
FINAL_STATUS="max_iterations_reached"

for (( i=1; i<=MAX_LOOP; i++ )); do
  echo "───────────────────────────────────────────────────────"
  echo " Iteration $i / $MAX_LOOP"
  echo "───────────────────────────────────────────────────────"

  export ITERATION="$i"

  # ── a. Check diff ───────────────────────────────────────────────
  if git diff --quiet "$TARGET_BRANCH...$CURRENT_BRANCH"; then
    echo "No diff between $TARGET_BRANCH and $CURRENT_BRANCH. Nothing to review."
    FINAL_STATUS="no_diff"
    break
  fi

  # ── c. Codex review ──────────────────────────────────────────────
  echo "[$(date +%H:%M:%S)] Running Codex review..."
  REVIEW_FILE="$LOG_DIR/review-${i}.json"
  rm -f "$REVIEW_FILE"

  REVIEW_PROMPT=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION' < "$PROMPTS_DIR/codex-review.prompt.md")

  if ! codex exec \
    --sandbox read-only \
    -o "$REVIEW_FILE" \
    "$REVIEW_PROMPT" 2>&1; then
    echo "Error: Codex review failed (iteration $i). Skipping this iteration."
    FINAL_STATUS="codex_error"
    break
  fi

  # ── d. Extract JSON from response ────────────────────────────────
  _rc=0
  REVIEW_JSON=$(_extract_json_from_file "$REVIEW_FILE") || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    if [[ $_rc -eq 2 ]]; then
      echo "Warning: review output file not found ($REVIEW_FILE). Codex may have failed."
    else
      echo "Warning: could not parse review output as JSON. Saving raw output."
    fi
    echo "  See $REVIEW_FILE for details."
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

  # ── Stash allowed dirty files (.gitignore/.reviewlooprc) ─────────
  # These files may be dirty from the installer or user edits.  Stash them
  # before snapshotting so they are excluded from Claude's commit even if
  # Claude happens to modify the same file.
  _allowed_dirty_stashed=false
  _allowed_dirty_files=()
  for _adf in .gitignore .reviewlooprc; do
    if git diff --name-only | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')" \
    || git diff --cached --name-only | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')" \
    || git ls-files --others --exclude-standard | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')"; then
      _allowed_dirty_files+=("$_adf")
    fi
  done
  if [[ ${#_allowed_dirty_files[@]} -gt 0 ]]; then
    git stash push --quiet --include-untracked -- "${_allowed_dirty_files[@]}" 2>/dev/null && _allowed_dirty_stashed=true
  fi

  # ── Snapshot pre-fix working tree state ──────────────────────────
  PRE_FIX_STATE=$(_snapshot_worktree)

  # ── g. Claude fix (two-step: opinion → execute) ─────────────────
  FIX_FILE="$LOG_DIR/fix-${i}.md"
  OPINION_FILE="$LOG_DIR/opinion-${i}.md"

  if ! _claude_two_step_fix "$REVIEW_JSON" "$OPINION_FILE" "$FIX_FILE" "fix"; then
    FINAL_STATUS="claude_error"
    rm -f "$PRE_FIX_STATE"
    _cleanup_stash
    break
  fi

  # ── g2. Claude self-review sub-loop ─────────────────────────────
  SELF_REVIEW_SUMMARY=""
  ORIGINAL_REVIEW_JSON="$REVIEW_JSON"
  if [[ "$MAX_SUBLOOP" -gt 0 ]]; then
    for (( j=1; j<=MAX_SUBLOOP; j++ )); do
      # Check if Claude's fix produced any changes vs pre-fix snapshot
      if ! _fix_files_tmp=$(_changed_files_since_snapshot "$PRE_FIX_STATE"); then
        echo "  No working tree changes from fix — skipping self-review."
        break
      fi

      echo "[$(date +%H:%M:%S)] Running Claude self-review (sub-iteration $j/$MAX_SUBLOOP)..."
      SELF_REVIEW_FILE="$LOG_DIR/self-review-${i}-${j}.json"

      # Dump diff for only files changed by the fix (exclude pre-existing dirty files)
      # Stage untracked files as intent-to-add so git diff HEAD can see them
      xargs -0 git add --intent-to-add -- < "$_fix_files_tmp" 2>/dev/null || true
      export DIFF_FILE="$LOG_DIR/diff-${i}-${j}.diff"
      xargs -0 git diff HEAD -- < "$_fix_files_tmp" > "$DIFF_FILE"
      # Immediately undo intent-to-add so we never clobber pre-existing staged state
      xargs -0 git reset --quiet -- < "$_fix_files_tmp" 2>/dev/null || true
      rm -f "$_fix_files_tmp"

      # Ensure self-review prompt always references the original Codex findings
      export REVIEW_JSON="$ORIGINAL_REVIEW_JSON"
      SELF_REVIEW_PROMPT=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION $REVIEW_JSON $DIFF_FILE' < "$PROMPTS_DIR/claude-self-review.prompt.md")

      # Claude self-review — tool access for git diff, file reading, etc.
      if ! printf '%s' "$SELF_REVIEW_PROMPT" | claude -p - \
        --allowedTools "Read,Glob,Grep" \
        > "$SELF_REVIEW_FILE" 2>&1; then
        echo "  Warning: self-review failed (sub-iteration $j). Continuing with current fixes."
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: self-review failed\n"
        break
      fi

      # JSON parsing (same logic as codex review)
      if [[ ! -s "$SELF_REVIEW_FILE" ]]; then
        echo "  Warning: self-review produced empty output (sub-iteration $j). Continuing with current fixes."
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: empty output\n"
        break
      fi
      _rc=0
      SELF_REVIEW_JSON=$(_extract_json_from_file "$SELF_REVIEW_FILE") || _rc=$?
      if [[ $_rc -ne 0 ]]; then
        if [[ $_rc -eq 2 ]]; then
          echo "  Warning: self-review output file not found ($SELF_REVIEW_FILE)."
        else
          echo "  Warning: could not parse self-review output."
        fi
        echo "  Continuing with current fixes."
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: parse error\n"
        break
      fi

      SR_FINDINGS=$(printf '%s' "$SELF_REVIEW_JSON" | jq '.findings | length')
      SR_OVERALL=$(printf '%s' "$SELF_REVIEW_JSON" | jq -r '.overall_correctness')
      echo "  Self-review: $SR_FINDINGS findings | $SR_OVERALL"

      if [[ "$SR_FINDINGS" -eq 0 ]] && [[ "$SR_OVERALL" == "patch is correct" ]]; then
        echo "  Self-review passed — fixes are clean."
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: 0 findings — passed\n"
        break
      fi

      # Claude re-fix (two-step: opinion → execute)
      REFIX_FILE="$LOG_DIR/refix-${i}-${j}.md"
      REFIX_OPINION_FILE="$LOG_DIR/refix-opinion-${i}-${j}.md"

      if ! _claude_two_step_fix "$SELF_REVIEW_JSON" "$REFIX_OPINION_FILE" "$REFIX_FILE" "re-fix"; then
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: $SR_FINDINGS findings — re-fix failed\n"
        break
      fi
      SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: $SR_FINDINGS findings — re-fixed\n"
    done
  fi
  export REVIEW_JSON="$ORIGINAL_REVIEW_JSON"

  # ── h. Commit & push fixes ──────────────────────────────────────
  if [[ "$AUTO_COMMIT" == true ]]; then
    COMMIT_MSG="fix(ai-review): apply iteration $i fixes

Auto-generated by review-loop.sh (iteration $i/$MAX_LOOP)"
    if [[ -n "$SELF_REVIEW_SUMMARY" ]]; then
      COMMIT_MSG="${COMMIT_MSG}
Self-review: $(printf '%b' "$SELF_REVIEW_SUMMARY" | tr '\n' '; ' | sed 's/; $//')"
    fi
    _commit_and_push "$PRE_FIX_STATE" "$COMMIT_MSG" "$CURRENT_BRANCH" || true
  else
    echo "  AUTO_COMMIT is disabled — skipping commit and push."
  fi
  rm -f "$PRE_FIX_STATE"
  _cleanup_stash
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
SUMMARY_FILE=$(_generate_summary)

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Done. Status: $FINAL_STATUS"
echo " Summary: $SUMMARY_FILE"
echo "═══════════════════════════════════════════════════════"
