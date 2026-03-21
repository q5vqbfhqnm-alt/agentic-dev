#!/bin/bash
# Hook: blocks git push unless pre-push-checks.sh has passed.
#
# The ship skill requires all pre-push checks (test, lint, build) to pass
# before pushing. This hook enforces that sequencing deterministically.
#
# The sentinel file (.pre-push-passed) is written by a wrapper and checked
# here. It includes the HEAD commit SHA at time of check, so pushing after
# new commits without re-running checks is also blocked.
#
# PreToolUse hook — receives JSON on stdin.
# Exit 0 = allow, exit 2 = block.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only intercept git push commands
if ! echo "$COMMAND" | grep -qE 'git\s+push'; then
  exit 0
fi

# Allow push --tags, push --delete, and other non-code pushes
if echo "$COMMAND" | grep -qE 'git\s+push\s+--(tags|delete|mirror)'; then
  exit 0
fi

SENTINEL="$(git rev-parse --git-dir 2>/dev/null)/.pre-push-passed"

if [ ! -f "$SENTINEL" ]; then
  echo "BLOCKED: pre-push-checks.sh has not been run. Run it before pushing." >&2
  echo "  bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh\"" >&2
  exit 2
fi

# Verify the sentinel matches current HEAD (checks weren't run on stale code)
SENTINEL_SHA=$(cat "$SENTINEL" 2>/dev/null)
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

if [ "$SENTINEL_SHA" != "$CURRENT_SHA" ]; then
  echo "BLOCKED: pre-push-checks.sh passed on commit $SENTINEL_SHA but HEAD is now $CURRENT_SHA. Re-run checks." >&2
  exit 2
fi

exit 0
