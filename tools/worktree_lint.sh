#!/bin/bash
# worktree_lint.sh
#
# Lints the git worktree registry for this repo. Prints every registered
# worktree that lives outside .claude/worktrees/ and .worktrees/ (the two
# harness-managed / sanctioned locations), flags any worktree rooted under
# /private/tmp (a banned location for worktrees — that path is meant for
# ephemeral scratch, not durable checkouts), and flags any worktree whose
# last commit is older than 7 days AND shows no recent activity (no process
# with cwd inside it, and no file touched in the last 6 hours).
#
# Exit code is non-zero if anything was flagged, so this can gate CI or a
# SessionStart hook. Use --json for machine-readable output.
#
# Background: worktree-prune-2026-09-09 found 199 external worktrees
# (54 under /private/tmp, 3 under ~/.ctf/paintbot-work, 142 under
# /Users/maxwellstarr/projects/*) accumulated by agents that never cleaned
# up after themselves. This script is meant to catch the next batch before
# it grows to the same size.
#
# See ~/.ctf/knowledge/reorg/T4-worktree-standard.md for the standard this
# enforces, and ~/.ctf/knowledge/reorg/worktree-prune-2026-09-09.md for the
# audit this was built from.

set -uo pipefail

JSON=0
if [ "${1:-}" == "--json" ]; then
  JSON=1
fi

STALE_DAYS=7
STALE_SECS=$((STALE_DAYS * 86400))
NOW=$(date +%s)

# Resolve repo root the same way regardless of which worktree invokes this.
REPO_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_TOPLEVEL" ]; then
  echo "worktree_lint: not inside a git repo" >&2
  exit 2
fi

TMP_PORCELAIN=$(mktemp)
TMP_LSOF=$(mktemp)
trap 'rm -f "$TMP_PORCELAIN" "$TMP_LSOF"' EXIT
git worktree list --porcelain > "$TMP_PORCELAIN" 2>/dev/null
# One lsof snapshot for all worktrees, instead of one process per row.
lsof -a -d cwd -Fn 2>/dev/null | grep '^n' > "$TMP_LSOF"

flagged=0
rows_json=()

path=""
head=""
branch=""
detached=0

emit_row() {
  local p="$1" b="$2" h="$3" det="$4"
  [ -z "$p" ] && return

  # Skip sanctioned locations.
  case "$p" in
    */.claude/worktrees/*) return ;;
    */.worktrees/*) return ;;
  esac
  # Skip the main worktree (repo root itself).
  if [ "$p" == "$REPO_TOPLEVEL" ]; then return; fi

  local banned_tmp=0
  case "$p" in
    /private/tmp/*|/tmp/*) banned_tmp=1 ;;
  esac

  local last_commit_epoch age_days=-1
  last_commit_epoch=$(git -C "$p" log -1 --format=%ct 2>/dev/null)
  if [ -n "$last_commit_epoch" ]; then
    age_days=$(( (NOW - last_commit_epoch) / 86400 ))
  fi

  local activity=0
  if grep -q "^n$p" "$TMP_LSOF" 2>/dev/null; then
    activity=1
  fi
  if [ "$activity" -eq 0 ] && [ -n "$(find "$p" -maxdepth 2 -not -path '*/.git/*' -newermt '-6 hours' 2>/dev/null | head -1)" ]; then
    activity=1
  fi

  local stale=0
  if [ "$age_days" -ge "$STALE_DAYS" ] 2>/dev/null && [ "$activity" -eq 0 ]; then
    stale=1
  fi

  local branch_disp="$b"
  if [ "$det" == "1" ]; then
    branch_disp="DETACHED@${h:0:8}"
  fi

  if [ "$banned_tmp" -eq 1 ] || [ "$stale" -eq 1 ]; then
    flagged=$((flagged+1))
    if [ "$JSON" -eq 1 ]; then
      rows_json+=("{\"path\":\"$p\",\"branch\":\"$branch_disp\",\"age_days\":$age_days,\"activity\":$( [ $activity -eq 1 ] && echo true || echo false ),\"banned_tmp\":$( [ $banned_tmp -eq 1 ] && echo true || echo false ),\"stale\":$( [ $stale -eq 1 ] && echo true || echo false )}")
    else
      local reasons=""
      [ "$banned_tmp" -eq 1 ] && reasons="banned-location(/private/tmp or /tmp)"
      if [ "$stale" -eq 1 ]; then
        [ -n "$reasons" ] && reasons="$reasons,"
        reasons="${reasons}stale(${age_days}d, no activity)"
      fi
      printf '%s\t%s\t%s\n' "$p" "$branch_disp" "$reasons"
    fi
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      # flush previous
      emit_row "$path" "$branch" "$head" "$detached"
      path="${line#worktree }"
      head=""
      branch=""
      detached=0
      ;;
    "HEAD "*) head="${line#HEAD }" ;;
    "branch "*) branch="${line#branch refs/heads/}" ;;
    "detached") detached=1 ;;
  esac
done < "$TMP_PORCELAIN"
emit_row "$path" "$branch" "$head" "$detached"

if [ "$JSON" -eq 1 ]; then
  printf '['
  for i in "${!rows_json[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '%s' "${rows_json[$i]}"
  done
  printf ']\n'
else
  echo "worktree_lint: $flagged flagged (out of sanctioned locations, banned /tmp path, or stale)" >&2
fi

if [ "$flagged" -gt 0 ]; then
  exit 1
fi
exit 0
