#!/bin/bash
# Records tests/fixtures/capture-<seed>.bitreplay, RETRYING until the episode
# actually ends in a capture with the beats the tests need.
#
# Why a retry loop and not one shot: the bots are separate live processes, so
# the ending is a property of the RUN, not of the seed — the same seed can
# capture on one recording and run to a draw on the next. test_broadcast_state
# has always said "scan a few seeds if needed"; this makes that mechanical.
#
# The two properties the suite needs:
#   1. the episode ENDS on a capture (test_broadcast_state's asserted ending);
#   2. only ONE flag is out from the last steal to that capture — the endzone
#      fade ramp test (test_replay_scan) watches this fixture just past the
#      last steal, and its per-frame band allowance assumes a single
#      powered-down endzone. A double-steal ending ships both bands at once
#      and busts the bound.
#
# Usage: tools/record_capture_fixture.sh <seed> [attempts]
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
SEED="${1:-4}"; ATTEMPTS="${2:-8}"
OUT="tests/fixtures/capture-seed$SEED.bitreplay"
for attempt in $(seq 1 "$ATTEMPTS"); do
  LOGF=/tmp/capfix-$SEED-$attempt.log
  PORT=$((21700 + attempt)) LOG=$LOGF \
    tools/record_fixture.sh "$OUT" "$SEED" >/dev/null 2>&1 || true
  # ENDING LINES. The engine prints, in order:
  #   `<color> captured the <color> heart`   then `<color> win`   -- a capture
  #   `<color> heart retired`                then `<color> win`   -- a wipe
  #   `<color> win`                          on its own           -- lives tiebreak
  #   `draw`                                                      -- time limit
  # So `<color> win` is the LAST line of three different endings and tail -1 alone
  # misreads a capture as a wipe. Classify on the line BEFORE the win.
  LAST=$(classify_ending "$LOGF")
  if [ "$LAST" != capture ]; then
    echo "attempt $attempt: ended '${LAST:-unknown}' — retrying"
    continue
  fi
  # How many hearts were out AT THE MOMENT OF THE CAPTURE. The log must be
  # truncated at the capture line first: an episode routinely prints a
  # "returned home" AFTER the capture (the captured team's own heart resets),
  # and counting to the end of the file lets that later line cancel a steal
  # that was genuinely outstanding — the check then passes vacuously on exactly
  # the recordings it exists to reject.
  CAPLINE=$(grep -n 'captured the [a-z]* heart' "$LOGF" | head -1 | cut -d: -f1)
  # No `tac` on macOS; `tail -r` is the portable reverse here.
  OUTSTANDING=$(head -n "$CAPLINE" "$LOGF" | grep -E 'stole the|returned home' \
    | tail -r | awk '/returned home/{exit} /stole the/{n++} END{print n+0}')
  # The capture itself is one carried heart; anything MORE is a second band.
  if [ "${OUTSTANDING:-0}" -gt 1 ]; then
    echo "attempt $attempt: captured but $OUTSTANDING flags were out — retrying"
    continue
  fi
  echo "attempt $attempt: OK — capture with $OUTSTANDING heart(s) out"
  echo "WINNER: $(grep -oE '^[a-z]+ win$' "$LOGF" | tail -1)"
  echo "CAPTURE: $(grep -oE '[a-z]+ captured the [a-z]+ heart' "$LOGF" | tail -1)"
  head -n "$CAPLINE" "$LOGF" | grep -E 'stole the|captured the|returned home' \
    | tail -4
  ls -la "$OUT"
  exit 0
done
echo "no clean capture in $ATTEMPTS attempts on seed $SEED" >&2
exit 1
