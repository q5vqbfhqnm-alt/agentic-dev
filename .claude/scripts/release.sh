#!/usr/bin/env bash
# Usage: release.sh <version> <changelog_body_file>
set -euo pipefail

VERSION="${1:?version required}"
NOTES_FILE="${2:?changelog body file required}"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PLUGIN_JSON="plugins/agentic-dev/.claude-plugin/plugin.json"
MARKETPLACE_JSON=".claude-plugin/marketplace.json"
CHANGELOG="${AGENTIC_DEV_CHANGELOG_PATH:-CHANGELOG.md}"

tmp=$(mktemp)

jq --arg v "$VERSION" '.version = $v' "$PLUGIN_JSON" > "$tmp" && mv "$tmp" "$PLUGIN_JSON"

jq --arg v "$VERSION" '(.plugins[] | select(.name == "agentic-dev")).version = $v' "$MARKETPLACE_JSON" > "$tmp" && mv "$tmp" "$MARKETPLACE_JSON"

{
  echo "# Changelog"
  echo ""
  echo "## ${VERSION} — $(date +%Y-%m-%d)"
  echo ""
  cat "$NOTES_FILE"
  echo ""
  tail -n +3 "$CHANGELOG"
} > "$tmp" && mv "$tmp" "$CHANGELOG"

rm -f "$tmp"

git add "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$CHANGELOG"
git commit -m "chore(release): agentic-dev v${VERSION}"
git tag "v${VERSION}"
git push --follow-tags

gh release create "v${VERSION}" \
  --title "agentic-dev v${VERSION}" \
  --notes-file "$NOTES_FILE"

echo "Released v${VERSION}"
