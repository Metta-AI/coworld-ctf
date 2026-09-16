#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/L1"
mkdir -p "$run_dir"
test -f "$HOME/nav-throughput-results-20260909/L0/DONE"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
cp "$HOME/nav-throughput-results-20260909/L0/bench-candidate" "$run_dir/bench-parent"
git diff > "$run_dir/candidate.patch"
sha256sum src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"
"$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-candidate" -o:"$run_dir/bench-candidate" tools/bench_body_nav_rework.nim > "$run_dir/build-candidate.log" 2>&1
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/binary-hashes.txt"
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
set +e
taskset -c 5 "$run_dir/bench-candidate" --quality --activation --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/quality-activation.json" 2> "$run_dir/quality-activation.stderr"
echo "$?" > "$run_dir/quality-activation.exit"
set -e
printf 'L1 DONE\n' > "$run_dir/DONE"
