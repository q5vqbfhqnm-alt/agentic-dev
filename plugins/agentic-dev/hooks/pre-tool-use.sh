#!/bin/bash
# Consolidated PreToolUse hook for agentic-dev.
#
# Runs all checks in a single shell process — one config.sh source,
# one jq parse, one process spawn per Bash tool call.
#
# Checks (in order):
#   1. validate-no-self-review  — block agents posting review/override comments directly
#   2. validate-branch-base     — block branches from wrong or stale base refs
#   3. validate-push-ready      — block push unless pre-push-checks.sh has passed
#   4. validate-commit-message  — enforce type(scope): description convention
#
# Exit 0 = allow, exit 2 = block (stderr fed back as error).

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"

# ── Prerequisites ────────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: jq is not installed. All hooks require jq to parse tool input. Install jq and retry." >&2
  exit 2
fi

source "$PLUGIN_ROOT/scripts/config.sh" 2>/dev/null || true

# ── Shared helpers ───────────────────────────────────────────────────────────

_hook_log() {
  local hook="$1" action="$2" detail="$3"
  local log_dir
  log_dir="$(git rev-parse --git-dir 2>/dev/null)/agentic-dev"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  printf '%s\thook=%s\taction=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$action" "$detail" \
    >> "$log_dir/hooks.log" 2>/dev/null || true
}

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

_CMD_SHORT="${COMMAND:0:120}"

# ── 1. No self-review ────────────────────────────────────────────────────────

if echo "$COMMAND" | grep -qE 'gh\s+pr\s+review' && ! echo "$COMMAND" | grep -q 'codex-review'; then
  _hook_log "no-self-review" "blocked" "reason=direct-pr-review cmd=$_CMD_SHORT"
  echo "BLOCKED: Direct PR review commands are not allowed. Use the codex-review scripts." >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'gh\s+pr\s+comment'; then
  _hook_log "no-self-review" "blocked" "reason=direct-pr-comment cmd=$_CMD_SHORT"
  echo "BLOCKED: Direct PR comment commands are not allowed. Reviews must be posted by the codex-review scripts; user-override comments are posted by the user via scripts/user-override.sh." >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'gh\s+api\s+.*issues/[0-9]+/comments' && \
   echo "$COMMAND" | grep -qE '(-X\s+POST|--method\s+POST)'; then
  _hook_log "no-self-review" "blocked" "reason=direct-api-comment cmd=$_CMD_SHORT"
  echo "BLOCKED: Direct API calls to post to the comments endpoint are not allowed. Reviews must be posted by the codex-review scripts; user-override comments are posted by the user via scripts/user-override.sh." >&2
  exit 2
fi

if echo "$COMMAND" | grep -qE 'codex\s+review'; then
  _hook_log "no-self-review" "blocked" "reason=direct-codex-review cmd=$_CMD_SHORT"
  echo "BLOCKED: Do not use 'codex review' directly. Use scripts/codex-review.sh or scripts/codex-re-review.sh." >&2
  exit 2
fi

# ── 2. Branch base ───────────────────────────────────────────────────────────

ALLOWED_BASES="${AGENTIC_DEV_BASE_BRANCH}|origin/${AGENTIC_DEV_BASE_BRANCH}"
if [ "${SESSION_TYPE:-}" = "hotfix" ]; then
  ALLOWED_BASES="${ALLOWED_BASES}|main|origin/main"
fi

