#!/bin/bash
# Records one 16-seat (8v8), 2-team CTF episode on the standard hand-
# authored "arena" map with the config-gated shrink zone turned on (a
# 3-phase toy schedule). Modeled on record_four_team_demo.sh / record_fixture.sh.
# Usage: tools/record_zone_demo.sh <out.bitreplay RELATIVE to repo root> <seed> [maxTicks]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-3000}"; PORT="${PORT:-21403}"
CFG=$(mktemp /tmp/ctf-zone-demo-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["fastMode"] = True
cfg["maxGames"] = 1
# Barrage off: keep the demo a clean read on the zone alone.
cfg["barrageMaxPerSec"] = 0
# A legible 3-phase toy schedule: long/gentle first, short/harsh last —
# matches the design doc's "long waits + low damage early, short waits +
# high damage late" rule (docs/designs/BR_MAPGEN.md sec 4.3).
cfg["zonePhases"] = [
    {"z": 0.65, "waitTicks": 120, "shrinkTicks": 240, "dps": 1},
    {"z": 0.35, "waitTicks": 100, "shrinkTicks": 200, "dps": 2},
    {"z": 0.15, "waitTicks": 80, "shrinkTicks": 160, "dps": 3},
]
# Close on the map's own center rather than the random per-game draw —
# easier to eyeball in a fixed demo, and exercises the authored zoneCenter
# path (§4.3). (617, 329) is the standard "arena" map's own CtfMap.center
# (1235x659); re-derive if this demo ever moves off that map.
cfg["zoneCenter"] = [617, 329]
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-zone-demo-server.log}"
BOTLOG="${BOTLOG:-/tmp/ctf-zone-demo-bots.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 40); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -20 "$LOG" >&2; exit 1; }

BOT_PIDS=()
for i in $(seq 0 15); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

DEADLINE=$((SECONDS + 300))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 5 minutes — killing; log tails:" >&2
    tail -20 "$LOG" >&2
    tail -10 "$BOTLOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
if ! wait $SERVER_PID; then
  echo "server exited non-zero; log tail:" >&2
  tail -20 "$LOG" >&2
fi
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
