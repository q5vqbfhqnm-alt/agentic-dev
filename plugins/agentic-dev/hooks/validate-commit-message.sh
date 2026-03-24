#!/bin/bash
# Hook: enforces commit message convention.
#
# Format: feat|fix|refactor(scope): short description [(closes #N)]
# On the trivial path, (closes #N) is optional.
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
  printf '%s\thook=validate-commit-message\taction=%s\t%s\n' \
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

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
  _hook_log "allowed" "reason=not-commit cmd=$_CMD_SHORT"
  exit 0
fi

# Skip amend, merge commits, and commits with --allow-empty-message
if echo "$COMMAND" | grep -qE '\-\-(amend|allow-empty-message)'; then
  _hook_log "allowed" "reason=amend-or-merge cmd=$_CMD_SHORT"
  exit 0
fi

# Extract the commit message from -m "..." or -m '...'
# Handle heredoc first — must check before -m "..." since heredoc also contains -m "
MSG=""
if echo "$COMMAND" | grep -q 'cat <<'; then
  # Heredoc pattern — extract first line of the message body
  MSG=$(echo "$COMMAND" | sed -n '/cat <</{n;p;}' | head -1 | sed 's/^[[:space:]]*//')
elif echo "$COMMAND" | grep -qE '\-m[[:space:]]+"'; then
  MSG=$(echo "$COMMAND" | sed -n -E 's/.*-m[[:space:]]+"([^"]+)".*/\1/p' | head -1)
elif echo "$COMMAND" | grep -qE "\-m[[:space:]]+'"; then
  MSG=$(echo "$COMMAND" | sed -n -E "s/.*-m[[:space:]]+'([^']+)'.*/\1/p" | head -1)
fi

# If we couldn't extract the message, allow it (don't block on parse failure)
if [ -z "$MSG" ]; then
  _hook_log "allowed" "reason=unparseable-msg cmd=$_CMD_SHORT"
  exit 0
fi

# Extract just the first line for validation
FIRST_LINE=$(echo "$MSG" | head -1)

# Validate format: type(scope): description
if ! echo "$FIRST_LINE" | grep -qE '^(feat|fix|refactor|docs|test|chore)\([^)]+\): .+'; then
  _hook_log "blocked" "reason=bad-commit-msg msg=$FIRST_LINE"
  echo "BLOCKED: Commit message doesn't match convention." >&2
  echo "  Expected: feat|fix|refactor|docs|test|chore(scope): description" >&2
  echo "  Got: $FIRST_LINE" >&2
  exit 2
fi

_hook_log "allowed" "msg=$FIRST_LINE"
exit 0
