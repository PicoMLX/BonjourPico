---
name: verification
description: How to verify work and prove it with evidence before claiming anything is done. Use this EVERY time you are about to say a task, fix, feature, or PR is complete, working, fixed, or passing — in interactive sessions, subagents, and routines. Also use when writing the Evidence section of a PR description.
---

# Verification

Core rule: **show evidence, don't assert success.** "Tests pass" is a claim; pasted test output is evidence. Every completion claim must be backed by the command you ran and what it returned.

## Standard verification

1. Run `.claude/scripts/checks.sh --clean` for pre-PR evidence (tool-native clean, then build/test/lint — incremental build state can mask failures). Plain `checks.sh` is fine for mid-iteration checks.
2. Paste the tail of its output (result lines, counts, timing) wherever you report completion — chat, PR description, or issue comment.
3. If any step was skipped (e.g., no simulator available in this environment), say so explicitly instead of implying full verification.

## UI changes (apps, views, components)

Never report a UI change as complete based on a successful edit or build alone. Verify it the way a human reviewer would:
- Run the app / preview and exercise the changed flow, or
- If the environment can't run a UI, state exactly that: "Built successfully; visual verification not possible in this environment — needs a human look at <screen>."
- Include what you checked: states (empty/loading/error), light/dark, dynamic type if relevant.

## New behavior

- Point to the specific test(s) that cover it. The cleanest fail-before proof is test-first: write the test, run it, show the failure output, then implement. If the test was written after the code, checking out the parent commit in a THROWAWAY `git worktree` and running the test there is acceptable. Never use `git stash` for this in an automated tree — stash conflicts with untracked/generated files can corrupt in-progress work. If neither is safely reproducible, say the proof was skipped rather than faking it.

## PR completion claims

Before claiming a PR is done, apply the pr-iteration skill's completion consistency check: checks must be COMPLETED (not merely started) for the CURRENT head SHA — re-read the SHA after collecting status; if it changed, re-verify.

## Quantify wherever possible

Prefer checks that produce numbers or binary outcomes: N tests passed, 0 lint warnings, build succeeded in Ns. The more quantitative the check, the more trustworthy the self-verification.
