#!/usr/bin/env bash
set -euo pipefail
#
# Run Codex review for a TRIVIAL PR (focused two-question prompt).
#
# Same mechanics as codex-review.sh (branch validation, verdict extraction,
# PR comment posting) but with a minimal prompt scoped to correctness and
# non-obvious breakage. This prompt should not grow beyond its two-question
# scope without a deliberate decision — see issue #321.
#
# Must be run from inside a worktree on the PR branch.
# Posts review as a PR comment and outputs session ID.
#
# Usage:  scripts/codex-review-trivial.sh <PR_NUMBER>
# Output: Prints CODEX_SESSION_ID=<id> on the last line (for re-review).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PR_NUMBER="${1:?Usage: codex-review-trivial.sh <PR_NUMBER>}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed"; exit 1; }

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

# Pin the head SHA now — we verify it again after Codex runs to detect mid-review pushes
REVIEWED_SHA=$(git rev-parse HEAD)

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
if [ -n "${AGENTIC_DEV_CODEX_LOG_PATH:-}" ]; then
  CODEX_LOG="$AGENTIC_DEV_CODEX_LOG_PATH"
  mkdir -p "$(dirname "$CODEX_LOG")"
  : > "$CODEX_LOG"
  PRESERVE_CODEX_LOG=1
else
  CODEX_LOG=$(mktemp)
  PRESERVE_CODEX_LOG="${AGENTIC_DEV_KEEP_CODEX_LOG:-0}"
fi
COMMENT_FILE=$(mktemp)
trap 'rm -f "$REVIEW_OUTPUT" "$PROMPT_FILE" "$COMMENT_FILE"; if [ "$PRESERVE_CODEX_LOG" != "1" ]; then rm -f "$CODEX_LOG"; fi' EXIT

# Build prompt — intentionally minimal. Two questions only.
cat > "$PROMPT_FILE" <<PROMPT
Review this pull request. It was classified as trivial (small scope, no logic/schema/auth impact) by the orchestrator.

Answer exactly three questions:
1. Scope validation — does the diff match the trivial classification? If it touches logic, schema, auth, or shared infra, say so explicitly as a BLOCKER.
2. Correctness — does the diff do what the PR description says?
3. Non-obvious breakage — could shared code, conditional rendering, CSS cascade, or import/export consumers break?

Rules:
- BLOCKER and STRONG findings only.
- Do not report NICE findings, style preferences, or pre-existing issues.
- In any section with no findings, output exactly: pass
- For any finding, use one bullet in this format:
  - [SEVERITY] file:line — problem. Exact change.

Output exactly in this structure:

### 1. Scope validation
pass

### 2. Correctness
pass

### 3. Non-obvious breakage
pass

### Verdict
VERDICT: approved — if zero BLOCKER and zero STRONG findings.
VERDICT: blocked — if any BLOCKER or STRONG finding exists.
Output exactly one of these two lines. This is the final word.

Context for this review:
- PR number: ${PR_NUMBER}
- PR branch: ${HEAD_BRANCH}
- Base branch: ${BASE_BRANCH}

Read in this order:
1. The diff:
Run: git diff origin/${BASE_BRANCH}...HEAD

2. The PR description:
Run: gh pr view ${PR_NUMBER} --json body --jq '.body'
PROMPT

# Run Codex review with the focused trivial prompt
echo "Streaming Codex terminal output to: $CODEX_LOG"
echo "Tip: tail -f \"$CODEX_LOG\" from another terminal to watch live."
CODEX_SANDBOX_ARGS=$(agentic_dev_codex_sandbox_args)
CODEX_EXIT=0
$CODEX_CMD exec $CODEX_SANDBOX_ARGS -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG" || CODEX_EXIT=$?
if [ "$CODEX_EXIT" -ne 0 ]; then
  echo "ERROR: Codex exec failed (exit code $CODEX_EXIT)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex trivial review failed** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-review-trivial.sh\` or check Codex CLI / API key status."
  exit 3
fi

# Verify the PR head has not moved while Codex was running
CURRENT_PR_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [ -n "$CURRENT_PR_SHA" ] && [ "$CURRENT_PR_SHA" != "$REVIEWED_SHA" ]; then
  echo "ERROR: PR head moved from $REVIEWED_SHA to $CURRENT_PR_SHA during review. Re-run review on the new commit." >&2
  exit 5
fi

