#!/usr/bin/env bash
# Sequential seat-rotated ISOLATION A/B batch for the mirror-active v7 levers
# (2026-07-17). Each: champion MINUS one lever (candidate hunter seats) vs the
# FULL champion (control seats), run once Red-hunter and once Blue-hunter.
# Read the MINUS-lever side's SCORE (RED on the Red-hunter run, BLUE on Blue-hunter):
# NEGATIVE on BOTH seatings => the lever earns its place; flat/positive => it doesn't.
# Run from repo root.
set -uo pipefail
GAMES="${1:-20}"
SEED="${2:-100}"
for KNOB in CHASETHIEF CORNERAIM SENTRYDISP TOPBIAS PLAYBOOK; do
  echo "########################## $KNOB (minus-lever vs full champion) ##########################"
  players/baseline/eval/isolate.sh "$KNOB" "$GAMES" "$SEED"
done
echo "########################## BATCH DONE ##########################"
