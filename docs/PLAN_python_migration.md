# Python Migration Roadmap

> Tracking issue: [#34](https://github.com/modocai/mr-overkill/issues/34)

## Background & Motivation

Mr. Overkill's review loop (`bin/review-loop.sh`) has grown to **5,628 lines across 9 shell scripts** containing **43 functions**. After multiple rounds of self-review (the tool reviewing its own code), recurring bug patterns have emerged — nearly all rooted in shell's inherent limitations:

| Problem | Example | Root Cause |
|---------|---------|------------|
| JSON parsing fragility | `jq empty` returns 0 on empty input | No native data structures |
| Temporary file leaks | trap-based cleanup misses edge cases | Manual resource management |
| O(n²) snapshot comparison | awk double-scan in `_changed_files_since_snapshot` | No dict/set data structures |
| String/path pitfalls | NUL-delimited parsing, tabs in paths | Shell word splitting |
| **Zero test coverage** | 43 functions, 0 BATS tests | Testing in shell is painful |

The last point is the immediate trigger: PR #59 (retry-with-backoff + resume flag) ships significant logic with no tests. Writing BATS tests now would be throwaway work if we're migrating to Python. Better to invest in pytest from the start.

## Current Architecture

```
bin/
├── review-loop.sh          554 lines   Main review loop
├── refactor-suggest.sh     715 lines   Refactoring suggestion loop
├── lib/
│   ├── common.sh           438 lines   Shared utilities (17 functions)
│   ├── retry.sh            260 lines   Retry with backoff (7 functions)
│   ├── check-claude-limit.sh 297 lines Claude budget checks (5 functions)
│   ├── check-codex-limit.sh  248 lines Codex budget checks (5 functions)
│   └── self-review.sh      429 lines   Self-review subloop (2 functions)
├── install.sh               72 lines
└── uninstall.sh            101 lines
                          ─────────
                          3,114 lines (lib + entry scripts)
```

### Dependency Graph

```
review-loop.sh ──┬── common.sh ──── retry.sh
                 │                    ├── check-claude-limit.sh
                 │                    └── check-codex-limit.sh
                 └── self-review.sh ── common.sh

refactor-suggest.sh ── common.sh ── (same as above)
```

## Function Classification

### Pure Functions (3) — no side effects

| Function | File | Line | Description |
|----------|------|------|-------------|
| `_classify_cli_error` | retry.sh | 19 | CLI error → transient/permanent/unknown |
| `_codex_limit_parse_window` | check-codex-limit.sh | 74 | rate_limits window JSON parsing |
| `_sr_inject_refactoring_plan` | self-review.sh | 21 | jq: inject refactoring_plan into output |

### Near-Pure Functions (2) — trivial I/O dependency

| Function | File | Line | Description | I/O Dependency |
|----------|------|------|-------------|----------------|
| `_seconds_until_iso` | retry.sh | 48 | ISO 8601 → seconds remaining | `date` command |
| `_extract_json_from_file` | common.sh | 103 | 3-tier JSON extraction | file read |

### Impure — Retry & Budget (12)

| Function | File | Line | Description |
|----------|------|------|-------------|
| `_retry_claude_cmd` | retry.sh | 165 | Claude CLI retry + exponential backoff |
| `_retry_codex_cmd` | retry.sh | 220 | Codex CLI retry + exponential backoff |
| `_wait_for_budget` | retry.sh | 85 | Poll until budget sufficient |
| `_wait_for_budget_check` | retry.sh | 141 | Tool-specific budget check dispatch |
| `_wait_for_budget_fetch` | retry.sh | 151 | Tool-specific budget JSON fetch |
| `_check_claude_token_budget` | check-claude-limit.sh | 174 | Claude budget status (OAuth → local fallback) |
| `_claude_budget_sufficient` | check-claude-limit.sh | 185 | Scope-based go/no-go decision |
| `_claude_limit_detect_tier` | check-claude-limit.sh | 18 | Subscription tier detection |
| `_claude_limit_oauth` | check-claude-limit.sh | 48 | OAuth-based usage query |
| `_claude_limit_local` | check-claude-limit.sh | 90 | Local JSONL usage estimation |
| `_check_codex_token_budget` | check-codex-limit.sh | 106 | Codex budget status |
| `_codex_budget_sufficient` | check-codex-limit.sh | 143 | Scope-based go/no-go |

### Impure — Git Operations (10)

| Function | File | Line | Description |
|----------|------|------|-------------|
| `_snapshot_worktree` | common.sh | 125 | Hash snapshot of dirty files |
| `_changed_files_since_snapshot` | common.sh | 145 | Diff against snapshot |
| `_git_all_dirty_nul` | common.sh | 60 | NUL-separated dirty file list |
| `_stash_allowlisted` | common.sh | 69 | Selective stash |
| `_unstash_allowlisted` | common.sh | 89 | Stash pop with recovery |
| `_commit_and_push` | common.sh | 232 | Commit changed files + push |
| `_resume_detect_state` | common.sh | 272 | Resume state detection from logs |
| `_resume_reset_working_tree` | common.sh | 334 | Reset to last committed state |
| `sha256` | common.sh | 24 | Portable SHA-256 |
| `_gen_uuid` | common.sh | 43 | UUID generation with fallbacks |

### Impure — Orchestration (9)

| Function | File | Line | Description |
|----------|------|------|-------------|
| `_claude_two_step_fix` | common.sh | 179 | Opinion → execute two-step fix |
| `_generate_summary` | common.sh | 345 | Iteration logs → summary.md |
| `_post_pr_comment` | common.sh | 385 | PR comment via gh CLI |
| `_self_review_subloop` | self-review.sh | 48 | Self-review iteration loop |
| `usage` (review-loop) | review-loop.sh | 76 | Usage display |
| `_cleanup` (review-loop) | review-loop.sh | 276 | Exit trap handler |
| `usage` (refactor-suggest) | refactor-suggest.sh | 88 | Usage display |
| `_cleanup` (refactor-suggest) | refactor-suggest.sh | 392 | Exit trap handler |
| `check_cmd` | common.sh | 16 | Command existence check |

**Totals: 3 pure + 2 near-pure + 12 retry/budget + 10 git + 9 orchestration = 36 unique functions**

> 7 functions (`_codex_limit_find_latest_token_count`, `_codex_limit_ts_to_iso`, `remove_gitignore_block`, etc.) are utility/install functions not part of the core review loop.

## Migration Phases

### Phase 1: Project Setup + Pure Function Migration ([#60](https://github.com/modocai/mr-overkill/issues/60))

**Scope**: Python project scaffolding + 5 pure/near-pure functions

```
src/mr_overkill/
├── __init__.py
├── cli.py            # Click/Typer entry point
├── classify.py       # _classify_cli_error
├── time_utils.py     # _seconds_until_iso
├── json_extract.py   # _extract_json_from_file
├── budget_parse.py   # _codex_limit_parse_window
└── review_inject.py  # _sr_inject_refactoring_plan
```

**Transition strategy**: Each function becomes a CLI subcommand callable from bash:

```bash
# Before (bash)
_classify_cli_error "$exit_code" "$stderr_output"

# After (Python, called from bash)
python3 -m mr_overkill classify-error --exit-code "$exit_code" --stderr "$stderr_output"
```

**Deliverables**:
- `pyproject.toml` with uv
- pytest tests for all 5 functions
- At least 1 bash function replaced with Python CLI call

### Phase 2: Retry & Budget Wrapper Migration ([#61](https://github.com/modocai/mr-overkill/issues/61))

**Scope**: 12 retry/budget functions → Python modules

```
src/mr_overkill/
├── retry.py          # _retry_claude_cmd, _retry_codex_cmd, _wait_for_budget
├── budget/
│   ├── __init__.py
│   ├── claude.py     # Claude budget checks (tier, OAuth, local)
│   └── codex.py      # Codex budget checks
```

**Key improvements**:
- `asyncio` or threading for budget polling (currently blocking `sleep`)
- Structured config objects instead of scattered env vars
- Mock-friendly architecture for testing retry scenarios

**Deliverables**:
- Full retry.sh, check-claude-limit.sh, check-codex-limit.sh replacement
- pytest with mocked subprocess calls
- `.reviewlooprc` compat maintained

### Phase 3: Git Operations Wrapper Migration ([#62](https://github.com/modocai/mr-overkill/issues/62))

**Scope**: 10 git operation functions → Python module

```
src/mr_overkill/
├── git_ops.py        # snapshot, stash, commit, push
├── resume.py         # resume detection + reset
```

**Key improvements**:
- `_snapshot_worktree` + `_changed_files_since_snapshot`: awk O(n²) → `dict` O(1)
- NUL-delimited parsing → native Python lists
- `_resume_detect_state`: returns dataclass instead of raw JSON string
- `subprocess.run` with `capture_output=True` everywhere

**Deliverables**:
- Full common.sh git functions replacement
- pytest with `tmp_path` + `git init` fixtures
- Structured return types (dataclass/TypedDict)

### Phase 4: Orchestration Layer Migration ([#63](https://github.com/modocai/mr-overkill/issues/63))

**Scope**: Main loops + reporting → Python

```
src/mr_overkill/
├── review_loop.py      # Main review loop
├── refactor_suggest.py # Refactor suggestion loop
├── self_review.py      # Self-review subloop
├── reporting.py        # summary.md + PR comment generation
├── two_step_fix.py     # Claude opinion → execute flow
```

**Transition strategy**: bash entry scripts become thin wrappers:

```bash
#!/usr/bin/env bash
# bin/review-loop.sh — thin wrapper
exec python3 -m mr_overkill review-loop "$@"
```

**Deliverables**:
- Complete Python implementation of review loop
- `--dry-run` flag support
- Integration tests with mocked CLI tools
- bash scripts preserved as thin wrappers for backward compatibility

## Testing Strategy ([#64](https://github.com/modocai/mr-overkill/issues/64))

### Framework

- **pytest** as test runner
- **pytest-cov** for coverage reporting
- **pytest-mock** for subprocess/API mocking
- Target: **80%+ coverage** for migrated functions

### Test Patterns by Phase

| Phase | Pattern | Example |
|-------|---------|---------|
| 1 | Unit tests, pure I/O | `assert classify_cli_error(1, "rate limit") == "transient"` |
| 2 | Mock subprocess, time | `mock_run.return_value = CompletedProcess(...)` |
| 3 | tmp_path git fixtures | `git_repo = tmp_path / "repo"; subprocess.run(["git", "init", ...])` |
| 4 | Integration, mock CLIs | Full loop with fake claude/codex binaries on PATH |

### Bash Coexistence Testing

During the transition period, bash functions can be tested via subprocess:

```python
def test_classify_cli_error_bash():
    """Verify Python matches bash behavior."""
    result = subprocess.run(
        ["bash", "-c", "source bin/lib/retry.sh; _classify_cli_error 1 'rate limit exceeded'"],
        capture_output=True, text=True
    )
    assert result.stdout.strip() == "transient"
```

## Tooling

| Tool | Purpose |
|------|---------|
| **uv** | Project management, venv, dependency resolution, script running |
| **pytest** | Test framework |
| **ruff** | Linting + formatting (replaces flake8 + black + isort) |
| **mypy** | Type checking (strict mode) |
| **Python 3.12+** | Minimum version (f-strings, match statements, tomllib) |

## Timeline & Dependencies

```
Phase 1 ──→ Phase 2 ──→ Phase 3 ──→ Phase 4
  (#60)       (#61)       (#62)       (#63)
    │           │           │           │
    └───────────┴───────────┴───────────┘
                    │
              Testing (#64)
              (parallel with each phase)
```

Each phase is a separate PR. Testing is incorporated into each phase PR, not a standalone effort.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Python not available on target system | Require Python 3.12+ in install.sh; most systems already have it |
| Performance regression (Python startup) | Batch CLI calls; keep hot-path operations in single process |
| Behavioral drift during transition | Bash subprocess tests verify parity before switching |
| Scope creep | Strict phase boundaries; each phase is a self-contained PR |

## References

- Parent issue: [#34](https://github.com/modocai/mr-overkill/issues/34)
- Phase 1 — Project setup + pure functions: [#60](https://github.com/modocai/mr-overkill/issues/60)
- Phase 2 — Retry/budget wrappers: [#61](https://github.com/modocai/mr-overkill/issues/61)
- Phase 3 — Git operations: [#62](https://github.com/modocai/mr-overkill/issues/62)
- Phase 4 — Orchestration layer: [#63](https://github.com/modocai/mr-overkill/issues/63)
- Test coverage: [#64](https://github.com/modocai/mr-overkill/issues/64)
- Retry with backoff (completed): [#47](https://github.com/modocai/mr-overkill/issues/47) → [PR #55](https://github.com/modocai/mr-overkill/pull/55)
