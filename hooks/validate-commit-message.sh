#!/bin/bash
# Hook: enforces commit message convention.
#
# Format: feat|fix|refactor(scope): short description [(closes #N)]
# On the trivial path, (closes #N) is optional.
#
# PreToolUse hook — receives JSON on stdin.
# Exit 0 = allow, exit 2 = block.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
  exit 0
fi

# Skip amend, merge commits, and commits with --allow-empty-message
if echo "$COMMAND" | grep -qE '\-\-(amend|allow-empty-message)'; then
  exit 0
fi

# Extract the commit message from -m "..." or -m '...'
# Handle both single and double quotes, and the heredoc pattern
MSG=""
if echo "$COMMAND" | grep -qE '\-m[[:space:]]+"'; then
  MSG=$(echo "$COMMAND" | sed -E 's/.*-m[[:space:]]+"([^"]+)".*/\1/')
elif echo "$COMMAND" | grep -qE "\-m[[:space:]]+'"; then
  MSG=$(echo "$COMMAND" | sed -E "s/.*-m[[:space:]]+'([^']+)'.*/\1/")
elif echo "$COMMAND" | grep -q 'cat <<'; then
  # Heredoc pattern — extract first line of the message
  MSG=$(echo "$COMMAND" | sed -n '/cat <</{n;p;}' | head -1 | sed 's/^[[:space:]]*//')
fi

# If we couldn't extract the message, allow it (don't block on parse failure)
if [ -z "$MSG" ]; then
  exit 0
fi

# Extract just the first line for validation
FIRST_LINE=$(echo "$MSG" | head -1)

# Validate format: type(scope): description
if ! echo "$FIRST_LINE" | grep -qE '^(feat|fix|refactor|docs|test|chore)\([^)]+\): .+'; then
  echo "BLOCKED: Commit message doesn't match convention." >&2
  echo "  Expected: feat|fix|refactor|docs|test|chore(scope): description" >&2
  echo "  Got: $FIRST_LINE" >&2
  exit 2
fi

exit 0
