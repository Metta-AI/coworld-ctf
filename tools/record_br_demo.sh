#!/bin/bash
# Records one battle-royale (brMode) episode on a generated corner or plus
# map: 32 seats dealt round the four teams (8 per team, slot mod 4), each
# seat a baseline bot. No respawns, no capture win — the game only ends when
# at most one team has a living player (or the maxTicks tiebreak fires).
# Demo fixture for the elimination ruleset (docs/designs/BR_MAPGEN.md).
# Usage: tools/record_br_demo.sh <corners|plus> <out.bitreplay RELATIVE to repo root> <seed> [maxTicks]
set -euo pipefail
cd "$(dirname "$0")/.."
LAYOUT="$1"; OUT="$2"; SEED="$3"; MAXTICKS="${4:-9000}"; PORT="${PORT:-21403}"
CFG=$(mktemp /tmp/ctf-br-demo-cfg-$$-XXXXXX)
python3 - "$CFG" "$LAYOUT" "$SEED" "$MAXTICKS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[3])
cfg["maxTicks"] = int(sys.argv[4])
cfg["speed"] = 16
cfg["maxGames"] = 1
cfg["teams"] = 4
cfg["mapPath"] = "gen"
cfg["mapLayout"] = sys.argv[2]
cfg["mapSeed"] = int(sys.argv[3])
cfg["brMode"] = True
# Drop the classic config's explicit red/blue slot assignments so 32 seats
# deal round all four teams (slot mod 4) on the open (non-closed) roster —
# same idiom as record_four_team_demo.sh, scaled from 4-per-team to
# 8-per-team (32 = MaxPlayers). `tokens[i]` pins `players[i].name` to slot i
# (readConfigTokens sets slots[i].token, readConfigPlayers then sets
# slots[i].name on the SAME slot — order matters, see sim_config.nim
# update()): a bot connecting with slot=i&token=tokens[i] resolves its
# identity to players[i].name via configuredPlayerName, which is what lets
# slotAuthMatches accept it. Dropping tokens (as this script's first draft
# did) leaves slots named but tokenless, so a token-only connection resolves
# to an ANONYMOUS identity that then fails slotAuthMatches's name check —
# every bot got rejected 403 "credentials do not match configured roster."
cfg.pop("slots", None)
pols = ["redshift:v1", "bluesteel:v1", "greenhorn:v1", "goldrush:v1"]
counts = [0, 0, 0, 0]
players = []
tokens = []
for slot in range(32):
    team = slot % 4
    counts[team] += 1
    players.append({"name": f"{pols[team]}_({counts[team]})"})
    tokens.append(f"0xBADA55_{slot}")
cfg["players"] = players
cfg["tokens"] = tokens
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/ctf-br-demo-server.log}"
BOTLOG="${BOTLOG:-/tmp/ctf-br-demo-bots.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to actually listen before spawning bots — a slow start
# would otherwise strand 32 bots and hang the lobby forever, silently.
for i in $(seq 1 40); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -20 "$LOG" >&2; exit 1; }

BOT_PIDS=()
for i in $(seq 0 31); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

# A bounded wait: the episode runs at 16x, so even a full-length game is
# done in a couple of minutes — a longer wait means a hang, and hangs must
# be loud, not silent.
DEADLINE=$((SECONDS + 600))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 10 minutes — killing; log tails:" >&2
    tail -20 "$LOG" >&2
    tail -10 "$BOTLOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
if ! wait $SERVER_PID; then
  echo "server exited non-zero; log tail:" >&2
  tail -20 "$LOG" >&2
fi
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
# A written replay under ~10KB is a truncated episode, not a demo.
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
# BR-specific sanity: the log must show a wipe/tiebreak ending, never a
# capture ending — grep the game log embedded in the server log for the
# tell-tale lines.
if grep -q " captured the .* heart" "$LOG"; then
  echo "WARNING: log shows a capture event — brMode should make this a no-op" >&2
fi
ls -la "$OUT"
