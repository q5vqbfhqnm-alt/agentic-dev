#!/usr/bin/env bats

setup() {
  load helpers
  HOOK="plugins/agentic-dev/hooks/validate-branch-base.sh"
}

# --- Should block ---

@test "blocks checkout -b from feature branch" {
  run run_hook "$HOOK" "git checkout -b fix-bug feature/old"
  [ "$status" -eq 2 ]
}

@test "blocks checkout -b from develop" {
  run run_hook "$HOOK" "git checkout -b fix-bug develop"
  [ "$status" -eq 2 ]
}

@test "blocks switch -c from staging" {
  run run_hook "$HOOK" "git switch -c fix-bug staging"
  [ "$status" -eq 2 ]
}

# --- Should allow ---

@test "allows checkout -b from preview" {
  run run_hook "$HOOK" "git checkout -b fix-bug preview"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b from origin/preview" {
  run run_hook "$HOOK" "git checkout -b fix-bug origin/preview"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b from main (hotfix)" {
  run run_hook "$HOOK" "git checkout -b hotfix-urgent main"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b from origin/main (hotfix)" {
  run run_hook "$HOOK" "git checkout -b hotfix-urgent origin/main"
  [ "$status" -eq 0 ]
}

@test "allows checkout -b with no base (defaults to HEAD)" {
  run run_hook "$HOOK" "git checkout -b fix-bug"
  [ "$status" -eq 0 ]
}

@test "allows switch -c from preview" {
  run run_hook "$HOOK" "git switch -c fix-bug preview"
  [ "$status" -eq 0 ]
}

@test "allows regular checkout (not creating branch)" {
  run run_hook "$HOOK" "git checkout main"
  [ "$status" -eq 0 ]
}

@test "allows non-git command" {
  run run_hook "$HOOK" "echo hello"
  [ "$status" -eq 0 ]
}

@test "allows empty command" {
  run run_hook "$HOOK" ""
  [ "$status" -eq 0 ]
}

# --- Worktree: should block ---

@test "blocks worktree add -b from feature branch (flag before path)" {
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug feature/old"
  [ "$status" -eq 2 ]
}

@test "blocks worktree add -b from develop (path before flag)" {
  run run_hook "$HOOK" "git worktree add ../fix-bug -b fix-bug develop"
  [ "$status" -eq 2 ]
}

# --- Worktree: should allow ---

@test "allows worktree add -b from preview (flag before path)" {
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug preview"
  [ "$status" -eq 0 ]
}

@test "allows worktree add -b from origin/preview (path before flag)" {
  run run_hook "$HOOK" "git worktree add ../fix-bug -b fix-bug origin/preview"
  [ "$status" -eq 0 ]
}

@test "allows worktree add -b from main (hotfix)" {
  run run_hook "$HOOK" "git worktree add -b hotfix ../hotfix main"
  [ "$status" -eq 0 ]
}

@test "allows worktree add -b with no base (defaults to HEAD)" {
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug"
  [ "$status" -eq 0 ]
}

@test "allows worktree add without -b (not creating branch)" {
  run run_hook "$HOOK" "git worktree add ../fix-bug"
  [ "$status" -eq 0 ]
}

# --- Stale base detection ---
# These tests create a temporary repo where local 'preview' is behind 'origin/preview'.

setup_stale_repo() {
  # Create a bare "remote" and a working clone
  export STALE_TMPDIR
  STALE_TMPDIR="$(mktemp -d)"
  git init --bare "$STALE_TMPDIR/remote.git" >/dev/null 2>&1
  git clone "$STALE_TMPDIR/remote.git" "$STALE_TMPDIR/work" >/dev/null 2>&1

  cd "$STALE_TMPDIR/work"
  git checkout -b preview >/dev/null 2>&1
  git commit --allow-empty -m "initial" >/dev/null 2>&1
  git push origin preview >/dev/null 2>&1

  # Advance origin/preview by one commit (simulate remote moving ahead)
  git clone "$STALE_TMPDIR/remote.git" "$STALE_TMPDIR/other" >/dev/null 2>&1
  cd "$STALE_TMPDIR/other"
  git checkout preview >/dev/null 2>&1
  git commit --allow-empty -m "remote advance" >/dev/null 2>&1
  git push origin preview >/dev/null 2>&1

  # Back to work repo — fetch so origin/preview is ahead, but local preview stays behind
  cd "$STALE_TMPDIR/work"
  git fetch origin >/dev/null 2>&1
}

teardown_stale_repo() {
  rm -rf "$STALE_TMPDIR"
}

@test "blocks checkout -b from stale local preview" {
  setup_stale_repo
  cd "$STALE_TMPDIR/work"
  run run_hook "$HOOK" "git checkout -b fix-bug preview"
  teardown_stale_repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"behind"* ]]
}

@test "allows checkout -b from origin/preview (not stale)" {
  setup_stale_repo
  cd "$STALE_TMPDIR/work"
  run run_hook "$HOOK" "git checkout -b fix-bug origin/preview"
  teardown_stale_repo
  [ "$status" -eq 0 ]
}

@test "blocks worktree add -b from stale local preview" {
  setup_stale_repo
  cd "$STALE_TMPDIR/work"
  run run_hook "$HOOK" "git worktree add -b fix-bug ../fix-bug preview"
  teardown_stale_repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"behind"* ]]
}
