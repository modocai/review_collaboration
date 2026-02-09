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

# Remove .review-loop/ directory
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  rm -rf "$TARGET_DIR/.review-loop"
  echo "Removed .review-loop/"
else
  echo "No .review-loop/ directory found."
fi

# Remove review-loop entries from .gitignore (only installer-owned block)
GITIGNORE="$TARGET_DIR/.gitignore"
MARKER_NEW="# review-loop (added by installer)"
MARKER_OLD="# AI review logs (added by review-loop installer)"
if [[ -f "$GITIGNORE" ]] && { grep -qxF "$MARKER_NEW" "$GITIGNORE" || grep -qxF "$MARKER_OLD" "$GITIGNORE"; }; then
  TMP_GITIGNORE=$(mktemp)
  awk -v m1="$MARKER_NEW" -v m2="$MARKER_OLD" '
    $0 == m1 || $0 == m2 { skip=1; next }
    skip && /^\.(review-loop\/|ai-review-logs\/|reviewlooprc\.example)$/ { next }
    skip && /^(bin\/|prompts\/)$/ { next }
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
