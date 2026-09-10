#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/profile_body_route_index.nim
run_dir="$HOME/nav-throughput-results-20260909/A2-profile"
test ! -e "$run_dir"
mkdir -p "$run_dir"
trap 'rm -f tools/profile_body_route_index.nim' EXIT
cp "$HOME/a2-profile-input.nim" tools/profile_body_route_index.nim
git rev-parse HEAD > "$run_dir/base-commit.txt"
sha256sum src/shell/body_route_index.nim tools/profile_body_route_index.nim > "$run_dir/source-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell -d:ProfileTracePath="$run_dir/index-trace.json" --nimcache:"$run_dir/cache" -o:"$run_dir/profile-index" tools/profile_body_route_index.nim > "$run_dir/build.log" 2>&1
taskset -c 5 "$run_dir/profile-index" > "$run_dir/run.log" 2>&1
sha256sum "$run_dir/profile-index" "$run_dir/index-trace.json" > "$run_dir/result-hashes.txt"
printf 'A2 PROFILE DONE\n' > "$run_dir/DONE"
