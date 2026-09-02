#!/bin/bash
# Re-records ALL EIGHT replay fixtures pinned by the native test suite AND
# the wasm-replay-viewer CI smoke job, then regenerates the DERIVED goldens
# that carry a GameVersion stamp. Run this once after any GameVersion bump
# (AGENTS.md "Replay fixtures") — every committed .bitreplay must carry the
# version stamp of the rules that produced it, and `test_replay.nim`'s
# "EVERY committed .bitreplay carries the current GameVersion" sweep fails
# loudly on any straggler.
#
# ALL EIGHT, every time — the native shards only read six
# (capture-seed1, wipe-lives1, draw-nokill, seats-numagents16, ctf,
# br-golden-16team);
# gen-small-pits and gen-colossal-4team are read by NO native test, only the
# CI wasm-replay-viewer job, so a re-record pass working from the test files
# alone silently misses them (GV44 shipped exactly this way once). The
# derived goldens are the same trap one layer down: they are BYTES computed
# from the current constants/fixtures, not recordings, so nothing about a
# re-record pass touches them — format2-legacy.golden.bin stamps the CURRENT
# GameVersion (the GV49 recut pass missed exactly this one), and the glory
# lockstep claims golden is derived from capture-seed1's fresh bytes.
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
tools/record_fixture.sh tests/fixtures/seats-numagents16.bitreplay 5 1500 \
  '{"num_agents":16}'

echo "== compiling the event-substrate acceptance check =="
EVENT_CHECK=/tmp/record-extract-events-check
nim c -d:release --hints:off --threads:on -o:"$EVENT_CHECK" \
  tests/test_extract_events.nim \
  > /tmp/record-extract-events-check-build.log 2>&1 \
  || { echo "event-substrate acceptance check build FAILED — see /tmp/record-extract-events-check-build.log" >&2; exit 1; }

echo "== recording event-substrate fixture: tests/replays/ctf.bitreplay =="
# GV50 shipped a grenade-kill-less take because this fixture was only
# re-simulated, not checked for the event content test_extract_events requires.
# Keep the fixture identity fixed; the live bot timing is the allowed dice roll.
EVENT_OK=0
for TAKE in 1 2 3; do
  echo "--- tests/replays/ctf.bitreplay take $TAKE/3 ---"
  uptime || true
  tools/record_fixture.sh tests/replays/ctf.bitreplay 907 10000 '{"lives":9}'
  if "$EVENT_CHECK" > "/tmp/record-extract-events-take-$TAKE.log" 2>&1; then
    echo "event-substrate fixture accepted on take $TAKE"
    EVENT_OK=1
    break
  fi
  echo "event-substrate fixture take $TAKE FAILED — see /tmp/record-extract-events-take-$TAKE.log" >&2
  grep -E "sawGunKill|sawSprayKill|sawGrenadeKill|sawPlayingPhase|sawGameOverPhase|named >= 2|Check failed|\\[FAILED\\]" \
    "/tmp/record-extract-events-take-$TAKE.log" >&2 || true
done
if [ "$EVENT_OK" -ne 1 ]; then
  echo "event-substrate fixture exhausted 3 takes without satisfying:" >&2
  echo "  sawGunKill && sawSprayKill && sawGrenadeKill" >&2
  echo "  sawPlayingPhase && sawGameOverPhase" >&2
  echo "  named >= 2" >&2
  echo "  extraction.finished with winner-in-teams or honest draw" >&2
  exit 1
fi
tools/record_fixture.sh tests/fixtures/gen-small-pits.bitreplay 4242 1500 \
  '{"mapPath":"gen","mapSeed":4242,"mapSize":"small"}'
tools/record_colossal_demo.sh tests/fixtures/gen-colossal-4team.bitreplay 4242 1500 16

echo "== recording the seventh fixture: the BR golden (own script) =="
# Its LOAD RULE is stricter than the six above (a permanent golden hash, not
# a redo-able tuning run) — see record_br_golden.sh's own header. Override
# BR_GOLDEN_PORT to a fleet-free port when the default collides.
# Seed 4248 since GV51: 4242 no longer reaches the shield pool under the
# parallel-motion collision rule (three of eight seeds did; 4248 is the first
# that also keeps the closing-distance property).
PORT="${BR_GOLDEN_PORT:-21777}" tools/record_br_golden.sh 4248

echo "== regenerating the DERIVED goldens (deterministic — no dice roll) =="
# replay-compat byte goldens: written at module load under this define; the
# suite then runs against what it just wrote (a failure here is signal).
nim c -r -d:release --hints:off --threads:on -d:writeReplayCompatFixtures \
  -o:/tmp/record-replay-compat-fixtures tests/test_replay_compat.nim \
  > /tmp/record-replay-compat-fixtures.log 2>&1 \
  || { echo "replay-compat golden regen FAILED — see /tmp/record-replay-compat-fixtures.log" >&2; exit 1; }
# the glory lockstep claims golden (test_glory_lockstep.nim's own ritual),
# regenerated AFTER capture-seed1 above so it derives from the fresh bytes.
nim c -r --hints:off --threads:on -d:recordGloryGolden \
  -o:/tmp/record-glory-golden tests/test_glory_lockstep.nim \
  > /tmp/record-glory-golden.log 2>&1 \
  || { echo "glory claims golden regen FAILED — see /tmp/record-glory-golden.log" >&2; exit 1; }
# shell replay byte goldens: manifest.bin embeds the engine manifest (with
# the CURRENT GameVersion) and play-call.bin pins the native reflex table's
# nativeGameVersion — both move on every bump (the GV49 pass missed these
# too, alongside format2-legacy above).
nim c -r -d:release --hints:off --threads:on -d:writeShellReplayGoldens \
  -o:/tmp/record-shell-replay-goldens tests/test_shell_replay.nim \
  > /tmp/record-shell-replay-goldens.log 2>&1 \
  || { echo "shell replay golden regen FAILED — see /tmp/record-shell-replay-goldens.log" >&2; exit 1; }

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
    tests/fixtures/gen-colossal-4team.bitreplay \
    tests/fixtures/br-golden-16team.bitreplay; do
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