REVIEW_BODY=$(cat "$REVIEW_OUTPUT")

# Extract verdict before any truncation — it lives at the end of the output
VERDICT_LINE=$(echo "$REVIEW_BODY" | grep -i '^VERDICT:' | tail -1 || true)

# Hard-fail if no verdict was produced — a verdict-less review is not actionable.
if [ -z "$VERDICT_LINE" ]; then
  echo "ERROR: Codex produced a review but no VERDICT line was found." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex trivial review produced no verdict** — the review output did not contain a \`VERDICT:\` line. This may indicate a truncated response or a Codex failure. Re-run \`codex-review-trivial.sh\`."
  exit 4
fi

# Truncate if exceeding GitHub comment limit (65,536 chars)
if [ ${#REVIEW_BODY} -gt 65000 ]; then
  FULL_REVIEW_PATH="${TMPDIR:-/tmp}/codex-review-trivial-pr${PR_NUMBER}-$(date +%s).txt"
  printf '%s' "$REVIEW_BODY" > "$FULL_REVIEW_PATH"
  echo "WARNING: Review body exceeds GitHub comment limit. Truncating."
  echo "Full review saved to: $FULL_REVIEW_PATH"
  REVIEW_BODY="${REVIEW_BODY:0:64000}

...[truncated — full review saved to $FULL_REVIEW_PATH]

${VERDICT_LINE}"
fi

# Stamp with machine marker (includes reviewed SHA for downstream binding)
REVIEW_MARKER="<!-- agentic-dev:codex-review:v1 reviewed-sha:${REVIEWED_SHA} -->"
REVIEW_BODY="${REVIEW_MARKER}
${REVIEW_BODY}"

# Collect old review comment IDs BEFORE posting — ensures new comment is live
# before any deletes, so the PR is never left without a review artifact
PREV_COMMENT_IDS=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq '[.[] | select(.body | test("<!-- agentic-dev:codex-review:v1")) | .id] | .[]' 2>/dev/null || true)

# Post new review comment
printf '%s' "$REVIEW_BODY" > "$COMMENT_FILE"
gh pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE"

# Now safe to delete old comments (new comment is already posted)
for cid in $PREV_COMMENT_IDS; do
  gh api -X DELETE "repos/$REPO/issues/comments/$cid" --silent 2>/dev/null || true
done

echo ""
echo "Codex verdict: $VERDICT_LINE"
# Emit raw VERDICT line for review-agent parsing (grep '^VERDICT:')
echo "$VERDICT_LINE"

# Extract session ID for re-review (best-effort)
CODEX_SESSION_ID=$(sed $'s/\033\\[[0-9;]*m//g' "$CODEX_LOG" | grep -oE 'session id: [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | sed 's/session id: //' || true)
if [ -z "$CODEX_SESSION_ID" ]; then
  CODEX_SESSION_ID=$($CODEX_CMD resume --last --json 2>/dev/null | jq -r '.id // empty' || true)
fi

if [ -z "$CODEX_SESSION_ID" ]; then
  echo "WARNING: Could not extract Codex session ID. Re-review will require a fresh session."
fi
echo "CODEX_SESSION_ID=${CODEX_SESSION_ID:-none}"

# Persist session state — use jq -n to ensure JSON is always well-formed
_SESSION_DIR="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
_SAFE_BRANCH="${HEAD_BRANCH//\//--}"
if mkdir -p "$_SESSION_DIR" 2>/dev/null; then
  _SESSION_FILE="$_SESSION_DIR/session-${_SAFE_BRANCH}.json"
  _VERDICT_TEXT=$(echo "$VERDICT_LINE" | sed 's/^VERDICT:[[:space:]]*//')
  _ROUND=$(echo "$VERDICT_LINE" | grep -qi 'approved' && echo 0 || echo 1)
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg branch "$HEAD_BRANCH" \
    --arg codex_session_id "${CODEX_SESSION_ID:-none}" \
    --arg verdict "$_VERDICT_TEXT" \
    --arg reviewed_sha "$REVIEWED_SHA" \
    --argjson round_completed 1 \
    --argjson round "$_ROUND" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pr_number: $pr_number, branch: $branch, codex_session_id: $codex_session_id,
      verdict: $verdict, reviewed_sha: $reviewed_sha,
      round_completed: $round_completed, round: $round, updated_at: $updated_at}' \
    > "$_SESSION_FILE" 2>/dev/null || true
fi
