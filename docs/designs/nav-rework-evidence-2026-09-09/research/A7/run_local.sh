#!/usr/bin/env bash
set -euo pipefail
root=/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research
out="$root/docs/designs/nav-rework-evidence-2026-09-09/research/A7"
cd /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-early-visited
mkdir -p "$out/local"
cp src/shell/body_route_index.nim "$out/original-index.nim"
trap 'cp "$out/original-index.nim" src/shell/body_route_index.nim' EXIT
for arm in eager eager-early lazy lazy-early; do
 cp "$out/snapshots/$arm.nim" src/shell/body_route_index.nim
 for mode in arms identity; do
  if [ "$mode" = arms ]; then tool=check_pixel_search_arms; else tool=check_body_route_index_identity; fi
  nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --nimcache:"$out/local/cache-$arm-$mode" -o:"$out/local/$arm-$mode" "tools/$tool.nim" > "$out/local/build-$arm-$mode.log" 2>&1
  "$out/local/$arm-$mode" > "$out/local/$arm-$mode.json" 2> "$out/local/$arm-$mode.stderr"
 done
 nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on -o:"$out/local/test-$arm" tests/test_shell_body_route_index.nim > "$out/local/test-$arm.log" 2>&1
done
printf 'A7 LOCAL DONE\n' > "$out/local/DONE"
