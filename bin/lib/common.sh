#!/usr/bin/env bash
# Shared utilities for mr-overkill scripts.
# Usage: source "$SCRIPT_DIR/lib/common.sh"
# Requires: caller must set -euo pipefail before sourcing.

[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ── Prerequisites ────────────────────────────────────────────────────
check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: '$1' is not installed or not in PATH."
    exit 1
  fi
}

# ── gh CLI detection ─────────────────────────────────────────────────
HAS_GH=true
if ! command -v gh &>/dev/null; then
  HAS_GH=false
fi

# ── UUID ─────────────────────────────────────────────────────────────
# UUID generator with fallback chain: uuidgen → /proc → python3
_gen_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v python3 &>/dev/null; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    # Last resort: build a valid v4 UUID from $RANDOM (15-bit each)
    printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
      $RANDOM $RANDOM $RANDOM $(( RANDOM & 0x0FFF )) \
      $(( (RANDOM & 0x3FFF) | 0x8000 )) $RANDOM $RANDOM $RANDOM
  fi
}

# ── Git Utilities ────────────────────────────────────────────────────
# NUL-separated unique list of dirty/untracked files
_git_all_dirty_nul() {
  { git diff -z --name-only; git diff -z --cached --name-only; git ls-files -z --others --exclude-standard; } \
    | perl -0 -e 'my %seen; while (defined(my $l = <>)) { chomp $l; print "$l\0" unless $seen{$l}++ }'
}

