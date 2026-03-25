#!/usr/bin/env bats

setup() {
  TEST_REPO=$(mktemp -d)
  git -C "$TEST_REPO" init -q
}

teardown() {
  rm -rf "$TEST_REPO"
}

resolve_changelog_path() {
  (
    cd "$TEST_REPO"
    unset AGENTIC_DEV_CHANGELOG_PATH
    source "$BATS_TEST_DIRNAME/../plugins/agentic-dev/scripts/config.sh"
    printf '%s' "$AGENTIC_DEV_CHANGELOG_PATH"
  )
}

@test "defaults to root CHANGELOG.md when docs changelog is absent" {
  touch "$TEST_REPO/CHANGELOG.md"

  run resolve_changelog_path
  [ "$status" -eq 0 ]
  [ "$output" = "CHANGELOG.md" ]
}

@test "prefers docs/CHANGELOG.md when present" {
  mkdir -p "$TEST_REPO/docs"
  touch "$TEST_REPO/docs/CHANGELOG.md"
  touch "$TEST_REPO/CHANGELOG.md"

  run resolve_changelog_path
  [ "$status" -eq 0 ]
  [ "$output" = "docs/CHANGELOG.md" ]
}

@test "allows explicit override through project config" {
  mkdir -p "$TEST_REPO/.claude"
  cat > "$TEST_REPO/.claude/agentic-dev.json" <<'EOF'
{"changelogPath":"notes/RELEASES.md"}
EOF

  run resolve_changelog_path
  [ "$status" -eq 0 ]
  [ "$output" = "notes/RELEASES.md" ]
}
