#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-.}"

# Ensure target directory exists and resolve to absolute path
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: target directory '$TARGET_DIR' does not exist."
  exit 1
fi
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

if ! command -v perl &>/dev/null; then
  echo "Error: 'perl' is required for uninstall but not found."
  exit 1
fi

echo "Uninstalling review-loop from: $TARGET_DIR"

# Remove .review-loop/ directory
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  rm -rf "$TARGET_DIR/.review-loop"
  echo "Removed .review-loop/"
else
  echo "Nothing to remove: .review-loop/ not found."
fi

# Remove review-loop entry from .gitignore (current marker)
GITIGNORE="$TARGET_DIR/.gitignore"
MARKER="# review-loop (added by installer)"
if [[ -f "$GITIGNORE" ]] && grep -qxF "$MARKER" "$GITIGNORE"; then
  TMP_GITIGNORE=$(mktemp)
  awk -v marker="$MARKER" '
    $0 == marker { skip=1; next }
    skip && /^[[:space:]]*$/ { next }
    skip && /^\.review-loop\/$/ { skip=0; next }
    { skip=0; print }
  ' "$GITIGNORE" > "$TMP_GITIGNORE"
  # Remove trailing blank lines
  perl -0777 -pe 's/\n+\z/\n/' "$TMP_GITIGNORE" > "$GITIGNORE"
  rm -f "$TMP_GITIGNORE"
  echo "Removed review-loop entries from .gitignore"
  # Remove .gitignore if it became empty
  if [[ ! -s "$GITIGNORE" ]]; then
    rm "$GITIGNORE"
    echo "Removed empty .gitignore"
  fi
fi

# Remove legacy .ai-review-logs/ entry from .gitignore
LEGACY_MARKER="# AI review logs (added by review-loop installer)"
if [[ -f "$GITIGNORE" ]] && grep -qxF "$LEGACY_MARKER" "$GITIGNORE"; then
  TMP_GITIGNORE=$(mktemp)
  awk '
    /^# AI review logs \(added by review-loop installer\)$/ { skip=1; next }
    skip && /^[[:space:]]*$/ { next }
    skip && /^\.ai-review-logs\/$/ { skip=0; next }
    { skip=0; print }
  ' "$GITIGNORE" > "$TMP_GITIGNORE"
  # Remove trailing blank lines
  perl -0777 -pe 's/\n+\z/\n/' "$TMP_GITIGNORE" > "$GITIGNORE"
  rm -f "$TMP_GITIGNORE"
  echo "Removed .ai-review-logs/ from .gitignore"
  # Remove .gitignore if it became empty
  if [[ ! -s "$GITIGNORE" ]]; then
    rm "$GITIGNORE"
    echo "Removed empty .gitignore"
  fi
fi

echo "Done. review-loop has been uninstalled."
