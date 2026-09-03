#!/bin/bash
# ring_walker A/B: one full 32-seat play-seat BR episode for ONE arm, ONE
# seed. baseline = monet v10 (commit 5c9cab0a, no ring_walker); candidate =
# monet v11 (commit e2df29c4, ring_walker + nearest_reachable zone-returns).
# Same engine binary both arms (built once from e2df29c4); same 9 reference
# plays both arms; the ONLY code difference is monet's own policy.py/plays
# (baseline's playbook has no ring_walker.wasm -- by design). Starter
# personas (aggressive/cautious/collaborative) run from the CANDIDATE
# worktree in BOTH arms -- they are unaffected by the ring_walker diff (see
# starter_harness.py's GATED_PLAYS/gate_open: the only change between v10
# and v11 is the "ring_walker" gate branch, dead code unless a ladder
# actually names the play), so this isolates the measured delta to monet.
#
# Usage: policies/monet/run_ab_ring.sh <baseline|candidate> <seed_index 0-9> [OUT_ROOT]
#
# Live-loop harness (layer_ladder): persona processes now stay connected
# and pumping the socket for the whole match (re-calling only on a trigger:
# hp drop, zone-phase change, partner death, being shot at, a new kill),
# exiting on death or when the server closes the socket at match end. This
# script's teardown (kill leftover seat PIDs after the server exits) is a
# safety net, not the primary exit path anymore.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CANDIDATE_ROOT"

ARM="${1:?usage: run_ab_ring.sh <baseline|candidate> <seed_index 0-9> [OUT_ROOT]}"
IDX="${2:?usage: run_ab_ring.sh <baseline|candidate> <seed_index 0-9> [OUT_ROOT]}"
OUT_ROOT="${3:-/tmp/monet-ab-ring}"

case "$ARM" in
  baseline)  MONET_ROOT="/tmp/ab-baseline"; PORT_BASE=21900 ;;
  candidate) MONET_ROOT="$CANDIDATE_ROOT";  PORT_BASE=21920 ;;
  *) echo "arm must be baseline or candidate" >&2; exit 1 ;;
esac

SEEDS=(31337 20260830 20260903 424242 90210 71823 559013 20260901 8675309 314159)
NUM_SEEDS=${#SEEDS[@]}
if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -ge "$NUM_SEEDS" ]; then
  echo "seed index must be 0..$((NUM_SEEDS - 1))" >&2
  exit 1
fi
SEED="${SEEDS[$IDX]}"

PERSONAS=(monet aggressive cautious collaborative)

FIRE_DIR="${MONET_FIRE_DIR:-/tmp/monet-fire}"
SERVER_BIN="$FIRE_DIR/ctf-server-ab"
VENV_PY="$FIRE_DIR/venv/bin/python3"
REF_PLAYBOOK="$OUT_ROOT/playbook-ref"
MONET_PLAYBOOK="$OUT_ROOT/playbook-$ARM-monet"

for f in "$SERVER_BIN" "$VENV_PY"; do
  [ -x "$f" ] || { echo "missing prebuilt artifact: $f" >&2; exit 1; }
done
[ -d "$REF_PLAYBOOK" ] || { echo "missing $REF_PLAYBOOK" >&2; exit 1; }
[ -d "$MONET_PLAYBOOK" ] || { echo "missing $MONET_PLAYBOOK" >&2; exit 1; }
[ -f "$MONET_ROOT/policies/monet/policy.py" ] || {
  echo "missing $MONET_ROOT/policies/monet/policy.py" >&2; exit 1; }

mkdir -p "$OUT_ROOT"
# Scoring tools are provisioned into OUT_ROOT (not per-arm) -- built once
# from the candidate worktree HEAD, valid for replays from either arm since
# both ran on the same engine binary. See policies/monet/run_series.sh's
# header note on the CWD-relative GameDir gotcha: these binaries must be
# invoked with cwd == CANDIDATE_ROOT, which this script guarantees (cd's
# there once, top of file, never leaves).
for tool in br_outcome_probe dump_glory_from_replay; do
  [ -x "$OUT_ROOT/$tool" ] || { echo "missing $OUT_ROOT/$tool (build it first)" >&2; exit 1; }
done

