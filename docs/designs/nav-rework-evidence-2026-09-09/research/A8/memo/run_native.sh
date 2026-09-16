#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/bench_index_constructor.nim
run_dir="$HOME/nav-throughput-results-20260909/A8-memo"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_route_index.nim "$run_dir/original-index.nim"
cmp "$run_dir/original-index.nim" "$HOME/a8-input/base.nim"
trap 'cp "$run_dir/original-index.nim" src/shell/body_route_index.nim; rm -f tools/bench_index_constructor.nim' EXIT
cp "$HOME/a8-input/bench_index_constructor.nim" tools/
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/a8-input/"*.nim > "$run_dir/input-hashes.txt"
for arm in parent candidate; do
 cp "$HOME/a8-input/$arm.nim" src/shell/body_route_index.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -d:IndexArmLabel="$arm" --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_index_constructor.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3; do
 arms="parent candidate"
 if [ "$repeat" = 2 ]; then arms="candidate parent"; fi
 for arm in $arms; do
  taskset -c 5 "$run_dir/bench-$arm" 48 5 > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
 done
done
sha256sum "$run_dir/bench-"* > "$run_dir/executable-hashes.txt"
printf 'A8 NATIVE DONE\n' > "$run_dir/DONE"
