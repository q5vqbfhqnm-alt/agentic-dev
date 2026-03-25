#!/usr/bin/env bats

setup() {
  load helpers
  HOOK="plugins/agentic-dev/hooks/pre-tool-use.sh"

  # Temp repo used by push-ready tests
  TEST_REPO=$(mktemp -d)
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" commit --allow-empty -m "init" -q
}

teardown() {
  rm -rf "$TEST_REPO"
  [ -z "${STALE_TMPDIR:-}" ] || rm -rf "$STALE_TMPDIR"
}

# Run the hook inside the temp repo (needed for push-ready and branch-base stale tests)
run_in_repo() {
  local repo="$1" cmd="$2"
  hook_input "$cmd" | bash -c "cd '$repo' && bash '$REPO_ROOT/$HOOK'"
}

# ── No self-review ────────────────────────────────────────────────────────────

@test "blocks gh pr review" {
  run run_hook "$HOOK" "gh pr review 42 --approve"
  [ "$status" -eq 2 ]
}

@test "blocks gh pr review with extra spaces" {
  run run_hook "$HOOK" "gh  pr  review 42"
  [ "$status" -eq 2 ]
}

@test "blocks codex review" {
  run run_hook "$HOOK" "codex review --base main"
  [ "$status" -eq 2 ]
}

@test "blocks codex review (simple)" {
  run run_hook "$HOOK" "codex review"
  [ "$status" -eq 2 ]
}

@test "blocks gh pr comment" {
  run run_hook "$HOOK" "gh pr comment 42 --body 'VERDICT: approved'"
  [ "$status" -eq 2 ]
}

@test "blocks gh pr comment without body" {
  run run_hook "$HOOK" "gh pr comment 42"
  [ "$status" -eq 2 ]
}

@test "blocks gh pr comment with fabricated review" {
  run run_hook "$HOOK" "gh pr comment 42 --body '### 1. Spec alignment\npass\n\nVERDICT: approved'"
  [ "$status" -eq 2 ]
}

@test "blocks gh api POST to comments endpoint" {
  run run_hook "$HOOK" "gh api -X POST repos/owner/repo/issues/42/comments --field body=test"
  [ "$status" -eq 2 ]
}

@test "allows gh pr view" {
  run run_hook "$HOOK" "gh pr view 42 --json body"
  [ "$status" -eq 0 ]
}

@test "allows gh api GET to comments endpoint" {
  run run_hook "$HOOK" "gh api repos/owner/repo/issues/42/comments"
  [ "$status" -eq 0 ]
}

@test "allows bash codex-review.sh" {
  run run_hook "$HOOK" "bash scripts/codex-review.sh 42"
  [ "$status" -eq 0 ]
}

@test "allows bash merge-gate.sh" {
  run run_hook "$HOOK" "bash scripts/merge-gate.sh 42"
  [ "$status" -eq 0 ]
}

# ── Commit message ────────────────────────────────────────────────────────────

@test "blocks commit with no type prefix" {
  run run_hook "$HOOK" 'git commit -m "add new feature"'
  [ "$status" -eq 2 ]
}

@test "blocks commit with missing scope" {
  run run_hook "$HOOK" 'git commit -m "feat: add export"'
  [ "$status" -eq 2 ]
}

@test "blocks commit with wrong type" {
  run run_hook "$HOOK" 'git commit -m "update(admin): add export"'
  [ "$status" -eq 2 ]
}

@test "allows valid feat commit" {
  run run_hook "$HOOK" 'git commit -m "feat(admin): add export endpoint"'
  [ "$status" -eq 0 ]
}

@test "allows valid fix commit" {
  run run_hook "$HOOK" 'git commit -m "fix(upload): handle timeout"'
  [ "$status" -eq 0 ]
}

@test "allows valid chore commit" {
  run run_hook "$HOOK" 'git commit -m "chore(deps): bump next to 14.2"'
  [ "$status" -eq 0 ]
}

@test "allows amend (skip validation)" {
  run run_hook "$HOOK" "git commit --amend"
  [ "$status" -eq 0 ]
}

@test "allows non-commit git command" {
  run run_hook "$HOOK" "git status"
  [ "$status" -eq 0 ]
}

# ── Branch base ───────────────────────────────────────────────────────────────

