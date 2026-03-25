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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PR_NUMBER="${1:?Usage: codex-re-review.sh <PR_NUMBER> <CODEX_SESSION_ID> <ROUND>}"
CODEX_SESSION_ID="${2:?Missing CODEX_SESSION_ID}"
ROUND="${3:?Missing round number}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed"; exit 1; }

discover_linked_issues() {
  local body="$1"
  # Only explicit closing keywords — no bare #N fallback to avoid pulling in unrelated issues
  printf '%s\n' "$body" \
    | grep -ioE '(closes|fixes|resolves|close|fix|resolve)[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' \
    | awk 'NF && !seen[$0]++' || true
}

# Hard guard: reject rounds above the configured maximum
MAX_ROUNDS="${AGENTIC_DEV_MAX_REVIEW_ROUNDS:-3}"
if ! [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: AGENTIC_DEV_MAX_REVIEW_ROUNDS is not a valid integer: '$MAX_ROUNDS'"
  exit 1
fi
if [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
  echo "ERROR: Round $ROUND exceeds maximum ($MAX_ROUNDS). Escalate to user."
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Verify we're on the PR branch
CURRENT_BRANCH=$(git branch --show-current)
PR_DATA=$(gh pr view "$PR_NUMBER" --json headRefName,baseRefName,body)
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')
PR_BODY_RAW=$(echo "$PR_DATA" | jq -r '.body // empty')

if [ "$CURRENT_BRANCH" != "$HEAD_BRANCH" ]; then
  echo "ERROR: Current branch ($CURRENT_BRANCH) does not match PR branch ($HEAD_BRANCH)"
  exit 1
fi

git fetch origin "$BASE_BRANCH" --quiet

# Pin the head SHA now — verify again after Codex to detect mid-review pushes
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

# Temp files — clean up on exit
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

LINKED_ISSUES=()
while IFS= read -r issue; do
  [ -n "$issue" ] && LINKED_ISSUES+=("$issue")
done < <(discover_linked_issues "$PR_BODY_RAW")

if [ "${#LINKED_ISSUES[@]}" -gt 0 ]; then
  REVIEWED_AGAINST=$(printf '#%s ' "${LINKED_ISSUES[@]}")
  REVIEWED_AGAINST="${REVIEWED_AGAINST% }"
  ISSUE_PROMPT_BLOCK="Linked issue(s) already discovered from the PR body: ${REVIEWED_AGAINST}
Read each linked issue:
$(for issue in "${LINKED_ISSUES[@]}"; do
  printf "Run: gh issue view %s --json title,body --jq '.title, .body'\n" "$issue"
done)"
else
  REVIEWED_AGAINST="none found"
  ISSUE_PROMPT_BLOCK="No linked issue was found in the PR body. Proceed without an issue."
fi

# Build re-review prompt
cat > "$PROMPT_FILE" <<PROMPT
Re-review this pull request.

Your job now:
1. Use the PR description as the authoritative spec. Linked issue(s) are supporting context only.
2. Verify each previous BLOCKER/STRONG finding is fixed against the PR description. Mark as RESOLVED or STILL OPEN.
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

Context for this review:
- PR number: ${PR_NUMBER}
- PR branch: ${HEAD_BRANCH}
- Base branch: ${BASE_BRANCH}
- Review round: ${ROUND}

Read in this order:
1. The updated diff:
Run: git diff origin/${BASE_BRANCH}...HEAD

2. Previous review and fix notes:
Run: gh pr view ${PR_NUMBER} --comments --json comments --jq '.comments[].body'

3. The linked issue(s):
${ISSUE_PROMPT_BLOCK}
PROMPT

# Run re-review — resume session if available, fresh exec if not
# codex exec resume accepts -o but not -s/--sandbox (sandbox inherited from original session).
echo "Streaming Codex terminal output to: $CODEX_LOG"
echo "Tip: tail -f \"$CODEX_LOG\" from another terminal to watch live."
CODEX_FAILED=0
if [ "$CODEX_SESSION_ID" != "none" ] && [ -n "$CODEX_SESSION_ID" ]; then
  $CODEX_CMD exec resume "$CODEX_SESSION_ID" -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG" || CODEX_FAILED=$?
else
  echo "WARNING: No session ID — running fresh codex exec with reduced confidence"
  # Prepend a short fallback note so Codex reconstructs prior findings from PR comments.
  NOTE_FILE=$(mktemp)
  cat > "$NOTE_FILE" <<'FALLBACK_NOTE'
NOTE: Fresh session fallback. Reconstruct prior findings from PR comments.
If you are unsure whether a prior finding is fully resolved, mark it as STILL OPEN.
Add this line at the top of your output:
⚠️ REDUCED CONFIDENCE — fresh session fallback (no prior context)
FALLBACK_NOTE
  cat "$PROMPT_FILE" >> "$NOTE_FILE"
  mv "$NOTE_FILE" "$PROMPT_FILE"
  CODEX_SANDBOX_ARGS=$(agentic_dev_codex_sandbox_args)
  $CODEX_CMD exec $CODEX_SANDBOX_ARGS -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG" || CODEX_FAILED=$?
fi

if [ "$CODEX_FAILED" -ne 0 ]; then
  echo "ERROR: Codex exec failed (exit code $CODEX_FAILED)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex re-review failed (round ${ROUND})** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-re-review.sh\` or check Codex CLI / API key status."
  exit 3
fi

# Verify the PR head has not moved while Codex was running
CURRENT_PR_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [ -n "$CURRENT_PR_SHA" ] && [ "$CURRENT_PR_SHA" != "$REVIEWED_SHA" ]; then
  echo "ERROR: PR head moved from $REVIEWED_SHA to $CURRENT_PR_SHA during review. Re-run review on the new commit." >&2
  exit 5
fi

# After fallback exec, try to recover a new session ID so subsequent rounds can resume
if [ "$CODEX_SESSION_ID" = "none" ] || [ -z "$CODEX_SESSION_ID" ]; then
  RECOVERED_ID=$(sed $'s/\033\\[[0-9;]*m//g' "$CODEX_LOG" | grep -oE 'session id: [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | sed 's/session id: //' || true)
  if [ -z "$RECOVERED_ID" ]; then
    RECOVERED_ID=$($CODEX_CMD resume --last --json 2>/dev/null | jq -r '.id // empty' || true)
  fi
  if [ -n "$RECOVERED_ID" ]; then
    CODEX_SESSION_ID="$RECOVERED_ID"
    echo "Recovered session ID from fallback run: $CODEX_SESSION_ID"
  fi
fi

REVIEW_BODY=$(cat "$REVIEW_OUTPUT")

# Extract verdict before any truncation — it lives at the end of the output
VERDICT_LINE=$(echo "$REVIEW_BODY" | grep -i '^VERDICT:' | tail -1 || true)

# Hard-fail if no verdict was produced — a verdict-less re-review is not actionable.
if [ -z "$VERDICT_LINE" ]; then
  echo "ERROR: Codex produced a re-review but no VERDICT line was found." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex re-review produced no verdict (round ${ROUND})** — the review output did not contain a \`VERDICT:\` line. This may indicate a truncated response or a Codex failure. Re-run \`codex-re-review.sh\`."
  exit 4
fi

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

# Stamp with machine marker (includes reviewed SHA for downstream binding)
REVIEW_MARKER="<!-- agentic-dev:codex-review:v1 reviewed-sha:${REVIEWED_SHA} -->"
REVIEW_BODY="${REVIEW_MARKER}
${REVIEW_BODY}"

# Collect old review comment IDs BEFORE posting — ensures new comment is live
# before any deletes, so the PR is never left without a review artifact
PREV_COMMENT_IDS=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq '[.[] | select(.body | test("<!-- agentic-dev:codex-review:v1")) | .id] | .[]' 2>/dev/null || true)

# Post review as PR comment (file-based to avoid shell argument limits)
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
echo "CODEX_SESSION_ID=${CODEX_SESSION_ID:-none}"

# Persist session state to .git/agentic-dev/session-{branch}.json (best-effort).
# Sanitize branch name: replace / with -- so fix/foo becomes session-fix--foo.json
_SESSION_DIR="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
_SAFE_BRANCH="${HEAD_BRANCH//\//--}"
if mkdir -p "$_SESSION_DIR" 2>/dev/null; then
  _SESSION_FILE="$_SESSION_DIR/session-${_SAFE_BRANCH}.json"
  _VERDICT_TEXT=$(echo "$VERDICT_LINE" | sed 's/^VERDICT:[[:space:]]*//')
  _ROUND_NEXT=$(echo "$VERDICT_LINE" | grep -qi 'approved' && echo 0 || echo "$ROUND")
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg branch "$HEAD_BRANCH" \
    --arg codex_session_id "${CODEX_SESSION_ID:-none}" \
    --arg verdict "$_VERDICT_TEXT" \
    --argjson round_completed "$ROUND" \
    --argjson round "$_ROUND_NEXT" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pr_number: $pr_number, branch: $branch, codex_session_id: $codex_session_id,
      verdict: $verdict, round_completed: $round_completed, round: $round, updated_at: $updated_at}' \
    > "$_SESSION_FILE" 2>/dev/null || true
fi
