#!/bin/bash
# Hook: blocks branch creation from wrong base.
#
# The dev workflow requires branching from the base branch (or `main` for hotfix).
# Branching from any other base silently creates merge problems that surface
# late in the cycle (rebase check or merge conflicts).
#
# PreToolUse hook — receives JSON on stdin.
# Exit 0 = allow, exit 2 = block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/config.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

ALLOWED_BASES="${AGENTIC_DEV_BASE_BRANCH}|main|origin/${AGENTIC_DEV_BASE_BRANCH}|origin/main"

# Check if a local base ref is behind its origin counterpart.
# Blocks when the local ref exists but is strictly behind origin (i.e. not up-to-date).
# Skips the check for origin/* refs (already remote) or when origin ref doesn't exist.
check_stale_base() {
  local base="$1"
  # Skip if already an origin/ ref
  case "$base" in origin/*) return 0 ;; esac

  local origin_ref="origin/$base"
  # Skip if origin ref doesn't exist locally (can't compare)
  if ! git rev-parse --verify "$origin_ref" >/dev/null 2>&1; then
    return 0
  fi
  # Skip if local ref doesn't exist (nothing to be stale)
  if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
    return 0
  fi

  local behind
  behind=$(git rev-list --count "$base".."$origin_ref" 2>/dev/null || echo 0)
  if [ "$behind" -gt 0 ]; then
    echo "BLOCKED: Local '$base' is $behind commit(s) behind '$origin_ref'. Run 'git fetch origin $base' first." >&2
    return 1
  fi
  return 0
}

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
    echo "BLOCKED: Branch must be created from '${AGENTIC_DEV_BASE_BRANCH}' (or 'main' for hotfix). Got base: $BASE" >&2
    exit 2
  fi
  if ! check_stale_base "$BASE"; then
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
    echo "BLOCKED: Worktree branch must be created from '${AGENTIC_DEV_BASE_BRANCH}' (or 'main' for hotfix). Got base: $BASE" >&2
    exit 2
  fi
  if ! check_stale_base "$BASE"; then
    exit 2
  fi
  exit 0
fi

exit 0
