#!/usr/bin/env bash
# tools/stranger_walk/chain_before_runs.sh <max-budget-usd> <model:run-id> [<model:run-id> ...]
#
# Launches a sequence of container BEFORE-walk runs ONE AT A TIME — GitHub
# sign-in and submission must never overlap between concurrent strangers
# sharing the same throwaway identity (see docs/designs/STRANGER_WALK.md,
# "Signing up is part of the measured path"). Each stage:
#   1. `launch.sh run_container.sh <model> <run-id> <max-budget-usd>` —
#      protocol v1.2 detached launch (survives this chain script's own
#      session dying, same guarantee run.sh/resume.sh already get).
#   2. Poll `launch.pid` until the container-blocking `run_container.sh`
#      process itself exits (it blocks synchronously on `docker wait` for
#      the run's whole duration — see that script).
#   3. `score.py <run-id>` (logged, non-gating) then `isolation_audit.sh
#      <run-id>` (GATING — v1.4 owner order: run this BEFORE the next stage
#      starts).
#   4. On audit PASS: proceed to the next run in the sequence.
#      On audit FAIL: best-effort `coworld retire-membership` cleanup for
#      that run's own throwaway-identity memberships (via `uvx coworld`,
#      using the run's own isolated $HOME so it never touches the owner's
#      or another run's session), write a HALT marker, and STOP — no
#      further runs in the sequence are launched.
#
# This script itself should be launched via `launch.sh` (or an equivalent
# setsid/nohup/disown wrapper) so IT ALSO survives the launching session
# ending — see protocol v1.2's own rationale (sonnet-b was killed exactly
# because nothing detached the supervising process).
#
# LIMITATION, stated plainly: a fully-detached background script has no
# mechanism in this environment to push a live notification to a chat
# session. On any HALT (audit FAIL) or at final completion, this script
# writes a clearly-named marker file under $RUNS_PARENT (see below) —
# whoever is watching this walk needs to poll for that file's existence,
# there is no active push.
set -uo pipefail  # no -e: every stage's failure must still write a marker and stop cleanly, not abort mid-log

MAX_BUDGET_USD="${1:?usage: chain_before_runs.sh <max-budget-usd> <model:run-id> [<model:run-id> ...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"
export STRANGER_ENTRY_URL="${STRANGER_ENTRY_URL:-https://softmax.com}"

CHAIN_LOG="$RUNS_PARENT/chain-before-runs.$(date +%s).log"
echo "[chain] started $(date -u +%Y-%m-%dT%H:%M:%SZ), entry=$STRANGER_ENTRY_URL, budget=$MAX_BUDGET_USD, stages: $*" | tee -a "$CHAIN_LOG"

retire_memberships_best_effort() {
  # Best-effort cleanup for a run whose audit FAILED. Uses the run's OWN
  # isolated $HOME (never the owner's, never another run's) so any
  # `coworld` session config it wrote persists at $RUN_DIR/.softmax/... on
  # the host (HOME=/home/stranger is bind-mounted at $RUN_DIR — see
  # run_container.sh) and can be reused here via `uvx coworld` (this host
  # has no global `coworld` install — see README.md — every invocation
  # goes through `uvx`, which fetches/caches it on first use).
  local run_id="$1" run_dir="$RUNS_PARENT/$1"
  echo "[chain] [$run_id] audit FAILED — attempting best-effort retire-membership cleanup" | tee -a "$CHAIN_LOG"
  local ids
  ids="$(HOME="$run_dir" uvx coworld submissions --mine 2>>"$CHAIN_LOG" | grep -oE 'lpm_[a-f0-9]+' | sort -u || true)"
  if [ -z "$ids" ]; then
    echo "[chain] [$run_id] no lpm_* membership id found via 'coworld submissions --mine' (or the CLI/session wasn't reachable) — leaving cleanup for manual follow-up, same as STRANGER_WALK.md's documented precedent" | tee -a "$CHAIN_LOG"
    return
  fi
  echo "$ids" | while IFS= read -r lpm; do
    [ -z "$lpm" ] && continue
    echo "[chain] [$run_id] retiring $lpm" | tee -a "$CHAIN_LOG"
    HOME="$run_dir" uvx coworld retire-membership "$lpm" --reason "protocol v1.4 auto-cleanup: isolation_audit FAIL, chain_before_runs.sh halted the sequence" >>"$CHAIN_LOG" 2>&1 || \
      echo "[chain] [$run_id] retire-membership FAILED for $lpm — see $CHAIN_LOG, manual follow-up needed" | tee -a "$CHAIN_LOG"
  done
}

for STAGE in "$@"; do
  MODEL="${STAGE%%:*}"
  RUN_ID="${STAGE#*:}"
  RUN_DIR="$RUNS_PARENT/$RUN_ID"

  echo "[chain] [$RUN_ID] launching model=$MODEL via launch.sh (protocol v1.2, detached)" | tee -a "$CHAIN_LOG"
  "$SCRIPT_DIR/launch.sh" run_container.sh "$MODEL" "$RUN_ID" "$MAX_BUDGET_USD" >>"$CHAIN_LOG" 2>&1

  PIDFILE="$RUN_DIR/launch.pid"
  for _ in $(seq 1 30); do
    [ -f "$PIDFILE" ] && break
    sleep 2
  done
  if [ ! -f "$PIDFILE" ]; then
    echo "[chain] [$RUN_ID] HALT: launch.pid never appeared — launch.sh itself failed, see $CHAIN_LOG" | tee -a "$CHAIN_LOG"
    echo "HALTED at $RUN_ID: launch.sh did not produce a launch.pid" > "$RUNS_PARENT/CHAIN-HALTED-$(date +%s).txt"
    exit 1
  fi

  echo "[chain] [$RUN_ID] launched, pid=$(cat "$PIDFILE"). Polling every 60s (this stage blocks synchronously on 'docker wait' for the run's whole duration)." | tee -a "$CHAIN_LOG"
  while kill -0 "$(cat "$PIDFILE")" 2>/dev/null; do
    sleep 60
  done
  echo "[chain] [$RUN_ID] run process exited. $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$CHAIN_LOG"

  python3 "$SCRIPT_DIR/score.py" "$RUN_ID" >>"$CHAIN_LOG" 2>&1
  echo "[chain] [$RUN_ID] score.py done (non-gating, logged above)" | tee -a "$CHAIN_LOG"

  if bash "$SCRIPT_DIR/isolation_audit.sh" "$RUN_ID" >>"$CHAIN_LOG" 2>&1; then
    echo "[chain] [$RUN_ID] isolation_audit.sh PASS — proceeding to next stage" | tee -a "$CHAIN_LOG"
  else
    echo "[chain] [$RUN_ID] isolation_audit.sh FAIL — see $CHAIN_LOG for the exact hit(s)" | tee -a "$CHAIN_LOG"
    retire_memberships_best_effort "$RUN_ID"
    echo "HALTED at $RUN_ID: isolation_audit.sh FAILED — chain stopped, no further runs launched. See $CHAIN_LOG and $RUN_DIR/." > "$RUNS_PARENT/CHAIN-HALTED-$(date +%s).txt"
    exit 1
  fi
done

echo "[chain] all stages complete: $*" | tee -a "$CHAIN_LOG"
echo "COMPLETE: $*" > "$RUNS_PARENT/CHAIN-COMPLETE-$(date +%s).txt"
