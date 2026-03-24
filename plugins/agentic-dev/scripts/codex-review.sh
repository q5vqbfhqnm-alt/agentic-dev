#!/usr/bin/env bash
set -euo pipefail
#
# Run Codex review for a PR (Round 1 — fresh session).
#
# Must be run from inside a worktree on the PR branch.
# Posts review as a PR comment and outputs session ID.
#
# Usage:  scripts/codex-review.sh <PR_NUMBER>
# Output: Prints CODEX_SESSION_ID=<id> on the last line (for re-review).

PR_NUMBER="${1:?Usage: codex-review.sh <PR_NUMBER>}"
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Verify we're on the PR branch, not preview/main
CURRENT_BRANCH=$(git branch --show-current)
PR_DATA=$(gh pr view "$PR_NUMBER" --json headRefName,baseRefName)
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')

if [ "$CURRENT_BRANCH" != "$HEAD_BRANCH" ]; then
  echo "ERROR: Current branch ($CURRENT_BRANCH) does not match PR branch ($HEAD_BRANCH)"
  echo "You must run this from inside the worktree on the PR branch."
  exit 1
fi

# Ensure base is fresh for accurate diff
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

# Temp files — clean up on exit (including failures due to set -e)
REVIEW_OUTPUT=$(mktemp)
PROMPT_FILE=$(mktemp)
CODEX_LOG=$(mktemp)
COMMENT_FILE=$(mktemp)
trap 'rm -f "$REVIEW_OUTPUT" "$PROMPT_FILE" "$CODEX_LOG" "$COMMENT_FILE"' EXIT

# Build prompt in a temp file to avoid quoting issues with variable expansion
cat > "$PROMPT_FILE" <<PROMPT
Review PR #${PR_NUMBER} as a skeptical reviewer.

You are on the PR branch (${HEAD_BRANCH}). The base branch is ${BASE_BRANCH}.

Step 1: Read the diff.
Run: git diff origin/${BASE_BRANCH}...HEAD

Step 2: Read the linked issue.
Run: gh pr view ${PR_NUMBER} --json body --jq '.body'
Scan the body for any issue reference using GitHub's closing keywords: Closes, Fixes, Resolves, close, fix, resolve (case-insensitive), followed by #N. Also look for bare #N references that appear to identify the driving issue. If multiple issues are referenced, read all of them. If none are found, proceed without an issue.
Run: gh issue view <N> --json title,body --jq '.title, .body' (for each issue found)

Step 3: Review. Do not modify any files.

Review for findings, not praise. Assume the happy path works.
For every non-pass finding include:
- severity: BLOCKER | STRONG | NICE
- file and line reference when possible
- problem
- why it matters
- exact change to make

Only report NICE findings when you are >=80% confident the issue is real and actionable.
Do NOT flag: style preferences, linter-catchable issues, pre-existing problems not introduced by this PR, code with lint-ignore comments, subjective improvements, or the issue's "E2E Required" field (E2E execution is handled by the merge gate, not by this review).

Check:
1. Spec alignment — AC met, edge cases covered, any drift from issue documented
2. Undocumented decisions — deviations from spec or docs/ADR.md patterns that are not noted in the PR description
3. Regression risk — shared code, call sites, adjacent flows likely affected by this change
4. State and UX — loading, error, and empty states handled
5. Test quality — gaps, weak assertions, missing edge-case coverage
6. Architectural alignment — follows existing codebase patterns
7. Security — auth, data exposure, silent failures (empty catch blocks, swallowed errors, generic error messages without actionable guidance)
8. Deploy risk — config, env vars, migration safety, rollback plan if needed
9. Observability — Sentry context on new failure paths

Before finalizing, verify that all 9 items are covered and that every claim is grounded in the diff, repo code, PR metadata, or linked issue.

Output exactly in this structure:

Reviewed against issue #[N] or [none found].

### 1. Spec alignment
[findings or pass]

### 2. Undocumented decisions
[findings or pass]

### 3. Regression risk
[findings or pass]

### 4. State and UX
[findings or pass]

### 5. Test quality
[findings or pass]

### 6. Architectural alignment
[findings or pass]

