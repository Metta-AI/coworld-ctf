#!/bin/bash
# The standing FREEPLAY field: a serve-forever match with every seat held by a
# policy, and seat takeover enabled so a human can walk up and assume one.
#
# Built on the dev-loop lane's practice substrate (config.practice.json,
# tools/dev_play.sh): maxGames=0 keeps the server alive across matches, so the
# field is always up and a browser can join at any time.
#
# Unlike dev_play.sh this leaves NO slot open — every seat is a bot. The human
# does not join an empty slot; they TAKE OVER an occupied one, and the swap
# lands at that cog's next respawn.
#
# Usage: tools/freeplay.sh
# Env overrides:
#   FREEPLAY_PORT        port to bind (default 2000)
#   FREEPLAY_CONFIG      config path (default config.freeplay.json)
#   FREEPLAY_SKIP_BUILD  skip the nim c build steps if already built (1/0)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

PORT="${FREEPLAY_PORT:-21777}"
CONFIG_PATH="${FREEPLAY_CONFIG:-config.freeplay.json}"
SKIP_BUILD="${FREEPLAY_SKIP_BUILD:-0}"

# Named `freeplay-server`, not `ctf-server`, on purpose: a shared dev box
# routinely runs `pkill -f "bin/ctf-server"` from other lanes, which would
# otherwise take the standing field down mid-session.
SERVER_BIN="$REPO_ROOT/bin/freeplay-server"
BOT_BIN="$REPO_ROOT/players/baseline/freeplay-bot.out"
LOG_DIR="$REPO_ROOT/.freeplay/logs"
mkdir -p "$REPO_ROOT/bin" "$LOG_DIR"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "[freeplay] config not found: $CONFIG_PATH" >&2
  exit 1
fi

if [ "$SKIP_BUILD" != "1" ]; then
  # -d:release is not optional: a debug server bakes its supersampled
  # spectator caches for minutes BEFORE opening its listener, which looks
  # exactly like a hung port.
  echo "[freeplay] building release server -> $SERVER_BIN"
  nim c -d:release --hints:off --path:src -o:"$SERVER_BIN" src/ctf.nim
  echo "[freeplay] building release baseline bot -> $BOT_BIN"
  nim c -d:release --hints:off -o:"$BOT_BIN" players/baseline/baseline.nim
else
  echo "[freeplay] FREEPLAY_SKIP_BUILD=1: reusing existing binaries"
fi

PIDS=()
cleanup() {
  echo ""
  echo "[freeplay] shutting down..."
  if [ "${#PIDS[@]}" -gt 0 ]; then
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[freeplay] starting server on port $PORT with $CONFIG_PATH..."
COGAME_HOST=0.0.0.0 \
COGAME_PORT="$PORT" \
COGAME_CONFIG_URI="file://$REPO_ROOT/$CONFIG_PATH" \
  "$SERVER_BIN" >"$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!
PIDS+=("$SERVER_PID")

echo "[freeplay] waiting for the listener on :$PORT..."
READY=0
for i in $(seq 1 120); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[freeplay] server exited during startup; log tail:" >&2
    tail -30 "$LOG_DIR/server.log" >&2
    exit 1
  fi
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then READY=1; break; fi
  sleep 0.5
done
if [ "$READY" -ne 1 ]; then
  echo "[freeplay] listener never opened; log tail:" >&2
  tail -30 "$LOG_DIR/server.log" >&2
  exit 1
fi
echo "[freeplay] listening."

TOKENS=()
while IFS= read -r line; do TOKENS+=("$line"); done < <(python3 -c "
import json
for t in json.load(open('$CONFIG_PATH'))['tokens']: print(t)
")
NUM_SLOTS="${#TOKENS[@]}"

echo "[freeplay] seating $NUM_SLOTS policies..."
for ((i = 0; i < NUM_SLOTS; i++)); do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=${TOKENS[$i]}" \
    "$BOT_BIN" >"$LOG_DIR/bot_$i.log" 2>&1 &
  PIDS+=("$!")
done

echo ""
echo "=================================================================="
echo "  The freeplay field is up. Take over any seat:"
for ((i = 0; i < NUM_SLOTS; i++)); do
  echo "    seat $i  http://localhost:$PORT/client/takeover?slot=$i&token=${TOKENS[$i]}&name=Green%20Rookie"
done
echo "=================================================================="
echo "[freeplay] watch:  http://localhost:$PORT/client/global"
echo "[freeplay] state:  http://localhost:$PORT/takeover/status"
echo "[freeplay] logs:   $LOG_DIR/"

wait "$SERVER_PID"
