---
name: test
description: "Test strategy and execution: flaky test policy, test data strategy, E2E update rules. Use when writing tests, handling flaky tests, or deciding test data approach."
user-invocable: false
---

# Test

Testing guidelines for the dev agent.

## Flaky test policy

- If you rerun CI more than once to get green, quarantine the test
  immediately — rerunning is a signal, not a solution.
- Quarantine: add `@quarantine` tag + open a GitHub Issue.
- Never merge to preview with a flaky unquarantined smoke test.

## Test data strategy

- **Preferred:** API seeding (`scripts/seed-e2e.mjs`) — fast, deterministic,
  self-cleaning.
- **Acceptable:** UI creation within the test.
- **Never:** pre-seeded shared state.
- Each test must be independently runnable in any order.

## E2E test updates

If your change touches files or routes exercised by existing E2E tests
(`e2e/smoke/`, `e2e/full/`), update those tests to match. A failing
suite you ignore is worse than no suite.

## When to write tests

- Full path: unit/integration tests covering all new behavior
- Trivial path: write new tests if the change is testable; ensure
  existing tests still pass
