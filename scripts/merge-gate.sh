#!/usr/bin/env bash
set -euo pipefail
#
# Local replacement for merge-gate.yml
#
# Runs release checks against a PR and auto-merges if all pass.
# CHANGELOG is auto-generated from PR metadata on success (not during /dev).
# Requires: gh CLI authenticated with write access.
#
# Usage:  ./scripts/merge-gate.sh <PR_NUMBER>

PR_NUMBER="${1:?Usage: merge-gate.sh <PR_NUMBER>}"
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

echo "=== Merge Gate ==="
echo "PR: #$PR_NUMBER  Repo: $REPO"

# Fetch all PR metadata in a single API call
PR_DATA=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json headRefName,mergeable,body,title)
BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_BODY_RAW=$(echo "$PR_DATA" | jq -r '.body')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')

# Determine if full E2E is needed based on which files the PR touches.
# Set AGENTIC_DEV_E2E_PATHS to a grep -E regex matching E2E-sensitive paths
# in your project. Defaults to common patterns.
E2E_PATHS="${AGENTIC_DEV_E2E_PATHS:-^(app/api/|app/lib/|src/api/|src/lib/|e2e/|tests/e2e/)}"
BASE_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName --jq '.baseRefName')
CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null || true)
E2E_REQUIRED="false"
if echo "$CHANGED_FILES" | grep -qE "$E2E_PATHS"; then
  E2E_REQUIRED="true"
fi

FAILED=0

# 0. Codex review comment exists (anti-hallucination gate)
#    Matches both Round 1 (9-point checklist: "### 1. Spec alignment") and
#    re-review comments ("### Previous findings"). Both contain a VERDICT line.
#    Also requires the machine marker stamped by the bundled review scripts —
#    comments without it are ignored even if they match the structure.
REVIEW_COMMENTS_JSON=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq '[.[] | select(.body | test("VERDICT:")) | select(.body | test("<!-- agentic-dev:codex-review:v1 -->")) | select(.body | test("### (1\\. Spec alignment|1\\. Correctness|Previous findings)"))]')
REVIEW_COUNT=$(echo "$REVIEW_COMMENTS_JSON" | jq 'length')

if [ "$REVIEW_COUNT" -gt "0" ]; then
  VERDICT_LINE=$(echo "$REVIEW_COMMENTS_JSON" | jq -r 'last | .body' | grep -i '^VERDICT:' | tail -1)
  if echo "$VERDICT_LINE" | grep -qi 'approved'; then
    echo "0. Codex review passed (VERDICT: approved)"
  else
    echo "0. Codex review found BUT VERDICT is not approved: $VERDICT_LINE"
    FAILED=1
  fi
else
  echo "0. No Codex review comment found — review has not been run"
  echo "   A PR comment with structured checklist and VERDICT line is required."
  echo "   This is a hard blocker. The model cannot skip or fake the review."
  FAILED=1
fi

# 1. CI passed (tolerates rebase-only changes since last green run)
#    Auto-discover workflow if not set: use most recent run on this branch.
if [ -n "$AGENTIC_DEV_CI_WORKFLOW" ]; then
  CI_WORKFLOW="$AGENTIC_DEV_CI_WORKFLOW"
else
  CI_WORKFLOW=$(gh run list --branch "$BRANCH" --repo "$REPO" -L 1 --json workflowName --jq '.[0].workflowName // empty' 2>/dev/null || true)
fi

if [ -z "$CI_WORKFLOW" ]; then
  echo "1. No CI workflow found — skipping CI check"
else
  CI_RUN=$(gh run list --branch "$BRANCH" \
    --workflow "$CI_WORKFLOW" --repo "$REPO" --json headSha,conclusion \
    --jq '[.[] | select(.conclusion=="success")][0] // empty')
  CI_SHA=$(echo "$CI_RUN" | jq -r '.headSha // empty')

  if [ -z "$CI_SHA" ]; then
    echo "1. CI has never passed on this branch"
    FAILED=1
  else
    # Check if any source files changed between the green run and current HEAD.
    CI_PATHS="${AGENTIC_DEV_CI_PATHS:-src/ app/ e2e/ package.json tsconfig.json}"
    CODE_DIFF=$(git diff "$CI_SHA"...HEAD -- $CI_PATHS 2>/dev/null || echo "changed")
    if [ -z "$CODE_DIFF" ]; then
      echo "1. CI passed (no source changes since green run)"
    else
      echo "1. CI passed previously but source files changed since — re-run required"
      FAILED=1
    fi
  fi
fi

# 2. Full E2E verified (if diff touches E2E-sensitive paths)
#    The E2E command is project-specific. Set AGENTIC_DEV_E2E_CMD in the
#    consuming repo's environment.
E2E_CMD="${AGENTIC_DEV_E2E_CMD:-npm run test:e2e}"
if [ "$E2E_REQUIRED" = "true" ]; then
  echo "2. Diff touches E2E-sensitive paths — running full E2E locally..."
  if eval "$E2E_CMD"; then
    echo "   Full E2E passed"
  else
    echo "   Full E2E failed"
    FAILED=1
  fi
