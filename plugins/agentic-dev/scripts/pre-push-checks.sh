#!/usr/bin/env bash
set -euo pipefail
#
# Path-aware pre-push checklist.
#
# Diffs against the base branch to decide which checks to run.
# Unknown or risky file types always run the full stack.
#
# Usage:  scripts/pre-push-checks.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Pre-push checks ==="

# ── Validate required config ─────────────────────────────────────────────
: "${AGENTIC_DEV_BASE_BRANCH:?config error: AGENTIC_DEV_BASE_BRANCH is not set}"

# Test, lint, and build commands are optional — repos may not have all three.
# An empty or unset value means that check is not available in this repo and
# will be skipped even if the path classification says it should run.

# ── Verify diff base is available ────────────────────────────────────────
BASE_REF="origin/$AGENTIC_DEV_BASE_BRANCH"
if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  echo "ERROR: $BASE_REF not found locally. Run: git fetch origin $AGENTIC_DEV_BASE_BRANCH"
  exit 1
fi

MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || {
  echo "ERROR: Could not compute merge base between HEAD and $BASE_REF"
  exit 1
}

CHANGED_FILES=$(git diff --name-only "$MERGE_BASE"...HEAD 2>/dev/null)

# ── Path classification ───────────────────────────────────────────────────
# Patterns are grep -E regexes matched against changed file paths.
# Resolution order: env var > project config > built-in default.

AGENTIC_DEV_SKIP_ALL_PATHS="${AGENTIC_DEV_SKIP_ALL_PATHS:-$(_cfg skipAllPaths)}"
AGENTIC_DEV_SKIP_ALL_PATHS="${AGENTIC_DEV_SKIP_ALL_PATHS:-(^|/)LICENSE$|\.(md|mdx|txt|gitignore)$|^(docs/|\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE|CODEOWNERS|FUNDING))}"

# Files that skip build but still run test+lint
# (test files: tests should pass, lint must pass; build is expensive and often irrelevant)
AGENTIC_DEV_SKIP_BUILD_PATHS="${AGENTIC_DEV_SKIP_BUILD_PATHS:-$(_cfg skipBuildPaths)}"
AGENTIC_DEV_SKIP_BUILD_PATHS="${AGENTIC_DEV_SKIP_BUILD_PATHS:-^(__tests__|tests|test)/|^\.github/workflows/}"

# Files that skip tests but still run lint+build
# (pure binary/static assets: no executable logic, tests cannot cover them meaningfully)
AGENTIC_DEV_SKIP_TEST_PATHS="${AGENTIC_DEV_SKIP_TEST_PATHS:-$(_cfg skipTestPaths)}"
AGENTIC_DEV_SKIP_TEST_PATHS="${AGENTIC_DEV_SKIP_TEST_PATHS:-\.(png|jpg|jpeg|gif|ico|woff2?|ttf|eot|svg)$}"

# ── Determine which checks are needed ────────────────────────────────────
if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files relative to $BASE_REF — running full check stack to be safe."
  NEED_TEST=true
  NEED_LINT=true
  NEED_BUILD=true
else
  NEED_TEST=false
  NEED_LINT=false
  NEED_BUILD=false

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_ALL_PATHS"; then
      continue
    fi

    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_BUILD_PATHS"; then
      NEED_TEST=true
      NEED_LINT=true
      continue
    fi

    if echo "$file" | grep -qE "$AGENTIC_DEV_SKIP_TEST_PATHS"; then
      NEED_LINT=true
      NEED_BUILD=true
      continue
    fi

    # Default: unknown file type — run everything
    NEED_TEST=true
    NEED_LINT=true
    NEED_BUILD=true
  done <<< "$CHANGED_FILES"
fi

# ── Run checks ────────────────────────────────────────────────────────────
FAILED_STEP=""
STEPS_RUN=0
STEPS_SKIPPED=0

run_step() {
  local label="$1" cmd="$2"
  STEPS_RUN=$((STEPS_RUN + 1))
  echo "$label"
  if ! bash -c "$cmd"; then
    FAILED_STEP="$label"
    echo ""
    echo "FAILED: $label"
    echo "Command: $cmd"
    return 1
  fi
}

skip_step() {
  STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
  echo "SKIPPED: $1 ($2)"
}

if [ "$NEED_TEST" = true ]; then
  if [ -n "${AGENTIC_DEV_TEST_CMD:-}" ]; then
    run_step "1/3 Tests" "$AGENTIC_DEV_TEST_CMD" || true
  else
    skip_step "Tests" "AGENTIC_DEV_TEST_CMD not configured"
  fi
else
  skip_step "Tests" "no test-affecting files changed"
fi

if [ -z "$FAILED_STEP" ] && [ "$NEED_LINT" = true ]; then
  if [ -n "${AGENTIC_DEV_LINT_CMD:-}" ]; then
    run_step "2/3 Lint" "$AGENTIC_DEV_LINT_CMD" || true
  else
    skip_step "Lint" "AGENTIC_DEV_LINT_CMD not configured"
  fi
elif [ -z "$FAILED_STEP" ]; then
  skip_step "Lint" "no lintable files changed"
fi

if [ -z "$FAILED_STEP" ] && [ "$NEED_BUILD" = true ]; then
  if [ -n "${AGENTIC_DEV_BUILD_CMD:-}" ]; then
    run_step "3/3 Build" "$AGENTIC_DEV_BUILD_CMD" || true
  else
    skip_step "Build" "AGENTIC_DEV_BUILD_CMD not configured"
  fi
elif [ -z "$FAILED_STEP" ]; then
  skip_step "Build" "no build-affecting files changed"
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

# ── Write sentinel (HEAD SHA + merge-base SHA) ────────────────────────────
# The push-ready hook validates both: current HEAD must match and the merge
# base must not have advanced since checks were run.
GIT_DIR=$(git rev-parse --git-dir)
printf '%s:%s' "$(git rev-parse HEAD)" "$MERGE_BASE" > "$GIT_DIR/.pre-push-passed" 2>/dev/null || true
