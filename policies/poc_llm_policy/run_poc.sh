#!/usr/bin/env bash
# End-to-end PoC run: a gate-on server with the wire consumers registered, and
# the policy harness driving one play seat against it.
#
#   ./run_poc.sh            # canned model response (offline, CI-safe)
#   ./run_poc.sh --live     # one real OpenRouter call per decision
#
# Knobs: POC_PORT (default 21815), POC_SLOT (default 0), POC_MODEL.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
port="${POC_PORT:-21815}"
slot="${POC_SLOT:-0}"
mode_flag="--canned"
if [ "${1:-}" = "--live" ]; then
  mode_flag=""
fi

run_dir="$(mktemp -d)"
config_path="$run_dir/config.json"
server_bin="$run_dir/poc-shell-server"
server_log="$run_dir/server.log"
harness_log="$run_dir/harness.log"
fetch_log="$run_dir/fetch_deps.log"

if command -v nc >/dev/null && nc -z 127.0.0.1 "$port" 2>/dev/null; then
  echo "port $port is already in use; set POC_PORT" >&2
  exit 1
fi

server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$repo_root"

# The gate-on config: the practice BR config with season2Shell on and every
# slot switched to the play-seat protocol. minPlayers/startWaitTicks are left
# alone so a single-seat PoC run stays in the pre-match phase -- the tick loop
# (and therefore the ingress drain) runs either way.
python3 - "$repo_root/config.practice.json" "$config_path" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    config = json.load(source)
config["season2Shell"] = True
config["viewIntervalTicks"] = 6
config["lobbyChatTicks"] = 0
config["playSeatBindTicks"] = 7200
for slot in config["slots"]:
    slot["control"] = "play"
with open(sys.argv[2], "w") as destination:
    json.dump(config, destination, separators=(",", ":"))
PY

echo "== fetching the wasm/wasi toolchain"
tools/runtime_spike/fetch_deps.sh >"$fetch_log"
WASMTIME_C_API="$(awk -F= '$1=="WASMTIME_C_API"{print substr($0, index($0, "=") + 1)}' "$fetch_log")"
WASI_SDK_PATH="$(awk -F= '$1=="WASI_SDK_PATH"{print substr($0, index($0, "=") + 1)}' "$fetch_log")"
if [ -z "$WASMTIME_C_API" ] || [ -z "$WASI_SDK_PATH" ]; then
  cat "$fetch_log" >&2
  echo "dependency discovery failed" >&2
  exit 1
fi
export WASMTIME_C_API WASI_SDK_PATH

echo "== building the playbook"
"$script_dir/build_playbook.sh" "$script_dir/playbook"

echo "== building the gate-on server"
nim c --threads:on -d:release -d:noSignalHandler --hints:off --path:src \
  -o:"$server_bin" policies/poc_llm_policy/poc_shell_server.nim

echo "== starting the server on port $port"
COGAME_HOST=127.0.0.1 \
COGAME_PORT="$port" \
COGAME_CONFIG_URI="file://$config_path" \
  "$server_bin" >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 120); do
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    tail -40 "$server_log" >&2
    echo "server exited during startup" >&2
    exit 1
  fi
  sleep 0.5
done

token="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['tokens'][int(sys.argv[2])])" "$config_path" "$slot")"

echo "== running the harness against slot $slot"
python="${POC_PYTHON:-$script_dir/.venv/bin/python}"
if [ ! -x "$python" ]; then
  python="python3"
fi
set +e
POC_HOST=127.0.0.1 POC_PORT="$port" POC_SLOT="$slot" POC_TOKEN="$token" \
POC_PLAYBOOK="$script_dir/playbook" \
  "$python" "$script_dir/poc_policy.py" $mode_flag 2>&1 | tee "$harness_log"
status=${PIPESTATUS[0]}
set -e

echo
echo "== server-side wire log"
grep -E "POC_WIRE" "$server_log" || echo "(no POC_WIRE lines)"
echo
echo "logs: $run_dir"
exit "$status"
