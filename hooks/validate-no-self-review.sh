#!/bin/bash
# Deterministic Codex guardrail: blocks the review agent from running
# any command that looks like a self-review (diff summary, git diff piped
# to analysis, or posting review comments without Codex).
#
# This hook receives PreToolUse JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (stderr fed back as error).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block attempts to post PR reviews directly (not via codex-review scripts)
if echo "$COMMAND" | grep -qE 'gh\s+pr\s+review' && ! echo "$COMMAND" | grep -q 'codex-review'; then
  echo "BLOCKED: Direct PR review commands are not allowed. Use the codex-review scripts." >&2
  exit 2
fi

# Block direct gh pr comment — review comments must be posted by the bundled
# review scripts (which run as subprocesses of "bash scripts/codex-review*.sh"
# and are therefore invisible to this hook). A direct "gh pr comment" call from
# either agent would bypass the Codex requirement.
if echo "$COMMAND" | grep -qE 'gh\s+pr\s+comment'; then
  echo "BLOCKED: Direct PR comment commands are not allowed. Reviews must be posted by the codex-review scripts." >&2
  exit 2
fi

# Block gh api calls to the issue/PR comments endpoint — same bypass vector
# as gh pr comment but via the raw API.
if echo "$COMMAND" | grep -qE 'gh\s+api\s+.*issues/[0-9]+/comments'; then
  echo "BLOCKED: Direct API calls to the comments endpoint are not allowed. Reviews must be posted by the codex-review scripts." >&2
  exit 2
fi

# Block attempts to run codex review or codex review --base (must use checked-in scripts)
if echo "$COMMAND" | grep -qE 'codex\s+review'; then
  echo "BLOCKED: Do not use 'codex review' directly. Use scripts/codex-review.sh or scripts/codex-re-review.sh." >&2
  exit 2
fi

exit 0
