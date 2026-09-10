#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/bench_body_danger_cache.nim
test ! -e tools/bench_body_danger_trace.nim
run_dir="$HOME/nav-throughput-results-20260909/C3-mechanisms"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/c3-mechanisms-input/base.nim"
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim; rm -f tools/bench_body_danger_cache.nim tools/bench_body_danger_trace.nim' EXIT
cp "$HOME/c3-mechanisms-input/bench_body_danger_cache.nim" tools/
cp "$HOME/c3-mechanisms-input/bench_body_danger_trace.nim" tools/
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/c3-mechanisms-input/"*.nim "$HOME/c3-mechanisms-input/traces/"*.txt > "$run_dir/input-hashes.txt"
for arm in parent candidate; do
 cp "$HOME/c3-mechanisms-input/$arm.nim" src/shell/body_nav.nim
 git diff > "$run_dir/$arm.patch"
 for mode in cache trace; do
  "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler -d:dangerSourceCacheCounters --threads:on --opt:speed --stackTrace:on --path:src/shell --nimcache:"$run_dir/cache-$arm-$mode" -o:"$run_dir/bench-$arm-$mode" "tools/bench_body_danger_$mode.nim" > "$run_dir/build-$arm-$mode.log" 2>&1
 done
done
for repeat in 1 2 3; do
 for arm in parent candidate; do
  taskset -c 5 "$run_dir/bench-$arm-cache" > "$run_dir/$arm-regimes-r$repeat.json" 2> "$run_dir/$arm-regimes-r$repeat.stderr"
  for trace in "$HOME/c3-mechanisms-input/traces/"*.txt; do
   tag="$(basename "$trace" .navsrc.txt)"
   taskset -c 5 "$run_dir/bench-$arm-trace" "$trace" > "$run_dir/$arm-$tag-r$repeat.json" 2> "$run_dir/$arm-$tag-r$repeat.stderr"
  done
 done
done
sha256sum "$run_dir/bench-"* > "$run_dir/executable-hashes.txt"
printf 'C3 mechanisms DONE\n' > "$run_dir/DONE"
