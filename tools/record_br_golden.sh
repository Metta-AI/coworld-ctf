#!/bin/bash
# Records (or re-records) THE 16-team BR golden fixture:
# tests/fixtures/br-golden-16team.bitreplay — 32 seats (16 duos),
# elimination + the shrink zone + all four authored item pools together, on
# the real brmapkit draw at tests/fixtures/br-golden-map.json. Backs
# tests/test_br_golden_e2e.nim, the launch-readiness audit's #1 gap: nothing
# in CI had ever stepped a 16-team sim before that suite.
#
# LOAD RULE (house scar): record on an IDLE machine. This machine routinely
# runs a 20+ agent fleet, and this script's OWN default log/port paths
# collide with other agents running the identical recipe concurrently —
# always override PORT (and LOG/BOTLOG if you want clean isolation) to a
# value nothing else in the fleet is using. A CPU-starved recording can also
# have its server killed outright before the lobby even fills (observed
# directly building this fixture at 1-minute load ~20-32 on a 14-core
# machine: two isolated attempts died within the port-open/lobby-fill
# window with no server-side error, just SIGTERM). This is the SAME class
# of risk AGENTS.md documents for the six classic fixtures — it applies
# here just as much, and once as a permanent golden hash, not a redo-able
# tuning run.
#
# Usage: PORT=<free port> tools/record_br_golden.sh [seed] [maxTicks]
set -euo pipefail
cd "$(dirname "$0")/.."

SEED="${1:-4242}"
MAXTICKS="${2:-6000}"
OUT="tests/fixtures/br-golden-16team.bitreplay"
MAPSPEC="tests/fixtures/br-golden-map.json"
PORT="${PORT:-21777}"
LOG="${LOG:-/tmp/br-golden-server-$$.log}"
BOTLOG="${BOTLOG:-/tmp/br-golden-bots-$$.log}"

echo "== load check (informational only) =="
uptime || true

echo "== building bin/ctf-server + players/baseline/baseline.out from HEAD =="
mkdir -p bin
nim c -d:release -d:useMalloc --opt:speed --stackTrace:on --hints:off \
  --out:bin/ctf-server src/ctf.nim
nim c -d:release -d:useMalloc -d:buildDefines="-d:release -d:useMalloc" \
  --opt:speed --stackTrace:on --hints:off \
  --out:players/baseline/baseline.out players/baseline/baseline.nim

echo "== recording (seed=$SEED maxTicks=$MAXTICKS port=$PORT) =="
rm -f "$OUT"
LOG="$LOG" BOTLOG="$BOTLOG" PORT="$PORT" \
  tools/record_br_match.sh "$OUT" "$MAPSPEC" "$SEED" "$MAXTICKS"

echo "== verifying the recorded properties (compiles + runs the real suite) =="
nim c -d:release --hints:off -o:/tmp/br_golden_verify_$$ tests/test_br_golden_e2e.nim
VERIFY_STATUS=0
/tmp/br_golden_verify_$$ || VERIFY_STATUS=$?
rm -f "/tmp/br_golden_verify_$$"

if [ "$VERIFY_STATUS" -ne 0 ]; then
  echo
  echo "FAILED: the recorded episode did not satisfy tests/test_br_golden_e2e.nim." >&2
  echo "Do NOT wire this fixture into a shard. Common causes: a degenerate" >&2
  echo "(load-starved) recording — re-run on a quieter window; or the" >&2
  echo "MinDisplacementPx/MinTeamsFiring floors in the test need re-deriving" >&2
  echo "from THIS recording's own numbers (its own doc comment explains why" >&2
  echo "they must never be invented)." >&2
  exit "$VERIFY_STATUS"
fi

echo
echo "== all properties verified. Wiring test_br_golden_e2e into shard_4 =="
if ! grep -q "test_br_golden_e2e" tests/shard_4.nim; then
  # Insert alphabetically next to its nearest neighbor (shard_4.nim's import
  # list is alphabetical: ..., test_barrage, test_broadcast_state, ...).
  sed -i.bak '/test_barrage,/a\
  test_br_golden_e2e,
' tests/shard_4.nim
  rm -f tests/shard_4.nim.bak
fi

echo
echo "== done =="
echo "Next: run the full suite (nim c -r tests/tests.nim, or the four shards)"
echo "to confirm everything is still green together, then commit:"
echo "  git add tests/fixtures/br-golden-16team.bitreplay tests/shard_4.nim"
echo "  git commit -m '...'"
