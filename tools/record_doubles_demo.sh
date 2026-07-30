#!/bin/bash
# Records one CTF episode seated like a CTF-Doubles league round: 4 policies,
# 2 per team (slots A,B,A,B,A,B,A,B,C,D,C,D,C,D,C,D — Red = A+C, Blue = B+D),
# with hosted-style " (N)" per-connection name suffixes. Demo fixture for the
# multi-team replay viewer.
# Usage: tools/record_doubles_demo.sh <out.bitreplay> <seed> [maxTicks]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-5000}"; PORT="${PORT:-21100}"
CFG=$(mktemp /tmp/ctf-doubles-demo-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["maxGames"] = 1
# Doubles-style roster names: front half alternates policies A,B; back half
# C,D (Red = A+C, Blue = B+D by slot parity), with the hosted-style per-seat
# suffix in its on-the-wire underscore form. The server assigns each slot its
# configured name, so the bots connect with slot+token only.
pols = {"A": "ctf-focusfire:v62", "B": "beacon:v33",
        "C": "osprey:v3", "D": "picasso:v9"}
counts = {k: 0 for k in pols}
players = []
for slot in range(16):
    key = ("A" if slot % 2 == 0 else "B") if slot < 8 else \
          ("C" if slot % 2 == 0 else "D")
    counts[key] += 1
    players.append({"name": f"{pols[key]}_({counts[key]})"})
cfg["players"] = players
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-doubles-demo-server.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!
sleep 1.5

BOT_PIDS=()
for i in $(seq 0 15); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done
wait $SERVER_PID || true
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
ls -la "$OUT"