### 7. Security
[findings or pass]

### 8. Deploy risk
[findings or pass]

### 9. Observability
[findings or pass]

### Summary
- List all BLOCKER and STRONG findings first.
- If none, say no blocking findings.

### Verdict
VERDICT: approved — if zero BLOCKER and zero STRONG findings.
VERDICT: blocked — if any BLOCKER or STRONG finding exists.
Output exactly one of these two lines. This is the final word.
PROMPT

# Run Codex review with the full 9-point prompt
# Capture terminal output (contains session ID) separately from -o file (review body)
if ! $CODEX_CMD exec -s read-only -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG"; then
  echo "ERROR: Codex exec failed (exit code $?)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex review failed** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-review.sh\` or check Codex CLI / API key status."
  exit 3
fi

REVIEW_BODY=$(cat "$REVIEW_OUTPUT")

# Extract verdict before any truncation — it lives at the end of the output
VERDICT_LINE=$(echo "$REVIEW_BODY" | grep -i '^VERDICT:' | tail -1 || true)

# Hard-fail if no verdict was produced — a verdict-less review is not actionable.
# Post a failure comment so the merge gate sees a clear signal, then exit non-zero
# so the calling agent knows the review did not complete.
if [ -z "$VERDICT_LINE" ]; then
  echo "ERROR: Codex produced a review but no VERDICT line was found." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex review produced no verdict** — the review output did not contain a \`VERDICT:\` line. This may indicate a truncated response or a Codex failure. Re-run \`codex-review.sh\`."
  exit 4
fi

# Truncate if exceeding GitHub comment limit (65,536 chars)
if [ ${#REVIEW_BODY} -gt 65000 ]; then
  FULL_REVIEW_PATH="${TMPDIR:-/tmp}/codex-review-pr${PR_NUMBER}-$(date +%s).txt"
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

# Delete previous agentic-dev review comments to avoid noise accumulation
PREV_COMMENT_IDS=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq '[.[] | select(.body | test("<!-- agentic-dev:codex-review:v1 -->")) | .id] | .[]' 2>/dev/null || true)
for cid in $PREV_COMMENT_IDS; do
  gh api -X DELETE "repos/$REPO/issues/comments/$cid" --silent 2>/dev/null || true
done

# Post review as PR comment (file-based to avoid shell argument limits)
printf '%s' "$REVIEW_BODY" > "$COMMENT_FILE"
gh pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE"
echo ""
echo "Codex verdict: $VERDICT_LINE"

# Extract session ID for re-review (best-effort)
# Codex prints "session id: <uuid>" in terminal output, not in the -o file.
# Search the terminal log first, then fall back to codex resume --last.
CODEX_SESSION_ID=$(sed $'s/\033\\[[0-9;]*m//g' "$CODEX_LOG" | grep -oE 'session id: [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | sed 's/session id: //' || true)
if [ -z "$CODEX_SESSION_ID" ]; then
  CODEX_SESSION_ID=$($CODEX_CMD resume --last --json 2>/dev/null | jq -r '.id // empty' || true)
fi

if [ -z "$CODEX_SESSION_ID" ]; then
  echo "WARNING: Could not extract Codex session ID. Re-review will require a fresh session."
fi
echo "CODEX_SESSION_ID=${CODEX_SESSION_ID:-none}"

# Persist session state to .git/agentic-dev/session-{branch}.json (best-effort).
# The orchestrator and re-review script can read this as the authoritative source
# for session ID, verdict, and round number across context boundaries.
_SESSION_DIR="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
if mkdir -p "$_SESSION_DIR" 2>/dev/null; then
  _SESSION_FILE="$_SESSION_DIR/session-${HEAD_BRANCH}.json"
  cat > "$_SESSION_FILE" <<SESSIONJSON
{
  "pr_number": ${PR_NUMBER},
  "branch": "${HEAD_BRANCH}",
  "codex_session_id": "${CODEX_SESSION_ID:-none}",
  "verdict": "$(echo "$VERDICT_LINE" | sed 's/^VERDICT:[[:space:]]*//')",
  "round": 1,
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
SESSIONJSON
fi
