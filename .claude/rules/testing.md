# Testing rules

- Adding new tests and updating tests for intentionally changed behavior is expected and encouraged.
- NEVER delete, disable, skip, or weaken a test to make it pass. Fix the implementation instead.
  - If you believe a test itself is wrong, STOP and ask the human, explaining why.
- Any diff that modifies an EXISTING test must be called out in its own PR section ("Test changes") with the reason.
- Every behavior change needs at least one test that fails before the change and passes after it.
- Tests assert observable behavior, not implementation details (no asserting on private state or call counts unless that IS the behavior).
- Never report work as complete based on a successful edit alone. Build and run the tests locally and include the actual output as evidence:
  `swift build && swift test`
- If a test is flaky (passes on retry with no code change), say so explicitly in the PR rather than re-running until green.
