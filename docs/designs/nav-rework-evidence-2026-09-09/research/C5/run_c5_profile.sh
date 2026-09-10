#!/usr/bin/env bash
# C5 configured danger attribution (root runs on m8i, then m5a). Uses the C5
# snapshot of the nav-source-cache tree (C2 over f9dff753 plus C5 markers and
# harness trace/counters: apply C5-body_nav-over-C2.patch and
# C5-bench-over-C2.patch, or copy the two snapshot files).
# Two binaries: TIMED (no counters, no breakdown beyond what the frozen gate
# uses) and COUNTED (counters, read after timing). Nested Fluffy durations are
# attribution only; never add stages or compare their percentiles to gates.
set -euo pipefail
tree="${C5_TREE:-$HOME/coworld-nav-source-cache}"
run_dir="${C5_RUN_DIR:-$HOME/nav-throughput-results-20260909/C5-profile}"
cpu="${C5_CPU:-5}"
pool_index="${C5_POOL_INDEX:-3}"   # configured index 3 = br-gen-5120
cd "$tree"
test ! -e "$run_dir"; mkdir -p "$run_dir"
git rev-parse HEAD > "$run_dir/base-commit.txt"
git status --porcelain > "$run_dir/git-status.txt"
sha256sum src/shell/body_nav.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
# 1. timed + traced (markers on, counters off)
"$NIM" c $FLAGS -d:ProfileTracePath="$run_dir/configured-trace.json" --nimcache:"$run_dir/cache-timed" -o:"$run_dir/bench-timed" tools/bench_body_nav_rework.nim > "$run_dir/build-timed.log" 2>&1
taskset -c "$cpu" "$run_dir/bench-timed" --configured-tick --pool-index "$pool_index" > "$run_dir/configured-timed.json" 2> "$run_dir/configured-timed.stderr" || true
# 2. counted (counters on, read after each row's timing; trace off)
"$NIM" c $FLAGS -d:dangerSourceCacheCounters --nimcache:"$run_dir/cache-counted" -o:"$run_dir/bench-counted" tools/bench_body_nav_rework.nim > "$run_dir/build-counted.log" 2>&1
taskset -c "$cpu" "$run_dir/bench-counted" --configured-tick --pool-index "$pool_index" > "$run_dir/configured-counted.json" 2> "$run_dir/configured-counted.stderr" || true
sha256sum "$run_dir"/bench-* "$run_dir/configured-trace.json" > "$run_dir/result-hashes.txt"
printf 'C5 PROFILE DONE\n' > "$run_dir/DONE"
