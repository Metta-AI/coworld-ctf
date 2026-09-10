#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/C3"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/c3-input/base.nim"
cp tools/bench_body_nav_rework.nim "$run_dir/original-bench.nim"
cmp "$run_dir/original-bench.nim" "$HOME/c3-input/base-bench.nim"
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim; cp "$run_dir/original-bench.nim" tools/bench_body_nav_rework.nim' EXIT
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum "$HOME/c3-input/"*.nim > "$run_dir/input-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
for arm in parent candidate; do
 cp "$HOME/c3-input/$arm.nim" src/shell/body_nav.nim
 cp "$HOME/c3-input/$arm-bench.nim" tools/bench_body_nav_rework.nim
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
for repeat in 1 2 3; do
 for arm in parent candidate; do
  set +e
  taskset -c 5 "$run_dir/bench-$arm" --configured-tick > "$run_dir/$arm-configured-r$repeat.json" 2> "$run_dir/$arm-configured-r$repeat.stderr"
  echo "$?" > "$run_dir/$arm-configured-r$repeat.exit"
  set -e
 done
done
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/executable-hashes.txt"
printf 'C3 DONE\n' > "$run_dir/DONE"
