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

# Source shared config so AGENTIC_DEV_BASE_BRANCH is authoritative — without
# this the base-advance check falls back to the hardcoded "preview" default
# even when the repo is configured for a different base branch.
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/config.sh
source "$_HOOK_DIR/../scripts/config.sh" 2>/dev/null || true

# Hard-fail if jq is missing — without it, COMMAND is empty and all checks
# silently pass. Exit 2 so the agent sees the block immediately.
if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: jq is not installed. All hooks require jq to parse tool input. Install jq and retry." >&2
  exit 2
fi

# Append a structured log entry to .git/agentic-dev/hooks.log (best-effort).
_hook_log() {
  local action="$1" detail="$2"
  local log_dir
  log_dir="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  printf '%s\thook=validate-push-ready\taction=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$detail" \
    >> "$log_dir/hooks.log" 2>/dev/null || true
}

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Truncate command for logging (first 120 chars)
_CMD_SHORT="${COMMAND:0:120}"

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
  _hook_log "blocked" "reason=no-sentinel cmd=$_CMD_SHORT"
  echo "BLOCKED: pre-push-checks.sh has not been run. Run it before pushing." >&2
  echo "  bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh\"" >&2
  exit 2
fi

# Sentinel format: <HEAD_SHA>:<MERGE_BASE_SHA>
SENTINEL_CONTENT=$(cat "$SENTINEL" 2>/dev/null || echo "")
SENTINEL_HEAD=$(echo "$SENTINEL_CONTENT" | cut -d: -f1)
SENTINEL_MERGE_BASE=$(echo "$SENTINEL_CONTENT" | cut -d: -f2)

CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# 1. HEAD must match
if [ "$SENTINEL_HEAD" != "$CURRENT_SHA" ]; then
  _hook_log "blocked" "reason=stale-head sentinel=$SENTINEL_HEAD current=$CURRENT_SHA cmd=$_CMD_SHORT"
  echo "BLOCKED: pre-push-checks.sh passed on $SENTINEL_HEAD but HEAD is now $CURRENT_SHA. Re-run checks." >&2
  exit 2
fi

# 2. Merge base must not have advanced (base branch may have received new commits)
if [ -n "$SENTINEL_MERGE_BASE" ]; then
  BASE_BRANCH=$(git for-each-ref --format='%(upstream:short)' "$(git symbolic-ref HEAD 2>/dev/null)" 2>/dev/null \
    | sed 's|origin/||' || true)
  # Fall back to AGENTIC_DEV_BASE_BRANCH if upstream is not set
  BASE_BRANCH="${BASE_BRANCH:-${AGENTIC_DEV_BASE_BRANCH:-preview}}"
  BASE_REF="origin/$BASE_BRANCH"

  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    CURRENT_MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)
    if [ -n "$CURRENT_MERGE_BASE" ] && [ "$CURRENT_MERGE_BASE" != "$SENTINEL_MERGE_BASE" ]; then
      _hook_log "blocked" "reason=base-advanced sentinel-base=$SENTINEL_MERGE_BASE current-base=$CURRENT_MERGE_BASE cmd=$_CMD_SHORT"
      echo "BLOCKED: $BASE_REF has advanced since checks were run. Re-run pre-push-checks.sh." >&2
      exit 2
    fi
  fi
fi

exit 0
