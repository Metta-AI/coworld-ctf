#!/usr/bin/env bash
# A5 attribution profile (root runs on m5a/m8i). Mirrors run_a2_profile.sh.
# Requires a checkout of nav-validation-symmetry WITH the A5 markers applied
# (A5-markers-over-A4.patch over the A4 baseline) and the A5 profiler
# (tools/profile_body_route_index.nim from A5-profiler.patch).
set -euo pipefail
tree="${A5_TREE:-$HOME/coworld-nav-validation-symmetry}"
run_dir="${A5_RUN_DIR:-$HOME/nav-throughput-results-20260909/A5-profile}"
cpu="${A5_CPU:-5}"
pool_index="${A5_POOL_INDEX:-48}"
repeats="${A5_REPEATS:-5}"
cd "$tree"
test ! -e "$run_dir"
mkdir -p "$run_dir"
git rev-parse HEAD > "$run_dir/base-commit.txt"
git status --porcelain > "$run_dir/git-status.txt"
sha256sum src/shell/body_route_index.nim tools/profile_body_route_index.nim > "$run_dir/source-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell -d:ProfileTracePath="$run_dir/index-trace.json" --nimcache:"$run_dir/cache" -o:"$run_dir/profile-index" tools/profile_body_route_index.nim > "$run_dir/build.log" 2>&1
taskset -c "$cpu" "$run_dir/profile-index" "$pool_index" "$repeats" > "$run_dir/run.log" 2>&1
sha256sum "$run_dir/profile-index" "$run_dir/index-trace.json" > "$run_dir/result-hashes.txt"
printf 'A5 PROFILE DONE\n' > "$run_dir/DONE"
