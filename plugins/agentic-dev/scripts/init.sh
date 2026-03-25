#!/usr/bin/env bash
set -euo pipefail
#
# agentic-dev setup checker.
#
# Verifies prerequisites, detects the build system, checks the base branch,
# and prints a resolved configuration summary.
#
# Usage:  bash scripts/init.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ! $1"; WARN=$((WARN + 1)); }

echo "=== agentic-dev setup ==="
echo ""

# ── 1. Prerequisites ───────────────────────────────────────────────────────
echo "Prerequisites:"

# git
if command -v git >/dev/null 2>&1; then
  pass "git $(git --version | sed 's/git version //')"
else
  fail "git is not installed"
fi

# Inside a git repo
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Inside a git repository"
else
  fail "Not inside a git repository — run this from your project root"
fi

# gh CLI
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    pass "gh CLI (authenticated)"
  else
    fail "gh CLI installed but not authenticated — run: gh auth login"
  fi
else
  fail "gh CLI not installed — https://cli.github.com"
fi

# Codex CLI
if command -v codex >/dev/null 2>&1; then
  pass "Codex CLI (global)"
elif npx @openai/codex --version >/dev/null 2>&1; then
  pass "Codex CLI (via npx)"
else
  fail "Codex CLI not installed — run: npm install -g @openai/codex"
fi

# OPENAI_API_KEY
if [ -n "${OPENAI_API_KEY:-}" ]; then
  pass "OPENAI_API_KEY is set"
else
  fail "OPENAI_API_KEY not set — required for Codex reviews"
fi

# jq
if command -v jq >/dev/null 2>&1; then
  pass "jq $(jq --version 2>/dev/null || echo '')"
else
  fail "jq not installed — required by hooks and scripts"
fi

echo ""

# ── 2. Build system detection ──────────────────────────────────────────────
echo "Build system:"

_report_cmd() {
  local label="$1" cmd="$2" suggested="$3"
  if [ -n "$cmd" ]; then
    pass "$label: $cmd"
  else
    warn "$label: not configured (will skip) — suggested: $suggested"
  fi
}

if [ -f "package.json" ]; then
  pass "Detected: npm (package.json)"
  _report_cmd "Test"  "$AGENTIC_DEV_TEST_CMD"  "export AGENTIC_DEV_TEST_CMD='npm test'"
  _report_cmd "Lint"  "$AGENTIC_DEV_LINT_CMD"  "export AGENTIC_DEV_LINT_CMD='npm run lint'"
  _report_cmd "Build" "$AGENTIC_DEV_BUILD_CMD" "export AGENTIC_DEV_BUILD_CMD='npm run build'"
elif [ -f "Makefile" ]; then
  warn "Detected: Make — set build commands"
  echo "    Suggested:"
  echo "      export AGENTIC_DEV_TEST_CMD='make test'"
  echo "      export AGENTIC_DEV_LINT_CMD='make lint'"
  echo "      export AGENTIC_DEV_BUILD_CMD='make build'"
elif [ -f "Cargo.toml" ]; then
  warn "Detected: Rust (Cargo) — set build commands"
  echo "    Suggested:"
  echo "      export AGENTIC_DEV_TEST_CMD='cargo test'"
  echo "      export AGENTIC_DEV_LINT_CMD='cargo clippy'"
  echo "      export AGENTIC_DEV_BUILD_CMD='cargo build'"
elif [ -f "go.mod" ]; then
  warn "Detected: Go — set build commands"
  echo "    Suggested:"
  echo "      export AGENTIC_DEV_TEST_CMD='go test ./...'"
  echo "      export AGENTIC_DEV_LINT_CMD='golangci-lint run'"
  echo "      export AGENTIC_DEV_BUILD_CMD='go build ./...'"
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  warn "Detected: Python — set build commands"
  echo "    Suggested:"
  echo "      export AGENTIC_DEV_TEST_CMD='pytest'"
  echo "      export AGENTIC_DEV_LINT_CMD='ruff check .'"
  echo "      export AGENTIC_DEV_BUILD_CMD='python -m build'"
elif [ -n "$AGENTIC_DEV_TEST_CMD" ] || [ -n "$AGENTIC_DEV_LINT_CMD" ] || [ -n "$AGENTIC_DEV_BUILD_CMD" ]; then
  pass "Custom build commands configured"
  _report_cmd "Test"  "$AGENTIC_DEV_TEST_CMD"  ""
  _report_cmd "Lint"  "$AGENTIC_DEV_LINT_CMD"  ""
  _report_cmd "Build" "$AGENTIC_DEV_BUILD_CMD" ""
