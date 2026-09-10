#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/V1"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/v1-input/parent.nim"
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim' EXIT
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum "$HOME/v1-input/"*.nim > "$run_dir/input-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
for arm in parent candidate; do
 cp "$HOME/v1-input/$arm.nim" src/shell/body_nav.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_body_nav_rework.nim > "$run_dir/build-$arm.log" 2>&1
done
taskset -c 5 "$run_dir/bench-candidate" --quality > "$run_dir/quality.json" 2> "$run_dir/quality.stderr"
printf '0\n' > "$run_dir/quality.exit"
python3 - "$run_dir/quality.json" <<'PYHASH'
import json, sys
quality = json.load(open(sys.argv[1]))["quality"]
assert quality["route_hash"] == "5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500"
PYHASH
for range in 331 1300; do
 for repeat in 1 2 3; do
  for arm in parent candidate; do
   set +e
   taskset -c 5 "$run_dir/bench-$arm" --tick --tick-gun-range "$range" > "$run_dir/$arm-$range-r$repeat.json" 2> "$run_dir/$arm-$range-r$repeat.stderr"
   echo "$?" > "$run_dir/$arm-$range-r$repeat.exit"
   set -e
  done
 done
done
set +e
taskset -c 5 "$run_dir/bench-candidate" --activation > "$run_dir/activation.json" 2> "$run_dir/activation.stderr"
echo "$?" > "$run_dir/activation.exit"
taskset -c 5 "$run_dir/bench-candidate" --configured-tick > "$run_dir/configured.json" 2> "$run_dir/configured.stderr"
echo "$?" > "$run_dir/configured.exit"
set -e
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/executable-hashes.txt"
printf 'V1 DONE\n' > "$run_dir/DONE"
