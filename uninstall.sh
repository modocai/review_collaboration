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

# Remove .review-loop/ directory
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  rm -rf "$TARGET_DIR/.review-loop"
  echo "Removed .review-loop/"
else
  echo "Nothing to remove: .review-loop/ not found."
fi

# Clean up .gitignore entries
GITIGNORE="$TARGET_DIR/.gitignore"
remove_gitignore_block "# review-loop (added by installer)" '^\\.review-loop/$' "review-loop entries"
remove_gitignore_block "# AI review logs (added by review-loop installer)" '^\\.ai-review-logs/$' ".ai-review-logs/ entry"

echo "Done. review-loop has been uninstalled."
