#!/bin/bash
# Re-records ALL SIX replay fixtures pinned by the native test suite AND the
# wasm-replay-viewer CI smoke job. Run this once after any GameVersion bump
# (AGENTS.md "Replay fixtures") — every committed .bitreplay must carry the
# version stamp of the rules that produced it, and `test_replay.nim`'s
# "EVERY committed .bitreplay carries the current GameVersion" sweep fails
# loudly on any straggler.
#
# ALL SIX, every time — the native shards only read four
# (capture-seed1, wipe-lives1, draw-nokill, ctf); gen-small-pits and
# gen-colossal-4team are read by NO native test, only the CI
# wasm-replay-viewer job, so a re-record pass working from the test files
# alone silently misses them (GV44 shipped exactly this way once).
#
# LOAD RULE (house scar): record on an IDLE machine. A CPU-starved speed-16
# recording drops its bots mid-episode and produces a degenerate ending (a
# capture fixture that times out to a draw instead, etc) — this has already
# happened once (the GV42 draw-nokill incident, see AGENTS.md). Check
# `uptime` / `sysctl -n vm.loadavg` before trusting this script's output as
# something to commit; a 1-minute load anywhere near or above the core count
# means wait for a quieter window and re-run.
#
# Usage: tools/record_all_fixtures.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== load check (informational only — this script does not gate on it) =="
uptime || true

echo "== building bin/ctf-server + players/baseline/baseline.out from HEAD =="
mkdir -p bin
nim c -d:release -d:useMalloc --opt:speed --stackTrace:on --hints:off \
  --out:bin/ctf-server src/ctf.nim
nim c -d:release -d:useMalloc -d:buildDefines="-d:release -d:useMalloc" \
  --opt:speed --stackTrace:on --hints:off \
  --out:players/baseline/baseline.out players/baseline/baseline.nim

echo "== recording the six pinned fixtures =="
export PATH="$PWD/bin:$PATH"
tools/record_fixture.sh tests/fixtures/capture-seed1.bitreplay 1
tools/record_fixture.sh tests/fixtures/wipe-lives1.bitreplay 3 10000 \
  '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}'
tools/record_fixture.sh tests/fixtures/draw-nokill.bitreplay 7 1500 \
  '{"hitPoints":1000,"carrierSpeedPct":1,"barrageMaxPerSec":0}'
tools/record_fixture.sh tests/replays/ctf.bitreplay 907 10000 '{"lives":9}'
tools/record_fixture.sh tests/fixtures/gen-small-pits.bitreplay 4242 1500 \
  '{"mapPath":"gen","mapSeed":4242,"mapSize":"small"}'
tools/record_colossal_demo.sh tests/fixtures/gen-colossal-4team.bitreplay 4242 1500 16

echo "== verifying every recorded fixture re-simulates deterministically =="
# extract_events.nim re-simulates with mismatchQuit on (hash-validated every
# step) and prints one JSON summary object last: tick count, winner, isDraw.
# A clean run here IS the "hashes match / re-simulates from disk" check —
# the same property test_replay.nim's "hashes match" pins for capture-seed1.
FAIL=0
for f in tests/fixtures/capture-seed1.bitreplay \
    tests/fixtures/wipe-lives1.bitreplay \
    tests/fixtures/draw-nokill.bitreplay \
    tests/replays/ctf.bitreplay \
    tests/fixtures/gen-small-pits.bitreplay \
    tests/fixtures/gen-colossal-4team.bitreplay; do
  echo "--- $f ---"
  if ! nim r --hints:off tools/extract_events.nim "$f" \
      > "/tmp/$(basename "$f").events.jsonl" 2>"/tmp/$(basename "$f").err.log"; then
    echo "FAILED to re-simulate $f — see /tmp/$(basename "$f").err.log" >&2
    FAIL=1
    continue
  fi
  echo "summary: $(tail -1 "/tmp/$(basename "$f").events.jsonl")"
done

echo
echo "== next steps (manual — this script does not do these) =="
echo "1. Read each summary line above: confirm the beat the fixture exists"
echo "   for actually occurred (capture-seed1 ends in a capture, wipe-lives1"
echo "   in a wipe, draw-nokill in a DRAW — not a winner; a barrage-armed"
echo "   config has no time-limit draw, only a wipe/mutual-kill one)."
echo "2. Re-pin any asserted winner/ending in tests/test_broadcast_state.nim"
echo "   (and test_replay_scan.nim, which watches capture-seed1's tail) to"
echo "   match what actually recorded."
echo "3. Run the full suite (nim c -r tests/tests.nim, or the four shards) —"
echo "   it must be green, including 'hashes match' and 'EVERY committed"
echo "   .bitreplay carries the current GameVersion'."
exit $FAIL
