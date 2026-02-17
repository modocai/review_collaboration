#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROMPTS_DIR="$SCRIPT_DIR/../prompts/active"
source "$SCRIPT_DIR/lib/common.sh"

# ── Defaults ──────────────────────────────────────────────────────────
SCOPE="micro"
TARGET_BRANCH="develop"
MAX_LOOP=""
MAX_SUBLOOP=4
DRY_RUN=false
AUTO_APPROVE=false
CREATE_PR=false

# ── Load .refactorsuggestrc (if present) ──────────────────────────────
REFACTORSUGGESTRC=".refactorsuggestrc"
_GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$_GIT_ROOT" && -f "$_GIT_ROOT/$REFACTORSUGGESTRC" ]]; then
  while IFS= read -r _rc_line || [[ -n "$_rc_line" ]]; do
    [[ -z "$_rc_line" || "$_rc_line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$_rc_line" =~ ^[[:space:]]*(SCOPE|TARGET_BRANCH|MAX_LOOP|MAX_SUBLOOP|DRY_RUN|AUTO_APPROVE|CREATE_PR|PROMPTS_DIR)=[\"\']?([^\"\']*)[\"\']?[[:space:]]*$ ]]; then
      _rc_val="${BASH_REMATCH[2]}"
      _rc_key="${BASH_REMATCH[1]}"
      _rc_val="${_rc_val%"${_rc_val##*[![:space:]]}"}"
      if [[ "$_rc_key" == "DRY_RUN" || "$_rc_key" == "AUTO_APPROVE" || "$_rc_key" == "CREATE_PR" ]]; then
        if [[ "$_rc_val" != "true" && "$_rc_val" != "false" ]]; then
          echo "Error: $_rc_key must be 'true' or 'false', got '$_rc_val'." >&2
          exit 1
        fi
      fi
      if [[ "$_rc_key" == "SCOPE" ]]; then
        case "$_rc_val" in
          micro|module|layer|full) ;;
          *) echo "Error: SCOPE must be one of: micro, module, layer, full. Got '$_rc_val' (in .refactorsuggestrc)." >&2; exit 1 ;;
        esac
      fi
      declare "${_rc_key}=${_rc_val}"
    else
      echo "Warning: ignoring unrecognised .refactorsuggestrc line: $_rc_line" >&2
    fi
  done < "$_GIT_ROOT/$REFACTORSUGGESTRC"
  unset _rc_line _rc_key _rc_val
fi

# Resolve relative PROMPTS_DIR against git root
if [[ -n "$_GIT_ROOT" && "$PROMPTS_DIR" != /* ]]; then
  PROMPTS_DIR="$_GIT_ROOT/$PROMPTS_DIR"
fi
unset _GIT_ROOT

# ── Usage ─────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: refactor-suggest.sh [OPTIONS]

Options:
  --scope <scope>          Refactoring scope: micro|module|layer|full (default: micro)
  -t, --target <branch>    Target branch to base from (default: develop)
  -n, --max-loop <N>       Maximum analysis-fix iterations (required)
  --max-subloop <N>        Maximum self-review sub-iterations per fix (default: 4)
  --no-self-review         Disable self-review (equivalent to --max-subloop 0)
  --dry-run                Run analysis only, do not apply fixes
  --no-dry-run             Force fixes even if .refactorsuggestrc sets DRY_RUN=true
  --auto-approve           Skip interactive confirmation for layer/full scope
  --create-pr              Create a draft PR after completing all iterations
  -V, --version            Show version
  -h, --help               Show this help message

Scopes:
  micro    Function/file-level improvements (low blast radius)
  module   Duplication removal, module boundary cleanup (low-medium)
  layer    Cross-cutting concerns across modules (medium-high)
  full     Architecture redesign (high-critical)

Flow:
  1. Collect source file list (git ls-files)
  2. Codex analyzes codebase for refactoring opportunities
  3. (layer/full) Display plan and wait for confirmation
  4. Claude applies refactoring (two-step: opinion → execute)
  5. Claude self-reviews changes, re-fixes if needed
  6. Auto-commit & push to refactoring branch
  7. Repeat until clean or max iterations
  8. (--create-pr) Create draft PR

Examples:
  refactor-suggest.sh --scope micro -n 3
  refactor-suggest.sh --scope module -n 2 --dry-run
  refactor-suggest.sh --scope layer -n 1 --auto-approve
  refactor-suggest.sh --scope full -n 1 --create-pr
EOF
  exit "${1:-0}"
}

# ── Argument parsing ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      if [[ $# -lt 2 ]]; then echo "Error: '$1' requires an argument."; usage 1; fi
      SCOPE="$2"; shift 2 ;;
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
    --auto-approve)    AUTO_APPROVE=true; shift ;;
    --create-pr)       CREATE_PR=true; shift ;;
    -V|--version) echo "refactor-suggest v$VERSION"; exit 0 ;;
    -h|--help)    usage ;;
    *)            echo "Error: unknown option '$1'"; usage 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────
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
  echo "Error: --max-subloop must be a non-negative integer, got '$MAX_SUBLOOP'."
  exit 1
fi

case "$SCOPE" in
  micro|module|layer|full) ;;
  *) echo "Error: --scope must be one of: micro, module, layer, full. Got '$SCOPE'."; exit 1 ;;
esac

# ── Prerequisite checks ──────────────────────────────────────────────
check_cmd git
check_cmd codex
if [[ "$DRY_RUN" == false ]]; then
  check_cmd claude
fi
check_cmd jq
check_cmd envsubst
check_cmd perl

if [[ "$CREATE_PR" == true ]] && [[ "$HAS_GH" == false ]]; then
  echo "Error: --create-pr requires 'gh' CLI."
  exit 1
fi

# ── Git checks ────────────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not inside a git repository."
  exit 1
fi

if ! git rev-parse --verify "$TARGET_BRANCH" &>/dev/null; then
  echo "Error: target branch '$TARGET_BRANCH' does not exist."
  exit 1
fi

# Clean working tree check (only when applying fixes)
if [[ "$DRY_RUN" == false ]]; then
  _dirty=$(git diff --name-only | grep -v -E '^(\.gitignore|\.refactorsuggestrc)$' || true)
  _untracked=$(git ls-files --others --exclude-standard | grep -v -E '^(\.gitignore|\.refactorsuggestrc)$' || true)
  _staged=$(git diff --cached --name-only | grep -v -E '^(\.gitignore|\.refactorsuggestrc)$' || true)
  if [[ -n "$_dirty" ]] || [[ -n "$_staged" ]] || [[ -n "$_untracked" ]]; then
    echo "Error: working tree is not clean. Commit or stash your changes before running refactor-suggest."
    echo ""
    echo "  git stash        # stash changes"
    echo "  git commit -am …  # or commit them"
    echo ""
    exit 1
  fi
  unset _dirty _staged _untracked
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ── Branch creation ───────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REFACTOR_BRANCH="refactor/${SCOPE}-${TIMESTAMP}"

if [[ "$DRY_RUN" == false ]]; then
  # Stash allowlisted files that may conflict with branch switch
  _needs_stash=false
  if ! git diff --quiet -- .gitignore .refactorsuggestrc 2>/dev/null; then
    _needs_stash=true
    git stash push --quiet -- .gitignore .refactorsuggestrc
  fi

  echo "Creating branch: $REFACTOR_BRANCH (from $TARGET_BRANCH)"
  git checkout -b "$REFACTOR_BRANCH" "$TARGET_BRANCH"

  if [[ "$_needs_stash" == true ]]; then
    git stash pop --quiet
  fi
  unset _needs_stash
  CURRENT_BRANCH="$REFACTOR_BRANCH"
else
  echo "Dry-run mode — staying on $CURRENT_BRANCH"
fi

export CURRENT_BRANCH TARGET_BRANCH

# ── Log directory + source file list ──────────────────────────────────
LOG_DIR="$SCRIPT_DIR/../logs/refactor"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/review-*.json "$LOG_DIR"/fix-*.md "$LOG_DIR"/opinion-*.md \
  "$LOG_DIR"/self-review-*.json "$LOG_DIR"/refix-*.md "$LOG_DIR"/refix-opinion-*.md \
  "$LOG_DIR"/summary.md "$LOG_DIR"/source-files.txt

# Collect source files (respects .gitignore)
SOURCE_FILES_PATH="$LOG_DIR/source-files.txt"
git ls-files > "$SOURCE_FILES_PATH"
SOURCE_COUNT=$(wc -l < "$SOURCE_FILES_PATH" | tr -d ' ')
echo "Collected $SOURCE_COUNT source files into $SOURCE_FILES_PATH"

export SOURCE_FILES_PATH

# ── Prompt validation ─────────────────────────────────────────────────
CODEX_PROMPT_FILE="codex-refactor-${SCOPE}.prompt.md"
if [[ ! -f "$PROMPTS_DIR/$CODEX_PROMPT_FILE" ]]; then
  echo "Error: required prompt not found: $PROMPTS_DIR/$CODEX_PROMPT_FILE" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
  if [[ ! -f "$PROMPTS_DIR/claude-refactor-fix.prompt.md" ]]; then
    echo "Error: required prompt not found: $PROMPTS_DIR/claude-refactor-fix.prompt.md" >&2
    exit 1
  fi
  if [[ ! -f "$PROMPTS_DIR/claude-refactor-fix-execute.prompt.md" ]]; then
    echo "Error: required prompt not found: $PROMPTS_DIR/claude-refactor-fix-execute.prompt.md" >&2
    exit 1
  fi
fi

if [[ "$MAX_SUBLOOP" -gt 0 ]] && [[ ! -f "$PROMPTS_DIR/claude-self-review.prompt.md" ]]; then
  echo "Warning: self-review prompt not found — disabling self-review."
  MAX_SUBLOOP=0
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Refactor Suggest: scope=$SCOPE | branch=$CURRENT_BRANCH → $TARGET_BRANCH"
echo " Max iterations: $MAX_LOOP | Sub-loops: $MAX_SUBLOOP | Dry-run: $DRY_RUN"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Cleanup trap ──────────────────────────────────────────────────────
_allowed_dirty_stashed=false
_cleanup() {
  rm -f "${PRE_FIX_STATE:-}"
  if [[ "${_allowed_dirty_stashed:-false}" == true ]]; then
    if ! git stash pop --index --quiet 2>/dev/null; then
      if ! git stash pop --quiet 2>/dev/null; then
        echo "  Error: failed to restore stashed edits. Check 'git stash list'." >&2
        FINAL_STATUS="stash_conflict"
      fi
    fi
    _allowed_dirty_stashed=false
  fi
}
trap _cleanup EXIT

# ── Loop ──────────────────────────────────────────────────────────────
FINAL_STATUS="max_iterations_reached"

for (( i=1; i<=MAX_LOOP; i++ )); do
  echo "───────────────────────────────────────────────────────"
  echo " Iteration $i / $MAX_LOOP"
  echo "───────────────────────────────────────────────────────"

  export ITERATION="$i"

  # ── a. Codex analysis ────────────────────────────────────────────
  echo "[$(date +%H:%M:%S)] Running Codex refactoring analysis (scope: $SCOPE)..."
  REVIEW_FILE="$LOG_DIR/review-${i}.json"
  rm -f "$REVIEW_FILE"

  REVIEW_PROMPT=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION $SOURCE_FILES_PATH' < "$PROMPTS_DIR/$CODEX_PROMPT_FILE")

  if ! codex exec \
    --sandbox read-only \
    -o "$REVIEW_FILE" \
    "$REVIEW_PROMPT" 2>&1; then
    echo "Error: Codex analysis failed (iteration $i)."
    FINAL_STATUS="codex_error"
    break
  fi

  # ── b. Extract JSON from response ────────────────────────────────
  _rc=0
  REVIEW_JSON=$(_extract_json_from_file "$REVIEW_FILE") || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    if [[ $_rc -eq 2 ]]; then
      echo "Warning: analysis output file not found ($REVIEW_FILE). Codex may have failed."
    else
      echo "Warning: could not parse analysis output as JSON."
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

  # ── c. Check findings ───────────────────────────────────────────
  FINDINGS_COUNT=$(printf '%s' "$REVIEW_JSON" | jq '.findings | length')
  OVERALL=$(printf '%s' "$REVIEW_JSON" | jq -r '.overall_correctness')

  echo "  Findings: $FINDINGS_COUNT | Overall: $OVERALL"

  if [[ "$FINDINGS_COUNT" -eq 0 ]] && [[ "$OVERALL" == "code is clean" ]]; then
    echo "  All clear — no refactoring opportunities found."
    FINAL_STATUS="all_clear"
    break
  fi

  # ── d. Display plan and confirm (layer/full) ─────────────────────
  if [[ "$SCOPE" == "layer" || "$SCOPE" == "full" ]] && [[ "$AUTO_APPROVE" == false ]]; then
    echo ""
    echo "  Refactoring plan:"
    printf '%s' "$REVIEW_JSON" | jq -r '.refactoring_plan | "  Summary: \(.summary)\n  Blast radius: \(.estimated_blast_radius)\n  Steps:", (.steps[] | "    \(.order). \(.description) [\(.files | join(", "))]")'
    echo ""
    read -r -p "  Apply this plan? [y/N] " _confirm
    if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
      echo "  Aborted by user."
      FINAL_STATUS="user_aborted"
      break
    fi
  fi

  # ── e. Dry-run check ────────────────────────────────────────────
  if [[ "$DRY_RUN" == true ]]; then
    echo "  Dry-run mode — skipping fixes."
    FINAL_STATUS="dry_run"
    break
  fi

  # ── Stash allowed dirty files ───────────────────────────────────
  _allowed_dirty_stashed=false
  _allowed_dirty_files=()
  for _adf in .gitignore .refactorsuggestrc; do
    if git diff --name-only | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')" \
    || git diff --cached --name-only | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')" \
    || git ls-files --others --exclude-standard | grep -qx "$(printf '%s' "$_adf" | sed 's/[.[\*^$()+?{|]/\\&/g')"; then
      _allowed_dirty_files+=("$_adf")
    fi
  done
  if [[ ${#_allowed_dirty_files[@]} -gt 0 ]]; then
    git stash push --quiet --include-untracked -- "${_allowed_dirty_files[@]}" 2>/dev/null && _allowed_dirty_stashed=true
  fi

  # ── Snapshot pre-fix working tree state ─────────────────────────
  PRE_FIX_STATE=$(_snapshot_worktree)

  # ── f. Claude fix (two-step: opinion → execute) ─────────────────
  FIX_FILE="$LOG_DIR/fix-${i}.md"
  OPINION_FILE="$LOG_DIR/opinion-${i}.md"

  if ! _claude_two_step_fix "$REVIEW_JSON" "$OPINION_FILE" "$FIX_FILE" "refactor-fix" \
    "claude-refactor-fix.prompt.md" "claude-refactor-fix-execute.prompt.md"; then
    FINAL_STATUS="claude_error"
    _cleanup
    break
  fi

  # ── g. Claude self-review sub-loop ──────────────────────────────
  SELF_REVIEW_SUMMARY=""
  ORIGINAL_REVIEW_JSON="$REVIEW_JSON"
  if [[ "$MAX_SUBLOOP" -gt 0 ]]; then
    for (( j=1; j<=MAX_SUBLOOP; j++ )); do
      if ! _fix_files_tmp=$(_changed_files_since_snapshot "$PRE_FIX_STATE"); then
        echo "  No working tree changes from fix — skipping self-review."
        break
      fi

      echo "[$(date +%H:%M:%S)] Running Claude self-review (sub-iteration $j/$MAX_SUBLOOP)..."
      SELF_REVIEW_FILE="$LOG_DIR/self-review-${i}-${j}.json"

      xargs -0 git add --intent-to-add -- < "$_fix_files_tmp" 2>/dev/null || true
      export DIFF_FILE="$LOG_DIR/diff-${i}-${j}.diff"
      xargs -0 git diff HEAD -- < "$_fix_files_tmp" > "$DIFF_FILE"
      xargs -0 git reset --quiet -- < "$_fix_files_tmp" 2>/dev/null || true
      rm -f "$_fix_files_tmp"

      export REVIEW_JSON="$ORIGINAL_REVIEW_JSON"
      SELF_REVIEW_PROMPT=$(envsubst '$CURRENT_BRANCH $TARGET_BRANCH $ITERATION $REVIEW_JSON $DIFF_FILE' < "$PROMPTS_DIR/claude-self-review.prompt.md")

      if ! printf '%s' "$SELF_REVIEW_PROMPT" | claude -p - \
        --allowedTools "Read,Glob,Grep" \
        > "$SELF_REVIEW_FILE" 2>&1; then
        echo "  Warning: self-review failed (sub-iteration $j). Continuing with current fixes."
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: self-review failed\n"
        break
      fi

      if [[ ! -s "$SELF_REVIEW_FILE" ]]; then
        echo "  Warning: self-review produced empty output (sub-iteration $j)."
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

      REFIX_FILE="$LOG_DIR/refix-${i}-${j}.md"
      REFIX_OPINION_FILE="$LOG_DIR/refix-opinion-${i}-${j}.md"

      if ! _claude_two_step_fix "$SELF_REVIEW_JSON" "$REFIX_OPINION_FILE" "$REFIX_FILE" "re-fix" \
        "claude-refactor-fix.prompt.md" "claude-refactor-fix-execute.prompt.md"; then
        SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: $SR_FINDINGS findings — re-fix failed\n"
        break
      fi
      SELF_REVIEW_SUMMARY="${SELF_REVIEW_SUMMARY}Sub-iteration $j: $SR_FINDINGS findings — re-fixed\n"
    done
  fi
  export REVIEW_JSON="$ORIGINAL_REVIEW_JSON"

  # ── h. Commit & push ────────────────────────────────────────────
  COMMIT_MSG="refactor(ai-$SCOPE): apply iteration $i changes

Auto-generated by refactor-suggest.sh (scope: $SCOPE, iteration $i/$MAX_LOOP)"
  if [[ -n "$SELF_REVIEW_SUMMARY" ]]; then
    COMMIT_MSG="${COMMIT_MSG}
Self-review: $(printf '%b' "$SELF_REVIEW_SUMMARY" | tr '\n' '; ' | sed 's/; $//')"
  fi
  _commit_and_push "$PRE_FIX_STATE" "$COMMIT_MSG" "$CURRENT_BRANCH"

  rm -f "$PRE_FIX_STATE"
  PRE_FIX_STATE=""
  _cleanup
  [[ "$FINAL_STATUS" == "stash_conflict" ]] && break

  echo ""
done

# ── Create draft PR ───────────────────────────────────────────────────
if [[ "$CREATE_PR" == true ]] && [[ "$DRY_RUN" == false ]] && [[ "$FINAL_STATUS" == "max_iterations_reached" ]]; then
  # Ensure branch is pushed
  if ! git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
    echo "[$(date +%H:%M:%S)] Pushing branch to remote..."
    git push -u origin "$CURRENT_BRANCH"
  fi

  echo "[$(date +%H:%M:%S)] Creating draft PR..."
  PR_BODY="## Refactoring: ${SCOPE} scope

Auto-generated by \`refactor-suggest.sh\`.

- **Scope**: ${SCOPE}
- **Iterations**: ${MAX_LOOP}
- **Final status**: ${FINAL_STATUS}"

  if gh pr create --draft \
    --title "refactor($SCOPE): AI-suggested ${SCOPE}-level improvements" \
    --body "$PR_BODY" \
    --base "$TARGET_BRANCH"; then
    echo "  Draft PR created."
  else
    echo "  Warning: failed to create draft PR (non-fatal)."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────
SUMMARY_FILE=$(_generate_summary "Refactor Suggest Summary" "- **Scope**: $SCOPE")

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Done. Status: $FINAL_STATUS"
echo " Summary: $SUMMARY_FILE"
echo "═══════════════════════════════════════════════════════"