SEED_DIR="$OUT_ROOT/$ARM/seed$IDX"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"

PORT="${PORT:-$((PORT_BASE + IDX))}"

echo "arm=$ARM seed_index=$IDX seed=$SEED port=$PORT monet_root=$MONET_ROOT" | tee "$SEED_DIR/meta.txt"

# --- team -> persona rotation map (identical formula both arms/seeds) ---
python3 - "$IDX" "$SEED_DIR/persona_map.json" <<'PY'
import json, sys
idx = int(sys.argv[1])
personas = ["monet", "aggressive", "cautious", "collaborative"]
m = {str(t): personas[(t + idx) % 4] for t in range(16)}
json.dump(m, open(sys.argv[2], "w"), indent=1)
PY

# --- per-episode config: config.practice.json is BYTE-IDENTICAL between
# 5c9cab0a and e2df29c4 (verified), so the candidate worktree's copy is
# used for both arms. ---
CONFIG_PATH="$SEED_DIR/config.json"
python3 - "$CANDIDATE_ROOT/config.practice.json" "$CONFIG_PATH" "$SEED" \
         "$SEED_DIR/persona_map.json" "$ARM" <<'PY'
import json, sys
base_path, out_path, seed, persona_map_path, arm = sys.argv[1:6]
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
    tag = f"{persona}-{arm}" if persona == "monet" else persona
    names.append(f"{tag}-{i:02d}")
config["players"] = [{"name": n} for n in names]

with open(out_path, "w") as f:
    json.dump(config, f, separators=(",", ":"))
print(f"wrote {out_path}: seed={config['seed']} maxGames={config['maxGames']} arm={arm}")
PY

REPLAY_PATH="$SEED_DIR/episode.bitreplay"
SERVER_LOG="$SEED_DIR/server.log"

echo "starting server ($ARM) on port $PORT ..."
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

# --- launch all 32 policy processes: monet from MONET_ROOT (arm-specific),
# starters ALWAYS from the candidate worktree (unaffected by the diff). ---
SEAT_PIDS=()
for k in $(seq 0 31); do
  team=$((k % 16))
  pidx=$(( (team + IDX) % 4 ))
  persona="${PERSONAS[$pidx]}"
  if [ "$persona" = "monet" ]; then
    policy_path="$MONET_ROOT/policies/monet/policy.py"
    playbook_dir="$MONET_PLAYBOOK"
  else
    policy_path="$CANDIDATE_ROOT/policies/starters/$persona/policy.py"
    playbook_dir="$REF_PLAYBOOK"
  fi
  POC_HOST=127.0.0.1 POC_PORT="$PORT" POC_SLOT="$k" \
  POC_TOKEN="0xBADA55_$k" POC_PLAYBOOK="$playbook_dir" POC_CANNED=1 \
  "$VENV_PY" "$policy_path" --canned \
    > "$SEED_DIR/seat$(printf '%02d' "$k").log" 2>&1 &
  SEAT_PIDS+=($!)
done
echo "${SEAT_PIDS[@]}" > "$SEED_DIR/seat_pids.txt"
echo "launched 32 policy seats ($ARM monet from $MONET_ROOT)"

# --- wait for the server to self-exit (maxGames=1) -- hard cap 12 min. ---
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

# --- validity gate (i): seats that reached call_accepted at least once ---
ACCEPTED=$(grep -l "call_accepted" "$SEED_DIR"/seat*.log 2>/dev/null | wc -l | tr -d ' ')
echo "seats_with_call_accepted=$ACCEPTED / 32" | tee -a "$SEED_DIR/meta.txt"

# --- validity gate (ii): movement census straight from the server log ---
MOVE_TOTAL=$(grep -c "FIRST_LIGHT_MOVEMENT" "$SERVER_LOG" 2>/dev/null || echo 0)
MOVE_NONZERO=$(grep "FIRST_LIGHT_MOVEMENT" "$SERVER_LOG" 2>/dev/null | grep -c "moving=[1-9]" || echo 0)
echo "movement_census: ${MOVE_NONZERO}/${MOVE_TOTAL} FIRST_LIGHT_MOVEMENT lines show moving>=1" \
  | tee -a "$SEED_DIR/meta.txt"

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

echo "$ARM seed $IDX (seed=$SEED) done"
