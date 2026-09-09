#!/usr/bin/env bash
# tools/stranger_walk/launch.sh <run.sh|resume.sh> <args...>
#
# PROTOCOL v1.2 (2026-09-09, sonnet-b finding): sonnet-b was killed mid-run
# (SIGKILL, exit 137) when the S2-lead session that dispatched it closed.
# Root cause: `run.sh` was started as a background Bash-tool call, so the
# `claude -p` stranger process it execs stayed in that session's process
# group; when the session exited, the harness tore down the group (and any
# still-running child in it) as a matter of course. Nothing about the
# stranger's own behavior caused this — it was mid-wait on a background
# poll loop, actively making progress (had just made `v3` champion).
#
# Fix: launch the target script fully DETACHED — its own session, its own
# process group, stdio pointed at files up front (never an inherited pipe
# that goes away with the parent) — so it keeps running no matter what
# happens to the session that launched it.
#   - `os.setsid()` (via a tiny python3 shim; macOS ships no `setsid(1)`)
#     moves the child into a brand-new session, detaching it from the
#     dispatching shell's controlling terminal and process group. A
#     process-group-directed kill/SIGHUP to the OLD group no longer reaches
#     it.
#   - `nohup` additionally makes the child immune to SIGHUP specifically
#     (belt + suspenders with setsid, which already ignores the controlling
#     terminal).
#   - `</dev/null` plus redirecting stdout/stderr to a file BEFORE
#     backgrounding means the child never blocks on, or is affected by, a
#     pipe/fd the parent session owns.
#   - `disown` drops the shell's own job-table reference so the dispatching
#     session doesn't consider it a job it owns either.
#
# Usage:
#   tools/stranger_walk/launch.sh run.sh <model> <run-id> [max-budget-usd]
#   tools/stranger_walk/launch.sh resume.sh <run-id> "<message>" [kind]
#
# Returns immediately with the detached PID. The dispatcher polls for
# completion with a Bash loop (never a backgrounded "wait for the
# notification" — see the same root cause above):
#   RUN_DIR=/Users/maxwellstarr/projects/stranger-walk-runs/<run-id>
#   while kill -0 "$(cat "$RUN_DIR/launch.pid")" 2>/dev/null; do sleep 60; done
# or by polling meta.json's run_status directly.
set -euo pipefail

TARGET="${1:?usage: launch.sh <run.sh|resume.sh> <args...>}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"

case "$TARGET" in
  run.sh)
    RUN_ID="${2:?usage: launch.sh run.sh <model> <run-id> [max-budget-usd]}"
    ;;
  resume.sh)
    RUN_ID="${1:?usage: launch.sh resume.sh <run-id> \"<message>\" [kind]}"
    ;;
  *)
    echo "unknown target: $TARGET (expected run.sh or resume.sh)" >&2
    exit 1
    ;;
esac

RUN_DIR="$RUNS_PARENT/$RUN_ID"
mkdir -p "$RUN_DIR"

LAUNCH_LOG="$RUN_DIR/launch.detached.$(date +%s).log"
PIDFILE="$RUN_DIR/launch.pid"

# python3's os.setsid() is the portable equivalent of util-linux's `setsid(1)`
# (not shipped on macOS by default). It puts the exec'd process in a new
# session/process group before handing off control via execvp.
nohup python3 -c '
import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$SCRIPT_DIR/$TARGET" "$@" </dev/null >"$LAUNCH_LOG" 2>&1 &
DETACHED_PID=$!
disown "$DETACHED_PID" 2>/dev/null || disown 2>/dev/null || true

echo "$DETACHED_PID" > "$PIDFILE"
echo "[$RUN_ID] launched DETACHED (protocol v1.2): pid=$DETACHED_PID sid=$(python3 -c "import os; print(os.getsid($DETACHED_PID))" 2>/dev/null || echo '?')" >&2
echo "[$RUN_ID] wrapper log: $LAUNCH_LOG" >&2
echo "[$RUN_ID] poll: while kill -0 \$(cat $PIDFILE) 2>/dev/null; do sleep 60; done" >&2