# ── Allowlisted Dirty-File Stash ──────────────────────────────────────
# Stash specific allowlisted files if they are dirty/untracked.
# Usage: _stash_allowlisted FILE...
# Returns 0 if files were stashed, 1 if nothing to stash, 2 on stash error.
_stash_allowlisted() {
  local _files=() _f _dirty
  # Collect all dirty/untracked files once (avoids per-file git calls)
  _dirty=$({ git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
  for _f in "$@"; do
    if printf '%s\n' "$_dirty" | grep -qxF "$_f"; then
      _files+=("$_f")
    fi
  done
  if [[ ${#_files[@]} -gt 0 ]]; then
    if ! git stash push --quiet --include-untracked -- "${_files[@]}" 2>/dev/null; then
      return 2
    fi
    return 0
  fi
  return 1
}

# Pop the most recent stash entry (counterpart to _stash_allowlisted).
# Returns 0 on success, 1 on failure.
_unstash_allowlisted() {
  if git stash pop --index --quiet 2>/dev/null; then
    return 0
  fi
  if git stash pop --quiet 2>/dev/null; then
    return 0
  fi
  return 1
}

# ── JSON Parsing ─────────────────────────────────────────────────────
# 3-tier JSON extraction: direct jq → sed fence → perl regex
# $1 = file path; stdout = JSON
# Returns: 0 on success, 2 if file not found, 1 if parse failure
_extract_json_from_file() {
  local _file="$1" _json=""
  if [[ ! -f "$_file" ]]; then
    return 2
  fi
  if jq empty "$_file" 2>/dev/null; then
    cat "$_file"
    return 0
  fi
  _json=$(sed -n '/^```[a-zA-Z]*$/,/^```$/{ /^```/d; p; }' "$_file")
  if [[ -z "$_json" ]] || ! printf '%s' "$_json" | jq empty 2>/dev/null; then
    _json=$(perl -0777 -ne 'print $1 if /(\{.*\})/s' "$_file" 2>/dev/null || true)
  fi
  if [[ -z "$_json" ]] || ! printf '%s' "$_json" | jq empty 2>/dev/null; then
    return 1
  fi
  printf '%s' "$_json"
}

# ── Worktree Snapshots ──────────────────────────────────────────────
# Snapshot every dirty/untracked file's hash+mode into a temp file.
# Prints temp file path to stdout; caller must rm.
_snapshot_worktree() {
  local _snap _f _hash _fmode
  _snap=$(mktemp)
  _git_all_dirty_nul | while IFS= read -r -d '' _f; do
    [[ -n "$_f" ]] || continue
    if [[ -f "$_f" ]]; then
      _hash=$(git hash-object "$_f" 2>/dev/null || echo UNHASHABLE)
      if [[ -x "$_f" ]]; then _fmode="100755"; else _fmode="100644"; fi
      printf '%s\t%s\t%s\n' "$_hash" "$_fmode" "$_f"
    else
      printf 'DELETED\t000000\t%s\n' "$_f"
    fi
  done > "$_snap"
  printf '%s' "$_snap"
}

# Compare current dirty files against a snapshot from _snapshot_worktree.
# $1 = snapshot file path
# Prints temp file (NUL-separated changed file list) path to stdout.
# Returns 1 if no changes detected (temp file is removed in that case).
_changed_files_since_snapshot() {
  local _snap="$1" _out _f _cur_hash _cur_mode _pre_hash _pre_mode
  _out=$(mktemp)
  _git_all_dirty_nul | while IFS= read -r -d '' _f; do
    [[ -n "$_f" ]] || continue
    [[ "$_f" == .review-loop/logs/* ]] && continue
    if [[ -f "$_f" ]]; then
      _cur_hash=$(git hash-object "$_f" 2>/dev/null || echo UNHASHABLE)
      if [[ -x "$_f" ]]; then _cur_mode="100755"; else _cur_mode="100644"; fi
    else
      _cur_hash="DELETED"
      _cur_mode="000000"
    fi
    _pre_hash=$(awk -F'\t' -v f="$_f" '$3 == f { print $1; exit }' "$_snap")
    _pre_mode=$(awk -F'\t' -v f="$_f" '$3 == f { print $2; exit }' "$_snap")
    if [[ -z "$_pre_hash" ]] || [[ "$_cur_hash" != "$_pre_hash" ]] || [[ "$_cur_mode" != "$_pre_mode" ]]; then
      printf '%s\0' "$_f"
    fi
  done > "$_out"
  if [[ ! -s "$_out" ]]; then
    rm -f "$_out"
    return 1
  fi
  printf '%s' "$_out"
}

# ── Claude Two-Step Execution ────────────────────────────────────────
# Two-step Claude fix: opinion (read-only) → execute (edit tools).
# $1 = review JSON, $2 = opinion output file, $3 = fix output file, $4 = label
# $5 = opinion prompt filename (optional, default: claude-fix.prompt.md)
# $6 = execute prompt filename (optional, default: claude-fix-execute.prompt.md)
# Uses globals: CURRENT_BRANCH, TARGET_BRANCH, PROMPTS_DIR (read-only)
# Does not modify global state.
# Returns 1 on failure; caller handles FINAL_STATUS/cleanup.
_claude_two_step_fix() {
  local _rjson="$1" _opinion_file="$2" _fix_file="$3" _label="$4"
  local _opinion_prompt="${5:-claude-fix.prompt.md}"
  local _execute_prompt="${6:-claude-fix-execute.prompt.md}"
  local _session_id _prompt _exec_prompt

  _session_id=$(_gen_uuid)

  _prompt=$(REVIEW_JSON="$_rjson" envsubst '$CURRENT_BRANCH $TARGET_BRANCH $REVIEW_JSON' < "$PROMPTS_DIR/$_opinion_prompt")

  echo "[$(date +%H:%M:%S)] Running Claude $_label (step 1: opinion)..."
  if ! printf '%s' "$_prompt" | claude -p - \
    --session-id "$_session_id" \
    --allowedTools "Read,Glob,Grep" \
    > "$_opinion_file" 2>&1; then
    echo "  Error: Claude $_label opinion failed. See $_opinion_file for details."
    return 1
  fi
  echo "  Opinion saved to $_opinion_file"

  echo "[$(date +%H:%M:%S)] Running Claude $_label (step 2: execute)..."
  _exec_prompt=$(cat "$PROMPTS_DIR/$_execute_prompt")

  if ! printf '%s' "$_exec_prompt" | claude -p - \
    --resume "$_session_id" \
    --allowedTools "Edit,Read,Glob,Grep,Bash" \
    > "$_fix_file" 2>&1; then
    echo "  Error: Claude $_label execute failed. See $_fix_file for details."
    return 1
  fi
  echo "  $_label log saved to $_fix_file"
}

# ── Commit & Push ───────────────────────────────────────────────────
# Commit files changed since a snapshot and push if upstream exists.
# Only files that are newly dirty or have different content vs the snapshot
# are committed, so pre-existing changes (e.g. installer's .gitignore)
# are never swept in.
# $1 = snapshot file, $2 = commit message, $3 = branch name (for push hint)
# Uses globals: none required.
# Returns 0 on commit or if nothing to commit; non-zero on git failure.
_commit_and_push() {
  local _snap="$1" _msg="$2" _branch="${3:-}"
  local _fix_files_nul

  if ! _fix_files_nul=$(_changed_files_since_snapshot "$_snap"); then
    echo "  No file changes after fix — nothing to commit."
    return 0
  fi

  echo "[$(date +%H:%M:%S)] Committing fixes..."
  git reset --quiet --pathspec-from-file="$_fix_files_nul" --pathspec-file-nul HEAD 2>/dev/null || true
  git add --pathspec-from-file="$_fix_files_nul" --pathspec-file-nul
  git commit -m "$_msg" --pathspec-from-file="$_fix_files_nul" --pathspec-file-nul
  rm -f "$_fix_files_nul"
  echo "  Committed."

  # Push to update PR (if remote tracking exists)
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
    echo "[$(date +%H:%M:%S)] Pushing to remote..."
    git push
    echo "  Pushed."
  else
    local _remote
    _remote=$(git remote | grep -m1 '^origin$' || git remote | head -1)
    if [[ -n "$_branch" ]] && [[ -n "$_remote" ]]; then
      echo "[$(date +%H:%M:%S)] Setting upstream and pushing..."
      git push -u "$_remote" "$_branch"
      echo "  Pushed (upstream set)."
    else
      echo "  No upstream/remote set — skipping push."
    fi
  fi
  return 0
}

# ── Resume Helpers ─────────────────────────────────────────────────
# Detect resume state from log directory and git history.
# $1 = log_dir, $2 = commit_pattern (e.g. "fix(ai-review): apply iteration")
# stdout: JSON { "status": "...", "resume_from": N, "reuse_review": bool }
# status: "completed" | "resumable" | "no_logs"
_resume_detect_state() {
  local _log_dir="$1" _commit_pattern="$2"

  # 1) If summary.md exists, check for completed status
  if [[ -f "$_log_dir/summary.md" ]]; then
    local _final_status
    _final_status=$(sed -n 's/.*\*\*Final status\*\*: //p' "$_log_dir/summary.md" | head -1)
    [[ -z "$_final_status" ]] && _final_status="unknown"

    case "$_final_status" in
      all_clear|no_diff|dry_run|max_iterations_reached)
        printf '{"status":"completed","resume_from":0,"reuse_review":false,"prev_status":"%s"}' "$_final_status"
        return 0 ;;
    esac
  fi

  # 2) Find last review file to determine failed iteration
  local _last_i=0 _f _n
  for _f in "$_log_dir"/review-*.json; do
    [[ -e "$_f" ]] || continue
    _n=$(basename "$_f" | sed 's/review-//;s/.json//')
    [[ "$_n" -gt "$_last_i" ]] && _last_i="$_n"
  done

  if [[ "$_last_i" -eq 0 ]]; then
    printf '{"status":"no_logs","resume_from":1,"reuse_review":false}'
    return 0
  fi

  # 3) Check if commit exists for this iteration
  # Trailing space prevents substring matches (e.g. iteration 1 matching 10).
  # Scope to commits after run start to avoid matching previous runs.
  local _log_range="HEAD"
  if [[ -f "$_log_dir/start-commit.txt" ]]; then
    local _start_commit
    _start_commit=$(cat "$_log_dir/start-commit.txt" 2>/dev/null || true)
    if [[ -n "$_start_commit" ]] && git rev-parse --verify "$_start_commit" &>/dev/null; then
      _log_range="${_start_commit}..HEAD"
    fi
  fi
  if git log --oneline --grep="$_commit_pattern ${_last_i} " "$_log_range" 2>/dev/null | grep -q .; then
    # Commit completed → start from next iteration
    printf '{"status":"resumable","resume_from":%d,"reuse_review":false}' $(( _last_i + 1 ))
  else
    # Commit missing → reuse this iteration's review JSON if valid
    local _review_f="$_log_dir/review-${_last_i}.json"
    if [[ -f "$_review_f" ]] && _extract_json_from_file "$_review_f" >/dev/null 2>&1; then
      printf '{"status":"resumable","resume_from":%d,"reuse_review":true}' "$_last_i"
    else
      printf '{"status":"resumable","resume_from":%d,"reuse_review":false}' "$_last_i"
    fi
  fi
}

# Reset working tree to last committed state (clean partial edits).
_resume_reset_working_tree() {
  git reset --quiet HEAD 2>/dev/null || true
  git checkout -- "$(git rev-parse --show-toplevel)" 2>/dev/null || true
  git clean -fd --quiet "$(git rev-parse --show-toplevel)" 2>/dev/null || true
}

# ── Summary Generation ──────────────────────────────────────────────
# Generate summary.md from iteration logs.
# $1 = title (e.g. "Review Loop Summary", "Refactor Suggest Summary")
# Additional lines can be passed as $2..$N and are inserted after the title.
# Uses globals: LOG_DIR, CURRENT_BRANCH, TARGET_BRANCH, MAX_LOOP, FINAL_STATUS
_generate_summary() {
  local _title="$1"; shift
  local SUMMARY_FILE="$LOG_DIR/summary.md"
  {
    echo "# $_title"
    echo ""
    local _extra
    for _extra in "$@"; do
      echo "$_extra"
    done
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
