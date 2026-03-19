---
name: ship
description: "Pre-push checks, localhost gate, commit convention, PR creation, and verification checklists. Use when preparing to push code, opening a PR, or running pre-push validation."
user-invocable: false
---

# Ship

Everything from pre-push checks through PR creation and verification.

## Pre-push checklist

### If LOCALHOST_MODE = yes

1. **Prepare the dev server:**
   ```bash
   lsof -ti:3000 | xargs kill -9 2>/dev/null || true
   npm install
   npm run dev &
   DEV_PID=$!
   ```
   Wait for the "Ready" message before continuing.

2. **Present links to the user** — based on which files/routes changed,
   give a checklist with exact localhost URLs:

   > Dev server is running. Please verify:
   >
   > - [ ] **Main flow** — http://localhost:3000/
   > - [ ] **Changed page** — http://localhost:3000/[route]
   > - [ ] Bug no longer reproduces (if bug fix)
   > - [ ] Nothing visually broken on affected pages
   >
   > Reply **ok** when done, or describe what's wrong.

   Map every changed route/page to its localhost URL.
   **Stop and wait for the user to confirm** before continuing.
   If the user reports an issue, fix it and re-present the checklist.

3. **Stop the dev server** — `kill $DEV_PID 2>/dev/null || true`
4. **Run automated checks:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh"`

### If LOCALHOST_MODE = no

1. **Run automated checks:** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh"`

All steps must pass before committing and pushing.

## Commit convention

Single commit per push. Message format:
`feat|fix|refactor(scope): short description (closes #N)`.

On the trivial path (no issue), omit `(closes #N)`:
`feat|fix|refactor(scope): short description`.

The PR will be squash-merged, so keep it to one clean commit.

## Opening the PR

Open PR against `preview`. If the repo has a PR template
(`$AGENTIC_DEV_PR_TEMPLATE`, defaults to `.github/pull_request_template.md`),
GitHub will pre-fill from it.

### Full path

Fill every section of the PR description:
- **What changed** — 2-3 sentence summary
- **Key decisions** — deviations from spec or ADR.md patterns
- **Risky areas** — anything that could regress; call sites; shared components
- **How to test / E2E auth** — exact commands or auth method
- All checklist items answered, test evidence filled in
- Preview URL and commit SHA
- Include `- Added/Fixed/Changed/Removed: [what]` bullets (merge-gate.sh
  extracts these for CHANGELOG)
- Include `Closes #[issue-number]`
- If AC changed during implementation, update the Issue and note
  "AC updated" in the PR description

### Trivial path

PR description can be lighter — fill **What changed** (1-2 lines) and
the checklist. Other sections can be "N/A" or omitted.
- Still include `- Added/Fixed/Changed/Removed: [what]` bullets for CHANGELOG
- No `Closes #[issue-number]` needed
- If mid-implementation escalation occurred, note the deviation

## Verification checklist

### Full path

- [ ] Acceptance criteria all met and verifiable
- [ ] Unit/integration tests written and passing
- [ ] No lint or type errors
- [ ] E2E tests updated if existing tests cover changed flows
- [ ] PR description fully filled (no placeholder text remaining)
- [ ] `Closes #[issue]` in PR description
- [ ] If AC changed: Issue updated + "AC updated" in PR
- [ ] Branch is from `preview`, not `main`

### Trivial path

- [ ] Change matches the user's description
- [ ] Unit/integration tests passing (write new ones if needed)
- [ ] No lint or type errors
- [ ] E2E tests updated if existing tests cover changed flows
- [ ] PR description has What changed + checklist filled
- [ ] Branch is from `preview`, not `main`
