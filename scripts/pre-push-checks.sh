#!/usr/bin/env bash
set -euo pipefail
#
# Pre-push checklist: test → lint → build (in order).
#
# Usage:  scripts/pre-push-checks.sh

echo "=== Pre-push checks ==="

echo "1/3 Running tests..."
npm test

echo "2/3 Running lint & type-check..."
npm run lint

echo "3/3 Running production build..."
npm run build

echo ""
echo "=== All pre-push checks passed ==="

# Write sentinel for the push-ready hook (SHA-pinned so stale checks are rejected)
git rev-parse HEAD > .pre-push-passed 2>/dev/null || true
