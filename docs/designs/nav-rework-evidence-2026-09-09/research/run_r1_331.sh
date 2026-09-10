#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/R1"
mkdir -p "$run_dir/range331"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
date -u +%FT%TZ > "$run_dir/range331/start-utc.txt"
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/executable-hashes.txt"
for repeat in 1 2 3; do
 for arm in parent candidate; do
  set +e
  taskset -c 5 "$run_dir/bench-$arm" --tick --tick-gun-range 331 > "$run_dir/range331/$arm-r$repeat.json" 2> "$run_dir/range331/$arm-r$repeat.stderr"
  echo "$?" > "$run_dir/range331/$arm-r$repeat.exit"
  set -e
 done
done
date -u +%FT%TZ > "$run_dir/range331/end-utc.txt"
printf 'R1 331 DONE\n' > "$run_dir/range331/DONE"
