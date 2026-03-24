#!/usr/bin/env bash
set -uo pipefail
#
# Path-aware pre-push checklist.
#
# Diffs against the base branch to decide which checks to run.
# Unknown or risky file types always run the full stack.
#
# Usage:  scripts/pre-push-checks.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Path classification ──────────────────────────────────────────────────
# Configurable patterns for files that DON'T need certain checks.
# Override in .claude/agentic-dev.json or env vars.
# Patterns are grep -E regexes matched against changed file paths.

# Files that need NO checks at all (docs, markdown, non-code assets)
AGENTIC_DEV_SKIP_ALL_PATHS="${AGENTIC_DEV_SKIP_ALL_PATHS:-$(_cfg skipAllPaths)}"
AGENTIC_DEV_SKIP_ALL_PATHS="${AGENTIC_DEV_SKIP_ALL_PATHS:-\.(md|mdx|txt|LICENSE|gitignore)$|^(docs/|\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE|CODEOWNERS|FUNDING))}"

# Files that skip build but still need test+lint (test files, configs)
AGENTIC_DEV_SKIP_BUILD_PATHS="${AGENTIC_DEV_SKIP_BUILD_PATHS:-$(_cfg skipBuildPaths)}"
AGENTIC_DEV_SKIP_BUILD_PATHS="${AGENTIC_DEV_SKIP_BUILD_PATHS:-\.(test|spec)\.(ts|tsx|js|jsx)$|^(__tests__|tests|test)/|^\.claude/|^\.github/workflows/}"

# Files that skip test but still need lint+build (pure style changes)
AGENTIC_DEV_SKIP_TEST_PATHS="${AGENTIC_DEV_SKIP_TEST_PATHS:-$(_cfg skipTestPaths)}"
AGENTIC_DEV_SKIP_TEST_PATHS="${AGENTIC_DEV_SKIP_TEST_PATHS:-\.(css|scss|less|svg|png|jpg|jpeg|gif|ico|woff2?|ttf|eot)$}"

# ── Determine what changed ───────────────────────────────────────────────
BASE_BRANCH="${AGENTIC_DEV_BASE_BRANCH}"
CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null || true)

if [ -z "$CHANGED_FILES" ]; then
  echo "=== Pre-push checks ==="
  echo "No changed files detected — running full check stack to be safe."
  NEED_TEST=true
  NEED_LINT=true
  NEED_BUILD=true
else
  NEED_TEST=false
  NEED_LINT=false
  NEED_BUILD=false

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Skip-all files don't trigger any checks
    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_ALL_PATHS"; then
      continue
    fi

    # At this point the file needs at least something.
    # Check if it's skip-build-only
    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_BUILD_PATHS"; then
      NEED_TEST=true
      NEED_LINT=true
      continue
    fi

    # Check if it's skip-test-only
    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_TEST_PATHS"; then
      NEED_LINT=true
      NEED_BUILD=true
      continue
    fi

    # Unknown/unmatched file — conservative: needs everything
    NEED_TEST=true
    NEED_LINT=true
    NEED_BUILD=true
  done <<< "$CHANGED_FILES"
fi

# ── Run checks ───────────────────────────────────────────────────────────
FAILED_STEP=""
STEPS_RUN=0
STEPS_SKIPPED=0

run_step() {
  local label="$1" cmd="$2"
  STEPS_RUN=$((STEPS_RUN + 1))
  echo "$label"
  if ! eval "$cmd"; then
    FAILED_STEP="$label"
    echo ""
    echo "FAILED at: $label"
    echo "Command:   $cmd"
    return 1
  fi
}

skip_step() {
  local label="$1" reason="$2"
  STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
  echo "$label SKIPPED ($reason)"
}

echo "=== Pre-push checks ==="

if [ "$NEED_TEST" = true ]; then
  run_step "1/3 Running tests..." "$AGENTIC_DEV_TEST_CMD" || true
else
  skip_step "1/3 Tests" "no test-affecting files changed"
fi

if [ -z "$FAILED_STEP" ]; then
  if [ "$NEED_LINT" = true ]; then
    run_step "2/3 Running lint & type-check..." "$AGENTIC_DEV_LINT_CMD" || true
  else
    skip_step "2/3 Lint" "no lintable files changed"
  fi
fi

if [ -z "$FAILED_STEP" ]; then
  if [ "$NEED_BUILD" = true ]; then
    run_step "3/3 Running production build..." "$AGENTIC_DEV_BUILD_CMD" || true
  else
    skip_step "3/3 Build" "no build-affecting files changed"
  fi
fi

if [ -n "$FAILED_STEP" ]; then
  echo ""
  echo "=== Pre-push checks FAILED ==="
  exit 1
fi

echo ""
if [ "$STEPS_SKIPPED" -gt 0 ]; then
  echo "=== Pre-push checks passed ($STEPS_RUN ran, $STEPS_SKIPPED skipped) ==="
else
  echo "=== All pre-push checks passed ==="
fi

# Write sentinel for the push-ready hook (SHA-pinned so stale checks are rejected)
git rev-parse HEAD > "$(git rev-parse --git-dir)/.pre-push-passed" 2>/dev/null || true
