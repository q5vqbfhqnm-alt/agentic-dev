---
name: ship
description: "Commit, push, and open a PR. Non-interactive mechanical step — no user prompts. Localhost review is handled by the dev agent before invoking this skill."
user-invocable: false
---

# Ship

Commit, push, and open a PR. This skill is purely mechanical — no user interaction,
no spec mutation. Localhost review (if required) is completed by the dev agent
before this skill is invoked.

## Pre-push checks

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh"
```

All checks must pass before committing. If any check fails, fix it and re-run.

## Commit

Single logical commit per PR. Message format:

Full path (issue exists):
```
feat|fix|refactor|docs|test|chore(scope): short description (closes #N)
```

Trivial path (no issue):
```
feat|fix|refactor|docs|test|chore(scope): short description
```

During a fix-review loop, additional commits are acceptable — the PR will be
squash-merged, so intermediate fix commits do not affect final history.
Do not amend a commit that has already been pushed.

## Push

First push:
```bash
git push -u origin HEAD
```

Subsequent pushes in a fix-review loop:
```bash
git push
```

## Open the PR

Open against `$AGENTIC_DEV_BASE_BRANCH`. If a PR template exists at
`$AGENTIC_DEV_PR_TEMPLATE` (default: `.github/pull_request_template.md`),
GitHub will pre-fill from it.

### Full path — required fields

- **What changed** — 2-3 sentence summary
- **Key decisions** — deviations from spec or ADR patterns
- **Risky areas** — anything that could regress; affected call sites; shared components
- **How to test** — exact commands or auth method
- `- Added/Fixed/Changed/Removed: [what]` bullets (used for CHANGELOG)
- `Closes #[issue-number]`

### Trivial path — required fields

- **What changed** — 1-2 lines
- `- Added/Fixed/Changed/Removed: [what]` bullets (used for CHANGELOG)

Omit other sections or mark them N/A.

## Verification checklist

Items marked *(if applicable)* are only required when that capability exists in the repo.

- [ ] Change matches the spec (ACs for full path; scope contract for trivial path)
- [ ] Unit/integration tests pass
- [ ] No lint or type errors *(if applicable — skip if repo has no lint/type tooling)*
- [ ] E2E tests updated if changed files are covered by existing E2E *(if applicable)*
- [ ] PR description has no placeholder text
- [ ] `- Added/Fixed/Changed/Removed:` bullets present
- [ ] `Closes #N` present *(full path only)*
- [ ] Branch is from `$AGENTIC_DEV_BASE_BRANCH`, not `main`
