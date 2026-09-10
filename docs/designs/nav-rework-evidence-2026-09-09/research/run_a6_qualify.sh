#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/A6-qualify"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_route_index.nim "$run_dir/original-index.nim"
trap 'cp "$run_dir/original-index.nim" src/shell/body_route_index.nim' EXIT
cp "$HOME/a6-input/lazy-body_route_index.nim" src/shell/body_route_index.nim
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
git diff > "$run_dir/candidate.patch"
sha256sum src/shell/body_route_index.nim > "$run_dir/source-hashes.txt"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
"$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache" -o:"$run_dir/bench" tools/bench_body_nav_rework.nim > "$run_dir/build.log" 2>&1
"$nim_bin" c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on -o:"$run_dir/test-index" tests/test_shell_body_route_index.nim > "$run_dir/focused.log" 2>&1
taskset -c 5 "$run_dir/bench" --quality > "$run_dir/quality.json" 2> "$run_dir/quality.stderr"
for mode in activation configured-tick; do
 set +e
 taskset -c 5 "$run_dir/bench" "--$mode" > "$run_dir/$mode.json" 2> "$run_dir/$mode.stderr"
 echo "$?" > "$run_dir/$mode.exit"
 set -e
done
sha256sum "$run_dir/bench" > "$run_dir/executable-hashes.txt"
printf 'A6 QUALIFY DONE\n' > "$run_dir/DONE"
