#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/bench_body_danger_wavefront.nim
run_dir="$HOME/nav-throughput-results-20260909/WF0-screen"
test ! -e "$run_dir"
mkdir -p "$run_dir"
trap 'rm -f tools/bench_body_danger_wavefront.nim' EXIT
cp "$HOME/wf0-screen-input.nim" tools/bench_body_danger_wavefront.nim
cp "$HOME/wf0-screen-input.nim" "$run_dir/source.nim"
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum "$run_dir/source.nim" > "$run_dir/source-hash.txt"
lscpu > "$run_dir/lscpu.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache" -o:"$run_dir/screen" tools/bench_body_danger_wavefront.nim > "$run_dir/build.log" 2>&1
sha256sum "$run_dir/screen" > "$run_dir/executable-hash.txt"
set +e
taskset -c 5 "$run_dir/screen" > "$run_dir/result.json" 2> "$run_dir/result.stderr"
echo "$?" > "$run_dir/result.exit"
set -e
printf 'WF0 SCREEN DONE\n' > "$run_dir/DONE"
