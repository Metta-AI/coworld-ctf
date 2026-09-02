#!/bin/bash
# MONET vs starters multi-seed A/B series: one full 32-seat play-seat BR
# episode per seed, canned mode (no model credentials), scored via
# tools/br_outcome_probe.nim against the recorded replay.
#
# 32 seats = 16 duos; duo/team k = seats k and k+16 (config.practice.json's
# own slot->team layout, unmodified). Per seed index s (0-4), team t runs
# PERSONAS[(t + s) % 4] -- both seats of the duo run the same persona, and
# the rotation shifts each seed so no persona owns a "lucky" team number.
#
# Usage: policies/monet/run_series.sh <seed_index 0-4> [OUT_ROOT]
#
# Idempotent: re-running an index wipes and rebuilds only that seed's
# directory under OUT_ROOT/seed<idx>/ -- other seeds are untouched.
#
# Reuses prebuilt artifacts from a prior live-fire run by default (server
# binary, playbook .wasm, python venv with websockets>=13) -- see
# MONET_FIRE_DIR below. Point it elsewhere (or build fresh into a new dir
# and pass that) if those artifacts are gone.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

IDX="${1:?usage: run_series.sh <seed_index 0-4> [OUT_ROOT]}"
OUT_ROOT="${2:-/tmp/monet-series}"

SEEDS=(31337 20260830 20260903 424242 90210)
NUM_SEEDS=${#SEEDS[@]}
if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -ge "$NUM_SEEDS" ]; then
  echo "seed index must be 0..$((NUM_SEEDS - 1))" >&2
  exit 1
fi
SEED="${SEEDS[$IDX]}"

PERSONAS=(monet aggressive cautious collaborative)

FIRE_DIR="${MONET_FIRE_DIR:-/tmp/monet-fire}"
SERVER_BIN="$FIRE_DIR/ctf-server"
PLAYBOOK_DIR="$FIRE_DIR/playbook"
VENV_PY="$FIRE_DIR/venv/bin/python3"

for f in "$SERVER_BIN" "$VENV_PY"; do
  if [ ! -x "$f" ]; then
    echo "missing prebuilt artifact: $f (set MONET_FIRE_DIR or rebuild)" >&2
    exit 1
  fi
done
[ -d "$PLAYBOOK_DIR" ] || { echo "missing playbook dir: $PLAYBOOK_DIR" >&2; exit 1; }

SEED_DIR="$OUT_ROOT/seed$IDX"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"

PORT="${PORT:-$((21850 + IDX))}"

echo "seed_index=$IDX seed=$SEED port=$PORT fire_dir=$FIRE_DIR" | tee "$SEED_DIR/meta.txt"

# --- team -> persona rotation map (also consumed by aggregate_series.py) ---
python3 - "$IDX" "$SEED_DIR/persona_map.json" <<'PY'
import json, sys
idx = int(sys.argv[1])
personas = ["monet", "aggressive", "cautious", "collaborative"]
m = {str(t): personas[(t + idx) % 4] for t in range(16)}
json.dump(m, open(sys.argv[2], "w"), indent=1)
PY

# --- per-episode config: config.practice.json + season2Shell play-seat
# transforms (same shape the prior live-fire run used) + this seed +
# maxGames=1 (clean self-exit + replay write on GameOver, no log-watching
# needed) + player names carrying the persona identity for readable logs.
CONFIG_PATH="$SEED_DIR/config.json"
python3 - "$REPO_ROOT/config.practice.json" "$CONFIG_PATH" "$SEED" \
         "$SEED_DIR/persona_map.json" <<'PY'
import json, sys
base_path, out_path, seed, persona_map_path = sys.argv[1:5]
config = json.load(open(base_path))
config["season2Shell"] = True
config["viewIntervalTicks"] = 6
config["lobbyChatTicks"] = 4320
config["playSeatBindTicks"] = 14400
config["seed"] = int(seed)
config["maxGames"] = 1
for slot in config["slots"]:
    slot["control"] = "play"

persona_map = json.load(open(persona_map_path))
TEAM_NAMES = ["red", "blue", "green", "yellow", "black", "silver", "ivory",
              "pink", "umber", "rust", "orange", "plum", "lime", "navy",
              "azure", "peach"]
name_to_idx = {n: i for i, n in enumerate(TEAM_NAMES)}
names = []
for i, slot in enumerate(config["slots"]):
    team_idx = name_to_idx[slot["team"]]
    persona = persona_map[str(team_idx)]
    names.append(f"{persona}-{i:02d}")
