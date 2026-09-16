#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
run_dir="$HOME/nav-throughput-results-20260909/A6-screen"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_route_index.nim "$run_dir/original-index.nim"
cp tools/profile_body_route_index.nim "$run_dir/original-profiler.nim"
trap 'cp "$run_dir/original-index.nim" src/shell/body_route_index.nim; cp "$run_dir/original-profiler.nim" tools/profile_body_route_index.nim' EXIT
cp "$HOME/a6-input/profile_body_route_index.nim" tools/profile_body_route_index.nim
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/a6-input/"*.nim > "$run_dir/input-hashes.txt"
for arm in eager direct lazy; do
 cp "$HOME/a6-input/$arm-body_route_index.nim" src/shell/body_route_index.nim
 git diff > "$run_dir/$arm.patch"
 "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell -d:ProfileTracePath="$run_dir/current-$arm.json" --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/profile-$arm" tools/profile_body_route_index.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3; do
 case "$repeat" in
  1) arms='eager direct lazy';;
  2) arms='lazy direct eager';;
  3) arms='direct eager lazy';;
 esac
 for arm in $arms; do
  taskset -c 5 "$run_dir/profile-$arm" 48 5 > "$run_dir/$arm-r$repeat.log" 2>&1
  mv "$run_dir/current-$arm.json" "$run_dir/$arm-r$repeat.json"
 done
done
sha256sum "$run_dir/profile-"* "$run_dir/"*.json > "$run_dir/result-hashes.txt"
printf 'A6 SCREEN DONE\n' > "$run_dir/DONE"
