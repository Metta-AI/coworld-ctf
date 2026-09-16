#!/bin/bash
# Shell demo wiring proof. The release probe prints the annotation and split
# timing gates first. Unless SHELL_DEMO_MEASURE_ONLY=1, the script then runs
# the real BR server with 32 presence-only play seats and tails its install
# telemetry beside the spectator URL. Ctrl-C stops every child.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$PWD"
PORT="${SHELL_DEMO_PORT:-21814}"
MEASURE_ONLY="${SHELL_DEMO_MEASURE_ONLY:-0}"
RUN_DIR="${TMPDIR:-/tmp}/coworld-ctf-shell-demo-$$"
CONFIG_PATH="$RUN_DIR/config.json"
SERVER_BIN="$RUN_DIR/ctf-shell-demo"
PRESENCE_BIN="$RUN_DIR/shell-presence"
PROBE_BIN="$RUN_DIR/shell-probe"
SERVER_LOG="$RUN_DIR/server.log"
FETCH_LOG="$RUN_DIR/fetch_deps.log"
mkdir -p "$RUN_DIR"

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "port $PORT in use — another shell demo server is running; kill it or set SHELL_DEMO_PORT" >&2
  exit 1
fi

PIDS=()
cleanup() {
  if [ "${#PIDS[@]}" -gt 0 ]; then
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

python3 - "$REPO_ROOT/config.practice.json" \
  "$REPO_ROOT/tests/fixtures/shell/shell_demo_config.json" \
  "$CONFIG_PATH" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    config = json.load(source)
with open(sys.argv[2]) as source:
    patch = json.load(source)
for key, value in patch.items():
    if value is None:
        config.pop(key, None)
    else:
        config[key] = value
with open(sys.argv[3], "w") as destination:
    json.dump(config, destination, separators=(",", ":"))
PY

tools/runtime_spike/fetch_deps.sh >"$FETCH_LOG"
WASMTIME_C_API="$(awk -F= '$1=="WASMTIME_C_API"{print substr($0, index($0, "=") + 1)}' "$FETCH_LOG")"
WASI_SDK_PATH="$(awk -F= '$1=="WASI_SDK_PATH"{print substr($0, index($0, "=") + 1)}' "$FETCH_LOG")"
if [ -z "$WASMTIME_C_API" ] || [ -z "$WASI_SDK_PATH" ]; then
  cat "$FETCH_LOG" >&2
  echo "shell demo dependency discovery failed" >&2
  exit 1
fi

WASI_SDK_PATH="$WASI_SDK_PATH" nim c -f --hints:off \
  play_sdk/examples/hello_play.nim
WASI_SDK_PATH="$WASI_SDK_PATH" nim c -f --hints:off \
  play_sdk/reference/edge_ride.nim

WASMTIME_C_API="$WASMTIME_C_API" nim c --threads:on -d:release \
  -d:noSignalHandler \
  --hints:off --path:src -o:"$PROBE_BIN" tools/shell_probe.nim
SHELL_DEMO_CONFIG_PATH="$CONFIG_PATH" "$PROBE_BIN"
if [ "$MEASURE_ONLY" = "1" ]; then
  exit 0
fi

WASMTIME_C_API="$WASMTIME_C_API" nim c --threads:on -d:release \
  -d:noSignalHandler \
  ${SHELL_EXTRA_NIM_FLAGS:-} \
  --hints:off --path:src -o:"$SERVER_BIN" src/ctf.nim
nim c -d:release --hints:off --path:src -o:"$PRESENCE_BIN" \
  tools/shell_presence.nim

COGAME_HOST=0.0.0.0 \
COGAME_PORT="$PORT" \
SHELL_ZONE_LOG=1 \
COGAME_CONFIG_URI="file://$CONFIG_PATH" \
  "$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
PIDS+=("$!")

for _ in $(seq 1 240); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  if ! kill -0 "${PIDS[0]}" 2>/dev/null; then
    tail -80 "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.5
done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  tail -80 "$SERVER_LOG" >&2
  exit 1
fi

for seat in $(seq 0 31); do
  token=$(python3 - "$CONFIG_PATH" "$seat" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    print(json.load(source)["tokens"][int(sys.argv[2])])
PY
)
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$seat&token=$token" \
    "$PRESENCE_BIN" >"$RUN_DIR/presence-$seat.log" 2>&1 &
  PIDS+=("$!")
done

echo "SHELL demo server is live; these are presence clients, not policies."
echo "Viewer: http://localhost:$PORT/client/global"
echo "Install telemetry follows (tick, seat, rule, provenance, bytes hash):"
tail -n +1 -f "$SERVER_LOG"
