# Git & PR rules

- NEVER push directly to `main`. NEVER merge a PR — merging is a human decision. Open PRs as **ready for review** (NOT draft): external automated reviewers (Codex) skip drafts, and their findings are part of the convergence loop. The `claude-ready` label on the issue — not the PR's review state — is the signal that work is converged and awaiting the human.
- Branch naming: `claude/issue-<number>-<short-slug>`.
- One issue = one branch = one PR. Do not bundle unrelated changes.
- Every PR description must contain:
  1. `Closes #<issue>` — the issue is the spec; link it.
  2. **What changed** — 3–6 bullets, plain language.
  3. **Evidence** — the actual commands run and their output (test results, build status). Paste output, don't assert success.
  4. **Not done on purpose** — anything in or near scope that was intentionally skipped, and why.
- Circuit breaker: if the same CI check fails 3 consecutive times after your fixes, STOP. Comment your diagnosis and what you tried on the PR, and end the run. Do not keep pushing.
- Never force-push over commits you did not create in the current run.