else
  echo "2. E2E not required — skipping full suite"
fi

# 3. PR is mergeable (no conflicts)
if [ "$MERGEABLE" = "MERGEABLE" ]; then
  echo "3. PR is mergeable"
elif [ "$MERGEABLE" = "UNKNOWN" ]; then
  echo "3. Mergeability not yet computed — try again in a few seconds"
  FAILED=1
else
  echo "3. PR is not mergeable (status: $MERGEABLE)"
  FAILED=1
fi

# 4. PR description has no placeholders
if echo "$PR_BODY_RAW" | grep -qiE '\[TODO\]|\[placeholder\]|\[fill in\]'; then
  echo "4. PR description contains placeholder text"
  FAILED=1
else
  echo "4. PR description looks complete"
fi

# 5. Check for new env vars (warn, don't block — only added lines)
ENV_VARS=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null \
  | grep '^+' | grep -oE 'process\.env\.[A-Z_]+' | sort -u || true)
if [ -n "$ENV_VARS" ]; then
  echo "5. New env vars detected — verify they are set in Vercel:"
  echo "$ENV_VARS" | sed 's/^/   /'
else
  echo "5. No new env vars"
fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: Release checks did not pass"
  exit 1
fi

echo "All release checks passed"

# 6. Auto-generate CHANGELOG entry from PR metadata
#    Runs only on success — never pushes a CHANGELOG commit for a failed gate.
#    Uses [skip ci] to avoid re-triggering CI and blocking --auto merge.
TODAY=$(date +%Y-%m-%d)

# Extract bullet points: lines starting with "- Added/Fixed/Changed/Removed:"
# Sanitize: strip HTML tags and markdown links to prevent injection via PR body.
CHANGELOG_BULLETS=$(echo "$PR_BODY_RAW" \
  | grep -E '^\s*-\s*(Added|Fixed|Changed|Removed):' \
  | sed 's/<[^>]*>//g' \
  | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
  || true)
if [ -z "$CHANGELOG_BULLETS" ]; then
  # Sanitize the fallback title too
  SAFE_TITLE=$(echo "$PR_TITLE" | sed 's/<[^>]*>//g')
  CHANGELOG_BULLETS="- Changed: $SAFE_TITLE"
fi

CHANGELOG_ENTRY=$(printf "## %s — %s\n%s" "$TODAY" "$PR_TITLE" "$CHANGELOG_BULLETS")
CHANGELOG_PATH="docs/CHANGELOG.md"

# Get current file content and SHA from the PR branch
EXISTING=$(gh api "repos/$REPO/contents/$CHANGELOG_PATH?ref=$BRANCH" \
  --jq '{sha: .sha, content: .content}' 2>/dev/null || echo '{}')
FILE_SHA=$(echo "$EXISTING" | jq -r '.sha // empty')
EXISTING_CONTENT=$(echo "$EXISTING" | jq -r '.content // empty' | base64 -d 2>/dev/null || echo "# Changelog")

# Build new content: header + new entry + rest
HEADER=$(echo "$EXISTING_CONTENT" | head -1)
REST=$(echo "$EXISTING_CONTENT" | tail -n +2)
NEW_CONTENT=$(printf "%s\n\n%s\n%s" "$HEADER" "$CHANGELOG_ENTRY" "$REST")

# Base64 encode — tr -d '\n' for cross-platform safety (macOS vs GNU)
NEW_B64=$(printf '%s' "$NEW_CONTENT" | base64 | tr -d '\n')

# Commit via GitHub Contents API (no local checkout)
COMMIT_ARGS=(-X PUT \
  -f message="docs: auto-update CHANGELOG for PR #$PR_NUMBER" \
  -f content="$NEW_B64" \
  -f branch="$BRANCH")
[ -n "$FILE_SHA" ] && COMMIT_ARGS+=(-f sha="$FILE_SHA")

gh api "repos/$REPO/contents/$CHANGELOG_PATH" "${COMMIT_ARGS[@]}" --silent
echo "6. CHANGELOG.md auto-updated from PR metadata"

# 7. Merge (squash, delete remote branch — no branch protection on preview)
echo ""
echo "Merging PR #$PR_NUMBER..."
gh pr merge "$PR_NUMBER" --repo "$REPO" --squash --delete-branch

# 8. Clean up worktree (if one exists for this PR branch)
WORKTREE_PATH=$(git worktree list --porcelain \
  | grep -B1 "branch refs/heads/$BRANCH" \
  | head -1 | sed 's/^worktree //')
if [ -n "$WORKTREE_PATH" ] && [ "$WORKTREE_PATH" != "$(git rev-parse --show-toplevel)" ]; then
  git worktree remove "$WORKTREE_PATH" 2>/dev/null || true
  git branch -d "$BRANCH" 2>/dev/null || true
  echo "8. Cleaned up worktree: $WORKTREE_PATH"
else
  echo "8. No worktree found for branch $BRANCH"
fi

echo ""
echo "=== Merge Gate complete ==="
