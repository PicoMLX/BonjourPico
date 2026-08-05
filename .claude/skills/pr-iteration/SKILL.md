---
name: pr-iteration
description: The playbook for opening, updating, and iterating on a pull request until it is mergeable. Use this whenever you open a PR, respond to CI failures, respond to automated or human review comments, rebase a branch, or are asked to "babysit", "fix", or "get a PR green". Applies in interactive sessions, subagents, and routines alike.
---

# PR iteration loop

Goal state (all must be true before you declare done):
1. A **ready-for-review** PR exists (NOT draft — external reviewers skip drafts) and links its issue (`Closes #N`). `gh pr create` without `--draft`; if a PR somehow exists as draft, promote it with `gh pr ready`.
2. All CI checks are green.
3. Every review comment — including from automated reviewers like Codex — is fixed (commit reference), answered (reasoned reply), or acknowledged (👍 reaction). None ignored.
3b. Never busy-poll and never use fixed sleeps for CI. Use the waiting strategy below.

## Waiting strategy

The single routine or interactive session owns the PR until it converges or
escalates. Strategy order for waiting:
   1. PRIMARY — SUBSCRIBE, if this session has PR-subscription/notification tools: subscribe to the PR's activity (CI results, review comments) and react to each event as it arrives. ALWAYS pair the subscription with a backstop check-in of AT MOST 5 minutes — subscriptions can drop events, and an unattended session that trusts one completely can wait forever. On each backstop wake-up with no events: verify actual PR state before going back to waiting (the event you're waiting for may have been dropped).
   2. If no subscription capability exists: the blocking watch below — it wakes the instant CI completes.
   3. If the blocking watch is unavailable or gets killed: scheduled check-ins alone, interval AT MOST 5 minutes.
   Rule for ANY check-in interval: keep it at most 5 minutes even when Xcode Cloud or automated review is slow. A one-hour check-in is a bug, not patience.

Waiting is done with BLOCKING commands, which cost no tokens and wake the instant something completes:
   - CI: `gh pr checks <pr> --watch --interval 30` — returns when all checks finish. This is the in-session subscription; there is no fixed sleep to tune and CI duration doesn't matter.
   - ZERO CHECKS IS NEVER GREEN. External CI systems (Xcode Cloud, etc.) can take 1-3 minutes to REGISTER after a push. First detect whether the preserved per-repo script supports CI listing with `grep -q -- '--list-ci-checks)' .claude/scripts/checks.sh`. If supported, read the exact required context names from `.claude/scripts/checks.sh --list-ci-checks`; when that list is nonempty, retry `gh pr checks <pr> --json name` every 60s for up to 5 minutes until EVERY configured name is present. One early provider is not sufficient. If the script is from an older scaffold or the configured list is empty, use the single-provider fallback and wait until at least one check registers. Only then start the watch. If the expected set never appears, escalate ("Expected CI checks never registered: ..."), do not declare success.
   - External reviewers (Codex etc.): apply this protocol independently for every head SHA. A submitted review for the current head completes the external-review gate. On the exact `@codex review` request for this head, a 👀 reaction from `chatgpt-codex-connector[bot]` means only "accepted/in progress"; a 👍 from that bot means "completed with no findings" and passes the gate.
     1. If neither completed signal exists 20 minutes after the CURRENT head was pushed, post a PR comment containing exactly `@codex review`. ONCE per head SHA — never repeat for the same head.
     2. Stay subscribed. If 60 minutes pass after that request without either a Codex-bot 👍 or a submitted review, escalate for human intervention: report the head SHA, CI state, request time, and missing review signal on the PR and linked issue, then replace `claude-running` with `claude-blocked`. Do not proceed on internal review alone.
     Do not count 👀, your own request comment, or reactions from other actors as completed review. Never reply to the request comment. A new push resets both deadlines.
   - Guard the watch: if the environment kills long-blocking calls, fall back to `sleep 120` + `gh pr checks` in a loop, still capped by this skill's iteration limits.

4. The PR description contains evidence per `.claude/rules/git.md`.

