#!/bin/bash
# TEMPORARY count-only diagnostic runner (CACHE_TRACE_PLAN.md). Runs one real
# Season 2 shell episode on the local Mac with the navSourceTrace server build
# and real baseline S2 clients, waits for the server's own finite exit
# (maxGames 1), and preserves the raw NAVSRC trace. Never timing evidence.
#
# Usage: tools/nav_source_trace_run.sh <config.json> <run-tag> [port]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG_SRC="$1"; TAG="$2"; PORT="${3:-21895}"
ROOT="$PWD"
BIN="$ROOT/tmp/navsrc/bin"
PLAYBOOK="$ROOT/tmp/navsrc/playbook"
RUN_DIR="$ROOT/tmp/navsrc/runs/$TAG"
WAIT_LIMIT_S="${NAVSRC_WAIT_LIMIT_S:-2400}"
mkdir -p "$RUN_DIR"
cp "$CONFIG_SRC" "$RUN_DIR/config.json"
SEATS=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['slots']))" "$RUN_DIR/config.json")
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM
if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then echo "port $PORT busy" >&2; exit 1; fi

COGAME_HOST=127.0.0.1 COGAME_PORT="$PORT" SHELL_ZONE_LOG=1 \
COGAME_CONFIG_URI="file://$RUN_DIR/config.json" \
  "$BIN/ctf-navsrc" >"$RUN_DIR/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 240); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 "$SERVER" 2>/dev/null || { tail -40 "$RUN_DIR/server.log" >&2; exit 1; }
  sleep 0.5
done
for seat in $(seq 0 $((SEATS - 1))); do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$seat&name=Player$((seat + 1))&token=0xBADA55_$seat" \
  BASELINE_PLAYBOOK="$PLAYBOOK" \
    "$BIN/baseline.out" >"$RUN_DIR/client-$seat.log" 2>&1 &
  PIDS+=("$!")
done
echo "run $TAG: server pid $SERVER, $SEATS baseline S2 clients, port $PORT, dir $RUN_DIR"
START=$(date +%s)
while kill -0 "$SERVER" 2>/dev/null; do
  if [ $(( $(date +%s) - START )) -ge "$WAIT_LIMIT_S" ]; then
    echo "wait limit ${WAIT_LIMIT_S}s reached; server still alive, killing (RECORD THIS)" | tee -a "$RUN_DIR/runner.log"
    kill "$SERVER" || true; break
  fi
  sleep 5
done
wait "$SERVER" 2>/dev/null && SERVER_EXIT=0 || SERVER_EXIT=$?
echo "server exit $SERVER_EXIT after $(( $(date +%s) - START ))s" | tee -a "$RUN_DIR/runner.log"
cleanup
grep '^NAVSRC ' "$RUN_DIR/server.log" > "$RUN_DIR/navsrc.txt" || true
{
  echo "tag=$TAG"; echo "head=$(git rev-parse HEAD)"; echo "nim=$(nim -v | head -1)"
  echo "server_flags=--threads:on -d:release -d:noSignalHandler -d:navSourceTrace"
  echo "seats=$SEATS"; echo "port=$PORT"; echo "server_exit=$SERVER_EXIT"
  echo "date=$(date -u +%FT%TZ)"; echo "navsrc_lines=$(wc -l < "$RUN_DIR/navsrc.txt")"
  echo "shell_line=$(grep -m1 '^SHELL enabled' "$RUN_DIR/server.log" || true)"
  echo "sys_line=$(grep -m1 '^NAVSRC sys' "$RUN_DIR/server.log" || true)"
} > "$RUN_DIR/manifest.txt"
cat "$RUN_DIR/manifest.txt"
