#!/usr/bin/env bash
set -euo pipefail
#
# User override: post an explicit merge-authorisation comment on a PR.
#
# This script is run directly by the user from their terminal — never by an
# agent. It posts an agentic-dev:user-override:v1 marker comment tied to the
# current PR head SHA, which the merge gate accepts in place of a Codex approval.
#
# Running this script is an explicit statement that the user has reviewed the
# outstanding findings and accepts responsibility for merging.
#
# Usage:  bash scripts/user-override.sh <PR_NUMBER>

PR_NUMBER="${1:?Usage: user-override.sh <PR_NUMBER>}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid')

if [ -z "$HEAD_SHA" ]; then
  echo "ERROR: Could not determine PR head SHA for PR #$PR_NUMBER" >&2
  exit 1
fi

PR_TITLE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title --jq '.title')

echo "PR #$PR_NUMBER: $PR_TITLE"
echo "HEAD SHA: $HEAD_SHA"
echo ""
echo "You are about to authorise a merge override for this PR."
echo "This bypasses Codex review. You accept responsibility for any outstanding findings."
echo ""
printf "Type 'yes' to confirm: "
read -r CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$(cat <<EOF
<!-- agentic-dev:user-override:v1 reviewed-sha:${HEAD_SHA} -->

**User override — merge authorised.**

The user has reviewed the outstanding findings for this PR and explicitly
authorises merge despite missing or blocked Codex approval. The user accepts
responsibility for this decision.

SHA reviewed: \`${HEAD_SHA}\`
EOF
)"

echo ""
echo "Override comment posted for SHA $HEAD_SHA."
echo "The merge gate will now accept this PR. Tell the orchestrator to proceed."
