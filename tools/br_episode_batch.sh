#!/bin/bash
# br_episode_batch — records N real BR episodes SEQUENTIALLY on one scratch
# port and decodes each into a br_outcome_probe row. The played-outcome feed
# for tools/mapgen_play_gate.py's BR gates.
#
# Usage: tools/br_episode_batch.sh <mapspec.json> <outdir> <seed1> [seed2 ...]
#   PORT (default 21471)  scratch websocket port — NEVER a fleet-owned one.
#
# Episodes run one at a time on purpose: each is a full server + 32 bot
# processes, and parallel runs on a loaded machine corrupt episode timing
# (fleet-load lesson). Distinct seeds per episode of one map is the
# paired-seed discipline: play every CANDIDATE map on this same seed list.
#
# BUDGET: see br_outcome_probe.nim's header — N >= 47 to resolve even a
# never-winning spawn group; small N demonstrates the instrument only.
set -euo pipefail
cd "$(dirname "$0")/.."
MAPSPEC="$1"; OUTDIR="$2"; shift 2
PORT="${PORT:-21471}"
mkdir -p "$OUTDIR"

# Build once (record_br_match.sh assumes both exist).
[ -x bin/ctf-server ] || nim c -d:release --hints:off -o:bin/ctf-server src/ctf.nim
[ -x players/baseline/baseline.out ] || \
  (cd players/baseline && nim c -d:release --hints:off -o:baseline.out baseline.nim)
[ -x /tmp/dp_outcome ] || nim c -d:release --hints:off -o:/tmp/dp_outcome tools/br_outcome_probe.nim

ROWS="$OUTDIR/rows.jsonl"
for SEED in "$@"; do
  OUT="$OUTDIR/ep-$SEED.bitreplay"
  # record_br_match.sh joins its OUT arg onto $PWD (repo root); hand it a
  # RELATIVE path or the replay silently lands in the OS temp dir instead.
  OUT_REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1]))" "$OUT")
  if [ ! -s "$OUT" ]; then
    echo "=== episode seed=$SEED port=$PORT"
    PORT=$PORT LOG="$OUTDIR/server-$SEED.log" BOTLOG="$OUTDIR/bots-$SEED.log" \
      tools/record_br_match.sh "$OUT_REL" "$MAPSPEC" "$SEED"
  fi
  /tmp/dp_outcome "$OUT" --out "$ROWS"
done
echo "rows -> $ROWS"
