#!/usr/bin/env bash
# FAST mirror-effect SCREEN for a v7 bundle lever (2026-07-17).
# All 16 seats run the champion; compares champion vs champion-MINUS-lever over
# a few seeds and diffs the per-seed table. IDENTICAL => the lever changes ZERO
# emitted actions in self-play (a mirror no-op — check WHY: never fires, cancels,
# or downstream-absorbed). DIFFERS => it has a measurable mirror effect; promote
# to a full seat-rotated A/B for the signed verdict.
#
# Usage:  players/baseline/eval/screen.sh KNOB [GAMES] [SEED]   (run from repo root)
set -euo pipefail
KNOB="${1:?usage: screen.sh KNOB [GAMES] [SEED]}"
GAMES="${2:-3}"
SEED="${3:-100}"
H="players/baseline/eval/harness.out"
ALL="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15"

env HUNTER_SLOTS="$ALL" SHIPBASE=1 \
  "$H" --games "$GAMES" --seed "$SEED" 2>&1 | grep -E "^ *[0-9]+ " > /tmp/screen_on.txt
env HUNTER_SLOTS="$ALL" SHIPBASE=1 "$KNOB=0" \
  "$H" --games "$GAMES" --seed "$SEED" 2>&1 | grep -E "^ *[0-9]+ " > /tmp/screen_off.txt

if diff -q /tmp/screen_on.txt /tmp/screen_off.txt >/dev/null; then
  echo "SCREEN $KNOB: IDENTICAL over $GAMES seeds — mirror NO-OP (needs a why-probe)"
else
  echo "SCREEN $KNOB: DIFFERS — measurable mirror effect, promote to seat-rotated A/B"
  diff /tmp/screen_on.txt /tmp/screen_off.txt | head
fi
