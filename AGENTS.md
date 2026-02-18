## Pull Request Rules

Every PR must pass the review loop (`review-loop.sh --dry-run`) before merging. No exceptions. We eat our own dog food — if Mr. Overkill can't approve it, neither can you.

## Branch Rules

Always commit and push before ending work on any branch other than develop.
Never commit directly to `main` or `develop`, nor force push to them. All changes must go through branch → PR → review before merge.

## Commit Messages

Principles:
- Write the subject in English, capturing the motivation/context of the change
- Keep conventional commit prefixes (fix, feat, refactor, etc.)
- Add a detailed body after a blank line if needed
