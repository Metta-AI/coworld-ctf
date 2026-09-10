#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/PROFILE"
mkdir -p "$run_dir"
if [ ! -f "$HOME/nav-throughput-results-20260909/B0/DONE" ]; then
  echo 'Baseline must complete before profiling' >&2
  exit 2
fi
export WASMTIME_C_API="$HOME/coworld-ctf-nav/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include" LIBRARY_PATH="$WASMTIME_C_API/lib" LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp tools/bench_body_nav_rework.nim "$run_dir/harness-original.nim"
trap 'cp "$run_dir/harness-original.nim" tools/bench_body_nav_rework.nim' EXIT
cp "$HOME/nav-throughput-profile-harness.nim" tools/bench_body_nav_rework.nim
git diff > "$run_dir/source.patch"
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -d:ProfileTracePath="$run_dir/profile-trace.json" -o:"$run_dir/bench-profile" tools/bench_body_nav_rework.nim > "$run_dir/build.log" 2>&1
set +e
taskset -c 5 "$run_dir/bench-profile" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"
echo "$?" > "$run_dir/run.exit"
set -e
test -s "$run_dir/profile-trace.json"
printf 'PROFILE DONE\n' > "$run_dir/DONE"
