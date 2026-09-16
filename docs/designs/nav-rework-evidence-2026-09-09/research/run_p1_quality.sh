#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/P1"
test ! -e "$run_dir"
mkdir -p "$run_dir/parent"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
for file in src/shell/body_map.nim src/shell/body_safety_query.nim src/shell/body_hazard.nim src/shell/body_route_index.nim src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim tools/build_nav_route_corpus.nim; do
 cp "$file" "$run_dir/parent/$(basename "$file")"
 cp "$HOME/p1-input/$(basename "$file")" "$file"
done
restore_sources() {
 for file in src/shell/body_map.nim src/shell/body_safety_query.nim src/shell/body_hazard.nim src/shell/body_route_index.nim src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim tools/build_nav_route_corpus.nim; do
  cp "$run_dir/parent/$(basename "$file")" "$file"
 done
}
trap restore_sources EXIT
git diff > "$run_dir/source.patch"
sha256sum "$HOME/p1-input/"*.nim > "$run_dir/input-source-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum coworld_manifest_paintbot.json data/br_map_pool.json > "$run_dir/input-hashes.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache" -o:"$run_dir/bench" tools/bench_body_nav_rework.nim > "$run_dir/build.log" 2>&1
sha256sum "$run_dir/bench" > "$run_dir/executable-hashes.txt"
set +e
taskset -c 5 "$run_dir/bench" --quality --activation > "$run_dir/activation.json" 2> "$run_dir/activation.stderr"
echo "$?" > "$run_dir/activation.exit"
set -e
printf 'P1 DONE\n' > "$run_dir/DONE"
