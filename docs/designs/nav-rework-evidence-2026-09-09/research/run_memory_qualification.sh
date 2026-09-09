#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/M0"
mkdir -p "$run_dir"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include" LIBRARY_PATH="$WASMTIME_C_API/lib" LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
"$nim_bin" --version > "$run_dir/compiler.txt"
cp src/shell/body_route_query.nim "$run_dir/candidate.nim"
trap 'cp "$run_dir/candidate.nim" src/shell/body_route_query.nim' EXIT
for variant in parent candidate; do
  if [ "$variant" = parent ]; then git show HEAD:src/shell/body_route_query.nim > src/shell/body_route_query.nim; else cp "$run_dir/candidate.nim" src/shell/body_route_query.nim; fi
  git diff > "$run_dir/$variant.patch"
  "$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-$variant" -o:"$run_dir/bench-$variant" tools/bench_body_nav_rework.nim > "$run_dir/build-$variant.log" 2>&1
done
for repeat in 1 2 3; do
  for variant in parent candidate; do
    date -u > "$run_dir/$variant-r$repeat-host.txt"
    uptime >> "$run_dir/$variant-r$repeat-host.txt"
    set +e
    taskset -c 5 "$run_dir/bench-$variant" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/$variant-r$repeat.json" 2> "$run_dir/$variant-r$repeat.stderr"
    echo "$?" > "$run_dir/$variant-r$repeat.exit"
    set -e
  done
done
set +e
taskset -c 5 "$run_dir/bench-candidate" --all --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/quality-activation.json" 2> "$run_dir/quality-activation.stderr"
echo "$?" > "$run_dir/quality-activation.exit"
set -e
printf 'M0 DONE\n' > "$run_dir/DONE"