@test "blocks checkout -b from wrong base" {
  run run_hook "$HOOK" "git checkout -b fix-bug develop"
  [ "$status" -eq 2 ]
}

@test "blocks switch -c from wrong base" {
  run run_hook "$HOOK" "git switch -c fix-bug staging"
  [ "$status" -eq 2 ]
}

@test "allows checkout -b from preview" {
  run run_hook "$HOOK" "git checkout -b fix-bug preview"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b from origin/preview" {
  run run_hook "$HOOK" "git checkout -b fix-bug origin/preview"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b from main (hotfix)" {
  SESSION_TYPE=hotfix run run_hook "$HOOK" "git checkout -b hotfix-urgent main"
  [ "$status" -eq 0 ]
}

@test "allows regular checkout (not creating branch)" {
  run run_hook "$HOOK" "git checkout main"
  [ "$status" -eq 0 ]
}

@test "blocks worktree add -b from wrong base" {
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug develop"
  [ "$status" -eq 2 ]
}

@test "allows worktree add -b from preview" {
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug preview"
  [ "$status" -eq 0 ]
}

setup_stale_repo() {
  export STALE_TMPDIR
  STALE_TMPDIR="$(mktemp -d)"
  git init --bare "$STALE_TMPDIR/remote.git" >/dev/null 2>&1
  git clone "$STALE_TMPDIR/remote.git" "$STALE_TMPDIR/work" >/dev/null 2>&1
  cd "$STALE_TMPDIR/work"
  git checkout -b preview >/dev/null 2>&1
  git commit --allow-empty -m "initial" >/dev/null 2>&1
  git push origin preview >/dev/null 2>&1
  git clone "$STALE_TMPDIR/remote.git" "$STALE_TMPDIR/other" >/dev/null 2>&1
  cd "$STALE_TMPDIR/other"
  git checkout preview >/dev/null 2>&1
  git commit --allow-empty -m "remote advance" >/dev/null 2>&1
  git push origin preview >/dev/null 2>&1
  cd "$STALE_TMPDIR/work"
  git fetch origin >/dev/null 2>&1
}

@test "blocks checkout -b from stale local preview" {
  setup_stale_repo
  cd "$STALE_TMPDIR/work"
  run run_hook "$HOOK" "git checkout -b fix-bug preview"
  [ "$status" -eq 2 ]
  [[ "$output" == *"behind"* ]]
}

@test "allows checkout -b from origin/preview (not stale)" {
  setup_stale_repo
  cd "$STALE_TMPDIR/work"
  run run_hook "$HOOK" "git checkout -b fix-bug origin/preview"
  [ "$status" -eq 0 ]
}

# ── Push ready ────────────────────────────────────────────────────────────────

@test "blocks push without sentinel" {
  rm -f "$TEST_REPO/.git/.pre-push-passed"
  run run_in_repo "$TEST_REPO" "git push origin main"
  [ "$status" -eq 2 ]
}

@test "allows push --tags without sentinel" {
  rm -f "$TEST_REPO/.git/.pre-push-passed"
  run run_in_repo "$TEST_REPO" "git push --tags"
  [ "$status" -eq 0 ]
}

@test "allows push --delete without sentinel" {
  rm -f "$TEST_REPO/.git/.pre-push-passed"
  run run_in_repo "$TEST_REPO" "git push --delete origin old-branch"
  [ "$status" -eq 0 ]
}

@test "allows push with valid sentinel" {
  git -C "$TEST_REPO" rev-parse HEAD > "$TEST_REPO/.git/.pre-push-passed"
  run run_in_repo "$TEST_REPO" "git push origin main"
  [ "$status" -eq 0 ]
}

@test "blocks push with stale sentinel" {
  echo "0000000000000000000000000000000000000000" > "$TEST_REPO/.git/.pre-push-passed"
  run run_in_repo "$TEST_REPO" "git push origin main"
  [ "$status" -eq 2 ]
}

# ── General ───────────────────────────────────────────────────────────────────

@test "allows empty command" {
  run run_hook "$HOOK" ""
  [ "$status" -eq 0 ]
}

@test "allows non-git command" {
  run run_hook "$HOOK" "echo hello"
  [ "$status" -eq 0 ]
}
