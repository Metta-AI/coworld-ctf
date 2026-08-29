#!/bin/bash
# THE MANY-SEAT MEASUREMENT RUN: a real local BR match where EVERY seat
# (not just one) is a real `players/onepage` runner, each pointed at its own
# page file (see /tmp/gen_seat_pages.py), so the recorded .bitreplay carries
# N independent page-carrying seats instead of the single-seat round trip
# tools/roundtrip_reflash_match.sh proved.
#
# Modeled on tools/roundtrip_reflash_match.sh, with the baseline bots for
# seats 1..N-1 replaced by more onepage runners.
#
# PORT: 21473 (own port; not 7420/21400-21403/21454/21471, which other
# lanes/Maxwell are using).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-rt/manyseat.bitreplay}"
PAGEDIR="${2:?usage: manyseat_reflash_match.sh OUT PAGEDIR [SEATS]}"
MAPSPEC="${MAPSPEC:-br-match-showmatch-4242.json}"
SEED="${SEED:-777002}"
MAXTICKS="${MAXTICKS:-300}"
PORT="${PORT:-21473}"
SEATS="${3:-${SEATS:-32}}"
CFG="$PWD/rt/manyseat_cfg.json"

python3 - "$CFG" "$SEED" "$MAXTICKS" "$MAPSPEC" "$SEATS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2]); cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16; cfg["fastMode"] = True; cfg["maxGames"] = 1
cfg["teams"] = 16
cfg["mapSpec"] = json.load(open(sys.argv[4]))
cfg["brMode"] = True
cfg["lives"] = 1
cfg["barrageMaxPerSec"] = 0
cfg["allowPolicyReflash"] = True
TEAM_NAMES = ["red","blue","green","yellow","black","silver","ivory","pink",
              "umber","rust","orange","plum","lime","navy","azure","peach"]
seats = int(sys.argv[5])
cfg["slots"] = [{"team": TEAM_NAMES[i % 16]} for i in range(seats)]
cfg["tokens"] = ["0xBADA55_%d" % i for i in range(seats)]
cfg["players"] = [{"name": "onepage%02d" % i} for i in range(seats)]
cfg["minPlayers"] = seats
T = int(sys.argv[3])
cfg["zonePhases"] = [
    {"z": 0.824, "waitTicks": T//3, "shrinkTicks": T//8, "dps": 0},
    {"z": 0.648, "waitTicks": 0, "shrinkTicks": T//8, "dps": 2},
    {"z": 0.472, "waitTicks": 0, "shrinkTicks": T//8, "dps": 4},
    {"z": 0.296, "waitTicks": 0, "shrinkTicks": T//8, "dps": 8},
    {"z": 0.120, "waitTicks": 0, "shrinkTicks": T//8, "dps": 12},
]
json.dump(cfg, open(sys.argv[1], "w"))
PY

LOG="${LOG:-/tmp/rfi-manyseat-server.log}"
: > /tmp/rfi-manyseat-bots.log
rm -f "$PWD/$OUT"

COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin_ctf > "$LOG" 2>&1 &
SERVER_PID=$!
echo "server pid=$SERVER_PID port=$PORT seats=$SEATS pagedir=$PAGEDIR"

for i in $(seq 1 60); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 $SERVER_PID 2>/dev/null || { echo "server died:"; tail -20 "$LOG"; exit 1; }
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened"; tail -20 "$LOG"; exit 1; }

BOT_PIDS=()
for i in $(seq 0 $((SEATS - 1))); do
  PF=$(printf "%s/page_seat%02d.json" "$PAGEDIR" "$i")
  COWORLD_POLICY_PAGE_FILE="$PF" \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./bin_onepage >> "/tmp/rfi-manyseat-bots.log" 2>&1 &
  BOT_PIDS+=($!)
done

DEADLINE=$((SECONDS + ${DEADLINE_SECS:-300}))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 5 minutes — killing" >&2
    tail -20 "$LOG" >&2; kill $SERVER_PID 2>/dev/null
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    exit 1
  fi
  sleep 1
done
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
echo "replay bytes: $SIZE"
[ "$SIZE" -lt 5000 ] && { echo "replay missing/truncated"; tail -25 "$LOG"; exit 1; }
echo "=== onepage proposals ==="; grep -Ec "proposed policy reflash" /tmp/rfi-manyseat-bots.log
exit 0
