#!/usr/bin/env bash
# v29 CONTINGENCY-MACHINE DEEPENING A/B (2026-07-29).
#
# Two loose ends the v21 design doc flagged and v26 only half-closed:
#   DEFTEETH  — PhDefend's recapture collapse aims at the REAL thief fix
#               (bot.carrierPos) instead of v26's mateCarryPos, which is OUR mate
#               carrying the ENEMY heart (wrong entity; (0,0) when nobody carries,
#               so the collapse degenerated to "walk to mid at my current height").
#   FORCETIME — the PhForce trigger moves off the never-firing 3800. MEASURED at 0
#               frames of 266,279: GV23 games end by WIPE at mean 2410 ticks.
#
# Both arms are champion-vs-champion (the ONLY correct control):
#   candidate slots: SHIPBASE=1 CONTROL_SHIPPED=1 <KNOB>=1   (champion + lever)
#   control  slots:  SHIPBASE=1 CONTROL_SHIPPED=1            (the champion)
# CONTROL_SHIPPED alone would be champion-vs-BARE-BASELINE and fakes a huge noise
# floor that inflates every effect size — the null MUST read near zero.
#
# Read the CANDIDATE side's SCORE (RED on the Red-candidate run, BLUE on Blue).
# POSITIVE on BOTH seatings = a real edge. Run from the lab repo root.
set -uo pipefail
GAMES="${1:-16}"
SEED="${2:-100}"
TICKS="${3:-6000}"
H="players/baseline/eval/harness.out"

RED="0,2,4,6,8,10,12,14"
BLUE="1,3,5,7,9,11,13,15"

run() { # $1=slots  $2..=extra env  -> the candidate side's score + mechanism metrics
  local slots="$1"; shift
  env HUNTER_SLOTS="$slots" SHIPBASE=1 CONTROL_SHIPPED=1 "$@" \
    "$H" --games "$GAMES" --seed "$SEED" --ticks "$TICKS" 2>&1 |
    grep -E "SCORE:|results:|grab->cap|K-D diff|survive:"
}

arm() { # $1=label  $2..=knob env
  local label="$1"; shift
  echo "########## $label  (games=$GAMES seed=$SEED ticks=$TICKS) ##########"
  echo "--- Red candidate ---"
  run "$RED" "$@"
  echo "--- Blue candidate ---"
  run "$BLUE" "$@"
}

# The NULL is not optional: identical tunes both sides must read ~0. A null far
# from zero means the rig is mis-specified, not that the game is noisy.
arm "NULL (champion vs champion, no lever)"
arm "DEFTEETH (PhDefend recapture teeth)"     DEFTEETH=1
arm "FORCETIME (PhForce timing, tuned tick)"  FORCETIME=1
echo "########## BATCH DONE ##########"
