---
name: build
description: "Implementation playbook: planning, coding constraints, ADR alignment, migrations, and ambiguity handling. Use when implementing a feature, fixing a bug, or writing code for a spec."
user-invocable: false
---

# Build

Implementation guidelines for the dev agent. Follow these when writing code.

## Before writing any code

### Full path (SESSION_PATH = full)

1. **ADR check** — if `$AGENTIC_DEV_ADR_PATH` is set and the file exists,
   read it. The ADR file is expected to be a single markdown document with a
   table or index at the top followed by numbered decision sections
   (`## ADR-N — Title` or similar). Scan the index, then read the 3 entries
   most relevant to this task. If the variable is unset or the file doesn't
   exist, skip.

2. **Read the issue** — `gh issue view [number] --comments` (include comments
   in case normative context was added there).

3. **State your plan** — write 3-5 lines as a note to yourself in this session
   describing: (a) how your approach aligns with any ADR decisions found, and
   (b) which files you expect to change. If you intend to deviate from an ADR,
   state that explicitly now. This is internal reasoning, not user-facing output.

4. **Trace affected paths** — read the relevant files to map the execution
   flow from entry point through to data persistence. Identify every file in
   the blast radius before writing anything. For large features, use multiple
   sequential Explore passes (UI layer, then API layer, then persistence) rather
   than guessing from filenames.

5. **Confirm scope** — if the blast radius is materially larger than the AC
   suggests, flag it to the orchestrator before proceeding.

### Trivial path (SESSION_PATH = trivial)

1. Read the file(s) you intend to change.
2. Confirm the scope contract matches what you see — if it doesn't, escalate.

## Constraints

- Do not build anything not in the issue (full path) or beyond the scope
  contract (trivial path)
- Do not refactor unrelated code in this PR
- Do not introduce new dependencies unless required — justify any new
  dependency in the PR description
- Follow existing patterns in the codebase. If a different approach is
  better, note it in the PR description but implement the existing pattern
  unless told otherwise

## Branch targeting

- Default: branch from `$AGENTIC_DEV_BASE_BRANCH`
- Hotfix: branch from `main` — only when the orchestrator explicitly passes
  `SESSION_TYPE=hotfix`. The dev agent does not classify a task as hotfix
  on its own.
- Branch name: `feature/`, `fix/`, `refactor/`, or `hotfix/` prefix + short name

## Ambiguous decisions

For a scope-defining gap (something that determines what gets built or changes
acceptance criteria), pause and return the question to the orchestrator. The
orchestrator will ask the user. Document the answer in the PR description
under Key decisions.

For an execution-safe gap (copy wording, minor placement, implementation
detail that doesn't affect AC), make a reasonable default and document it
as an assumption in the PR description. Do not pause.

## Migrations

If the change requires a schema or database migration:

- Write the migration
- Verify it is backwards compatible (old code can run against new schema)
- Note it in the PR description with a rollback plan
- Never run an irreversible migration without flagging it explicitly —
  irreversible migrations require review before merge
