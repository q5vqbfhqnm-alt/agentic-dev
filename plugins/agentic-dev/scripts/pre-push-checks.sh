#!/usr/bin/env bash
set -euo pipefail
#
# Pre-push checklist: test → lint → build (in order).
#
# Usage:  scripts/pre-push-checks.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Pre-push checks ==="

echo "1/3 Running tests..."
eval "$AGENTIC_DEV_TEST_CMD"

echo "2/3 Running lint & type-check..."
eval "$AGENTIC_DEV_LINT_CMD"

echo "3/3 Running production build..."
eval "$AGENTIC_DEV_BUILD_CMD"

echo ""
echo "=== All pre-push checks passed ==="

# Write sentinel for the push-ready hook (SHA-pinned so stale checks are rejected)
git rev-parse HEAD > "$(git rev-parse --git-dir)/.pre-push-passed" 2>/dev/null || true
