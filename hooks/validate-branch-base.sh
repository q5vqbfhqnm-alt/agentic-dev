#!/bin/bash
# Hook: blocks branch creation from wrong base.
#
# The dev workflow requires branching from `preview` (or `main` for hotfix).
# Branching from any other base silently creates merge problems that surface
# late in the cycle (rebase check or merge conflicts).
#
# PreToolUse hook — receives JSON on stdin.
# Exit 0 = allow, exit 2 = block.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

ALLOWED_BASES="preview|main|origin/preview|origin/main"

# git checkout -b <name> [base]  →  base is word 5 (if present)
# git switch -c <name> [base]    →  base is word 5 (if present)
if echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  # Normalize whitespace and extract positional args
  # Word positions: git(1) checkout(2) -b(3) name(4) base(5)
  WORD_COUNT=$(echo "$COMMAND" | awk '{print NF}')
  BASE=$(echo "$COMMAND" | awk '{print $5}')

  # No explicit base (only 4 words) → allow (defaults to HEAD)
  if [ "$WORD_COUNT" -le 4 ] || [ -z "$BASE" ]; then
    exit 0
  fi

  if ! echo "$BASE" | grep -qE "^($ALLOWED_BASES)$"; then
    echo "BLOCKED: Branch must be created from 'preview' (or 'main' for hotfix). Got base: $BASE" >&2
    exit 2
  fi
  exit 0
fi

# git worktree add [-b <name>] <path> [base]
# The -b flag can appear before or after <path>, so positional parsing is
# unreliable. Instead, strip "git worktree add" and the "-b <name>" pair,
# leaving just "<path> [base]".
if echo "$COMMAND" | grep -qE 'git\s+worktree\s+add\s+'; then
  # Only check if -b is present (creating a new branch)
  if ! echo "$COMMAND" | grep -qE '\s-b\s'; then
    exit 0
  fi

  # Strip the command prefix and the -b <name> flag pair
  ARGS=$(echo "$COMMAND" | sed -E 's/git[[:space:]]+worktree[[:space:]]+add[[:space:]]+//' | sed -E 's/-b[[:space:]]+[^[:space:]]+//')
  # Remaining: <path> [base]  (after trimming whitespace)
  ARGS=$(echo "$ARGS" | xargs)
  ARG_COUNT=$(echo "$ARGS" | awk '{print NF}')
  BASE=$(echo "$ARGS" | awk '{print $2}')

  # Only path, no base → allow (defaults to HEAD)
  if [ "$ARG_COUNT" -le 1 ] || [ -z "$BASE" ]; then
    exit 0
  fi

  if ! echo "$BASE" | grep -qE "^($ALLOWED_BASES)$"; then
    echo "BLOCKED: Worktree branch must be created from 'preview' (or 'main' for hotfix). Got base: $BASE" >&2
    exit 2
  fi
  exit 0
fi

exit 0
