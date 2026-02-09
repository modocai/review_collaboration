#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-.}"

# Ensure target directory exists and resolve to absolute path
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: target directory '$TARGET_DIR' does not exist."
  exit 1
fi
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

echo "Uninstalling review-loop from: $TARGET_DIR"

# Remove .review-loop/ directory (current layout)
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  rm -rf "$TARGET_DIR/.review-loop"
  echo "Removed .review-loop/"
else
  echo "No .review-loop/ directory found."
fi

# Remove legacy install artifacts (pre-.review-loop/ layout)
if [[ -f "$TARGET_DIR/bin/review-loop.sh" ]]; then
  rm "$TARGET_DIR/bin/review-loop.sh"
  echo "Removed legacy bin/review-loop.sh"
  rmdir "$TARGET_DIR/bin" 2>/dev/null && echo "Removed empty bin/" || true
fi
for _pfile in codex-review.prompt.md claude-fix.prompt.md; do
  if [[ -f "$TARGET_DIR/prompts/active/$_pfile" ]]; then
    rm "$TARGET_DIR/prompts/active/$_pfile"
    echo "Removed legacy prompts/active/$_pfile"
  fi
done
rmdir "$TARGET_DIR/prompts/active" 2>/dev/null && echo "Removed empty prompts/active/" || true
rmdir "$TARGET_DIR/prompts" 2>/dev/null && echo "Removed empty prompts/" || true
if [[ -f "$TARGET_DIR/.reviewlooprc.example" ]]; then
  rm "$TARGET_DIR/.reviewlooprc.example"
  echo "Removed legacy .reviewlooprc.example"
fi

# Remove review-loop entries from .gitignore (only installer-owned block)
GITIGNORE="$TARGET_DIR/.gitignore"
MARKER_NEW="# review-loop (added by installer)"
MARKER_OLD="# AI review logs (added by review-loop installer)"
if [[ -f "$GITIGNORE" ]] && { grep -qxF "$MARKER_NEW" "$GITIGNORE" || grep -qxF "$MARKER_OLD" "$GITIGNORE"; }; then
  TMP_GITIGNORE=$(mktemp)
  awk -v m1="$MARKER_NEW" -v m2="$MARKER_OLD" '
    $0 == m1 || $0 == m2 { skip=1; next }
    skip && /^\.(review-loop\/|ai-review-logs\/)$/ { next }
    { skip=0; print }
  ' "$GITIGNORE" > "$TMP_GITIGNORE"
  # Remove trailing blank lines
  sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TMP_GITIGNORE" > "$GITIGNORE"
  rm -f "$TMP_GITIGNORE"
  echo "Removed review-loop entries from .gitignore"
  # Remove .gitignore if it became empty
  if [[ ! -s "$GITIGNORE" ]]; then
    rm "$GITIGNORE"
    echo "Removed empty .gitignore"
  fi
fi

echo "Done. review-loop has been uninstalled."
