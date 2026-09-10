#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/W7"
mkdir -p "$run_dir/original"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
for file in src/shell/body_map.nim src/shell/body_hazard.nim src/shell/body_route_index.nim src/shell/body_safety_query.nim src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim tools/build_nav_route_corpus.nim; do
 cp "$file" "$run_dir/original/$(basename "$file")"
done
restore_sources() {
 for file in src/shell/body_map.nim src/shell/body_hazard.nim src/shell/body_route_index.nim src/shell/body_safety_query.nim src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim tools/build_nav_route_corpus.nim; do
  cp "$run_dir/original/$(basename "$file")" "$file"
 done
}
trap restore_sources EXIT
cp "$HOME/w7-input/body_hazard.nim" src/shell/body_hazard.nim
cp "$HOME/w7-input/body_route_index.nim" src/shell/body_route_index.nim
cp "$HOME/w7-input/body_safety_query.nim" src/shell/body_safety_query.nim
cp "$HOME/w7-input/body_nav.nim" src/shell/body_nav.nim
cp "$HOME/w7-input/body_route_query.nim" src/shell/body_route_query.nim
cp "$HOME/w7-input/bench_body_nav_rework.nim" tools/bench_body_nav_rework.nim
cp "$HOME/w7-input/build_nav_route_corpus.nim" tools/build_nav_route_corpus.nim
for arm in parent candidate; do
 cp "$HOME/w7-input/body_map-$arm.nim" src/shell/body_map.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_body_nav_rework.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3; do
 for arm in parent candidate; do
  set +e
  taskset -c 5 "$run_dir/bench-$arm" --tick --tick-gun-range 1300 > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
  echo "$?" > "$run_dir/$arm-r$repeat.exit"
  set -e
 done
done
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/executable-hashes.txt"
printf 'W7 DONE\n' > "$run_dir/DONE"
