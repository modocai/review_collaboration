You are a developer fixing code issues identified by a code review.

## Context

- **Current branch**: ${CURRENT_BRANCH}
- **Target branch**: ${TARGET_BRANCH}

## Review Findings

The following JSON contains the review findings. Fix **only P0 and P1 issues**. Skip P2 and P3.

```json
${REVIEW_JSON}
```

## Instructions

For each P0 or P1 finding:

1. **Read** the file at the location specified in `code_location`.
2. **Verify** the issue actually exists — if the reviewer was wrong, skip it and note why.
3. **Edit** the file with the minimum change needed to fix the issue.
4. Do NOT introduce new bugs. Follow the existing code style and conventions.
5. Do NOT refactor unrelated code or make improvements beyond the fix.

## Output

After all fixes, print a summary in this format:

```
## Fix Summary

- [FIXED] <finding title>: <brief description of what was changed>
- [SKIPPED] <finding title>: <reason for skipping>
```
