#!/usr/bin/env bash
set -euo pipefail
#
# Merge gate: anti-hallucination check.
#
# Accepts either of two comment markers, both requiring a SHA match:
#
#   1. Codex approval    — agentic-dev:codex-review:v1 with VERDICT: approved
#      Posted by the codex-review scripts after Codex clears the PR.
#
#   2. User override     — agentic-dev:user-override:v1
#      Posted by the user running scripts/user-override.sh from their terminal.
#      Never posted by any agent. Accepts responsibility for merging despite
#      missing/blocked Codex approval.
#
# The model cannot post either marker directly — the no-self-review hook blocks
# gh pr comment and direct API POSTs. The distinction matters for auditability:
# a Codex approval means the guardrail was satisfied; a user override means the
# user consciously assumed responsibility.
#
# Note on authenticity: verification is limited to comment body pattern matching
# (marker + SHA). The gate's primary purpose is preventing the model from merging
# without any review artifact at all — not preventing a determined adversary from
# spoofing comments.
#
# Exits 0 if a valid SHA-matched approval or user-override comment is found, 1 otherwise.
#
# Usage:  scripts/merge-gate.sh <PR_NUMBER>

PR_NUMBER="${1:?Usage: merge-gate.sh <PR_NUMBER>}"
REPO=$(gh repo view --json nameWithOwner | jq -r '.nameWithOwner')

# Get the current PR head SHA
HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json headRefOid | jq -r '.headRefOid')

if [ -z "$HEAD_SHA" ]; then
  echo "ERROR: Could not determine PR head SHA"
  exit 1
fi

# Fetch all comments once; filter locally so test stubs don't need to implement --jq.
COMMENTS=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments")

# Path 1: Codex approval comment matching the current HEAD.
# Marker format: <!-- agentic-dev:codex-review:v1 reviewed-sha:<SHA> -->
APPROVAL=$(echo "$COMMENTS" | jq --arg sha "$HEAD_SHA" '
    [.[]
      | select(.body | test("<!-- agentic-dev:codex-review:v1 reviewed-sha:" + $sha))
      | select(.body | test("VERDICT:.*approved"; "i"))
    ] | last // empty
  ')

if [ -n "$APPROVAL" ]; then
  COMMENT_ID=$(echo "$APPROVAL" | jq -r '.id')
  echo "Codex review: approved (comment #$COMMENT_ID reviewed sha $HEAD_SHA)"
  exit 0
fi

# Path 2: User override comment matching the current HEAD.
# Marker format: <!-- agentic-dev:user-override:v1 reviewed-sha:<SHA> -->
# Only reachable after the user runs scripts/user-override.sh from their terminal.
USER_OVERRIDE=$(echo "$COMMENTS" | jq --arg sha "$HEAD_SHA" '
    [.[]
      | select(.body | test("<!-- agentic-dev:user-override:v1 reviewed-sha:" + $sha))
    ] | last // empty
  ')

if [ -n "$USER_OVERRIDE" ]; then
  COMMENT_ID=$(echo "$USER_OVERRIDE" | jq -r '.id')
  echo "Merge gate: user override accepted (comment #$COMMENT_ID reviewed sha $HEAD_SHA)"
  exit 0
fi

# Neither path matched — distinguish for diagnostics
ANY_CODEX=$(echo "$COMMENTS" | jq '[.[] | select(.body | test("<!-- agentic-dev:codex-review:v1")) | select(.body | test("VERDICT:.*approved"; "i"))] | last // empty')

if [ -n "$ANY_CODEX" ]; then
  STALE_SHA=$(echo "$ANY_CODEX" | jq -r '.body' \
    | grep -oE 'reviewed-sha:[0-9a-f]{40}' | head -1 | sed 's/reviewed-sha://' || echo "unknown")
  echo "Codex review: approval exists but for a different commit (approved sha $STALE_SHA, current sha $HEAD_SHA)"
  echo "New commits were pushed after the review — re-review required"
else
  echo "Codex review: no approved comment found — review has not been run"
fi
exit 1
