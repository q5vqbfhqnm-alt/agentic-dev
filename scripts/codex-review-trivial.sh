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
HEAD_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')

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
trap 'rm -f "$REVIEW_OUTPUT" "$PROMPT_FILE" "$CODEX_LOG"' EXIT

# Build prompt — intentionally minimal. Two questions only.
cat > "$PROMPT_FILE" <<PROMPT
Review PR #${PR_NUMBER}. This is a trivial change (small scope, no logic/schema/auth impact).

You are on the PR branch (${HEAD_BRANCH}). The base branch is ${BASE_BRANCH}.

Step 1: Read the diff.
Run: git diff origin/${BASE_BRANCH}...HEAD

Step 2: Read the PR description.
Run: gh pr view ${PR_NUMBER} --json body --jq '.body'

Step 3: Answer exactly two questions.

### 1. Is this change correct?
Does the diff do what the PR description says? Are there typos, off-by-one errors, wrong selectors, or incorrect logic in the change itself?

### 2. Could this break something non-obvious?
Consider: shared components, conditional rendering dependencies, CSS cascade effects, import/export changes, anything that consumers of the changed code rely on.

For every non-pass finding include:
- severity: BLOCKER | STRONG
- file and line reference when possible
- problem
- exact change to make

Do NOT report NICE findings. Do NOT flag style preferences or pre-existing issues.

Output exactly in this structure:

### 1. Correctness
[findings or pass]

### 2. Non-obvious breakage
[findings or pass]

### Verdict
VERDICT: approved — if zero BLOCKER and zero STRONG findings.
VERDICT: blocked — if any BLOCKER or STRONG finding exists.
Output exactly one of these two lines. This is the final word.
PROMPT

# Run Codex review with the focused trivial prompt
# Capture terminal output (contains session ID) separately from -o file (review body)
if ! $CODEX_CMD exec -s read-only -o "$REVIEW_OUTPUT" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CODEX_LOG"; then
  echo "ERROR: Codex exec failed (exit code $?)." >&2
  gh pr comment "$PR_NUMBER" --body "<!-- agentic-dev:codex-review:v1 -->
**Codex trivial review failed** — \`codex exec\` exited non-zero. This is an infrastructure failure, not a review verdict. Re-run \`codex-review-trivial.sh\` or check Codex CLI / API key status."
  exit 3
fi

REVIEW_BODY=$(cat "$REVIEW_OUTPUT")

# Extract verdict before any truncation — it lives at the end of the output
VERDICT_LINE=$(echo "$REVIEW_BODY" | grep -i '^VERDICT:' | tail -1 || true)

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

# Post review as PR comment
gh pr comment "$PR_NUMBER" --body "$REVIEW_BODY"
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
