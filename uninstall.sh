#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-.}"

# Ensure target directory exists and resolve to absolute path
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: target directory '$TARGET_DIR' does not exist."
  exit 1
fi
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

## Remove a marker+entry block from .gitignore, clean up if empty.
## Usage: remove_gitignore_block <marker_line> <entry_regex> <label>
remove_gitignore_block() {
  local marker="$1" entry_re="$2" label="$3"
  [[ -f "$GITIGNORE" ]] && grep -qxF "$marker" "$GITIGNORE" || return 0
  local tmp
  tmp=$(mktemp)
  awk -v marker="$marker" -v entry="$entry_re" '
    $0 == marker { skip=1; next }
    skip && /^[[:space:]]*$/ { next }
    skip && $0 ~ entry { skip=0; next }
    { skip=0; print }
  ' "$GITIGNORE" > "$tmp"
  sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$GITIGNORE"
  rm -f "$tmp"
  echo "Removed $label from .gitignore"
  if [[ ! -s "$GITIGNORE" ]]; then
    rm "$GITIGNORE"
    echo "Removed empty .gitignore"
  fi
}

echo "Uninstalling review-loop from: $TARGET_DIR"

# Remove installer-owned files inside .review-loop/ (current layout)
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  # bin/ (entirely installer-owned)
  if [[ -d "$TARGET_DIR/.review-loop/bin" ]]; then
    rm -rf "$TARGET_DIR/.review-loop/bin"
    echo "Removed .review-loop/bin/"
  fi
  # prompts/active/ — only remove known installer files
  for _pfile in codex-review.prompt.md claude-fix.prompt.md claude-fix-execute.prompt.md claude-self-review.prompt.md \
    codex-refactor-micro.prompt.md codex-refactor-module.prompt.md codex-refactor-layer.prompt.md codex-refactor-full.prompt.md \
    claude-refactor-fix.prompt.md claude-refactor-fix-execute.prompt.md; do
    if [[ -f "$TARGET_DIR/.review-loop/prompts/active/$_pfile" ]]; then
      rm "$TARGET_DIR/.review-loop/prompts/active/$_pfile"
      echo "Removed .review-loop/prompts/active/$_pfile"
    fi
  done
  rmdir "$TARGET_DIR/.review-loop/prompts/active" 2>/dev/null && echo "Removed empty .review-loop/prompts/active/" || true
  rmdir "$TARGET_DIR/.review-loop/prompts" 2>/dev/null && echo "Removed empty .review-loop/prompts/" || true
  # logs/ (runtime artifacts)
  if [[ -d "$TARGET_DIR/.review-loop/logs" ]]; then
    rm -rf "$TARGET_DIR/.review-loop/logs"
    echo "Removed .review-loop/logs/"
  fi
  # rc examples
  for _rc in .reviewlooprc.example .refactorsuggestrc.example; do
    if [[ -f "$TARGET_DIR/.review-loop/$_rc" ]]; then
      rm "$TARGET_DIR/.review-loop/$_rc"
      echo "Removed .review-loop/$_rc"
    fi
  done
  # Remove .review-loop/ only if empty (preserves user-added files)
  rmdir "$TARGET_DIR/.review-loop" 2>/dev/null && echo "Removed empty .review-loop/" || true
else
  echo "Nothing to remove: .review-loop/ not found."
fi

# Clean up .gitignore entries
GITIGNORE="$TARGET_DIR/.gitignore"
remove_gitignore_block "# review-loop (added by installer)" '^\\.review-loop/$' "review-loop entries"
remove_gitignore_block "# AI review logs (added by review-loop installer)" '^\\.ai-review-logs/$' ".ai-review-logs/ entry"

echo "Done. review-loop has been uninstalled."
