# Shared helpers for hook tests.
# Source this in setup() via: load helpers

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Build valid PreToolUse JSON for a given command string.
hook_input() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

# Run a hook script with the given command, return its exit code.
# Usage: run_hook hooks/validate-foo.sh "git push"
run_hook() {
  hook_input "$2" | bash "$REPO_ROOT/$1"
}