_check_stale_base() {
  local base="$1"
  case "$base" in origin/*) return 0 ;; esac
  if ! git rev-parse --verify "origin/$base" >/dev/null 2>&1; then return 0; fi
  if ! git rev-parse --verify "$base" >/dev/null 2>&1; then return 0; fi
  local behind
  behind=$(git rev-list --count "$base".."origin/$base" 2>/dev/null || echo 0)
  if [ "$behind" -gt 0 ]; then
    echo "BLOCKED: Local '$base' is $behind commit(s) behind 'origin/$base'. Run 'git fetch origin $base' first." >&2
    return 1
  fi
  return 0
}

if echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  WORD_COUNT=$(echo "$COMMAND" | awk '{print NF}')
  BASE=$(echo "$COMMAND" | awk '{print $5}')
  if [ "$WORD_COUNT" -le 4 ] || [ -z "$BASE" ]; then
    IMPLICIT_BASE=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [ -n "$IMPLICIT_BASE" ] && ! echo "$IMPLICIT_BASE" | grep -qE "^($ALLOWED_BASES)$"; then
      _hook_log "branch-base" "blocked" "reason=implicit-wrong-base base=$IMPLICIT_BASE cmd=$_CMD_SHORT"
      echo "BLOCKED: Current branch '$IMPLICIT_BASE' is not an allowed base. Switch to '${AGENTIC_DEV_BASE_BRANCH}' before creating a branch." >&2
      exit 2
    fi
    if [ -n "$IMPLICIT_BASE" ] && ! _check_stale_base "$IMPLICIT_BASE"; then
      _hook_log "branch-base" "blocked" "reason=implicit-stale-base base=$IMPLICIT_BASE cmd=$_CMD_SHORT"
      exit 2
    fi
  else
    if ! echo "$BASE" | grep -qE "^($ALLOWED_BASES)$"; then
      _hook_log "branch-base" "blocked" "reason=wrong-base base=$BASE cmd=$_CMD_SHORT"
      echo "BLOCKED: Branch must be created from '${AGENTIC_DEV_BASE_BRANCH}' (or 'main' for hotfix). Got base: $BASE" >&2
      exit 2
    fi
    if ! _check_stale_base "$BASE"; then
      _hook_log "branch-base" "blocked" "reason=stale-base base=$BASE cmd=$_CMD_SHORT"
      exit 2
    fi
  fi
fi

if echo "$COMMAND" | grep -qE 'git\s+worktree\s+add\s+' && echo "$COMMAND" | grep -qE '\s-b\s'; then
  ARGS=$(echo "$COMMAND" | sed -E 's/git[[:space:]]+worktree[[:space:]]+add[[:space:]]+//' | sed -E 's/-b[[:space:]]+[^[:space:]]+//')
  ARGS=$(echo "$ARGS" | xargs)
  ARG_COUNT=$(echo "$ARGS" | awk '{print NF}')
  BASE=$(echo "$ARGS" | awk '{print $2}')
  if [ "$ARG_COUNT" -le 1 ] || [ -z "$BASE" ]; then
    IMPLICIT_BASE=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [ -n "$IMPLICIT_BASE" ] && ! echo "$IMPLICIT_BASE" | grep -qE "^($ALLOWED_BASES)$"; then
      _hook_log "branch-base" "blocked" "reason=worktree-implicit-wrong-base base=$IMPLICIT_BASE cmd=$_CMD_SHORT"
      echo "BLOCKED: Current branch '$IMPLICIT_BASE' is not an allowed base. Switch to '${AGENTIC_DEV_BASE_BRANCH}' before creating a worktree branch." >&2
      exit 2
    fi
    if [ -n "$IMPLICIT_BASE" ] && ! _check_stale_base "$IMPLICIT_BASE"; then
      _hook_log "branch-base" "blocked" "reason=worktree-implicit-stale-base base=$IMPLICIT_BASE cmd=$_CMD_SHORT"
      exit 2
    fi
  else
    if ! echo "$BASE" | grep -qE "^($ALLOWED_BASES)$"; then
      _hook_log "branch-base" "blocked" "reason=worktree-wrong-base base=$BASE cmd=$_CMD_SHORT"
      echo "BLOCKED: Worktree branch must be created from '${AGENTIC_DEV_BASE_BRANCH}' (or 'main' for hotfix). Got base: $BASE" >&2
      exit 2
    fi
    if ! _check_stale_base "$BASE"; then
      _hook_log "branch-base" "blocked" "reason=worktree-stale-base base=$BASE cmd=$_CMD_SHORT"
      exit 2
    fi
  fi
fi

# ── 3. Push ready ────────────────────────────────────────────────────────────

if echo "$COMMAND" | grep -qE 'git\s+push' && ! echo "$COMMAND" | grep -qE 'git\s+push\s+--(tags|delete|mirror)'; then
  SENTINEL="$(git rev-parse --git-dir 2>/dev/null)/.pre-push-passed"
  if [ ! -f "$SENTINEL" ]; then
    _hook_log "push-ready" "blocked" "reason=no-sentinel cmd=$_CMD_SHORT"
    echo "BLOCKED: pre-push-checks.sh has not been run. Run it before pushing." >&2
    echo "  bash \"${PLUGIN_ROOT}/scripts/pre-push-checks.sh\"" >&2
    exit 2
  fi

  SENTINEL_CONTENT=$(cat "$SENTINEL" 2>/dev/null || echo "")
  SENTINEL_HEAD=$(echo "$SENTINEL_CONTENT" | cut -d: -f1)
  SENTINEL_MERGE_BASE=$(echo "$SENTINEL_CONTENT" | cut -d: -f2)
  CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  if [ "$SENTINEL_HEAD" != "$CURRENT_SHA" ]; then
    _hook_log "push-ready" "blocked" "reason=stale-head sentinel=$SENTINEL_HEAD current=$CURRENT_SHA cmd=$_CMD_SHORT"
    echo "BLOCKED: pre-push-checks.sh passed on $SENTINEL_HEAD but HEAD is now $CURRENT_SHA. Re-run checks." >&2
    exit 2
  fi

  if [ -n "$SENTINEL_MERGE_BASE" ]; then
    BASE_BRANCH=$(git for-each-ref --format='%(upstream:short)' "$(git symbolic-ref HEAD 2>/dev/null)" 2>/dev/null \
      | sed 's|origin/||' || true)
    BASE_BRANCH="${BASE_BRANCH:-${AGENTIC_DEV_BASE_BRANCH:-preview}}"
    BASE_REF="origin/$BASE_BRANCH"
    if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
      CURRENT_MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)
      if [ -n "$CURRENT_MERGE_BASE" ] && [ "$CURRENT_MERGE_BASE" != "$SENTINEL_MERGE_BASE" ]; then
        _hook_log "push-ready" "blocked" "reason=base-advanced sentinel-base=$SENTINEL_MERGE_BASE current-base=$CURRENT_MERGE_BASE cmd=$_CMD_SHORT"
        echo "BLOCKED: $BASE_REF has advanced since checks were run. Re-run pre-push-checks.sh." >&2
        exit 2
      fi
    fi
  fi
fi

# ── 4. Commit message ────────────────────────────────────────────────────────

if echo "$COMMAND" | grep -qE 'git\s+commit' && ! echo "$COMMAND" | grep -qE '\-\-(amend|allow-empty-message)'; then
  MSG=""
  if echo "$COMMAND" | grep -q 'cat <<'; then
    MSG=$(echo "$COMMAND" | sed -n '/cat <</{n;p;}' | head -1 | sed 's/^[[:space:]]*//')
  elif echo "$COMMAND" | grep -qE '\-m[[:space:]]+"'; then
    MSG=$(echo "$COMMAND" | sed -n -E 's/.*-m[[:space:]]+"([^"]+)".*/\1/p' | head -1)
  elif echo "$COMMAND" | grep -qE "\-m[[:space:]]+'"; then
    MSG=$(echo "$COMMAND" | sed -n -E "s/.*-m[[:space:]]+'([^']+)'.*/\1/p" | head -1)
  fi

  if [ -z "$MSG" ]; then
    _hook_log "commit-message" "blocked" "reason=unparseable-commit-msg cmd=$_CMD_SHORT"
    echo "BLOCKED: Could not extract commit message from this git commit command." >&2
    echo "  Use: git commit -m \"type(scope): description\"" >&2
    echo "  Or a heredoc: git commit -m \"\$(cat <<'EOF'...EOF)\"" >&2
    exit 2
  fi

  FIRST_LINE=$(echo "$MSG" | head -1)
  if ! echo "$FIRST_LINE" | grep -qE '^(feat|fix|refactor|docs|test|chore)\([^)]+\): .+'; then
    _hook_log "commit-message" "blocked" "reason=bad-commit-msg msg=$FIRST_LINE"
    echo "BLOCKED: Commit message doesn't match convention." >&2
    echo "  Expected: feat|fix|refactor|docs|test|chore(scope): description" >&2
    echo "  Got: $FIRST_LINE" >&2
    exit 2
  fi
fi

exit 0
