#!/usr/bin/env bash
#
# Centralized configuration for agentic-dev.
# All scripts and hooks source this file to resolve configurable values.
#
# Resolution order (highest wins):
#   1. Environment variable  (e.g. export AGENTIC_DEV_E2E_CMD="…")
#   2. Project config file   (.claude/agentic-dev.json in the repo root)
#   3. Auto-detected from package.json scripts (build commands only)
#   4. Built-in default      (hardcoded below)
#
# The project config file is for project-identity settings (base branch,
# CI workflow, paths, templates). Build/E2E commands are auto-detected
# from package.json — do NOT store them in .claude/agentic-dev.json.

# ── Project config file ─────────────────────────────────────────────────────
# Locate the repo root (works inside worktrees too).
_AGENTIC_DEV_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
_AGENTIC_DEV_PROJECT_CONFIG="${_AGENTIC_DEV_REPO_ROOT:+$_AGENTIC_DEV_REPO_ROOT/.claude/agentic-dev.json}"

# _cfg <json_key> — read a value from the project config file (empty if missing)
_cfg() {
  if [ -n "$_AGENTIC_DEV_PROJECT_CONFIG" ] && [ -f "$_AGENTIC_DEV_PROJECT_CONFIG" ]; then
    jq -r --arg k "$1" '.[$k] // empty' "$_AGENTIC_DEV_PROJECT_CONFIG" 2>/dev/null || true
  fi
}

# _detect_pkg_script <script-name> ...
# Returns the first matching npm script name found in package.json, or empty.
# Usage: CMD=$(_detect_pkg_script "test:e2e:full:local" "test:e2e" "e2e")
_detect_pkg_script() {
  local pkg="${_AGENTIC_DEV_REPO_ROOT:+$_AGENTIC_DEV_REPO_ROOT/package.json}"
  [ -f "$pkg" ] || return 0
  for script in "$@"; do
    if jq -e --arg s "$script" '.scripts[$s]' "$pkg" >/dev/null 2>&1; then
      echo "npm run $script"
      return
    fi
  done
}

_agentic_dev_default_changelog_path() {
  if [ -n "$_AGENTIC_DEV_REPO_ROOT" ]; then
    if [ -f "$_AGENTIC_DEV_REPO_ROOT/docs/CHANGELOG.md" ]; then
      echo "docs/CHANGELOG.md"
      return
    fi
    if [ -f "$_AGENTIC_DEV_REPO_ROOT/CHANGELOG.md" ]; then
      echo "CHANGELOG.md"
      return
    fi
  fi
  echo "CHANGELOG.md"
}

# ── Branch configuration ────────────────────────────────────────────────────
AGENTIC_DEV_BASE_BRANCH="${AGENTIC_DEV_BASE_BRANCH:-$(_cfg baseBranch)}"
AGENTIC_DEV_BASE_BRANCH="${AGENTIC_DEV_BASE_BRANCH:-preview}"
AGENTIC_DEV_PROTECTED_BRANCHES="${AGENTIC_DEV_PROTECTED_BRANCHES:-$(_cfg protectedBranches)}"
AGENTIC_DEV_PROTECTED_BRANCHES="${AGENTIC_DEV_PROTECTED_BRANCHES:-main|${AGENTIC_DEV_BASE_BRANCH}}"

# ── Build system commands ───────────────────────────────────────────────────
# Auto-detected from package.json scripts, then hardcoded defaults.
# Environment variables always win.
AGENTIC_DEV_TEST_CMD="${AGENTIC_DEV_TEST_CMD:-$(_detect_pkg_script "test")}"
AGENTIC_DEV_TEST_CMD="${AGENTIC_DEV_TEST_CMD:-npm test}"
AGENTIC_DEV_LINT_CMD="${AGENTIC_DEV_LINT_CMD:-$(_detect_pkg_script "lint")}"
AGENTIC_DEV_LINT_CMD="${AGENTIC_DEV_LINT_CMD:-npm run lint}"
AGENTIC_DEV_BUILD_CMD="${AGENTIC_DEV_BUILD_CMD:-$(_detect_pkg_script "build")}"
AGENTIC_DEV_BUILD_CMD="${AGENTIC_DEV_BUILD_CMD:-npm run build}"
AGENTIC_DEV_INSTALL_CMD="${AGENTIC_DEV_INSTALL_CMD:-npm install}"
AGENTIC_DEV_DEV_CMD="${AGENTIC_DEV_DEV_CMD:-$(_detect_pkg_script "dev")}"
AGENTIC_DEV_DEV_CMD="${AGENTIC_DEV_DEV_CMD:-npm run dev}"

# E2E: probe for common script names in decreasing specificity
AGENTIC_DEV_E2E_CMD="${AGENTIC_DEV_E2E_CMD:-$(_detect_pkg_script "test:e2e:full:local" "test:e2e:full" "test:e2e" "e2e")}"
AGENTIC_DEV_E2E_CMD="${AGENTIC_DEV_E2E_CMD:-npm run test:e2e}"
AGENTIC_DEV_E2E_SMOKE_CMD="${AGENTIC_DEV_E2E_SMOKE_CMD:-$(_detect_pkg_script "test:e2e:smoke" "e2e:smoke")}"
AGENTIC_DEV_E2E_SMOKE_CMD="${AGENTIC_DEV_E2E_SMOKE_CMD:-}"

