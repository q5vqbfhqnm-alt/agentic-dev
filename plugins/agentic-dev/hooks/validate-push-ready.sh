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
  _hook_log "allowed" "cmd=<non-bash>"
  exit 0
fi

# Truncate command for logging (first 120 chars)
_CMD_SHORT="${COMMAND:0:120}"

# Only intercept git push commands
if ! echo "$COMMAND" | grep -qE 'git\s+push'; then
  _hook_log "allowed" "reason=not-push cmd=$_CMD_SHORT"
  exit 0
fi

# Allow push --tags, push --delete, and other non-code pushes
if echo "$COMMAND" | grep -qE 'git\s+push\s+--(tags|delete|mirror)'; then
  _hook_log "allowed" "reason=non-code-push cmd=$_CMD_SHORT"
  exit 0
fi

SENTINEL="$(git rev-parse --git-dir 2>/dev/null)/.pre-push-passed"

if [ ! -f "$SENTINEL" ]; then
  _hook_log "blocked" "reason=no-sentinel cmd=$_CMD_SHORT"
  echo "BLOCKED: pre-push-checks.sh has not been run. Run it before pushing." >&2
  echo "  bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pre-push-checks.sh\"" >&2
  exit 2
fi

# Verify the sentinel matches current HEAD (checks weren't run on stale code)
SENTINEL_SHA=$(cat "$SENTINEL" 2>/dev/null)
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

if [ "$SENTINEL_SHA" != "$CURRENT_SHA" ]; then
  _hook_log "blocked" "reason=stale-sentinel cmd=$_CMD_SHORT"
  echo "BLOCKED: pre-push-checks.sh passed on commit $SENTINEL_SHA but HEAD is now $CURRENT_SHA. Re-run checks." >&2
  exit 2
fi

_hook_log "allowed" "cmd=$_CMD_SHORT"
exit 0
