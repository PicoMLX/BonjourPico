# Simplicity rules

These rules apply to ALL code written in this repository, by any session, subagent, or routine.

- Default to concrete types. A new protocol, generic, or abstraction layer with fewer than 3 current call sites requires a concrete justification in the PR description (e.g. platform boundary, actor isolation, a second implementation that exists today). "We might need it later" is not a justification.
- Prefer value semantics where the domain is naturally value-oriented. Use classes or actors when identity, shared lifetime, observation, synchronization, or reference semantics require them. Any new type named `*Manager`, `*Coordinator`, `*Factory`, `*Service`, `*Provider`, or `*Helper` requires a one-line justification in the PR description (unless that naming is already the repo's convention).
- Match the patterns that already exist in this codebase before introducing new ones. If the codebase does X one way, do X that way.
- When choosing between two working designs, pick the one with fewer types and fewer files.
- Do not add configuration options, feature flags, dependency-injection seams, or extension points that the current issue does not require.
- Solve the issue as written. If the scope seems wrong or too small, comment on the issue — do not silently expand the implementation.
- Minimize net complexity, not line count. Deleting obsolete code is good, but do not compress responsibilities or skip necessary implementation to produce a smaller diff.
