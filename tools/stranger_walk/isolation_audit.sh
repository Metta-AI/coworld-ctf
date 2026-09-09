#!/usr/bin/env bash
# tools/stranger_walk/isolation_audit.sh <run-id> [runs-parent]
#
# Greps a completed run's transcript for any sign the stranger saw internal
# paths, tooling, or vocabulary it should never have had access to. Any hit
# means the run is DISQUALIFIED per the protocol (docs/designs/STRANGER_WALK.md)
# — discard it and rerun once.
set -euo pipefail

RUN_ID="${1:?usage: isolation_audit.sh <run-id> [runs-parent]}"
RUNS_PARENT="${2:-${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}}"
RUN_DIR="$RUNS_PARENT/$RUN_ID"
TRANSCRIPT="$RUN_DIR/transcript.jsonl"

if [ ! -f "$TRANSCRIPT" ]; then
  echo "no transcript at $TRANSCRIPT" >&2
  exit 2
fi

# Claude Code itself (in ANY process, main or spawned) auto-persists oversized
# tool output to a file under ~/.claude/projects/<slug-of-cwd>/tool-results/
# and tells the model to Read it back — this fires on any big WebFetch, which
# is normal, expected stranger behavior (fetching real pages), NOT a boundary
# violation. Found 2026-09-09: this made `.claude/projects` fire on EVERY run,
# always, on line 1's own tool-results path — a guaranteed false positive
# unrelated to anything the stranger did wrong. The slug is derived from the
# run's OWN working directory, so self-references to it are benign; anything
# else under `.claude/projects` (another project's slug) is a real hit.
RUN_SLUG="$(echo "$RUN_DIR" | sed 's#/#-#g')"

PATTERNS=(
  '~/.ctf'
  '\.claude/projects'
  'projects/coworld-ctf'
  'projects/metta'
  'ctf-monet'
  'paintbot-ops'
  'tailscale'
  '\.apps\.softmax'
)

HITS=0
for pat in "${PATTERNS[@]}"; do
  MATCHES="$(grep -n -E "$pat" "$TRANSCRIPT" || true)"
  if [ "$pat" = '\.claude/projects' ] && [ -n "$MATCHES" ]; then
    MATCHES="$(echo "$MATCHES" | grep -v -- "$RUN_SLUG" || true)"
  fi
  if [ -n "$MATCHES" ]; then
    HITS=$((HITS + 1))
    echo "HIT [$pat]:"
    echo "$MATCHES" | sed 's/^/  /'
  fi
done

if [ "$HITS" -gt 0 ]; then
  echo "RESULT: DISQUALIFIED ($HITS pattern(s) matched) — $RUN_ID" >&2
  exit 1
else
  echo "RESULT: PASS — $RUN_ID has no isolation-boundary hits" >&2
  exit 0
fi
