#!/usr/bin/env bash
set -euo pipefail
#
# Run Codex re-review for a PR (session resume).
#
# Resumes a previous Codex session to verify fixes. Only allows new BLOCKER
# findings — scope shrinks each round to prevent infinite review loops.
#
# If session ID is "none" (extraction failed in round 1), falls back to
# a fresh codex exec with prior review context injected via PR comments.
#
# Must be run from inside a worktree on the PR branch.
#
# Usage:  scripts/codex-re-review.sh <PR_NUMBER> <CODEX_SESSION_ID> <ROUND>

PR_NUMBER="${1:?Usage: codex-re-review.sh <PR_NUMBER> <CODEX_SESSION_ID> <ROUND>}"
CODEX_SESSION_ID="${2:?Missing CODEX_SESSION_ID}"
ROUND="${3:?Missing round number}"
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Verify we're on the PR branch
CURRENT_BRANCH=$(git branch --show-current)
HEAD_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')

if [ "$CURRENT_BRANCH" != "$HEAD_BRANCH" ]; then
  echo "ERROR: Current branch ($CURRENT_BRANCH) does not match PR branch ($HEAD_BRANCH)"
  exit 1
fi

git fetch origin "$BASE_BRANCH" --quiet

# Verify Codex is available and resolve the invocation to use for execution
if command -v codex >/dev/null 2>&1; then
  CODEX_CMD="codex"
elif npx @openai/codex --version >/dev/null 2>&1; then
  CODEX_CMD="npx @openai/codex"
else
  echo "ERROR: Codex CLI is not installed."
  echo "Install with: npm install -g @openai/codex"
  echo "Or set OPENAI_API_KEY and use npx @openai/codex"
  exit 1
fi

# Temp files — clean up on exit
REVIEW_OUTPUT=$(mktemp)
PROMPT_FILE=$(mktemp)
CODEX_LOG=$(mktemp)
COMMENT_FILE=$(mktemp)
trap 'rm -f "$REVIEW_OUTPUT" "$PROMPT_FILE" "$CODEX_LOG" "$COMMENT_FILE"' EXIT

# Build re-review prompt
cat > "$PROMPT_FILE" <<PROMPT
Re-review PR #${PR_NUMBER}. This is review round ${ROUND}.

I fixed the BLOCKER/STRONG findings from your previous review.
Run: git diff origin/${BASE_BRANCH}...HEAD   to see the updated diff.
Run: gh pr view ${PR_NUMBER} --comments --json comments --jq '.comments[].body'   to see your previous review and my fix notes.
Run: gh pr view ${PR_NUMBER} --json body --jq '.body'   — scan for any issue reference using GitHub closing keywords (Closes, Fixes, Resolves, close, fix, resolve, case-insensitive) followed by #N, plus any bare #N references that appear to identify the driving issue. If multiple issues are found, read all of them. If none are found, proceed without an issue.
Run: gh issue view <N> --json title,body --jq '.title, .body'   (for each issue found) to get the latest spec (it may have changed since round 1).

IMPORTANT: The linked issue may have been updated since the previous review round.
Re-read the issue to get the current acceptance criteria before evaluating:
Run: gh pr view ${PR_NUMBER} --json body --jq '.body'   — apply the same closing-keyword scan as above to find all linked issues.
Run: gh issue view <N> --json body --jq '.body'   (for each issue found) to get the current issue ACs.
If an AC was updated to match the implementation, mark the corresponding finding as RESOLVED.

Your job now:
1. Re-read the linked issue as the authoritative spec — it supersedes any spec details from prior rounds.
2. Verify each previous BLOCKER/STRONG finding is fixed against the latest spec. Mark as RESOLVED or STILL OPEN.
3. You may raise NEW findings only if they are BLOCKER severity (would cause data loss, security breach, or runtime crash). Do NOT raise new STRONG or NICE findings — the scope of this review is to verify fixes, not to expand the review.

Output exactly:

### Previous findings
- [finding]: RESOLVED / STILL OPEN

### New findings (BLOCKER only)
- [any new BLOCKER, or 'none']

### Verdict
VERDICT: approved — if all previous findings are RESOLVED and no new BLOCKERs.
VERDICT: blocked — if any previous finding is STILL OPEN or a new BLOCKER exists.
Output exactly one of these two lines.
PROMPT

# Run re-review — resume session if available, fresh exec if not
# codex exec resume accepts -o but not -s/--sandbox (sandbox inherited from original session).
CODEX_FAILED=0
if [ "$CODEX_SESSION_ID" != "none" ] && [ -n "$CODEX_SESSION_ID" ]; then
  $CODEX_CMD exec resume "$CODEX_SESSION_ID" -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG" || CODEX_FAILED=$?
else
  echo "WARNING: No session ID — running fresh codex exec (no memory of prior findings)"
  # Prepend context note so Codex knows to rely on PR comments for prior review
  NOTE_FILE=$(mktemp)
  echo "NOTE: This is a fresh session (no memory of prior rounds). Read PR comments carefully for your previous review findings before evaluating." > "$NOTE_FILE"
  cat "$PROMPT_FILE" >> "$NOTE_FILE"
  mv "$NOTE_FILE" "$PROMPT_FILE"
  $CODEX_CMD exec -s read-only -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG" || CODEX_FAILED=$?
fi

if [ "$CODEX_FAILED" -ne 0 ]; then
  echo "ERROR: Codex exec failed (exit code $CODEX_FAILED)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex re-review failed (round ${ROUND})** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-re-review.sh\` or check Codex CLI / API key status."
  exit 3
fi

REVIEW_BODY=$(cat "$REVIEW_OUTPUT")

# Extract verdict before any truncation — it lives at the end of the output
VERDICT_LINE=$(echo "$REVIEW_BODY" | grep -i '^VERDICT:' | tail -1 || true)

# Truncate if exceeding GitHub comment limit
if [ ${#REVIEW_BODY} -gt 65000 ]; then
  FULL_REVIEW_PATH="${TMPDIR:-/tmp}/codex-re-review-pr${PR_NUMBER}-r${ROUND}-$(date +%s).txt"
  printf '%s' "$REVIEW_BODY" > "$FULL_REVIEW_PATH"
  echo "WARNING: Review body exceeds GitHub comment limit. Truncating."
  echo "Full review saved to: $FULL_REVIEW_PATH"
  REVIEW_BODY="${REVIEW_BODY:0:64000}

...[truncated — full review saved to $FULL_REVIEW_PATH]

${VERDICT_LINE}"
fi

# Stamp with machine marker so merge-gate.sh can verify origin
REVIEW_MARKER="<!-- agentic-dev:codex-review:v1 -->"
REVIEW_BODY="${REVIEW_MARKER}
${REVIEW_BODY}"

# Post review as PR comment (file-based to avoid shell argument limits)
printf '%s' "$REVIEW_BODY" > "$COMMENT_FILE"
gh pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE"
echo ""
echo "Codex verdict: $VERDICT_LINE"

