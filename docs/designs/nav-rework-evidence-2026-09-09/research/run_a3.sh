#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/A3"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_map.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/a3-input/parent.nim"
restore_sources() {
 cp "$run_dir/original.nim" src/shell/body_map.nim
}
trap restore_sources EXIT
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum "$HOME/a3-input/"*.nim > "$run_dir/input-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
for arm in parent candidate; do
 cp "$HOME/a3-input/$arm.nim" src/shell/body_map.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_body_nav_rework.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3; do
 for arm in parent candidate; do
  set +e
  taskset -c 5 "$run_dir/bench-$arm" --activation --pool-index 48 > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
  echo "$?" > "$run_dir/$arm-r$repeat.exit"
  set -e
 done
done
set +e
taskset -c 5 "$run_dir/bench-candidate" --quality > "$run_dir/quality.json" 2> "$run_dir/quality.stderr"
echo "$?" > "$run_dir/quality.exit"
taskset -c 5 "$run_dir/bench-candidate" --activation > "$run_dir/activation.json" 2> "$run_dir/activation.stderr"
echo "$?" > "$run_dir/activation.exit"
taskset -c 5 "$run_dir/bench-candidate" --configured-tick > "$run_dir/configured.json" 2> "$run_dir/configured.stderr"
echo "$?" > "$run_dir/configured.exit"
set -e
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/executable-hashes.txt"
printf 'A3 DONE\n' > "$run_dir/DONE"
