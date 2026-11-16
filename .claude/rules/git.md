# Git & PR rules

- NEVER push directly to `main`. NEVER merge a PR — merging is a human decision.
- Branch naming: `claude/<short-slug>`, or `claude/issue-<number>-<short-slug>` when the work has an issue.
- One issue or task = one branch = one PR. Do not bundle unrelated changes.
- Every PR description must contain:
  1. `Closes #<issue>` when the work has an issue.
  2. **What changed** — 3–6 bullets, plain language.
  3. **Evidence** — the actual commands run and their output (test results, build status). Paste output, don't assert success.
  4. **Not done on purpose** — anything in or near scope that was intentionally skipped, and why.
- Never force-push over commits you did not create.
