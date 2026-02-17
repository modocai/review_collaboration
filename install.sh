#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET_DIR="${1:-.}"

# Read version from review-loop.sh
VERSION=$(grep -m1 '^VERSION=' "$SCRIPT_DIR/bin/review-loop.sh" | cut -d'"' -f2)

# Ensure target directory exists and resolve to absolute path
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: target directory '$TARGET_DIR' does not exist."
  exit 1
fi
TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

echo "Installing review-loop v${VERSION} into: $TARGET_DIR/.review-loop/"

INSTALL_DIR="$TARGET_DIR/.review-loop"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/logs/refactor"

# Copy bin/
cp -r "$SCRIPT_DIR/bin" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/review-loop.sh"
chmod +x "$INSTALL_DIR/bin/refactor-suggest.sh"

# Copy active prompts
mkdir -p "$INSTALL_DIR/prompts/active"
cp "$SCRIPT_DIR"/prompts/active/* "$INSTALL_DIR/prompts/active/"

# Copy rc examples
if [[ -f "$SCRIPT_DIR/.reviewlooprc.example" ]]; then
  cp "$SCRIPT_DIR/.reviewlooprc.example" "$INSTALL_DIR/"
  echo "Copied .reviewlooprc.example"
fi
if [[ -f "$SCRIPT_DIR/.refactorsuggestrc.example" ]]; then
  cp "$SCRIPT_DIR/.refactorsuggestrc.example" "$INSTALL_DIR/"
  echo "Copied .refactorsuggestrc.example"
fi

# Add .review-loop/ to .gitignore
GITIGNORE="$TARGET_DIR/.gitignore"
MARKER="# review-loop (added by installer)"
if [[ -f "$GITIGNORE" ]] && grep -qxF ".review-loop/" "$GITIGNORE"; then
  echo "review-loop entry already in .gitignore"
else
  # Ensure file ends with a newline before appending
  if [[ -f "$GITIGNORE" ]] && [[ -s "$GITIGNORE" ]] && [[ "$(tail -c1 "$GITIGNORE")" != "" ]]; then
    echo "" >> "$GITIGNORE"
  fi
  {
    echo "$MARKER"
    echo ".review-loop/"
  } >> "$GITIGNORE"
  echo "Added .review-loop/ to .gitignore"
fi

echo "Done. Run: .review-loop/bin/review-loop.sh -n 3"