config["players"] = [{"name": n} for n in names]

with open(out_path, "w") as f:
    json.dump(config, f, separators=(",", ":"))
print(f"wrote {out_path}: seed={config['seed']} maxGames={config['maxGames']} "
      f"minPlayers={config.get('minPlayers')}")
PY

REPLAY_PATH="$SEED_DIR/episode.bitreplay"
SERVER_LOG="$SEED_DIR/server.log"

echo "starting server on port $PORT ..."
COGAME_HOST=127.0.0.1 COGAME_PORT="$PORT" \
COGAME_CONFIG_URI="file://$CONFIG_PATH" \
COGAME_SAVE_REPLAY_URI="file://$REPLAY_PATH" \
"$SERVER_BIN" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$SEED_DIR/server.pid"

READY=0
for i in $(seq 1 60); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "server died during startup" | tee -a "$SEED_DIR/meta.txt"
    tail -40 "$SERVER_LOG"
    exit 1
  fi
  sleep 0.5
done
if [ "$READY" -ne 1 ]; then
  echo "server never listened on $PORT" | tee -a "$SEED_DIR/meta.txt"
  kill "$SERVER_PID" 2>/dev/null || true
  exit 1
fi
echo "server ready on port $PORT (pid $SERVER_PID)"

# --- launch all 32 policy processes: real python persona clients, no
# presence-bot fillers (every slot is a real policy so minPlayers=32 is
# satisfied by the roster itself). ---
SEAT_PIDS=()
for k in $(seq 0 31); do
  team=$((k % 16))
  pidx=$(( (team + IDX) % 4 ))
  persona="${PERSONAS[$pidx]}"
  if [ "$persona" = "monet" ]; then
    policy_path="$REPO_ROOT/policies/monet/policy.py"
  else
    policy_path="$REPO_ROOT/policies/starters/$persona/policy.py"
  fi
  POC_HOST=127.0.0.1 POC_PORT="$PORT" POC_SLOT="$k" \
  POC_TOKEN="0xBADA55_$k" POC_PLAYBOOK="$PLAYBOOK_DIR" POC_CANNED=1 \
  "$VENV_PY" "$policy_path" --canned \
    > "$SEED_DIR/seat$(printf '%02d' "$k").log" 2>&1 &
  SEAT_PIDS+=($!)
done
echo "${SEAT_PIDS[@]}" > "$SEED_DIR/seat_pids.txt"
echo "launched 32 policy seats"

# --- wait for the server to self-exit (maxGames=1 -> quitAfterFrame on
# GameOver, writes the replay, then quits) -- hard cap 12 min. ---
CAP=720
START=$SECONDS
while kill -0 "$SERVER_PID" 2>/dev/null; do
  if [ $((SECONDS - START)) -ge $CAP ]; then
    echo "TIMEOUT after ${CAP}s -- killing server" | tee -a "$SEED_DIR/meta.txt"
    kill "$SERVER_PID" 2>/dev/null || true
    break
  fi
  sleep 5
done
wait "$SERVER_PID" 2>/dev/null
echo "server exited (elapsed $((SECONDS - START))s)" | tee -a "$SEED_DIR/meta.txt"

for pid in "${SEAT_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
wait 2>/dev/null

# --- validity: seats that reached call_accepted at least once ---
ACCEPTED=$(grep -l "call_accepted" "$SEED_DIR"/seat*.log 2>/dev/null | wc -l | tr -d ' ')
echo "seats_with_call_accepted=$ACCEPTED / 32" | tee -a "$SEED_DIR/meta.txt"

# --- outcome extraction from the recorded replay ---
if [ -s "$REPLAY_PATH" ]; then
  "$OUT_ROOT/br_outcome_probe" "$REPLAY_PATH" > "$SEED_DIR/outcome.json" \
    2> "$SEED_DIR/probe.log"
  if [ -s "$SEED_DIR/outcome.json" ]; then
    echo "outcome written to $SEED_DIR/outcome.json" | tee -a "$SEED_DIR/meta.txt"
  else
    echo "PROBE PRODUCED NO OUTPUT -- see probe.log" | tee -a "$SEED_DIR/meta.txt"
  fi
else
  echo "NO REPLAY WRITTEN at $REPLAY_PATH" | tee -a "$SEED_DIR/meta.txt"
fi

echo "seed $IDX (seed=$SEED) done"
