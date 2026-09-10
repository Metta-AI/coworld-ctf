#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/G0"
mkdir -p "$run_dir"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp src/shell/body_route_query.nim "$run_dir/query-parent.nim"
cp tools/bench_body_nav_rework.nim "$run_dir/harness-parent.nim"
trap 'cp "$run_dir/query-parent.nim" src/shell/body_route_query.nim; cp "$run_dir/harness-parent.nim" tools/bench_body_nav_rework.nim' EXIT
cp "$HOME/g0-input/body_route_query.nim" src/shell/body_route_query.nim
cp "$HOME/g0-input/bench_body_nav_rework.nim" tools/bench_body_nav_rework.nim
git diff > "$run_dir/source.patch"
sha256sum src/shell/body_route_query.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"
gcc --version > "$run_dir/compiler.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" --version >> "$run_dir/compiler.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache" -o:"$run_dir/bench" tools/bench_body_nav_rework.nim > "$run_dir/build.log" 2>&1
for repeat in 1 2 3; do
 for gun_range in 331 1300; do
  set +e
  taskset -c 5 "$run_dir/bench" --tick --tick-gun-range "$gun_range" > "$run_dir/range$gun_range-r$repeat.json" 2> "$run_dir/range$gun_range-r$repeat.stderr"
  echo "$?" > "$run_dir/range$gun_range-r$repeat.exit"
  set -e
 done
done
printf 'G0 DONE\n' > "$run_dir/DONE"
