---
name: build
description: "Implementation playbook: planning, coding constraints, ADR alignment, migrations, and ambiguity handling. Use when implementing a feature, fixing a bug, or writing code for a spec."
user-invocable: false
---

# Build

Implementation guidelines for the dev agent. Follow these when writing code.

## Before writing any code

### Full path (SESSION_PATH = full)

1. If `$AGENTIC_DEV_ADR_PATH` is set, read the ADR file at that path —
   scan the index, then read the 3 most relevant entries. If the variable
   is not set or the file doesn't exist, skip to step 2.
2. Read the GitHub Issue in full: `gh issue view [number]`
3. If ADR entries were found, list those decisions and state how your
   approach matches them. If you intend to deviate, say so now. Keep to
   3-5 lines.
4. **Trace affected paths** — map the execution flow from entry point through
   to data persistence. Identify every file in the blast radius. For large
   features, spawn 2-3 parallel Explore agents each focused on a different
   subsystem (e.g. UI layer, API route, external service integration).
5. **State your approach** — 3-5 lines describing the implementation approach
   and why it fits existing codebase patterns. One confident recommendation,
   not multiple options.

### Trivial path (SESSION_PATH = trivial)

1. Read the file(s) you intend to change.
2. State the change in 1-2 lines (what + where).

## Constraints

- Do not build anything not in the issue (full path) or beyond the user's
  described change (trivial path)
- Do not refactor unrelated code in this PR
- Do not introduce new dependencies unless required — justify any new
  dependency in the PR description
- Follow existing patterns in the codebase. If you think a different
  approach is better, note it in the PR description but implement the
  existing pattern unless told otherwise
- Branch from `preview` by default.
  Exception: hotfix branches branch from `main`.
  Branch name: `[feature|fix|refactor]/[short-name]` or `hotfix/[short-name]`

## Migrations

If the change requires a schema or database migration:

- Write the migration
- Confirm it is backwards compatible
- Note it in the PR description with a rollback plan
- Never run an irreversible migration without flagging it explicitly —
  irreversible migrations require review before merge

## Ambiguous decisions

Stop. Do not assume. Ask the question in chat before proceeding.
Document the answer in the PR description under Key decisions.
