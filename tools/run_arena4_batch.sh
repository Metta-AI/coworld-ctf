#!/usr/bin/env bash
# Re-runs the 4-team play batch WITH the hand-authored arena4 control in it.
#
# map_playtest.py can only state deltas between maps measured in the SAME
# invocation, so adding a control means re-playing the five generated boards
# too — the committed 4t-playtest.json is that script's OUTPUT, not its input.
# Same five seeds and same 3 episodes as tools/map_playtest_results/4team-control.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${OUT:-/tmp/ctf4ctl/batch}
export CTF_MAP_GALLERY=${CTF_MAP_GALLERY:-/tmp/ctf4ctl/gallery}
MAPS=(maps/arena4.json gen:1003 gen:1007 gen:1010 gen:1013 gen:1020)
EPISODES=${EPISODES:-3}

mkdir -p "$OUT" "$CTF_MAP_GALLERY"
nim c -d:release --hints:off --warnings:off \
  --nimcache:/tmp/nc-mapplaytest -o:/tmp/map_playtest tools/map_playtest.nim

for m in "${MAPS[@]}"; do
  echo "=== playing $m ==="
  /tmp/map_eval play "$m" --episodes "$EPISODES" --teams 4 --out "$OUT"
done

for r in "$OUT"/*.bitreplay; do
  base=$(basename "$r" .bitreplay)
  # map_eval slugs ':' -> '-', '/' -> '_', '.' -> '_' and appends -epN.
  name=$(printf '%s' "$base" | sed -E 's/-ep[0-9]+$//; s/^maps_arena4_json$/arena4/; s/^gen-/gen:/')
  /tmp/map_playtest "$r" --name "$name" --out "${r%.bitreplay}.json"
done

python3 tools/map_playtest.py "$OUT"/*.json
