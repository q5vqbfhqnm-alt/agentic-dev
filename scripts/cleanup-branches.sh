#!/usr/bin/env bash
set -euo pipefail
#
# Prune stale worktrees and local branches left over from previous /dev sessions.
# Safe: skips branches with unpushed commits, open PRs, or uncommitted worktree changes.
# Called automatically at the start of each /dev session.
#
# Usage: ./scripts/cleanup-branches.sh

PROTECTED="main|preview"

echo "=== Branch & Worktree Cleanup ==="

# 1. Prune remote tracking refs that no longer exist
git fetch --prune --quiet

# 2. Remove worktrees that point to missing directories or broken refs
git worktree prune

# 3. Remove worktrees whose branches have been deleted on the remote
for wt in $(git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //'); do
  # Skip the main repo
  [ "$wt" = "$(git rev-parse --show-toplevel)" ] && continue

  # Get the branch for this worktree
  branch=$(git worktree list --porcelain | grep -A2 "^worktree $wt" | grep '^branch ' | sed 's|^branch refs/heads/||' || true)
  [ -z "$branch" ] && continue

  # Skip protected branches
  echo "$branch" | grep -qE "^($PROTECTED)$" && continue

  # Check for uncommitted changes in the worktree
  if [ -d "$wt" ] && git -C "$wt" diff --quiet 2>/dev/null && git -C "$wt" diff --cached --quiet 2>/dev/null; then
    # Check if remote branch is gone
    if ! git rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
      echo "  Removing worktree: $wt (branch '$branch' — remote gone)"
      git worktree remove "$wt" 2>/dev/null || true
    fi
  else
    echo "  Skipping worktree: $wt (has uncommitted changes)"
  fi
done

# 4. Delete local branches whose remote is gone and have no unpushed commits
for branch in $(git branch --format='%(refname:short)' | grep -vE "^($PROTECTED)$"); do
  # Skip if branch is currently checked out in any worktree
  if git worktree list --porcelain | grep -q "branch refs/heads/$branch"; then
    continue
  fi

  # Check if remote tracking branch is gone
  tracking=$(git for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null || true)
  remote_exists=$(git rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null && echo "yes" || echo "no")

  if [ "$remote_exists" = "no" ]; then
    # Remote is gone — check for unpushed commits against preview
    unpushed=$(git log "origin/preview..$branch" --oneline 2>/dev/null || true)
    if [ -z "$unpushed" ]; then
      echo "  Deleting branch: $branch (remote gone, no unpushed commits)"
      git branch -d "$branch" 2>/dev/null || true
    else
      # Check if all commits exist in preview (merged but branch not cleaned)
      all_merged=true
      while IFS= read -r sha_line; do
        sha=$(echo "$sha_line" | awk '{print $1}')
        if ! git merge-base --is-ancestor "$sha" origin/preview 2>/dev/null; then
          all_merged=false
          break
        fi
      done <<< "$unpushed"

      if [ "$all_merged" = true ]; then
        echo "  Deleting branch: $branch (remote gone, all commits merged)"
        git branch -D "$branch" 2>/dev/null || true
      else
        # Squash-merges create new SHAs, so git can't tell commits were merged.
        # Fall back to checking if a PR for this branch was merged on GitHub.
        merged_pr=$(gh pr list --head "$branch" --state merged --json number --jq '.[0].number' 2>/dev/null || true)
        if [ -n "$merged_pr" ]; then
          echo "  Deleting branch: $branch (PR #$merged_pr squash-merged)"
          git branch -D "$branch" 2>/dev/null || true
        else
          echo "  Skipping branch: $branch (has unpushed unmerged commits, no merged PR)"
        fi
      fi
    fi
  fi
done

# 5. Delete stale remote branches (merged PRs that GitHub didn't clean up)
for remote_branch in $(git branch -r --format='%(refname:short)' | grep -v HEAD | sed 's|^origin/||' | grep -vE "^($PROTECTED)$"); do
  # Check if there's an open PR for this branch
  open_pr=$(gh pr list --head "$remote_branch" --state open --json number --jq 'length' 2>/dev/null || echo "1")
  if [ "$open_pr" = "0" ]; then
    # No open PR — check if merged
    merged_pr=$(gh pr list --head "$remote_branch" --state merged --json number --jq 'length' 2>/dev/null || echo "0")
    if [ "$merged_pr" != "0" ]; then
      echo "  Deleting remote branch: origin/$remote_branch (PR merged)"
      git push origin --delete "$remote_branch" 2>/dev/null || true
    else
      # No PR at all — check if branch is fully merged into preview
      if git merge-base --is-ancestor "origin/$remote_branch" origin/preview 2>/dev/null; then
        echo "  Deleting remote branch: origin/$remote_branch (fully merged, no PR)"
        git push origin --delete "$remote_branch" 2>/dev/null || true
      fi
    fi
  fi
done

echo "=== Cleanup complete ==="
