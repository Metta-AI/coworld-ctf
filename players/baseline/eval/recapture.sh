#!/usr/bin/env bash
# v29 DEFEND RECAPTURE MEASUREMENT (2026-07-29).
#
# Why this exists instead of a plain win-column A/B: the phase-occupancy probe showed
# PhDefend is only ~1.7-3.0% of plan-layer frames AND that mirror play is asymmetric in
# stealing (RED grabbed 10 hearts to BLUE's 1 over 12 games). So in a seat-rotated mirror
# A/B the CANDIDATE seats barely enter DEFEND at all — the gate funnel read
# `attacker 1263 -> teethOn 0`, i.e. every DEFEND frame belonged to the control side.
# A win-delta from that rig would be noise about a branch that never ran.
#
# So measure the MECHANISM from the defending side. The harness already reports, per team,
# the fate of runs against it:
#   survive:   mean ticks the ENEMY carrier lived after robbing us  -> LOWER = we recapture faster
#   drop@home: how far along its run the enemy carrier died         -> LOWER = we kill it earlier
#   grab->cap: how many of its steals it converted                  -> LOWER = we deny captures
# Those three read directly on "does DEFEND have teeth", regardless of the win column.
#
# The lever goes on BOTH teams (all 16 slots) so both sides run it while defending —
# with a knob on one side only, the side under test mostly isn't the side being robbed.
# Compare against the same run with the knob off. Judge the DEFENDER's numbers.
set -uo pipefail
GAMES="${1:-12}"
SEED="${2:-100}"
OUT="${3:-/tmp/v29recap}"
H="players/baseline/eval/harness.out"
ALL="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15"
mkdir -p "$OUT"

run() { # $1=name  $2..=knob env
  local name="$1"; shift
  env HUNTER_SLOTS="$ALL" SHIPBASE=1 CONTROL_SHIPPED=1 "$@" \
    "$H" --games "$GAMES" --seed "$SEED" --ticks 6000 > "$OUT/$name.log" 2>&1 &
  echo "launched $name (pid $!)"
}

run off
run on DEFTEETH=1
echo "2 arms running (games=$GAMES seed=$SEED) -> $OUT"
wait
echo "=== DEFENDER-SIDE RECAPTURE METRICS (lower survive/drop@home/grab->cap = better defense) ==="
for a in off on; do
  echo "--- DEFTEETH $a ---"
  grep -E "survive:|drop@home:|grab->cap|SCORE:|results:" "$OUT/$a.log" 2>/dev/null
done
