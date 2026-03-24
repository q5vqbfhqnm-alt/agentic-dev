# Template Contract

This document describes which sections of PR descriptions and issue bodies the
agentic-dev review pipeline and merge gate actually parse or depend on. Teams
using custom templates should preserve these sections to avoid breaking the
automated workflow.

## PR description

### Sections referenced by the review prompt

The Codex review prompt (`scripts/codex-review.sh`) reads the PR body to find
linked issues via GitHub closing keywords (`Closes`, `Fixes`, `Resolves` and
their lowercase variants, followed by `#N`). It does not parse specific section
headers — the review output structure is defined by the prompt itself, not the
PR template.

### Sections parsed by the merge gate

The merge gate (`scripts/merge-gate.sh`) checks the PR body for:

| Check | Pattern | Effect |
|-------|---------|--------|
| Placeholder detection | `[TODO]`, `[placeholder]`, `[fill in]` (case-insensitive) | Blocks merge |
| CHANGELOG bullets | Lines matching `- Added\|Fixed\|Changed\|Removed: ...` | Extracted for auto-generated CHANGELOG entry |
| Env var detection | `process.env.VAR_NAME` in the diff (not body) | Warning only, does not block |

If no CHANGELOG bullets are found, the merge gate falls back to the PR title.

### Recommended sections

The ship skill (`skills/ship/SKILL.md`) recommends but does not enforce:

- **What changed** — 2-3 sentence summary
- **Key decisions** — deviations from spec
- **Risky areas** — regression surface
- **How to test** — commands or auth method

These are guidance for the dev agent, not parsed by any script.

## Issue body

### Sections referenced by the review prompt

The Codex review and re-review prompts read linked issues to check spec
alignment. They look for acceptance criteria and general issue content but
do not parse specific section headers. Any structured issue format works as
long as acceptance criteria are clearly stated.

### Sections referenced by the spec agent

The spec agent (`agents/spec.md`) reads issue templates from
`$AGENTIC_DEV_ISSUE_TEMPLATES` (defaults to `.github/ISSUE_TEMPLATE/`) and
follows their structure when creating issues. The bundled templates include:

- `feature.md` — User Story, Acceptance Criteria, Out of Scope, Risky Areas, Dependencies
- `bug.md` — similar structure with Evidence section
- `refactor.md` — similar structure
- `chore.md` — similar structure

Teams can modify or replace these templates. The spec agent adapts to whatever
template structure it finds; if no templates exist, it uses a plain format.

## Session state

Review scripts write session state to `.git/agentic-dev/session-{branch}.json`.
This file is not part of the template contract but is referenced by the
orchestrator for cross-context state recovery. See `agents/orchestrator.md`
for details.
