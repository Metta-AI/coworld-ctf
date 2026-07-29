#!/usr/bin/env bash
# v7 BUNDLE ISOLATION A/B (2026-07-17).
# Measures ONE bundle lever's contribution by running the champion MINUS that
# lever (candidate) vs the FULL champion (control), seat-rotated.
#
#   candidate slots: SHIPBASE=1 CONTROL_SHIPPED=1 <KNOB>=0  (champion - lever)
#   control  slots:                CONTROL_SHIPPED=1         (full champion)
#
# If the minus-side LOSES on BOTH seatings, the lever earns its place.
# Flat/positive on both => it doesn't help in the mirror (or hurts).
#
# Usage:  players/baseline/eval/isolate.sh KNOB [GAMES] [SEED]
#   e.g.  players/baseline/eval/isolate.sh HOMESTRETCH 24 100
# Run from the repo root (harness reads data/ relative to cwd).
set -euo pipefail
KNOB="${1:?usage: isolate.sh KNOB [GAMES] [SEED]}"
GAMES="${2:-24}"
SEED="${3:-100}"
H="players/baseline/eval/harness.out"

RED="0,2,4,6,8,10,12,14"
BLUE="1,3,5,7,9,11,13,15"

run() { # $1=slots  -> prints the SCORE line for the hunter (minus-lever) side
  env HUNTER_SLOTS="$1" SHIPBASE=1 CONTROL_SHIPPED=1 "$KNOB=0" \
    "$H" --games "$GAMES" --seed "$SEED" 2>&1 | grep -E "SCORE:|grab->cap|survive:"
}

echo "=== ISOLATION A/B: champion MINUS $KNOB  (games=$GAMES seed=$SEED) ==="
echo "--- Red hunter (minus-lever on Red seats) ---"
run "$RED"
echo "--- Blue hunter (minus-lever on Blue seats) ---"
run "$BLUE"
echo "(Read: SCORE for the minus-lever side. NEGATIVE on both = lever earns its place.)"