## Loop procedure

Track an iteration counter. **Hard cap: 8 iterations.** On hitting the cap, or on the same check failing 3 times in a row, stop and escalate (see below).

1. **Snapshot state against the current head:**
   - `HEAD_SHA=$(gh pr view <pr> --json headRefOid --jq .headRefOid)` — record it.
   - `gh pr checks <pr>` (interactive sessions may use `--watch`; routines poll with sleep, don't spin).
     Checks count only if they are COMPLETED (not queued/in-progress) and apply to $HEAD_SHA.
   - `gh pr view <pr> --comments` and `gh api repos/{owner}/{repo}/pulls/<pr>/comments` for review threads.
1b. **Triage every comment before acting.** Classify each as: actionable current defect / already fixed / outdated (on a superseded commit) / duplicate / non-blocking suggestion / human or product decision / bot status chatter / my own prior reply. ONLY "actionable current defect" triggers code changes. Acknowledgment protocol — react, don't reply:
   - Reviewed, nothing to do (non-actionable, already fixed, outdated, bot status, agree-but-non-blocking): add a 👍 reaction to that comment. `gh api repos/{owner}/{repo}/pulls/comments/<id>/reactions -f content='+1'` (inline review comments) or `.../issues/comments/<id>/reactions` (PR conversation comments). A reaction proves the comment was seen without creating thread noise, and nothing re-triggers on reactions — no reply loops.
   - Fixed: reply with the commit SHA (text, because the reference matters).
   - Disagree on substance: one reasoned reply, then stop — do not debate a bot across multiple turns; escalate if it blocks required checks.
   - Never reply to your own comments.
2. **Diagnose before touching code:**
   - For a failed check: `gh run view <run-id> --log-failed`. Read the actual error. Reproduce locally with `.claude/scripts/checks.sh` before attempting a fix.
   - Distinguish: my code broke it / flaky test / broken main / infra failure. Only the first is yours to fix by editing code.
3. **Fix the root cause, minimally.** Obey `.claude/rules/simplicity.md` and `.claude/rules/testing.md`. Never edit tests to get green.
4. **Verify locally** with `.claude/scripts/checks.sh` and capture output.
5. **Commit + push.** One coherent batch per iteration: group findings that share a cause; don't mix unrelated repairs, and don't make one commit per nitpick. Message format: `fix(ci): <what> — iteration <n>`.
6. **Close the loop on review comments**: fixed ones get a reply with the commit SHA; everything else you processed gets a 👍 reaction per the acknowledgment protocol in 1b.
7. Return to step 1.

## Completion consistency check (MANDATORY before declaring done)

1. Re-read the head SHA: `gh pr view <pr> --json headRefOid --jq .headRefOid`.
2. If it differs from the $HEAD_SHA your status snapshot used, discard the snapshot and return to step 1 — green checks for a stale commit prove nothing.
3. Require: at least one check exists, and all REQUIRED checks completed successfully for the current head SHA, and the review-thread triage was performed against the current code. An empty check list fails this gate.
4. For a loop-managed PR linked with `Closes #N`, replace `claude-running`
   with `claude-ready`, then verify the issue has exactly one state label and
   that it is `claude-ready` (not `claude-running` or `claude-blocked`).

## Escalation (cap hit, repeated failure, or genuinely stuck)

Post ONE comment on the PR containing: what fails, your diagnosis, what you tried (with commit refs), and your best hypothesis. Then find the linked issue from the PR's `Closes #N`, post an issue escalation containing the diagnosis, attempts, commit refs, and specific questions, and replace `claude-running` with `claude-blocked`. Verify the issue has exactly the blocked terminal label before stopping. A stalled loop with a good diagnosis and a blocked issue is a success condition, not a failure — burning iterations past the cap or leaving the issue running is the failure.

## Never

- Never merge, never push to main.
- Never respond to CI runs triggered by your own just-pushed commit as if they were new external feedback — wait for the run to finish, act once.
- Never disable, skip, or `continue-on-error` a CI check to get green.
