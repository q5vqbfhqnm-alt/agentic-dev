# agentic-dev

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) that runs a full dev cycle — spec → build → test → ship → review → merge — using multi-agent orchestration with an independent Codex review gate.

## Install

```bash
claude plugins marketplace add q5vqbfhqnm-alt/agentic-dev
claude plugins install agentic-dev@agentic-dev
```

## Quick start

After installing, run the setup checker from your project root:

```bash
bash plugins/agentic-dev/scripts/init.sh
```

This verifies prerequisites, auto-detects your build system, checks the base branch, and prints a resolved configuration summary. If GitHub issue or PR templates are missing, it copies starter templates into `.github/` — review and commit them. Fix any failures before using the workflow.

## Prerequisites

**Tools:**

- [Claude Code](https://claude.com/claude-code)
- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [GitHub CLI](https://cli.github.com) (`gh`, authenticated)
- `OPENAI_API_KEY` in your environment

**Repo requirements:**

The plugin assumes your project has these in place. All are configurable:

| Requirement | Default | Override |
|-------------|---------|----------|
| Base branch | `preview` | `AGENTIC_DEV_BASE_BRANCH` |
| Test command | `npm test` | `AGENTIC_DEV_TEST_CMD` |
| Lint command | `npm run lint` | `AGENTIC_DEV_LINT_CMD` |
| Build command | `npm run build` | `AGENTIC_DEV_BUILD_CMD` |
| CI workflow | Auto-discovered | `AGENTIC_DEV_CI_WORKFLOW` |
| CHANGELOG path | Auto-detected (`docs/CHANGELOG.md` or `CHANGELOG.md`) | `AGENTIC_DEV_CHANGELOG_PATH` |
| PR template | `.github/pull_request_template.md` | `AGENTIC_DEV_PR_TEMPLATE` |
| Issue templates | `.github/ISSUE_TEMPLATE/` | `AGENTIC_DEV_ISSUE_TEMPLATES` |
| ADR file | Not set (skipped) | `AGENTIC_DEV_ADR_PATH` |

**Non-npm projects:** Set `AGENTIC_DEV_TEST_CMD`, `AGENTIC_DEV_LINT_CMD`, and `AGENTIC_DEV_BUILD_CMD` to match your build system. The init script will suggest values for Make, Cargo, Go, and Python projects.

### Project config file

Instead of exporting environment variables, you can commit a `.claude/agentic-dev.json` to your repo. All settings from the table above are supported using camelCase keys. Environment variables still take precedence.

```json
{
  "baseBranch": "develop",
  "e2eCmd": "npm run test:e2e:full:local",
  "e2eSmokeCmd": "npm run test:e2e:smoke",
  "testCmd": "make test",
  "lintCmd": "make lint",
  "buildCmd": "make build"
}
```

Resolution order: environment variable > project config file > built-in default.

## Usage

The plugin sets `orchestrator` as the default agent. Start a session with:

```
implement #42          # full path — implement issue #42
fix the H1             # trivial path — auto-classified
write a spec for ...   # create a spec issue from a brief
```

### How it works

```
orchestrator agent → triage (trivial or full?)
  │
  ├─ trivial: user description is the spec
  ├─ full: requires a GitHub Issue (run spec agent first)
  │
  ↓
dev agent (worktree) → build → test → ship → push → PR
  ↓
review agent (isolated, no Write/Edit tools)
  → CI watch + Codex review (parallel)
  → verdict pass-through (only user can override)
  ↓
blocked? → dev fixes → push → re-review (max 3 cycles)
  ↓
approved → merge gate (CI + rebase + E2E none/smoke/full) → squash-merge
```

### Trivial vs full path

The dev agent auto-classifies changes:

- **Trivial** — ≤2 files, no schema/auth/API/dependency changes, obviously correct. Gets a focused 2-question Codex review.
- **Full** — everything else. Requires a spec issue and gets the full 9-point Codex review.

You can override: say "use full path" or "this is trivial" at any time.

## What's included

### Agents

| Agent | Role |
|-------|------|
| `orchestrator` | Top-level state machine. Triages, delegates spec/dev/review, and manages fix-review loops. |
| `dev` | Implementation agent. Works in a worktree, runs checks, and opens the PR. |
| `spec` | Requirements analyst. Turns briefs into unambiguous GitHub Issues. |
| `review` | CI + Codex gate. Isolated context, restricted tools, cannot self-review. |

### Skills

| Skill | Covers |
|-------|--------|
| `build` | ADR alignment, coding constraints, migrations, ambiguity handling |
| `test` | Flaky test policy, test data strategy, E2E update rules |
| `ship` | Pre-push checks, localhost gate, commit convention, PR creation |

### Hooks

Four `PreToolUse` hooks fire on every Bash command while the plugin is active:

| Hook | Enforces |
|------|----------|
| `validate-no-self-review` | Blocks direct PR review/comment commands — reviews must go through Codex scripts |
| `validate-branch-base` | Branches must be created from base branch (or `main` for hotfix); rejects stale local refs behind origin |
| `validate-push-ready` | `git push` blocked unless `pre-push-checks.sh` passed on current HEAD |
| `validate-commit-message` | Commit messages must match `type(scope): description` |

## Configuration

### Environment variables

All configuration is through environment variables. Defaults are defined in [`scripts/config.sh`](plugins/agentic-dev/scripts/config.sh).

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `OPENAI_API_KEY` | Yes | — | Codex CLI authentication |
| `AGENTIC_DEV_BASE_BRANCH` | No | `preview` | Branch to create feature branches from and merge PRs into |
| `AGENTIC_DEV_TEST_CMD` | No | `npm test` | Test command for pre-push checks |
| `AGENTIC_DEV_LINT_CMD` | No | `npm run lint` | Lint command for pre-push checks |
| `AGENTIC_DEV_BUILD_CMD` | No | `npm run build` | Build command for pre-push checks |
| `AGENTIC_DEV_INSTALL_CMD` | No | `npm install` | Dependency install command for localhost mode |
| `AGENTIC_DEV_DEV_CMD` | No | `npm run dev` | Dev server command for localhost mode |
| `AGENTIC_DEV_E2E_CMD` | No | `npm run test:e2e` | Full E2E test command for merge gate |
| `AGENTIC_DEV_E2E_SMOKE_CMD` | No | Falls back to `E2E_CMD` | Smoke E2E command (lighter than full) |
| `AGENTIC_DEV_E2E_FULL_PATHS` | No | Auth, API, payment, middleware paths | Grep regex — files that trigger full E2E |
| `AGENTIC_DEV_E2E_SMOKE_PATHS` | No | UI/app source files | Grep regex — files that trigger smoke E2E |
| `AGENTIC_DEV_CHANGELOG_PATH` | No | Auto-detected | CHANGELOG file updated after merge |
| `AGENTIC_DEV_CI_WORKFLOW` | No | Auto-discovered | GitHub Actions workflow name for CI |
| `AGENTIC_DEV_CI_PATHS` | No | `src/ app/ e2e/ package.json tsconfig.json` | Path prefixes for CI-sensitive file detection |
| `AGENTIC_DEV_MAX_REVIEW_ROUNDS` | No | `3` | Max Codex re-review rounds before escalating |
| `AGENTIC_DEV_ADR_PATH` | No | Not set (skipped) | Architecture decision records file |
| `AGENTIC_DEV_ISSUE_TEMPLATES` | No | `.github/ISSUE_TEMPLATE/` | Issue template directory for spec agent |
| `AGENTIC_DEV_PR_TEMPLATE` | No | `.github/pull_request_template.md` | PR template path |

### Path-aware pre-push checks

Pre-push checks diff against the base branch and skip steps that can't be affected by the changed files:

| Changed files | Test | Lint | Build |
|---------------|------|------|-------|
| Docs, markdown, assets | skip | skip | skip |
| Test files, configs | run | run | skip |
| Style files (CSS, SVG, images) | skip | run | run |
| Unknown / unmatched | run | run | run |

The default is conservative: unknown file types always run the full stack. Path patterns are configurable via `AGENTIC_DEV_SKIP_ALL_PATHS`, `AGENTIC_DEV_SKIP_BUILD_PATHS`, and `AGENTIC_DEV_SKIP_TEST_PATHS`.

### Tiered E2E

The merge gate routes E2E tests into three tiers based on which files changed:

| Tier | Triggers on | Command |
|------|-------------|---------|
| **full** | Auth, API, payment, middleware, core library paths | `AGENTIC_DEV_E2E_CMD` |
| **smoke** | UI/app source files (`.tsx`, `.jsx`, `.ts`, `.js`) | `AGENTIC_DEV_E2E_SMOKE_CMD` (falls back to full) |
| **none** | Docs, config, test-only changes | Skipped |

Set `AGENTIC_DEV_E2E_SMOKE_CMD` to a lighter test command (e.g., `npm run test:e2e:smoke`) to save time on UI-only changes while keeping full coverage on core paths.

### Settings

`settings.json` sets `orchestrator` as the default agent when the plugin is active.

## The Codex guardrail

The same model that wrote the code cannot objectively review it. This plugin enforces that at three levels:

1. **Structural** — the review agent has no Write/Edit tools
2. **Deterministic** — `PreToolUse` hooks on both agents block direct review commands, PR comment posting, and API calls to the comments endpoint
3. **Machine marker** — review scripts stamp comments with a marker that `merge-gate.sh` requires before accepting a verdict

Only the user can override a Codex verdict.

## License

All rights reserved.
