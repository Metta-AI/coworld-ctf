#!/usr/bin/env bash
set -euo pipefail
out=/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research/docs/designs/nav-rework-evidence-2026-09-09/research/A7
cd /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-early-visited
cp src/shell/body_route_index.nim "$out/before-edge-coverage.nim"
trap 'cp "$out/before-edge-coverage.nim" src/shell/body_route_index.nim' EXIT
for arm in eager eager-early lazy lazy-early; do
 cp "$out/snapshots/$arm.nim" src/shell/body_route_index.nim
 nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --nimcache:"$out/local/cache-$arm-arms" -o:"$out/local/$arm-arms-v2" tools/check_pixel_search_arms.nim > "$out/local/build-$arm-arms-v2.log" 2>&1
 "$out/local/$arm-arms-v2" > "$out/local/$arm-arms-v2.json" 2> "$out/local/$arm-arms-v2.stderr"
done
printf 'A7 EDGE COVERAGE DONE\n' > "$out/local/EDGE_DONE"
