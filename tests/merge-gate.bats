#!/usr/bin/env bats

GATE="plugins/agentic-dev/scripts/merge-gate.sh"

setup() {
  TEST_REPO=$(mktemp -d)
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" commit --allow-empty -m "init" -q
  HEAD_SHA=$(git -C "$TEST_REPO" rev-parse HEAD)
  export HEAD_SHA TEST_REPO

  # Stub directory on PATH — fake gh resolves PR head SHA and comments
  STUB_DIR=$(mktemp -d)
  export STUB_DIR
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_REPO" "$STUB_DIR"
}

# Write a fake `gh` that returns controlled responses
write_gh_stub() {
  local repo_response="$1"       # nameWithOwner
  local head_sha="$2"            # headRefOid
  local comments_json="$3"       # JSON array of comments

  cat > "$STUB_DIR/gh" <<EOF
#!/bin/bash
args="\$*"
if echo "\$args" | grep -q "nameWithOwner"; then
  echo '{"nameWithOwner":"$repo_response"}'
elif echo "\$args" | grep -q "headRefOid"; then
  echo '{"headRefOid":"$head_sha"}'
elif echo "\$args" | grep -q "issues.*comments"; then
  echo '$comments_json'
fi
EOF
  chmod +x "$STUB_DIR/gh"
}

codex_comment() {
  local sha="$1"
  printf '[{"id":1,"body":"<!-- agentic-dev:codex-review:v1 reviewed-sha:%s -->\\nVERDICT: approved"}]' "$sha"
}

override_comment() {
  local sha="$1"
  printf '[{"id":2,"body":"<!-- agentic-dev:user-override:v1 reviewed-sha:%s -->\\nUser override"}]' "$sha"
}

stale_codex_comment() {
  printf '[{"id":3,"body":"<!-- agentic-dev:codex-review:v1 reviewed-sha:0000000000000000000000000000000000000000 -->\\nVERDICT: approved"}]'
}

no_comments() {
  echo '[]'
}

run_gate() {
  bash "$BATS_TEST_DIRNAME/../$GATE" "$1"
}

# ── Codex approval path ───────────────────────────────────────────────────────

@test "passes on matching Codex approval comment" {
  write_gh_stub "owner/repo" "$HEAD_SHA" "$(codex_comment "$HEAD_SHA")"
  run run_gate 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved"* ]]
}

@test "fails when Codex approval is for a different SHA" {
  write_gh_stub "owner/repo" "$HEAD_SHA" "$(stale_codex_comment)"
  run run_gate 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"different commit"* ]]
}

@test "fails when no Codex approval comment exists" {
  write_gh_stub "owner/repo" "$HEAD_SHA" "$(no_comments)"
  run run_gate 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"no approved comment"* ]]
}

# ── User override path ────────────────────────────────────────────────────────

@test "passes on matching user-override comment" {
  write_gh_stub "owner/repo" "$HEAD_SHA" "$(override_comment "$HEAD_SHA")"
  run run_gate 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"user override accepted"* ]]
}

@test "fails when user-override is for a different SHA" {
  write_gh_stub "owner/repo" "$HEAD_SHA" "$(override_comment "0000000000000000000000000000000000000000")"
  run run_gate 42
  [ "$status" -eq 1 ]
}
