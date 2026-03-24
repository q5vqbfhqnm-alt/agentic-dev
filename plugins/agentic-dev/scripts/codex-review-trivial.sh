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

PR_NUMBER="${1:?Usage: codex-review-trivial.sh <PR_NUMBER>}"
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
Review this pull request. It is a trivial change with small scope and no logic, schema, or auth impact.

Answer exactly two questions:
1. Correctness — does the diff do what the PR description says?
2. Non-obvious breakage — could shared code, conditional rendering, CSS cascade, or import/export consumers break?

Rules:
- BLOCKER and STRONG findings only.
- Do not report NICE findings, style preferences, or pre-existing issues.
- In any section with no findings, output exactly: pass
- For any finding, use one bullet in this format:
  - [SEVERITY] file:line — problem. Exact change.

Output exactly in this structure:

### 1. Correctness
pass

### 2. Non-obvious breakage
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
# Capture terminal output (contains session ID) separately from -o file (review body)
echo "Streaming Codex terminal output to: $CODEX_LOG"
echo "Tip: tail -f \"$CODEX_LOG\" from another terminal to watch live."
if ! $CODEX_CMD exec -s read-only -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG"; then
  echo "ERROR: Codex exec failed (exit code $?)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex trivial review failed** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-review-trivial.sh\` or check Codex CLI / API key status."
  exit 3
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
# Sanitize branch name: replace / with -- so fix/foo becomes session-fix--foo.json
_SESSION_DIR="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
_SAFE_BRANCH="${HEAD_BRANCH//\//--}"
if mkdir -p "$_SESSION_DIR" 2>/dev/null; then
  _SESSION_FILE="$_SESSION_DIR/session-${_SAFE_BRANCH}.json"
  cat > "$_SESSION_FILE" <<SESSIONJSON
{
  "pr_number": ${PR_NUMBER},
  "branch": "${HEAD_BRANCH}",
  "codex_session_id": "${CODEX_SESSION_ID:-none}",
  "verdict": "$(echo "$VERDICT_LINE" | sed 's/^VERDICT:[[:space:]]*//')",
  "round_completed": 1,
  "round": $(if echo "$VERDICT_LINE" | grep -qi 'approved'; then echo 0; else echo 1; fi),
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
SESSIONJSON
fi
