#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/LATENCY"
mkdir -p "$run_dir"
export WASMTIME_C_API="$HOME/coworld-ctf-nav/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp tools/bench_body_nav_rework.nim "$run_dir/harness-original.nim"
trap 'cp "$run_dir/harness-original.nim" tools/bench_body_nav_rework.nim' EXIT
cp "$HOME/nav-latency-harness.nim" tools/bench_body_nav_rework.nim
git diff > "$run_dir/source.patch"
nim --version > "$run_dir/compiler.txt"
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -o:"$run_dir/bench-latency" tools/bench_body_nav_rework.nim > "$run_dir/build.log" 2>&1
for repeat in 1 2; do
  date -u > "$run_dir/r$repeat-host.txt"
  uptime >> "$run_dir/r$repeat-host.txt"
  set +e
  taskset -c 5 "$run_dir/bench-latency" --latency --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/r$repeat.json" 2> "$run_dir/r$repeat.stderr"
  echo "$?" > "$run_dir/r$repeat.exit"
  set -e
done
printf 'LATENCY DONE\n' > "$run_dir/DONE"
