#!/usr/bin/env bash
# Parallel launcher for the v29 phase-deepening A/B (2026-07-29).
# Six independent runs (3 arms x 2 seatings), each to its own log, all at once —
# the harness is single-threaded, so on a loaded box parallel arms finish together
# instead of queueing behind each other. Read with phasedeep_report.sh.
#
# Arms (all champion-vs-champion; a null far from 0 means the rig is mis-specified):
#   null      SHIPBASE=1 CONTROL_SHIPPED=1                 (identical tunes)
#   defteeth  SHIPBASE=1 CONTROL_SHIPPED=1 DEFTEETH=1
#   forcetime SHIPBASE=1 CONTROL_SHIPPED=1 FORCETIME=1
set -uo pipefail
GAMES="${1:-16}"
SEED="${2:-100}"
OUT="${3:-/tmp/v29ab}"
H="players/baseline/eval/harness.out"
mkdir -p "$OUT"

RED="0,2,4,6,8,10,12,14"
BLUE="1,3,5,7,9,11,13,15"

launch() { # $1=name $2=slots $3..=knob env
  local name="$1" slots="$2"; shift 2
  env HUNTER_SLOTS="$slots" SHIPBASE=1 CONTROL_SHIPPED=1 "$@" \
    "$H" --games "$GAMES" --seed "$SEED" --ticks 6000 > "$OUT/$name.log" 2>&1 &
  echo "launched $name (pid $!)"
}

launch null-red       "$RED"
launch null-blue      "$BLUE"
launch defteeth-red   "$RED"  DEFTEETH=1
launch defteeth-blue  "$BLUE" DEFTEETH=1
launch forcetime-red  "$RED"  FORCETIME=1
launch forcetime-blue "$BLUE" FORCETIME=1
echo "6 arms running, games=$GAMES seed=$SEED -> $OUT"
wait
echo "ALL ARMS DONE"
