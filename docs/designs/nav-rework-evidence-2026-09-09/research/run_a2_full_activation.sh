#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
source_dir="$HOME/nav-throughput-results-20260909/A2"
test -e "$source_dir/DONE"
run_dir="$HOME/nav-throughput-results-20260909/A2-full-activation"
test ! -e "$run_dir"
mkdir -p "$run_dir"
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp "$source_dir/base-commit.txt" "$source_dir/candidate.patch" "$source_dir/executable-hashes.txt" "$run_dir/"
set +e
taskset -c 5 "$source_dir/bench-candidate" --activation > "$run_dir/activation.json" 2> "$run_dir/activation.stderr"
echo "$?" > "$run_dir/activation.exit"
taskset -c 5 "$source_dir/bench-candidate" --configured-tick > "$run_dir/configured.json" 2> "$run_dir/configured.stderr"
echo "$?" > "$run_dir/configured.exit"
set -e
printf 'A2 FULL ACTIVATION DONE\n' > "$run_dir/DONE"
