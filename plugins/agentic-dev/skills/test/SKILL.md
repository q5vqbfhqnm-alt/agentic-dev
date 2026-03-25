---
name: test
description: "Test strategy and execution: flaky test policy, test data strategy, E2E update rules. Use when writing tests, handling flaky tests, or deciding test data approach."
user-invocable: false
---

# Test

Testing guidelines for the dev agent.

## Flaky test policy

The dev agent does not monitor CI directly — the orchestrator does. Flakiness
reaches the dev agent as a CI failure returned by the orchestrator where the
failing test is not related to this PR's changes.

When the orchestrator reports a CI failure and the failing test is unrelated
to the changed code:

1. Quarantine the test so it no longer blocks the pipeline
2. Open a GitHub Issue to track the flakiness

**Quarantine mechanism** — use whichever form the test framework supports:
- Jest / Vitest: `test.skip(...)` with a `// quarantine:` comment
- Playwright: `test.skip()` or `test.fixme()`
- Other: use the framework's native skip/pending mechanism

Always add a comment inline: `// quarantined: intermittent, see #<issue-number>`

If the CI failure is related to this PR's changes, it is a real failure — fix
it, do not quarantine.

Never merge with a flaky unquarantined test blocking CI.

## Test data strategy

- **Preferred:** API seeding via a dedicated seed script (e.g.
  `scripts/seed-e2e.mjs` if present) — fast, deterministic, self-cleaning.
  If no seed script exists, fall back to the next option.
- **Acceptable:** UI creation within the test.
- **Never:** pre-seeded shared state that persists between test runs.

Each test must be runnable in isolation and in any order. Exception: full E2E
suites may share `beforeAll` setup within a single file, but not across files.

## E2E test updates

Update existing E2E tests only when the change alters **externally observable
behavior**: visible UI, user-facing routes, API response shape, or interaction
flow.

Do not update E2E tests for internal refactors or implementation moves that
have no effect on what the user or API consumer sees — even if those changes
touch files the E2E tests exercise.

If unsure: check whether the test's assertions would still pass against the
new code without modification. If yes, no update needed.

## When to write tests

- **Full path:** unit tests for isolated logic; integration tests for
  interactions with external systems (database, API, third-party service).
  Cover all new behavior.
- **Trivial path:** write new tests if the change is testable in isolation;
  verify existing tests still pass.