else
  warn "No recognized build system — set AGENTIC_DEV_TEST_CMD, AGENTIC_DEV_LINT_CMD, AGENTIC_DEV_BUILD_CMD"
fi

echo ""

# ── 3. Base branch ─────────────────────────────────────────────────────────
echo "Base branch: $AGENTIC_DEV_BASE_BRANCH"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Check local
  if git show-ref --verify --quiet "refs/heads/$AGENTIC_DEV_BASE_BRANCH" 2>/dev/null; then
    pass "Local branch '$AGENTIC_DEV_BASE_BRANCH' exists"
  else
    fail "Local branch '$AGENTIC_DEV_BASE_BRANCH' does not exist"
    echo "    Create it:  git checkout -b $AGENTIC_DEV_BASE_BRANCH"
    echo "    Or change:  export AGENTIC_DEV_BASE_BRANCH=main"
  fi

  # Check remote
  if git ls-remote --exit-code --heads origin "$AGENTIC_DEV_BASE_BRANCH" >/dev/null 2>&1; then
    pass "Remote branch 'origin/$AGENTIC_DEV_BASE_BRANCH' exists"
  else
    warn "Remote branch 'origin/$AGENTIC_DEV_BASE_BRANCH' not found"
    echo "    Push it:    git push -u origin $AGENTIC_DEV_BASE_BRANCH"
  fi
fi

echo ""

# ── 4. GitHub templates ────────────────────────────────────────────────────
echo "GitHub templates:"

TEMPLATE_SRC="$SCRIPT_DIR/../templates"
ISSUE_TPL_DIR="$AGENTIC_DEV_ISSUE_TEMPLATES"
PR_TPL_PATH="$AGENTIC_DEV_PR_TEMPLATE"
SCAFFOLDED=0

if [ -d "$ISSUE_TPL_DIR" ] && [ "$(ls -A "$ISSUE_TPL_DIR" 2>/dev/null)" ]; then
  pass "Issue templates found in $ISSUE_TPL_DIR"
else
  warn "No issue templates found at $ISSUE_TPL_DIR"
  if [ -d "$TEMPLATE_SRC/ISSUE_TEMPLATE" ]; then
    mkdir -p "$ISSUE_TPL_DIR"
    cp "$TEMPLATE_SRC/ISSUE_TEMPLATE"/*.md "$ISSUE_TPL_DIR/"
    pass "Scaffolded issue templates (feature, bug, refactor, chore) → $ISSUE_TPL_DIR"
    SCAFFOLDED=$((SCAFFOLDED + 1))
  fi
fi

if [ -f "$PR_TPL_PATH" ]; then
  pass "PR template found at $PR_TPL_PATH"
else
  warn "No PR template found at $PR_TPL_PATH"
  if [ -f "$TEMPLATE_SRC/pull_request_template.md" ]; then
    mkdir -p "$(dirname "$PR_TPL_PATH")"
    cp "$TEMPLATE_SRC/pull_request_template.md" "$PR_TPL_PATH"
    pass "Scaffolded PR template → $PR_TPL_PATH"
    SCAFFOLDED=$((SCAFFOLDED + 1))
  fi
fi

if [ "$SCAFFOLDED" -gt 0 ]; then
  echo ""
  echo "  $SCAFFOLDED template(s) scaffolded. Review and commit them to your repo."
fi

echo ""

# ── 5. Configuration summary ───────────────────────────────────────────────
echo "Resolved configuration:"
echo "  Base branch:     $AGENTIC_DEV_BASE_BRANCH"
echo "  Protected:       $AGENTIC_DEV_PROTECTED_BRANCHES"
echo "  Test command:    $AGENTIC_DEV_TEST_CMD"
echo "  Lint command:    $AGENTIC_DEV_LINT_CMD"
echo "  Build command:   $AGENTIC_DEV_BUILD_CMD"
echo "  Install command: $AGENTIC_DEV_INSTALL_CMD"
echo "  Dev command:     $AGENTIC_DEV_DEV_CMD"
echo "  CHANGELOG path:  $AGENTIC_DEV_CHANGELOG_PATH"
echo "  CI workflow:     ${AGENTIC_DEV_CI_WORKFLOW:-<auto-discover>}"
echo "  CI paths:        $AGENTIC_DEV_CI_PATHS"
echo "  ADR path:        ${AGENTIC_DEV_ADR_PATH:-<not set>}"
echo "  PR template:     $AGENTIC_DEV_PR_TEMPLATE"
echo "  Issue templates: $AGENTIC_DEV_ISSUE_TEMPLATES"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $WARN warnings ==="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Fix the failures above before using the workflow."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Warnings are optional but recommended to address."
fi

echo ""
echo "Ready to use the orchestrator workflow!"
