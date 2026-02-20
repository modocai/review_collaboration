#!/usr/bin/env bats
# Tests for refactor-suggest.sh --with-review / --with-review-loops flags.

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../bin/refactor-suggest.sh"

teardown() {
  _teardown_temp_repo
  _teardown_mock_bin
}

# ═════════════════════════════════════════════════════════════════════
# A. Help / Usage  (no external tools required)
# ═════════════════════════════════════════════════════════════════════

@test "--help shows --with-review flag" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-review "* ]]
}

@test "--help shows --with-review-loops flag" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-review-loops"* ]]
}

@test "--help shows flow step 9" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"(--with-review) Run review-loop"* ]]
}

# ═════════════════════════════════════════════════════════════════════
# B. Validation errors  (no external tools required)
# ═════════════════════════════════════════════════════════════════════

@test "--with-review-loops 0 fails validation" {
  run bash "$SCRIPT" --with-review-loops 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

@test "--with-review-loops -1 fails validation" {
  run bash "$SCRIPT" --with-review-loops -1
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

@test "--with-review-loops abc fails validation" {
  run bash "$SCRIPT" --with-review-loops abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

@test "--with-review-loops without argument fails" {
  run bash "$SCRIPT" --with-review-loops
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

# ═════════════════════════════════════════════════════════════════════
# C. RC file tests  (temp git repo)
# ═════════════════════════════════════════════════════════════════════

@test "rc file WITH_REVIEW=maybe rejected" {
  _setup_temp_repo
  echo 'WITH_REVIEW=maybe' > "$TEMP_REPO/.refactorsuggestrc"

  # RC validation error goes to stderr, so redirect
  run bash -c "cd '$TEMP_REPO' && bin/refactor-suggest.sh --help 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WITH_REVIEW must be 'true' or 'false'"* ]]
}

@test "rc file WITH_REVIEW=true accepted" {
  _setup_temp_repo
  echo 'WITH_REVIEW=true' > "$TEMP_REPO/.refactorsuggestrc"

  # Should pass RC parsing and exit 0 via --help
  run bash -c "cd '$TEMP_REPO' && bin/refactor-suggest.sh --help 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WITH_REVIEW must be"* ]]
}

@test "rc file REVIEW_LOOPS=0 rejected" {
  _setup_temp_repo
  echo 'REVIEW_LOOPS=0' > "$TEMP_REPO/.refactorsuggestrc"

  # REVIEW_LOOPS is validated after arg parsing (general validation section)
  run bash -c "cd '$TEMP_REPO' && bin/refactor-suggest.sh 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

@test "rc file REVIEW_LOOPS=abc rejected" {
  _setup_temp_repo
  echo 'REVIEW_LOOPS=abc' > "$TEMP_REPO/.refactorsuggestrc"

  run bash -c "cd '$TEMP_REPO' && bin/refactor-suggest.sh 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

# ═════════════════════════════════════════════════════════════════════
# D. Dry-run integration tests  (codex/jq/envsubst/perl needed → skip)
# ═════════════════════════════════════════════════════════════════════

@test "--with-review --dry-run shows review-loop enabled in banner" {
  _require_cmd jq
  _require_cmd envsubst
  _require_cmd perl
  _setup_temp_repo
  _setup_mock_bin codex

  run bash -c "cd '$TEMP_REPO' && PATH='$MOCK_BIN:$PATH' bin/refactor-suggest.sh --with-review --dry-run 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review-loop: enabled (4 iterations)"* ]]
}

@test "--with-review-loops 2 --dry-run shows correct iteration count" {
  _require_cmd jq
  _require_cmd envsubst
  _require_cmd perl
  _setup_temp_repo
  _setup_mock_bin codex

  run bash -c "cd '$TEMP_REPO' && PATH='$MOCK_BIN:$PATH' bin/refactor-suggest.sh --with-review-loops 2 --dry-run 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review-loop: enabled (2 iterations)"* ]]
}

@test "--with-review --dry-run shows skip message" {
  _require_cmd jq
  _require_cmd envsubst
  _require_cmd perl
  _setup_temp_repo
  _setup_mock_bin codex

  run bash -c "cd '$TEMP_REPO' && PATH='$MOCK_BIN:$PATH' bin/refactor-suggest.sh --with-review --dry-run 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-review skipped in dry-run mode"* ]]
}

@test "--with-review implies --create-pr (gh check fires)" {
  _require_cmd jq
  _require_cmd envsubst
  _require_cmd perl
  # This test only works when gh is NOT available in PATH
  command -v gh &>/dev/null && skip "gh is available; cannot test missing-gh scenario"

  _setup_temp_repo
  _setup_mock_bin codex claude   # no gh mock

  run bash -c "cd '$TEMP_REPO' && PATH='$MOCK_BIN:$PATH' bin/refactor-suggest.sh --with-review 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--create-pr requires 'gh' CLI"* ]]
}
