#!/usr/bin/env bash
# Reads the v29 phase-deepening A/B logs and prints the CANDIDATE side's score per
# arm/seating. The candidate is whichever side holds the hunter slots: RED on a
# *-red run, BLUE on a *-blue run. POSITIVE on BOTH seatings = a real edge.
set -uo pipefail
OUT="${1:-/tmp/v29ab}"

score() { # $1=log $2=RED|BLUE -> that side's SCORE integer
  local line
  line=$(grep -m1 "SCORE:" "$1" 2>/dev/null) || return 1
  if [[ "$2" == RED ]]; then
    sed -E 's/.*RED ([+-][0-9]+).*/\1/' <<<"$line"
  else
    sed -E 's/.*BLUE ([+-][0-9]+).*/\1/' <<<"$line"
  fi
}

printf '%-11s %10s %10s %8s   %s\n' ARM RED-CAND BLUE-CAND VERDICT NOTE
for arm in null defteeth forcetime; do
  r=$(score "$OUT/$arm-red.log" RED 2>/dev/null || echo "-")
  b=$(score "$OUT/$arm-blue.log" BLUE 2>/dev/null || echo "-")
  verdict="?"
  note=""
  if [[ "$r" != "-" && "$b" != "-" ]]; then
    if (( r > 0 && b > 0 )); then verdict="REAL"; note="positive both seatings"
    elif (( r < 0 && b < 0 )); then verdict="REGRESS"; note="negative both seatings"
    else verdict="WASH"; note="seat-split — under the noise floor"; fi
    [[ "$arm" == null ]] && note="$note (must be ~0 or the rig is mis-specified)"
  else
    note="still running"
  fi
  printf '%-11s %10s %10s %8s   %s\n' "$arm" "$r" "$b" "$verdict" "$note"
done
echo
echo "grab->cap + K-D per arm (mechanism sub-metrics — a single lever's win delta"
echo "sits under the 60-game noise floor, so judge the MECHANISM too):"
for arm in null defteeth forcetime; do
  for seat in red blue; do
    f="$OUT/$arm-$seat.log"
    [[ -f "$f" ]] || continue
    printf '  %-16s ' "$arm-$seat"
    grep -m1 "K-D diff" "$f" 2>/dev/null | tr -s ' ' || echo "(running)"
  done
done
