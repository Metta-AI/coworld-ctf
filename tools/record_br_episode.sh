#!/bin/bash
# THE EPISODE: record_br_showmatch.sh, ARMED for the one-page policy system
# — allowPolicyReflash on, and the zone schedule swapped for
# record_br_match.sh's 7-phase table (closes fully to z=0.001 by maxTicks
# instead of showmatch's 5-phase table, which can leave interior and time
# out). This is the script the LLM-strategy episode actually uses; the
# roster is expected to be onepage wrapper scripts, one per seat, each
# pointing COWORLD_POLICY_PAGE_FILE at a real playbook page.
#
# Records a BR match with a MIXED ROSTER: each of the 32 seats can run a
# DIFFERENT real bot binary, named honestly by what it actually is. This is
# record_br_match.sh's sibling for the "real everything" showmatch — that
# script always launches ./players/baseline/baseline.out for all 32 seats;
# this one launches whatever tools/build_showmatch_roster.py (or any script)
# wrote into a roster JSON, so a champion build, the open-source baseline,
# and any other real, independently-built binary can share one board.
#
# Usage: tools/record_br_showmatch.sh <out.bitreplay RELATIVE to repo root> \
#                                     <ctf-map-spec.json> <seed> <roster.json> \
#                                     [maxTicks]
#
# roster.json is a JSON array of exactly SEATS objects, index == slot:
#   [{"slot": 0, "bin": "/abs/path/to/some-policy.out",
#     "name": "some-policy-00-0"}, ...]
# `bin` must be an executable that speaks this branch's wire protocol
# (same GameVersion) — build it from wherever it really comes from and
# point the roster at the resulting binary; this script never builds
# anything itself, only launches what the roster names.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; MAPSPEC="$2"; SEED="$3"; ROSTER="$4"; MAXTICKS="${5:-6000}"
# NOT 21400-21403/21454/21464/21471: those are owned by other agents/
# scripts in this fleet's shared machine.
PORT="${PORT:-21777}"
SEATS="${SEATS:-32}"
CFG=$(mktemp /tmp/ctf-br-showmatch-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$MAPSPEC" "$SEATS" "$ROSTER" <<'PY'
import json, os, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["speed"] = 16
cfg["fastMode"] = True
cfg["maxGames"] = 1

# --- the mode contract (BR_MAPGEN.md §1) ---------------------------------
cfg["teams"] = 16
cfg["mapSpec"] = json.load(open(sys.argv[4]))
cfg["brMode"] = True

TEAM_NAMES = [
    "red", "blue", "green", "yellow", "black", "silver", "ivory", "pink",
    "umber", "rust", "orange", "plum", "lime", "navy", "azure", "peach",
]
seats = int(sys.argv[5])
roster = json.load(open(sys.argv[6]))
if len(roster) != seats:
    sys.exit(f"roster has {len(roster)} entries, expected {seats}")
roster.sort(key=lambda r: r["slot"])
if [r["slot"] for r in roster] != list(range(seats)):
    sys.exit("roster slots must be exactly 0..seats-1, one each")

cfg["slots"] = [{"team": TEAM_NAMES[i % 16]} for i in range(seats)]
cfg["tokens"] = ["0xBADA55_%d" % i for i in range(seats)]
# The one real difference from record_br_match.sh: the player NAME carries
# the real policy identity (roster["name"]), not a generic "duoNN-k" label,
# so the recorded config — and therefore the HUD/replay — states honestly
# what every seat is running.
cfg["players"] = [{"name": roster[i]["name"]} for i in range(seats)]
cfg["minPlayers"] = seats

cfg["lives"] = 1
cfg["barrageMaxPerSec"] = 0

# THE GATE. Off by default everywhere else in the shipped config; this is
# the one place it is armed so a mid-episode reflash (if the runner ever
# proposes one) is not silently refused by applyPolicyPage.
cfg["allowPolicyReflash"] = True

# record_br_match.sh's 7-phase table, not showmatch's 5-phase one: this
# closes fully to z=0.001 by MAXTICKS, which structurally rules out a
# maxTicks timeout (no interior left at the cap, whatever the bots do).
# Proportional to the same MAXTICKS this script actually runs with (default
# 6000, same as record_br_match.sh's derivation): the first wait defaults
# to maxTicks/3 (see BR_FIRST_WAIT below), shrinks sum to maxTicks/2, so
# the schedule closes fully by ~5/6 of maxTicks.
T = int(sys.argv[3])
# First-wall timing: measured on episode-final (seed 31337), combat is over
# by ~tick 1000 after the Playing edge while the first shrink waited until
# T/2 (3000) — two thousand ticks of dead air. Default is now T/3 (2000 at
# T=6000): late enough for competent policies that actually fight longer,
# early enough that the zone takes over roughly when the fighting fades.
# Override per-recording with BR_FIRST_WAIT=<ticks> to tune pacing without
# editing this table.
FIRST_WAIT = int(os.environ.get("BR_FIRST_WAIT", T // 3))
cfg["zonePhases"] = [
    {"z": 0.824, "waitTicks": FIRST_WAIT, "shrinkTicks": T * 528 // 6000, "dps": 0},
    {"z": 0.648, "waitTicks": 0, "shrinkTicks": T * 528 // 6000, "dps": 2},
    {"z": 0.472, "waitTicks": 0, "shrinkTicks": T * 528 // 6000, "dps": 4},
    {"z": 0.296, "waitTicks": 0, "shrinkTicks": T * 528 // 6000, "dps": 8},
    {"z": 0.120, "waitTicks": 0, "shrinkTicks": T * 528 // 6000, "dps": 12},
    {"z": 0.060, "waitTicks": 0, "shrinkTicks": T * 180 // 6000, "dps": 16},
    {"z": 0.001, "waitTicks": 0, "shrinkTicks": T * 180 // 6000, "dps": 20},
]
# zoneCenter absent on purpose — see record_br_match.sh's note; the drawn
# (not fixed) center is the shipping behaviour.

json.dump(cfg, open(sys.argv[1], "w"))
PY

LOG="${LOG:-/tmp/ctf-br-showmatch-server.log}"
BOTLOG="${BOTLOG:-/tmp/ctf-br-showmatch-bots.log}"
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
  BOTBIN=$(python3 -c "import json,sys; r=json.load(open('$ROSTER')); r.sort(key=lambda x:x['slot']); print(r[$i]['bin'])")
  CTF_BOT_FAST_READY=1 \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    "$BOTBIN" >> "$BOTLOG" 2>&1 &
  BOT_PIDS+=($!)
done

DEADLINE=$((SECONDS + 3600))
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
