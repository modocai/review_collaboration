#!/usr/bin/env bash
# Shared helpers for bats tests.
# Usage: load test_helper   (inside *.bats files)

# ── Skip helpers ─────────────────────────────────────────────────────
# Require a command; skip the current test if missing.
_require_cmd() {
  command -v "$1" &>/dev/null || skip "'$1' not found in PATH"
}

# ── Temp git repo ────────────────────────────────────────────────────
# Create a disposable git repo with:
#   - bin/ copied from the real repo (isolation from real log dirs)
#   - develop branch
#   - dummy prompt files in prompts/active/
# Sets: TEMP_REPO
_setup_temp_repo() {
  TEMP_REPO=$(mktemp -d)
  local _orig_dir
  _orig_dir=$(pwd)

  cd "$TEMP_REPO" || return 1
  git init --quiet
  git config user.email "test@bats.local"
  git config user.name "Bats Test"
  echo "initial" > README.md
  git add README.md
  git commit --quiet -m "initial commit"
  git branch develop

  # Copy bin/ from the real repo so SCRIPT_DIR resolves inside temp repo
  cp -R "$BATS_TEST_DIRNAME/../bin" "$TEMP_REPO/bin"

  # Create dummy prompt files
  mkdir -p "$TEMP_REPO/prompts/active"
  local scope
  for scope in micro module layer full; do
    printf '# dummy codex prompt for %s\n' "$scope" \
      > "$TEMP_REPO/prompts/active/codex-refactor-${scope}.prompt.md"
  done
  local f
  for f in claude-refactor-fix claude-refactor-fix-execute \
           claude-self-review claude-fix claude-fix-execute codex-review; do
    printf '# dummy prompt: %s\n' "$f" \
      > "$TEMP_REPO/prompts/active/${f}.prompt.md"
  done

  cd "$_orig_dir" || return 1
}

# Clean up the temporary repo.
_teardown_temp_repo() {
  if [[ -n "${TEMP_REPO:-}" && -d "${TEMP_REPO:-}" ]]; then
    rm -rf "$TEMP_REPO"
  fi
  TEMP_REPO=""
}

# ── Mock executables ─────────────────────────────────────────────────
# Create lightweight mock commands in a temp directory.
# Usage: _setup_mock_bin codex claude gh ...
# Sets: MOCK_BIN
_setup_mock_bin() {
  MOCK_BIN=$(mktemp -d)

  local cmd
  for cmd in "$@"; do
    case "$cmd" in
      codex)
        cat > "$MOCK_BIN/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock codex — writes canned JSON review to -o target
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      cat > "$2" <<'JSON'
{"findings":[{"title":"mock finding","confidence_score":"high","code_location":{"file_path":"README.md","line_range":{"start":1,"end":1}}}],"overall_correctness":"needs review"}
JSON
      shift 2 ;;
    *) shift ;;
  esac
done
MOCK_EOF
        chmod +x "$MOCK_BIN/codex"
        ;;

      claude)
        cat > "$MOCK_BIN/claude" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "mock claude output"
MOCK_EOF
        chmod +x "$MOCK_BIN/claude"
        ;;

      gh)
        cat > "$MOCK_BIN/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "mock gh output"
MOCK_EOF
        chmod +x "$MOCK_BIN/gh"
        ;;

      *)
        printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/$cmd"
        chmod +x "$MOCK_BIN/$cmd"
        ;;
    esac
  done
}

# Clean up mock bin.
_teardown_mock_bin() {
  if [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN:-}" ]]; then
    rm -rf "$MOCK_BIN"
  fi
  MOCK_BIN=""
}
