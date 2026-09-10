#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/L0"
mkdir -p "$run_dir"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
cp src/shell/body_nav.nim "$run_dir/candidate-body-nav.nim"
trap 'cp "$run_dir/candidate-body-nav.nim" src/shell/body_nav.nim' EXIT
for variant in parent candidate; do
  if [ "$variant" = parent ]; then git show HEAD:src/shell/body_nav.nim > src/shell/body_nav.nim; else cp "$run_dir/candidate-body-nav.nim" src/shell/body_nav.nim; fi
  git diff > "$run_dir/$variant.patch"
  "$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$variant" -o:"$run_dir/bench-$variant" tools/bench_body_nav_rework.nim > "$run_dir/build-$variant.log" 2>&1
done
for repeat in 1 2 3; do
  for variant in parent candidate; do
    set +e
    taskset -c 5 "$run_dir/bench-$variant" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/$variant-r$repeat.json" 2> "$run_dir/$variant-r$repeat.stderr"
    echo "$?" > "$run_dir/$variant-r$repeat.exit"
    set -e
  done
done
for repeat in 1 2; do
  set +e
  taskset -c 5 "$run_dir/bench-candidate" --latency --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/latency-r$repeat.json" 2> "$run_dir/latency-r$repeat.stderr"
  echo "$?" > "$run_dir/latency-r$repeat.exit"
  set -e
done
printf 'L0 DONE\n' > "$run_dir/DONE"
