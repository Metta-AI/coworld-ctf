#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/I0"
mkdir -p "$run_dir"
test -f "$HOME/nav-throughput-results-20260909/PROFILE/DONE"
export WASMTIME_C_API="$HOME/coworld-ctf-nav/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include" LIBRARY_PATH="$WASMTIME_C_API/lib" LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp tools/bench_body_nav_rework.nim "$run_dir/harness-original.nim"
trap 'cp "$run_dir/harness-original.nim" tools/bench_body_nav_rework.nim' EXIT
cp "$HOME/nav-throughput-instrumentation-harness.nim" tools/bench_body_nav_rework.nim
git diff > "$run_dir/source.patch"
for variant in A1 B A2; do
  extra=()
  if [ "$variant" = B ]; then extra=(-d:navGateNoBreakdown); fi
  nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on "${extra[@]}" --nimcache:"$run_dir/cache-$variant" -o:"$run_dir/bench-$variant" tools/bench_body_nav_rework.nim > "$run_dir/build-$variant.log" 2>&1
done
for repeat in 1 2 3; do
  for variant in A1 B A2; do
    date -u > "$run_dir/$variant-r$repeat-host.txt"
    uptime >> "$run_dir/$variant-r$repeat-host.txt"
    set +e
    NAV_GATE_COMMIT=20234cc7 NAV_GATE_DIRTY=true taskset -c 5 "$run_dir/bench-$variant" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/$variant-r$repeat.json" 2> "$run_dir/$variant-r$repeat.stderr"
    echo "$?" > "$run_dir/$variant-r$repeat.exit"
    set -e
  done
done
printf 'I0 DONE\n' > "$run_dir/DONE"
