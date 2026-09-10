#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/check_body_graph_identity.nim
run_dir="$HOME/nav-throughput-results-20260909/A0"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_route_query.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/a0-input/parent.nim"
restore_sources() {
 cp "$run_dir/original.nim" src/shell/body_route_query.nim
 rm -f tools/check_body_graph_identity.nim
}
trap restore_sources EXIT
cp "$HOME/a0-input/check_body_graph_identity.nim" tools/check_body_graph_identity.nim
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum "$HOME/a0-input/"*.nim > "$run_dir/input-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
for arm in parent candidate; do
 cp "$HOME/a0-input/$arm.nim" src/shell/body_route_query.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_body_nav_rework.nim > "$run_dir/build-$arm.log" 2>&1
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-graph-$arm" -o:"$run_dir/graph-$arm" tools/check_body_graph_identity.nim > "$run_dir/build-graph-$arm.log" 2>&1
 taskset -c 5 "$run_dir/graph-$arm" > "$run_dir/graph-$arm.json" 2> "$run_dir/graph-$arm.stderr"
done
for repeat in 1 2 3; do
 for arm in parent candidate; do
  set +e
  taskset -c 5 "$run_dir/bench-$arm" --activation > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
  echo "$?" > "$run_dir/$arm-r$repeat.exit"
  set -e
 done
done
set +e
taskset -c 5 "$run_dir/bench-candidate" --quality > "$run_dir/quality.json" 2> "$run_dir/quality.stderr"
echo "$?" > "$run_dir/quality.exit"
taskset -c 5 "$run_dir/bench-candidate" --configured-tick > "$run_dir/configured.json" 2> "$run_dir/configured.stderr"
echo "$?" > "$run_dir/configured.exit"
set -e
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" "$run_dir/graph-parent" "$run_dir/graph-candidate" > "$run_dir/executable-hashes.txt"
printf 'A0 DONE\n' > "$run_dir/DONE"
