#!/bin/bash
# One-command human playtest loop: builds the RELEASE server + baseline bot,
# starts the server on the practice config (config.practice.json --
# minPlayers=2, maxGames=0/"serve forever"), fills every non-human slot with
# a bot process using the practice config's static tokens[], waits for the
# listener to open, and prints the exact player URL to open in a browser.
#
# The practice config's maxGames=0 means the server keeps running and
# auto-starts a new lobby after each match ends -- the already-connected
# browser tab and bot processes automatically rejoin (see resetToLobby /
# needsReregister in src/ctf/sim.nim + src/ctf/server.nim). No relaunch
# needed between matches; only Ctrl-C tears the whole session down.
#
# Usage: tools/dev_play.sh
# Env overrides:
#   DEV_PLAY_PORT         port to bind (default 2000)
#   DEV_PLAY_HUMAN_SLOT   slot left open for the human (default 0)
#   DEV_PLAY_CONFIG       config path (default config.practice.json)
#   DEV_PLAY_SKIP_BUILD   skip the nim c build steps if already built (1/0)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

PORT="${DEV_PLAY_PORT:-2000}"
HUMAN_SLOT="${DEV_PLAY_HUMAN_SLOT:-0}"
CONFIG_PATH="${DEV_PLAY_CONFIG:-config.practice.json}"
SKIP_BUILD="${DEV_PLAY_SKIP_BUILD:-0}"

SERVER_BIN="$REPO_ROOT/bin/ctf-server"
BOT_BIN="$REPO_ROOT/players/baseline/baseline.out"
LOG_DIR="$REPO_ROOT/.dev_play/logs"
mkdir -p "$REPO_ROOT/bin" "$LOG_DIR"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "[dev_play] config not found: $CONFIG_PATH" >&2
  exit 1
fi

if [ "$SKIP_BUILD" != "1" ]; then
  # -d:release is not optional: a debug server bakes its supersampled
  # spectator caches at ~3% CPU (3+ minutes) BEFORE opening its listener,
  # which looks exactly like a hung port. Release bakes in ~11s.
  echo "[dev_play] building release server -> $SERVER_BIN"
  nim c -d:release --hints:off --path:src -o:"$SERVER_BIN" src/ctf.nim

  echo "[dev_play] building release baseline bot -> $BOT_BIN"
  nim c -d:release --hints:off -o:"$BOT_BIN" players/baseline/baseline.nim
else
  echo "[dev_play] DEV_PLAY_SKIP_BUILD=1: reusing existing binaries"
fi

PIDS=()
cleanup() {
  echo ""
  echo "[dev_play] shutting down (server + $((${#PIDS[@]} > 0 ? ${#PIDS[@]} - 1 : 0)) bot(s))..."
  if [ "${#PIDS[@]}" -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[dev_play] starting server on port $PORT with $CONFIG_PATH..."
COGAME_HOST=0.0.0.0 \
COGAME_PORT="$PORT" \
COGAME_CONFIG_URI="file://$REPO_ROOT/$CONFIG_PATH" \
  "$SERVER_BIN" >"$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!
PIDS+=("$SERVER_PID")

echo "[dev_play] waiting for the server to open its listener on :$PORT..."
READY=0
for i in $(seq 1 120); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[dev_play] server process exited during startup; log tail:" >&2
    tail -30 "$LOG_DIR/server.log" >&2
    exit 1
  fi
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 0.5
done
if [ "$READY" -ne 1 ]; then
  echo "[dev_play] server never opened its listener within 60s; log tail:" >&2
  tail -30 "$LOG_DIR/server.log" >&2
  exit 1
fi
echo "[dev_play] server is listening."

TOKENS=()
while IFS= read -r line; do
  TOKENS+=("$line")
done < <(python3 -c "
import json
cfg = json.load(open('$CONFIG_PATH'))
for t in cfg['tokens']:
    print(t)
")
NUM_SLOTS="${#TOKENS[@]}"

if [ "$HUMAN_SLOT" -lt 0 ] || [ "$HUMAN_SLOT" -ge "$NUM_SLOTS" ]; then
  echo "[dev_play] DEV_PLAY_HUMAN_SLOT=$HUMAN_SLOT out of range (0..$((NUM_SLOTS - 1)))" >&2
  exit 1
fi

echo "[dev_play] filling $((NUM_SLOTS - 1)) non-human slot(s) with bots..."
for ((i = 0; i < NUM_SLOTS; i++)); do
  if [ "$i" -eq "$HUMAN_SLOT" ]; then
    continue
  fi
  token="${TOKENS[$i]}"
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=$token" \
    "$BOT_BIN" >"$LOG_DIR/bot_$i.log" 2>&1 &
  PIDS+=("$!")
done

HUMAN_TOKEN="${TOKENS[$HUMAN_SLOT]}"
PLAYER_URL="http://localhost:$PORT/client/player?slot=$HUMAN_SLOT&token=$HUMAN_TOKEN"

echo ""
echo "=================================================================="
echo "  Practice match is up -- open this URL to play slot $HUMAN_SLOT:"
echo "  $PLAYER_URL"
echo "=================================================================="
echo ""
echo "[dev_play] server log: $LOG_DIR/server.log"
echo "[dev_play] bot logs:   $LOG_DIR/bot_<slot>.log"
echo "[dev_play] maxGames=0: the next match auto-starts when this one ends --"
echo "[dev_play]   no relaunch needed. Ctrl-C here stops the server + bots."

wait "$SERVER_PID"
