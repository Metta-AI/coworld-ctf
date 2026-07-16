#!/bin/bash
# Records one full-scale CTF episode as a .bitreplay fixture.
# Usage: tools/record_fixture.sh <out.bitreplay> <seed> [maxTicks] [extraConfigJson]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-10000}"; EXTRA="${4:-}"; PORT="${PORT:-21000}"
[ -z "$EXTRA" ] && EXTRA='{}'
CFG=$(mktemp /tmp/ctf-fixture-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$EXTRA" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["maxGames"] = 1
cfg.update(json.loads(sys.argv[4]))
json.dump(cfg, open(sys.argv[1], "w"))
PY
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server &
SERVER_PID=$!
sleep 1.5
BOT_PIDS=()
for i in ${SLOTS:-$(seq 0 15)}; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done
wait $SERVER_PID || true
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
ls -la "$OUT"
