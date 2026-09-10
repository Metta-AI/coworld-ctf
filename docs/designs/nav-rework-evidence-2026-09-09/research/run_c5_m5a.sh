#!/usr/bin/env bash
set -euo pipefail
while kill -0 58413 2>/dev/null; do sleep 10; done
test -f "$HOME/nav-throughput-results-20260909/A6-screen/DONE"
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/C5-v2-profile"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original-nav.nim"
cp tools/bench_body_nav_rework.nim "$run_dir/original-bench.nim"
trap 'cp "$run_dir/original-nav.nim" src/shell/body_nav.nim; cp "$run_dir/original-bench.nim" tools/bench_body_nav_rework.nim' EXIT
cp "$HOME/c5-input/C5v2-body_nav.nim" src/shell/body_nav.nim
cp "$HOME/c5-input/C5v2-bench_body_nav_rework.nim" tools/bench_body_nav_rework.nim
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
git diff > "$run_dir/source.patch"
lscpu > "$run_dir/lscpu.txt"
sha256sum src/shell/body_nav.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"
for mode in traced counted; do
 flags=()
 if [ "$mode" = traced ]; then flags+=("-d:ProfileTracePath=$run_dir/configured-trace.json"); else flags+=(-d:dangerSourceCacheCounters); fi
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on "${flags[@]}" --nimcache:"$run_dir/cache-$mode" -o:"$run_dir/bench-$mode" tools/bench_body_nav_rework.nim > "$run_dir/build-$mode.log" 2>&1
 printf 'build-%s exit=0\n' "$mode" >> "$run_dir/exit-codes.txt"
 set +e
 taskset -c 5 "$run_dir/bench-$mode" --configured-tick --pool-index 3 > "$run_dir/configured-$mode.json" 2> "$run_dir/configured-$mode.stderr"
 result=$?
 set -e
 printf 'run-%s exit=%s\n' "$mode" "$result" >> "$run_dir/exit-codes.txt"
 if [ "$result" -gt 1 ]; then exit "$result"; fi
done
python3 "$HOME/c5-input/attribute_clears.py" "$run_dir/configured-trace.json" > "$run_dir/clear-attribution.json"
sha256sum "$run_dir/bench-"* "$run_dir/configured-trace.json" > "$run_dir/result-hashes.txt"
printf 'C5 V2 PROFILE DONE\n' > "$run_dir/DONE"
