#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-.}"

# Resolve to absolute path
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

echo "Uninstalling review-loop from: $TARGET_DIR"

# Remove bin/review-loop.sh
if [[ -f "$TARGET_DIR/bin/review-loop.sh" ]]; then
  rm "$TARGET_DIR/bin/review-loop.sh"
  echo "Removed bin/review-loop.sh"
  # Remove bin/ if empty
  rmdir "$TARGET_DIR/bin" 2>/dev/null && echo "Removed empty bin/" || true
fi

# Remove prompts/active/
if [[ -d "$TARGET_DIR/prompts/active" ]]; then
  rm -rf "$TARGET_DIR/prompts/active"
  echo "Removed prompts/active/"
  # Remove prompts/ if empty
  rmdir "$TARGET_DIR/prompts" 2>/dev/null && echo "Removed empty prompts/" || true
fi

# Remove .reviewlooprc.example
if [[ -f "$TARGET_DIR/.reviewlooprc.example" ]]; then
  rm "$TARGET_DIR/.reviewlooprc.example"
  echo "Removed .reviewlooprc.example"
fi

# Remove .ai-review-logs/ entry from .gitignore
GITIGNORE="$TARGET_DIR/.gitignore"
if [[ -f "$GITIGNORE" ]] && grep -qF '.ai-review-logs/' "$GITIGNORE"; then
  # Remove the comment line and the entry
  sed -i '' '/^# AI review logs$/d' "$GITIGNORE"
  sed -i '' '/^\.ai-review-logs\/$/d' "$GITIGNORE"
  # Remove trailing blank lines
  sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$GITIGNORE"
  echo "Removed .ai-review-logs/ from .gitignore"
fi

echo "Done. review-loop has been uninstalled."
