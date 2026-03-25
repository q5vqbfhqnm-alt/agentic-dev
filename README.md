# agentic-dev

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) that runs a full dev cycle — spec, build, test, ship, review, merge — using multi-agent orchestration with an independent Codex review gate.

## Install

```bash
claude plugins marketplace add cansva/agentic-dev
claude plugins install agentic-dev@agentic-dev
```

Then run the setup checker from your project root:

```bash
bash plugins/agentic-dev/scripts/init.sh
```

This verifies prerequisites, detects your build system, and scaffolds GitHub templates if missing.

### Dev container

A devcontainer is included for working on agentic-dev itself. Open this repo in VS Code and choose **Reopen in Container**. The container includes Claude Code, Codex CLI, `gh`, `git`, and `jq`, and persists `~/.claude` and `~/.config/gh` across rebuilds so you only authenticate once.

Required env vars (set locally before opening the container):

```
ANTHROPIC_API_KEY
OPENAI_API_KEY
GH_TOKEN
```

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
  │
  └─ localhost checkpoint (UI changes) → user verifies → continue
  ↓
review agent (isolated, no Write/Edit tools)
  → Codex review → verdict (user can override via scripts/user-override.sh)
  ↓
blocked? → orchestrator classifies findings:
  ├─ objective: dev fixes → push → re-review
  ├─ spec superseded: update issue ACs + PR description → re-review (no code change)
  └─ subjective: user decides → dismiss or fix (max 3 cycles)
  ↓
orchestrator → CI gate (single workflow watch) → rebase if needed → squash-merge → worktree cleanup
```

**Trivial** changes (≤2 files, no schema/auth/API/dependency changes) get a focused 3-question review: scope validation, correctness, and non-obvious breakage. **Full** changes require a spec issue and get the 9-point review. Override with "use full path" or "this is trivial" at any time.

When Codex flags a spec mismatch (implementation intentionally went beyond or diverged from the issue ACs), the orchestrator offers to update the issue and PR description to match what was built, then re-reviews — Codex reads them fresh and naturally drops the finding. No code change, no cycle increment.

## What's included

| Component | Description |
|-----------|-------------|
| **orchestrator** agent | Top-level state machine: triage, delegation, fix-review loops |
| **dev** agent | Implementation in a worktree, runs checks, opens PRs |
| **spec** agent | Turns briefs into unambiguous GitHub Issues |
| **review** agent | Codex gate, isolated context, cannot self-review |
| **build** skill | ADR alignment, coding constraints, migrations |
| **test** skill | Flaky test policy, test data strategy, E2E update rules |
| **ship** skill | Pre-push checks, localhost gate, commit convention, PR creation |

Skills are loaded by the **dev** agent only.

### Hooks

A single `PreToolUse` hook fires on every Bash command (`hooks/pre-tool-use.sh`) and runs four checks in one process:

| Check | Enforces |
|-------|----------|
| No self-review | Reviews must go through Codex scripts; override comments via `user-override.sh` only |
| Branch base | Branches from base branch (or `main` for hotfix); rejects stale refs |
| Push ready | Push blocked unless pre-push checks passed on current HEAD |
| Commit message | `type(scope): description` convention |

Hard-fails when `jq` is missing and logs blocked commands to `.git/agentic-dev/hooks.log`.

## Configuration

Build commands are auto-detected from `package.json` scripts. Project-identity settings (branch, CI, paths, templates) go in `.claude/agentic-dev.json`. Environment variables always take precedence.

Resolution order: env var > project config > `package.json` auto-detection > built-in default.

```json
{
  "baseBranch": "develop",
  "ciWorkflow": "CI",
  "maxReviewRounds": 3
}
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `AGENTIC_DEV_BASE_BRANCH` | `preview` | Branch for feature branches and PR targets |
| `AGENTIC_DEV_TEST_CMD` | Auto-detected from `package.json` | Test command; empty (skipped) if no matching script found |
| `AGENTIC_DEV_LINT_CMD` | Auto-detected from `package.json` | Lint command; empty (skipped) if no matching script found |
| `AGENTIC_DEV_BUILD_CMD` | Auto-detected from `package.json` | Build command; empty (skipped) if no matching script found |
| `AGENTIC_DEV_INSTALL_CMD` | `npm install` | Dependency install for localhost mode |
| `AGENTIC_DEV_DEV_CMD` | Auto-detected from `package.json` | Dev server for localhost mode |
| `AGENTIC_DEV_CI_WORKFLOW` | Auto-discovered from recent runs | GitHub Actions workflow name |
| `AGENTIC_DEV_MAX_REVIEW_ROUNDS` | `3` | Max re-review rounds before escalating |
| `AGENTIC_DEV_CHANGELOG_PATH` | Auto-detected | CHANGELOG file path |
| `AGENTIC_DEV_ADR_PATH` | Not set | Architecture decision records file |

Non-npm projects: set the test/lint/build commands via env vars. The init script suggests values for Make, Cargo, Go, and Python.

### Path-aware checks

Pre-push checks skip steps based on which files changed:

| Changed files | Test | Lint | Build |
|---------------|------|------|-------|
| Docs, markdown | skip | skip | skip |
| Test files, configs | run | run | skip |
| Style files (CSS, images) | skip | run | run |
| Unknown / unmatched | run | run | run |

E2E runs as part of CI if configured in the consumer project. The orchestrator does not trigger or gate on E2E directly.

## The Codex guardrail

The same model that wrote the code cannot review it. Enforced at three levels:

1. **Structural** — review agent has no Write/Edit tools
2. **Deterministic** — hooks block direct review commands and PR comment posting
3. **Machine marker** — review scripts stamp comments; merge gate requires the marker

Only the user can override a Codex verdict. This option is available at any point during PR review — before review starts, mid fix-review loop, or when the merge gate fails. To override, run `scripts/user-override.sh <PR_NUMBER>` directly from your terminal (the orchestrator will show the exact path). The script prompts for confirmation, then posts a distinct `agentic-dev:user-override:v1` marker that the merge gate accepts in place of Codex approval. CI and rebase still run; only the Codex review step is skipped.

## License

MIT © [cansva](https://github.com/cansva)