AGENTIC_DEV_CHANGELOG_PATH="${AGENTIC_DEV_CHANGELOG_PATH:-$(_cfg changelogPath)}"
AGENTIC_DEV_CHANGELOG_PATH="${AGENTIC_DEV_CHANGELOG_PATH:-$(_agentic_dev_default_changelog_path)}"

# ── Path detection ──────────────────────────────────────────────────────────
AGENTIC_DEV_CI_WORKFLOW="${AGENTIC_DEV_CI_WORKFLOW:-$(_cfg ciWorkflow)}"
AGENTIC_DEV_CI_WORKFLOW="${AGENTIC_DEV_CI_WORKFLOW:-}"
AGENTIC_DEV_CI_PATHS="${AGENTIC_DEV_CI_PATHS:-$(_cfg ciPaths)}"
AGENTIC_DEV_CI_PATHS="${AGENTIC_DEV_CI_PATHS:-src/ app/ e2e/ package.json tsconfig.json}"
# E2E tier: "full" paths trigger the full E2E suite, "smoke" paths trigger a
# lightweight smoke run, and anything else means no E2E.
# Both are grep -E regexes matched against changed file paths.
AGENTIC_DEV_E2E_FULL_PATHS="${AGENTIC_DEV_E2E_FULL_PATHS:-$(_cfg e2eFullPaths)}"
AGENTIC_DEV_E2E_FULL_PATHS="${AGENTIC_DEV_E2E_FULL_PATHS:-^(app/api/|src/api/|app/lib/|src/lib/|e2e/|tests/e2e/|.*auth|.*payment|.*middleware)}"
AGENTIC_DEV_E2E_SMOKE_PATHS="${AGENTIC_DEV_E2E_SMOKE_PATHS:-$(_cfg e2eSmokePaths)}"
AGENTIC_DEV_E2E_SMOKE_PATHS="${AGENTIC_DEV_E2E_SMOKE_PATHS:-^(app/|src/|pages/|components/).*\.(tsx|jsx|ts|js)$}"
# Legacy alias — still respected if the tiered paths aren't set
AGENTIC_DEV_E2E_PATHS="${AGENTIC_DEV_E2E_PATHS:-$(_cfg e2ePaths)}"
AGENTIC_DEV_E2E_PATHS="${AGENTIC_DEV_E2E_PATHS:-}"

# ── Review configuration ─────────────────────────────────────────────────
AGENTIC_DEV_MAX_REVIEW_ROUNDS="${AGENTIC_DEV_MAX_REVIEW_ROUNDS:-$(_cfg maxReviewRounds)}"
AGENTIC_DEV_MAX_REVIEW_ROUNDS="${AGENTIC_DEV_MAX_REVIEW_ROUNDS:-3}"

# ── CI workflow discovery ────────────────────────────────────────────────
# Unified helper used by both merge-gate.sh and ci-watch.sh.
# Returns the resolved workflow name (or empty if none found).
# Usage: WORKFLOW=$(agentic_dev_discover_ci_workflow <branch> <repo>)
agentic_dev_discover_ci_workflow() {
  local branch="$1" repo="$2"
  # 1. Explicit override
  if [ -n "${AGENTIC_DEV_CI_WORKFLOW}" ]; then
    echo "$AGENTIC_DEV_CI_WORKFLOW"
    return
  fi
  # 2. Most recent run on this branch
  local wf
  wf=$(gh run list --branch "$branch" --repo "$repo" -L 1 \
    --json workflowName --jq '.[0].workflowName // empty' 2>/dev/null || true)
  if [ -n "$wf" ]; then
    echo "$wf"
    return
  fi
  # 3. First workflow defined in the repo
  wf=$(gh api "repos/$repo/actions/workflows" \
    --jq '.workflows[0].name // empty' 2>/dev/null || true)
  echo "$wf"
}

# ── Optional integrations ──────────────────────────────────────────────────
AGENTIC_DEV_ADR_PATH="${AGENTIC_DEV_ADR_PATH:-$(_cfg adrPath)}"
AGENTIC_DEV_ADR_PATH="${AGENTIC_DEV_ADR_PATH:-}"
AGENTIC_DEV_PR_TEMPLATE="${AGENTIC_DEV_PR_TEMPLATE:-$(_cfg prTemplate)}"
AGENTIC_DEV_PR_TEMPLATE="${AGENTIC_DEV_PR_TEMPLATE:-.github/pull_request_template.md}"
AGENTIC_DEV_ISSUE_TEMPLATES="${AGENTIC_DEV_ISSUE_TEMPLATES:-$(_cfg issueTemplates)}"
AGENTIC_DEV_ISSUE_TEMPLATES="${AGENTIC_DEV_ISSUE_TEMPLATES:-.github/ISSUE_TEMPLATE/}"
