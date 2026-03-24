# Changelog

## 1.4.0 — 2026-03-24

Reliability hardening: fail-loud guards, persistent session state, verdict validation.

### Core reliability
- Fixed: All four hooks now hard-fail (exit 2) when `jq` is missing instead of silently allowing all commands through
- Fixed: `codex-review.sh`, `codex-review-trivial.sh`, and `codex-re-review.sh` exit non-zero when Codex output contains no VERDICT line
- Added: Review scripts persist session state (`CODEX_SESSION_ID`, verdict, round) to `.git/agentic-dev/session-{branch}.json`
- Added: Orchestrator references session state file as authoritative source for review state across context boundaries

### Observability
- Added: All four hooks log every invocation (timestamp, hook name, action, command summary) to `.git/agentic-dev/hooks.log`

### Cleanup
- Changed: Spec agent no longer instructs user to manually copy issue URL — output section matches orchestrator's automated handoff
- Added: `docs/template-contract.md` documenting which PR/issue sections the review prompt and merge gate depend on

## 1.3.0 — 2026-03-24

Path-aware checks, tiered E2E, hardened merge/review workflow.

### Performance
- Added: Path-aware pre-push checks — skips test/lint/build when changed files can't affect them (docs skip everything, test files skip build, style files skip tests)
- Added: Tiered E2E routing (none/smoke/full) — UI-only changes run smoke E2E, core paths run full, docs/config skip entirely
- Changed: `--local-only` cleanup skips remote refresh and GitHub lookups for faster startup (~0.2s)

### Workflow reliability
- Added: Stale base detection — `validate-branch-base` hook rejects local refs behind origin
- Added: Dev agent fetches before worktree creation, branches from `origin/$BASE_BRANCH`
- Added: Auto-symlink `.env`, `.env.local`, `.env.development.local`, `.env.test.local` into worktrees
- Added: Project-level config file (`.claude/agentic-dev.json`) — commit settings per-repo
- Added: `ci-watch.sh` — standalone CI polling script replacing inline prompt loops
- Added: Unified CI workflow discovery (`agentic_dev_discover_ci_workflow`) used by merge-gate and ci-watch
- Added: CHANGELOG path auto-detection (`docs/CHANGELOG.md` or `CHANGELOG.md`)
- Changed: Merge gate merges first, then commits CHANGELOG to base branch (eliminates race between concurrent gates)
- Changed: Merge gate retries UNKNOWN mergeability (3× with 5s delay)
- Changed: Merge gate polls in-progress CI runs (up to 10 min) instead of instant-failing
- Changed: Merge gate auto-rebases with `--force-with-lease` on conflicts
- Changed: Merge gate reuses PR metadata in single API call
- Changed: Review agent pushes with `--force-with-lease` after rebase
- Changed: Review agent removed duplicate rebase step (merge gate handles it)

### Review system
- Added: Max review round guard in `codex-re-review.sh` (rejects rounds above `AGENTIC_DEV_MAX_REVIEW_ROUNDS`)
- Added: E2E failure triage guidance in review agent (flaky vs regression vs pre-existing)
- Added: Review/merge-gate boundary clarification — gate is authoritative for CI, mergeability, E2E
- Added: Reduced-confidence flag on session resume fallback
- Changed: All review scripts use `--body-file` instead of inline `--body` (prevents truncation)
- Changed: Review scripts delete previous agentic-dev comments before posting (eliminates noise)

### DX
- Changed: Pre-push checks report which step failed with the failing command
- Changed: `cleanup-branches.sh` batches PR API calls (2 calls instead of N)
- Changed: Cleanup skips squash-merge PR lookup in local-only mode

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
