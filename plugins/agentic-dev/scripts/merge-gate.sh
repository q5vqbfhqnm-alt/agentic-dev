#!/usr/bin/env bash
set -euo pipefail
#
# Merge gate: anti-hallucination check.
#
# Verifies that a Codex review comment with VERDICT: approved exists on the PR
# AND that the comment's reviewed-sha marker matches the current head commit SHA.
# This prevents merging on a PR that has been modified since it was last reviewed.
#
# Note on authenticity: verification is limited to comment body pattern matching
# (marker + SHA). Any actor able to post a PR comment with the
# agentic-dev:codex-review:v1 marker can satisfy this gate. The gate's primary
# purpose is preventing the model from merging without having run the review
# scripts at all — not preventing a determined adversary from spoofing a comment.
#
# Exits 0 if a valid SHA-matched approved comment is found, 1 otherwise.
#
# Usage:  scripts/merge-gate.sh <PR_NUMBER>

PR_NUMBER="${1:?Usage: merge-gate.sh <PR_NUMBER>}"
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Get the current PR head SHA
HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json headRefOid --jq '.headRefOid')

if [ -z "$HEAD_SHA" ]; then
  echo "ERROR: Could not determine PR head SHA"
  exit 1
fi

# Find an approval comment whose reviewed-sha marker matches the current HEAD.
# The marker format is: <!-- agentic-dev:codex-review:v1 reviewed-sha:<SHA> -->
APPROVAL=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq --arg sha "$HEAD_SHA" '
    [.[]
      | select(.body | test("<!-- agentic-dev:codex-review:v1 reviewed-sha:" + $sha))
      | select(.body | test("VERDICT:.*approved"; "i"))
    ] | last // empty
  ')

if [ -n "$APPROVAL" ]; then
  COMMENT_ID=$(echo "$APPROVAL" | jq -r '.id')
  echo "Codex review: approved (comment #$COMMENT_ID reviewed sha $HEAD_SHA)"
  exit 0
else
  # Distinguish between "no approval ever" and "approval for a different SHA"
  ANY_APPROVAL=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
    --jq '[.[] | select(.body | test("<!-- agentic-dev:codex-review:v1")) | select(.body | test("VERDICT:.*approved"; "i"))] | last // empty')

  if [ -n "$ANY_APPROVAL" ]; then
    STALE_SHA=$(echo "$ANY_APPROVAL" | jq -r '.body' \
      | grep -oE 'reviewed-sha:[0-9a-f]{40}' | head -1 | sed 's/reviewed-sha://' || echo "unknown")
    echo "Codex review: approval exists but for a different commit (approved sha $STALE_SHA, current sha $HEAD_SHA)"
    echo "New commits were pushed after the review — re-review required"
  else
    echo "Codex review: no approved comment found — review has not been run"
  fi
  exit 1
fi
