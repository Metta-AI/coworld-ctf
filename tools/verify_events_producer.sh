#!/bin/bash
# Proves the tier-2 events producer end to end, both ways round:
#
#   1. LIVE   — records a real 16-bot episode with COGAME_EVENTS_URI set, so the
#              game writes events.json the way it does in a platform episode
#              (dispatcher sets that env var; the runner uploads the file).
#   2. RESIM  — replays the .bitreplay that same episode recorded through
#              tools/extract_events.nim, the retroactive path for episodes that
#              were recorded before the live emitter shipped.
#
# Then it asserts the two artifacts are BYTE-IDENTICAL. That is the whole point
# of keeping the serializer in src/ctf/events.nim: a resim of an episode must
# reproduce exactly what the live game would have written, or the retroactive
# backfill would silently disagree with freshly-played episodes.
#
# Usage: tools/verify_events_producer.sh [seed]   (default seed 7, ~2 min)
set -euo pipefail
cd "$(dirname "$0")/.."

SEED="${1:-7}"
PORT="${PORT:-21778}"
WORK="$(mktemp -d /tmp/ctf-events-verify-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "== building game, bot, and extractor"
nim c --hints:off -d:release -d:useMalloc --opt:speed -o:bin/ctf-server src/ctf.nim
nim c --hints:off -d:release -d:useMalloc --opt:speed \
  -o:players/baseline/baseline.out players/baseline/baseline.nim
nim c --hints:off -d:release --opt:speed -o:"$WORK/extract" tools/extract_events.nim

python3 - "$WORK/config.json" "$SEED" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = 10000
cfg["speed"] = 16
cfg["maxGames"] = 1
json.dump(cfg, open(sys.argv[1], "w"))
PY

echo "== recording a live episode (seed $SEED) with COGAME_EVENTS_URI set"
COGAME_HOST=127.0.0.1 COGAME_PORT="$PORT" \
COGAME_CONFIG_URI="file://$WORK/config.json" \
COGAME_SAVE_REPLAY_URI="file://$WORK/replay.bitreplay" \
COGAME_RESULTS_URI="file://$WORK/results.json" \
COGAME_EVENTS_URI="file://$WORK/live-events.json" \
  ./bin/ctf-server > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 2
BOT_PIDS=()
for i in $(seq 0 15); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done
wait "$SERVER_PID" || { echo "FAIL: game exited nonzero"; tail -20 "$WORK/server.log"; exit 1; }
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done

grep "Events written" "$WORK/server.log" || { echo "FAIL: game wrote no events artifact"; exit 1; }

echo "== resimming that replay through the extractor"
"$WORK/extract" "$WORK/replay.bitreplay" --out "$WORK/resim-events.json"

echo "== comparing"
if ! cmp "$WORK/live-events.json" "$WORK/resim-events.json"; then
  echo "FAIL: live and resim artifacts differ"
  diff <(cat "$WORK/live-events.json") <(cat "$WORK/resim-events.json") | head -20
  exit 1
fi

# Both are real streams, not two matching empties.
python3 - "$WORK/live-events.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
events, summary = rows[:-1], rows[-1]
assert summary["type"] == "summary", "artifact does not end in a summary row"
assert summary["events"] == len(events), "summary count disagrees with rows"
assert not summary["truncated"], "episode truncated; raise MaxCollectedEvents"
kinds = {e["kind"] for e in events}
# A full match must exercise the channels the workbench actually renders.
for required in ("shot", "hit", "damage", "kill", "death", "phase"):
    assert required in kinds, f"no {required} events in a full match"
print(f"  {len(events)} events, kinds: {sorted(kinds)}")
print(f"  ticks {summary['ticks']}, gameVersion {summary['gameVersion']}")
PY

echo "PASS: live emission and resim produce byte-identical events.json"
