#!/bin/bash
# Records THE BR MATCH: 16 duos, 32 seats, elimination, a closing zone, on a
# brmapkit draw. This is the mode contract of docs/designs/BR_MAPGEN.md §1
# played end to end for the first time.
#
# Usage: tools/record_br_match.sh <out.bitreplay RELATIVE to repo root> \
#                                 <ctf-map-spec.json> <seed> [maxTicks]
#
# The map spec argument is a CTF spec, i.e. the output of
# tools/br_spec_to_ctf.nim run over a brmapkit draw — not the draw itself.
#
# Modeled on tools/record_zone_demo.sh, which this supersedes for BR: that
# one is a 2-team CTF game with the zone bolted on, this is the real thing.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; MAPSPEC="$2"; SEED="$3"; MAXTICKS="${4:-6000}"
# NOT 21400-21403: those are owned by other agents in this fleet.
PORT="${PORT:-21454}"
SEATS="${SEATS:-32}"
CFG=$(mktemp /tmp/ctf-br-match-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$MAPSPEC" "$SEATS" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["fastMode"] = True
cfg["maxGames"] = 1

# --- the mode contract (BR_MAPGEN.md §1) ---------------------------------
# 16 duos. `teams` must equal the map's own spawnGroups or
# resolveCtfMapMetadata rejects the pair outright (that is the bridge doing
# its job, and it is the check that used to make this impossible).
cfg["teams"] = 16
cfg["mapSpec"] = json.load(open(sys.argv[4]))
cfg["brMode"] = True

# The stock config.json seats a 2-team CTF game: 16 slots hard-pinned to
# red/blue, 16 tokens, 16 player names. Every one of those has to be
# rebuilt or the roster quietly stays 8v8 red-vs-blue no matter what
# `teams` says — the first take of this match did exactly that, and the
# only tell was `blue caught outside the zone` scrolling past with no
# other colour in it.
#
# Teams are pinned EXPLICITLY, two seats each, rather than left to
# teamForSlot's round-robin. The round-robin would produce the same
# seating (it reads the same teamCount), but pinning states the duo
# structure in the artifact, so the replay's own config says "16 duos"
# instead of leaving it to be re-derived.
TEAM_NAMES = [
    "red", "blue", "green", "yellow", "black", "silver", "ivory", "pink",
    "umber", "rust", "orange", "plum", "lime", "navy", "azure", "peach",
]
seats = int(sys.argv[5])
cfg["slots"] = [{"team": TEAM_NAMES[i % 16]} for i in range(seats)]
cfg["tokens"] = ["0xBADA55_%d" % i for i in range(seats)]
cfg["players"] = [{"name": "duo%02d-%d" % (i % 16, i // 16)}
                  for i in range(seats)]
cfg["minPlayers"] = seats

# No respawns is brMode's own rule (killPlayer forces lives to 0 on the
# first death), but `lives` is left explicit at 1 so the HUD, the config
# echo and the replay all say the same thing rather than relying on a
# runtime override to contradict a 3 sitting in the file.
cfg["lives"] = 1

# gunRange is DELIBERATELY ABSENT. §4.1 derives it from the field and the
# group count (331 px on this giant board) and the generator already baked
# it into the map spec; sim_config only overrides the map's value when the
# config names the key, so omitting it is how the map wins. Naming it here
# would silently retune aim sigma too, since sigma derives from the live
# gunRange.

# Barrage off: it is an unrelated pressure source and the zone is the
# protagonist clock. Keeping it on would also confound the elimination
# read (a barrage death is not a BR death).
cfg["barrageMaxPerSec"] = 0

# --- the zone (BR_MAPGEN.md §4.3) ----------------------------------------
# The doc's five-phase table, verbatim in z: 0.75, 0.55, 0.40, 0.28, 0.17,
# which is the column that keeps R/G (a group's territory radius in gun
# ranges) falling monotonically as eliminations push the group count down.
# Waits and damage follow the stated BR-practice rule the doc cites: long
# waits and low damage early, short waits and high damage late.
#
# The FIRST phase carries dps 0, and that is load-bearing rather than
# gentle. A phase's dps applies during its WAIT as well as its shrink, and
# the wait is spent at the PREVIOUS rect — for phase 1 that is the implicit
# z=1.0 "drop" rect. But zoneRectAtScale centers a full-SIZE rect on the
# DRAWN center, so when the center is drawn off-map-center (the shipping
# behaviour, §4.3), the z=1.0 rect hangs off one edge and leaves an equal
# band of the field OUTSIDE the zone from tick 0. With dps 1 there, the
# drop phase is lethal: the first take of this match killed 6 of 16 duos at
# tick 256 without a shot being fired, purely because their grid spawns sat
# in that band. Spawns span the WHOLE field by ruling (§4.2, no keep-away,
# not inset), so this is not a bad draw, it is structural.
# Late phases are LETHAL, and that pricing is deliberate. A weak ring does
# not force an endgame: it lets episodes run to the clock and be decided by
# survival farming rather than by fighting, which is the same passive-play
# failure the draw-free tiebreak closes from the other end. A cog has 3 hp,
# so the last two phases kill in roughly a second and a half outside — long
# enough to run back in, far too short to camp.
cfg["zonePhases"] = [
    {"z": 0.75, "waitTicks": 600, "shrinkTicks": 420, "dps": 0},
    {"z": 0.55, "waitTicks": 480, "shrinkTicks": 360, "dps": 2},
    {"z": 0.40, "waitTicks": 360, "shrinkTicks": 300, "dps": 4},
    {"z": 0.28, "waitTicks": 240, "shrinkTicks": 240, "dps": 8},
    {"z": 0.17, "waitTicks": 180, "shrinkTicks": 180, "dps": 12},
]
# zoneCenter is ABSENT ON PURPOSE. §4.3's central guarantee is that the
# center is DRAWN, not fixed at map center: a fixed center makes a strong
# middle decide every episode and hands central spawns a permanent edge.
# Drawing it is the shipping behaviour, so the first real match runs it.

json.dump(cfg, open(sys.argv[1], "w"))
PY

LOG="${LOG:-/tmp/ctf-br-match-server.log}"
BOTLOG="${BOTLOG:-/tmp/ctf-br-match-bots.log}"
: > "$BOTLOG"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/ctf-server > "$LOG" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 60); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -30 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -30 "$LOG" >&2; exit 1; }

BOT_PIDS=()
for i in $(seq 0 $((SEATS - 1))); do
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./players/baseline/baseline.out >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

DEADLINE=$((SECONDS + 900))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 15 minutes — killing; log tails:" >&2
    tail -30 "$LOG" >&2
    tail -10 "$BOTLOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
if ! wait $SERVER_PID; then
  echo "server exited non-zero; log tail:" >&2
  tail -30 "$LOG" >&2
fi
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -30 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
