# Changelog

## 1.2.0 — 2026-03-23

Orchestrator agent and smart localhost gate.

- Added: `orchestrator` agent — top-level state machine that owns the full spec → dev → review lifecycle with zero manual handoffs
- Added: Smart localhost gate — auto-detects UI changes instead of asking the user
- Added: Worktree-aware dev server — runs on port 3001 inside the worktree to avoid conflicts
- Added: Spec sync — updates GitHub Issue ACs when localhost review changes scope
- Added: Blocker classification — objective Codex findings auto-fixed, subjective ones require user confirmation
- Changed: `dev` agent slimmed to implementation-only role (triage/review moved to orchestrator)
- Changed: `review` agent inputs/outputs reference orchestrator instead of dev agent
- Changed: Default agent changed from `dev` to `orchestrator`
- Fixed: Inline Codex availability check removed from review and dev agents (already handled inside scripts)

## 1.1.1 — 2026-03-21

Bug fixes.

- Fixed: `validate-commit-message` blocked heredoc-style commits — heredoc check now runs before `-m "..."` extraction, and sed uses `-n .../p` to avoid outputting the raw command on no-match
- Fixed: `pre-push-checks.sh` wrote `.pre-push-passed` to the working tree — sentinel now lives in `.git/`, so it never appears as an untracked file in user projects

## 1.1.0 — 2026-03-20

Configurable setup.

- Added: `init.sh` setup checker — verifies prerequisites, detects build system, scaffolds GitHub templates
- Added: `config.sh` — base branch, build commands, and paths are now configurable via environment variables
- Changed: Non-npm projects supported out of the box (Make, Cargo, Go, Python)
- Changed: Branch cleanup is automatic and local-only on startup
- Changed: Tighter trivial triage and review fix loops
- Fixed: Agent routing uses intent matching instead of slash-command syntax

## 0.1.0 — 2026-03-20

Initial release.

### Agents
- `dev` — orchestrator with triage (trivial/full), worktree setup, review delegation
- `spec` — requirements analyst, produces GitHub Issues
- `review` — isolated Codex review gate with restricted tools

### Skills
- `build` — implementation guidelines, ADR alignment, migration rules
- `test` — flaky test policy, test data strategy, E2E update rules
- `ship` — pre-push checks, localhost gate, commit convention, PR creation

### Hooks
- `validate-no-self-review` — blocks direct PR review/comment commands
- `validate-branch-base` — enforces branching from preview or main
- `validate-push-ready` — blocks push unless pre-push checks passed
- `validate-commit-message` — enforces type(scope): description convention

### Scripts
- `codex-review.sh` — 9-point Codex review with machine marker
- `codex-review-trivial.sh` — focused 2-question review for trivial path
- `codex-re-review.sh` — session-resume re-review
- `merge-gate.sh` — review + CI + E2E verification, CHANGELOG generation, squash-merge
- `pre-push-checks.sh` — lint, type check, tests
- `cleanup-branches.sh` — prune stale worktrees and branches
