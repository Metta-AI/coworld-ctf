#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/V1-rollover"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/v1-rollover-input/parent.nim"
test ! -e tools/check_body_danger_rollover.nim
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim; rm -f tools/check_body_danger_rollover.nim' EXIT
cp "$HOME/v1-rollover-input/check_body_danger_rollover.nim" tools/check_body_danger_rollover.nim
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/v1-rollover-input/"*.nim > "$run_dir/input-hashes.txt"
for arm in parent candidate; do
 cp "$HOME/v1-rollover-input/$arm.nim" src/shell/body_nav.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/check-$arm" tools/check_body_danger_rollover.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3; do
 for arm in parent candidate; do
  taskset -c 5 "$run_dir/check-$arm" > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
  printf '0\n' > "$run_dir/$arm-r$repeat.exit"
 done
done
sha256sum "$run_dir/check-parent" "$run_dir/check-candidate" > "$run_dir/executable-hashes.txt"
printf 'V1 rollover DONE\n' > "$run_dir/DONE"
