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
PROBE_RESULT="$RUN_DIR/isolation_probe.json"

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

# Protocol v1.3: container runs (tools/stranger_walk/run_container.sh) write
# a scripted isolation_probe.json (own PID namespace, no host paths in
# ps/env, no host credential dirs visible, network reaches the public entry
# point but not host loopback — see tools/stranger_walk/container/probe.sh).
# A bare run.sh run has no such file — that's expected, not a failure; only
# check it when present, and only mark it fatal, not merely a warning: a
# container run whose OWN probe failed its isolation claim should disqualify
# exactly like a real boundary hit in the transcript does.
if [ -f "$PROBE_RESULT" ]; then
  PROBE_SUMMARY="$(python3 -c "
import json
d = json.load(open('$PROBE_RESULT'))
failed = [c for c in d.get('checks', []) if not c.get('ok')]
if not d.get('overall_pass', False) or failed:
    for c in failed:
        print('FAIL [' + c['name'] + ']: ' + c.get('detail', ''))
    print('PROBE_FAIL')
else:
    print('PROBE_PASS (' + str(len(d.get('checks', []))) + ' checks)')
")"
  if echo "$PROBE_SUMMARY" | grep -q '^PROBE_FAIL$'; then
    HITS=$((HITS + 1))
    echo "HIT [container isolation_probe.json]:"
    echo "$PROBE_SUMMARY" | grep '^FAIL ' | sed 's/^/  /'
  else
    echo "$PROBE_SUMMARY" >&2
  fi
fi

if [ "$HITS" -gt 0 ]; then
  echo "RESULT: DISQUALIFIED ($HITS pattern(s) matched) — $RUN_ID" >&2
  exit 1
else
  echo "RESULT: PASS — $RUN_ID has no isolation-boundary hits" >&2
  exit 0
fi
