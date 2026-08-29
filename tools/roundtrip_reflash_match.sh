#!/bin/bash
# THE ROUND TRIP: a real local BR match with a real `onepage` seat, the
# reflash gate armed, a tick-1 starting flash AND a mid-episode reflash,
# recorded to a real .bitreplay and re-simulated by the shipped instrument.
#
# Modeled on tools/record_br_match.sh (the canonical BR recorder) with three
# changes: `allowPolicyReflash` armed, seat 0 driven by players/onepage
# instead of baseline, and the page file rewritten mid-match so the runner's
# own `pollForNewPage` fires a SECOND, mid-episode flash.
#
# PORT: 21471. NOT 7420 (Maxwell's live field), NOT 21400-21403 or 21454
# (other agents in this fleet).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-rt/roundtrip.bitreplay}"
MAPSPEC="${2:-br-match-map-14005.json}"
SEED="${SEED:-777001}"
MAXTICKS="${MAXTICKS:-900}"
PORT="${PORT:-21471}"
SEATS="${SEATS:-16}"
PAGEFILE="$PWD/rt/live_page.json"
CFG="$PWD/rt/live_cfg.json"

cp rt/page_a.json "$PAGEFILE"

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
# THE GATE. Off by default everywhere else; this match is the one place it
# is armed, and `applyPolicyPage` refuses every page without it.
cfg["allowPolicyReflash"] = True
TEAM_NAMES = ["red","blue","green","yellow","black","silver","ivory","pink",
              "umber","rust","orange","plum","lime","navy","azure","peach"]
seats = int(sys.argv[5])
cfg["slots"] = [{"team": TEAM_NAMES[i % 16]} for i in range(seats)]
cfg["tokens"] = ["0xBADA55_%d" % i for i in range(seats)]
cfg["players"] = [{"name": ("onepage" if i == 0 else "duo%02d" % i)} for i in range(seats)]
cfg["minPlayers"] = seats
# Zone compressed to fit a short match: same shape, same monotone recession,
# just scaled to MAXTICKS so the episode resolves instead of timing out.
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

LOG="${LOG:-/tmp/rfi-match-server.log}"
BOTLOG="${BOTLOG:-/tmp/rfi-match-bots.log}"
ONEPAGELOG="${ONEPAGELOG:-/tmp/rfi-match-onepage.log}"
: > "$BOTLOG"; : > "$ONEPAGELOG"
rm -f "$PWD/$OUT"

COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin_ctf > "$LOG" 2>&1 &
SERVER_PID=$!
echo "server pid=$SERVER_PID port=$PORT"

for i in $(seq 1 60); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 $SERVER_PID 2>/dev/null || { echo "server died:"; tail -20 "$LOG"; exit 1; }
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened"; tail -20 "$LOG"; exit 1; }

BOT_PIDS=()
# Seat 0: the onepage runner. Its startup page is delivered by env FILE, and
# its episode-start flash goes over the SAME propose path as a mid-episode
# one — so the starting page is not a hidden input.
COWORLD_POLICY_PAGE_FILE="$PAGEFILE" \
COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=0&token=0xBADA55_0" \
  ./bin_onepage >> "$ONEPAGELOG" 2>&1 &
BOT_PIDS+=($!)
for i in $(seq 1 $((SEATS - 1))); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

# THE MID-EPISODE REFLASH, run as a BACKGROUND watcher.
#
# Keyed off the SERVER's "game started" line, not the runner's stdout: the
# runner is a Nim binary writing to a file, so its stdout is BLOCK-buffered
# and its "proposed policy reflash" line does not appear until the process
# exits. Watching it made the first take of this script silently skip the
# mid-episode swap and record only the opening flash — a run that passes the
# positive arm while proving half the feature.
#
# In the BACKGROUND because the foreground has to be free to wait on the
# server: a fixed-length poll in the foreground raced the lobby (16 bots
# connecting is slower than a wall-clock guess) and gave up before the match
# even began, which is the second way this same swap silently went missing.
(
  while kill -0 $SERVER_PID 2>/dev/null; do
    grep -q "game started" "$LOG" && break
    sleep 0.2
  done
  if grep -q "game started" "$LOG"; then
    echo "[watcher] match is LIVE; swapping the page under the running cog"
    sleep "${REFLASH_DELAY:-2}"
    cp rt/page_b.json "$PAGEFILE"; echo "[watcher] mid-episode page B written"
    sleep "${REFLASH_DELAY2:-2}"
    cp rt/page_c.json "$PAGEFILE"; echo "[watcher] mid-episode page C written"
  else
    echo "[watcher] the match never started" >&2
  fi
) &
WATCHER_PID=$!

DEADLINE=$((SECONDS + 300))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 5 minutes — killing" >&2
    tail -20 "$LOG" >&2; kill $SERVER_PID 2>/dev/null
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    exit 1
  fi
  sleep 1
done
kill $WATCHER_PID 2>/dev/null
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
echo "replay bytes: $SIZE"
[ "$SIZE" -lt 5000 ] && { echo "replay missing/truncated"; tail -25 "$LOG"; exit 1; }
echo "=== onepage runner said ==="; grep -E "proposed|applied|rejected" "$ONEPAGELOG" | head -20
exit 0
