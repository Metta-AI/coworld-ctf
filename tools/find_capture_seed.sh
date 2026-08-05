#!/bin/bash
# Finds a seed whose default-config episode ends in a CAPTURE, for the
# tests/fixtures/capture-seed<N>.bitreplay recipe (GV38: seed 4).
#
# The ending a seed produces is a property of the RULES it was recorded under,
# not a constant — GV30 moved the pickups and turned seed 7 from a capture into
# a draw; GV38 (hex arena) did the same to seed 1. So on every GameVersion bump
# the seed has to be re-found, not assumed.
#
# Usage: tools/find_capture_seed.sh <seed> [seed...]
set -uo pipefail
cd "$(dirname "$0")/.."
classify_ending() {
  local log="$1"
  if grep -q 'captured the [a-z]* heart' "$log"; then echo capture; return; fi
  if grep -q 'heart retired' "$log"; then echo wipe; return; fi
  if grep -qE '^[a-z]+ win$' "$log"; then echo tiebreak; return; fi
  if grep -qE '^draw$' "$log"; then echo draw; return; fi
  echo unknown
}
PORT_BASE=${PORT_BASE:-21600}
i=0
for SEED in "$@"; do
  i=$((i + 1))
  LOGF=/tmp/capseed-$SEED.log
  PORT=$((PORT_BASE + i)) LOG=$LOGF \
    tools/record_fixture.sh "tests/fixtures/capture-seed$SEED.bitreplay" \
      "$SEED" >/dev/null 2>&1 || true
  ENDING=$(classify_ending "$LOGF")
  STEALS=$(grep -c 'stole the' "$LOGF" || true)
  echo "seed $SEED -> ${ENDING:-unknown}  (steals: $STEALS)"
  if [ "$ENDING" = capture ]; then
    echo "CAPTURE SEED: $SEED"
    exit 0
  fi
  rm -f "tests/fixtures/capture-seed$SEED.bitreplay"
done
echo "no capture in: $*"
exit 1
