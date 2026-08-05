#!/bin/bash
# Finds a seed whose episode ends with the ENDING a fixture recipe needs.
#
# The ending a seed produces is a property of the RULES it was recorded under,
# not a constant, and it is not even fully determined by the seed: the bots are
# separate live processes, so the same seed can end differently on two runs.
# On a GameVersion bump both facts bite at once, and every fixture recipe in
# tests/test_broadcast_state.nim has to be re-found rather than assumed.
#
# GV38 (hex arena) moved all three: seed 1 stopped capturing, and the wipe
# recipe's seed 3 started drawing — the hexagonal field is roomier and its
# bases sit deeper, so engagements are rarer per tick.
#
# Usage:
#   tools/find_fixture_seed.sh <ending-regex> <out-name> <maxTicks> <extraJson> <seed>...
# e.g.
#   tools/find_fixture_seed.sh 'win' wipe-lives1 10000 \
#     '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}' 3 5 9 11
#
# ENDING LINES. The engine prints, in order:
#   `<color> captured the <color> heart`   then `<color> win`   -- a capture
#   `<color> heart retired`                then `<color> win`   -- a wipe
#   `<color> win`                          on its own           -- lives tiebreak
#   `draw`                                                      -- time limit
# So `<color> win` is the LAST line of three different endings and tail -1 alone
# misreads a capture as a wipe. Classify on the line BEFORE the win.
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
WANT="$1"; NAME="$2"; TICKS="$3"; EXTRA="$4"; shift 4
i=0
for SEED in "$@"; do
  i=$((i + 1))
  LOGF=/tmp/fixseed-$NAME-$SEED.log
  PORT=$((21800 + i)) LOG=$LOGF \
    tools/record_fixture.sh "tests/fixtures/$NAME.bitreplay" \
      "$SEED" "$TICKS" "$EXTRA" >/dev/null 2>&1 || true
  LAST=$(classify_ending "$LOGF")
  echo "seed $SEED -> ${LAST:-unknown}"
  if echo "$LAST" | grep -qE "$WANT"; then
    echo "SEED: $SEED"
    ls -la "tests/fixtures/$NAME.bitreplay"
    exit 0
  fi
done
echo "no '$WANT' ending in: $*" >&2
exit 1
