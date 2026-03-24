# agentic-dev

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) that runs a full dev cycle — spec, build, test, ship, review, merge — using multi-agent orchestration with an independent Codex review gate.

## Install

```bash
claude plugins marketplace add q5vqbfhqnm-alt/agentic-dev
claude plugins install agentic-dev@agentic-dev
```

Then run the setup checker from your project root:

```bash
bash plugins/agentic-dev/scripts/init.sh
```

This verifies prerequisites, detects your build system, and scaffolds GitHub templates if missing.

## Prerequisites

- [Claude Code](https://claude.com/claude-code)
- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [GitHub CLI](https://cli.github.com) (`gh`, authenticated)
- `jq`
- `OPENAI_API_KEY` in your environment

## Usage

The plugin sets `orchestrator` as the default agent. Start with:

```
implement #42          # full path — implement issue #42
fix the H1             # trivial path — auto-classified
write a spec for ...   # create a spec issue from a brief
```

### How it works

```
orchestrator → triage (trivial or full?)
  │
  ├─ trivial: user description is the spec
  ├─ full: requires a GitHub Issue (spec agent creates one)
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
approved → merge gate (CI + E2E + rebase) → squash-merge
```

**Trivial** changes (≤2 files, no schema/auth/API/dependency changes) get a focused 2-question review. **Full** changes require a spec issue and get the 9-point review. Override with "use full path" or "this is trivial" at any time.

## What's included

| Component | Description |
|-----------|-------------|
| **orchestrator** agent | Top-level state machine: triage, delegation, fix-review loops |
| **dev** agent | Implementation in a worktree, runs checks, opens PRs |
| **spec** agent | Turns briefs into unambiguous GitHub Issues |
| **review** agent | CI + Codex gate, isolated context, cannot self-review |
| **build** skill | ADR alignment, coding constraints, migrations |
| **test** skill | Flaky test policy, test data strategy, E2E rules |
| **ship** skill | Pre-push checks, localhost gate, commit convention, PR creation |

### Hooks

Four `PreToolUse` hooks fire on every Bash command:

| Hook | Enforces |
|------|----------|
| `validate-no-self-review` | Reviews must go through Codex scripts |
| `validate-branch-base` | Branches from base branch (or `main` for hotfix); rejects stale refs |
| `validate-push-ready` | Push blocked unless pre-push checks passed on current HEAD |
| `validate-commit-message` | `type(scope): description` convention |

All hooks hard-fail when `jq` is missing and log blocked commands to `.git/agentic-dev/hooks.log`.

## Configuration

All settings are configurable via environment variables or a project config file (`.claude/agentic-dev.json`). Resolution order: env var > project config > built-in default.

```json
{
  "baseBranch": "develop",
  "testCmd": "make test",
  "lintCmd": "make lint",
  "buildCmd": "make build",
  "e2eCmd": "npm run test:e2e:full:local",
  "e2eSmokeCmd": "npm run test:e2e:smoke"
}
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `AGENTIC_DEV_BASE_BRANCH` | `preview` | Branch for feature branches and PR targets |
| `AGENTIC_DEV_TEST_CMD` | `npm test` | Test command |
| `AGENTIC_DEV_LINT_CMD` | `npm run lint` | Lint command |
| `AGENTIC_DEV_BUILD_CMD` | `npm run build` | Build command |
| `AGENTIC_DEV_INSTALL_CMD` | `npm install` | Dependency install for localhost mode |
| `AGENTIC_DEV_DEV_CMD` | `npm run dev` | Dev server for localhost mode |
| `AGENTIC_DEV_E2E_CMD` | `npm run test:e2e` | Full E2E command |
| `AGENTIC_DEV_E2E_SMOKE_CMD` | Falls back to E2E_CMD | Smoke E2E command |
| `AGENTIC_DEV_CI_WORKFLOW` | Auto-discovered | GitHub Actions workflow name |
| `AGENTIC_DEV_MAX_REVIEW_ROUNDS` | `3` | Max re-review rounds before escalating |
| `AGENTIC_DEV_CHANGELOG_PATH` | Auto-detected | CHANGELOG file path |
| `AGENTIC_DEV_ADR_PATH` | Not set | Architecture decision records file |

Non-npm projects: set the test/lint/build commands to match your stack. The init script suggests values for Make, Cargo, Go, and Python.

### Path-aware checks

Pre-push checks skip steps based on which files changed:

| Changed files | Test | Lint | Build |
|---------------|------|------|-------|
| Docs, markdown | skip | skip | skip |
| Test files, configs | run | run | skip |
| Style files (CSS, images) | skip | run | run |
| Unknown / unmatched | run | run | run |

### Tiered E2E

The merge gate routes E2E by file impact: **full** for auth/API/core paths, **smoke** for UI files, **none** for docs/config. Configure with `AGENTIC_DEV_E2E_FULL_PATHS` and `AGENTIC_DEV_E2E_SMOKE_PATHS`.

## The Codex guardrail

The same model that wrote the code cannot review it. Enforced at three levels:

1. **Structural** — review agent has no Write/Edit tools
2. **Deterministic** — hooks block direct review commands and PR comment posting
3. **Machine marker** — review scripts stamp comments; merge gate requires the marker

Only the user can override a Codex verdict.

## Docs

- [Template contract](docs/template-contract.md) — which PR/issue sections the pipeline depends on

## License

All rights reserved.
