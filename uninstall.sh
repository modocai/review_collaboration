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

# Remove installer-owned files inside .review-loop/ (current layout)
if [[ -d "$TARGET_DIR/.review-loop" ]]; then
  # bin/lib/
  if [[ -f "$TARGET_DIR/.review-loop/bin/lib/common.sh" ]]; then
    rm "$TARGET_DIR/.review-loop/bin/lib/common.sh"
    echo "Removed .review-loop/bin/lib/common.sh"
  fi
  rmdir "$TARGET_DIR/.review-loop/bin/lib" 2>/dev/null && echo "Removed empty .review-loop/bin/lib/" || true
  # bin/
  if [[ -f "$TARGET_DIR/.review-loop/bin/review-loop.sh" ]]; then
    rm "$TARGET_DIR/.review-loop/bin/review-loop.sh"
    echo "Removed .review-loop/bin/review-loop.sh"
  fi
  if [[ -f "$TARGET_DIR/.review-loop/bin/refactor-suggest.sh" ]]; then
    rm "$TARGET_DIR/.review-loop/bin/refactor-suggest.sh"
    echo "Removed .review-loop/bin/refactor-suggest.sh"
  fi
  rmdir "$TARGET_DIR/.review-loop/bin" 2>/dev/null && echo "Removed empty .review-loop/bin/" || true
  # prompts/active/
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
  if [[ -f "$TARGET_DIR/.review-loop/.reviewlooprc.example" ]]; then
    rm "$TARGET_DIR/.review-loop/.reviewlooprc.example"
    echo "Removed .review-loop/.reviewlooprc.example"
  fi
  if [[ -f "$TARGET_DIR/.review-loop/.refactorsuggestrc.example" ]]; then
    rm "$TARGET_DIR/.review-loop/.refactorsuggestrc.example"
    echo "Removed .review-loop/.refactorsuggestrc.example"
  fi
  # Remove .review-loop/ only if empty (preserves user-added files)
  rmdir "$TARGET_DIR/.review-loop" 2>/dev/null && echo "Removed empty .review-loop/" || true
fi

# Remove legacy install layout (pre-.review-loop/ consolidation)
_legacy_install=false
if [[ -f "$TARGET_DIR/bin/review-loop.sh" ]] || [[ -d "$TARGET_DIR/prompts/active" ]]; then
  _legacy_install=true
fi
for _bfile in review-loop.sh refactor-suggest.sh; do
  if [[ -f "$TARGET_DIR/bin/$_bfile" ]]; then
    rm "$TARGET_DIR/bin/$_bfile"
    echo "Removed bin/$_bfile"
  fi
done
rmdir "$TARGET_DIR/bin" 2>/dev/null && echo "Removed empty bin/" || true
for _pfile in codex-review.prompt.md claude-fix.prompt.md claude-fix-execute.prompt.md claude-self-review.prompt.md \
  codex-refactor-micro.prompt.md codex-refactor-module.prompt.md codex-refactor-layer.prompt.md codex-refactor-full.prompt.md \
  claude-refactor-fix.prompt.md claude-refactor-fix-execute.prompt.md; do
  if [[ -f "$TARGET_DIR/prompts/active/$_pfile" ]]; then
    rm "$TARGET_DIR/prompts/active/$_pfile"
    echo "Removed prompts/active/$_pfile"
  fi
done
rmdir "$TARGET_DIR/prompts/active" 2>/dev/null && echo "Removed empty prompts/active/" || true
rmdir "$TARGET_DIR/prompts" 2>/dev/null && echo "Removed empty prompts/" || true
# Only remove root .reviewlooprc.example for legacy installs — the current
# installer places it inside .review-loop/ which is already removed above.
if [[ "$_legacy_install" == true ]] && [[ -f "$TARGET_DIR/.reviewlooprc.example" ]]; then
  rm "$TARGET_DIR/.reviewlooprc.example"
  echo "Removed legacy .reviewlooprc.example"
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
