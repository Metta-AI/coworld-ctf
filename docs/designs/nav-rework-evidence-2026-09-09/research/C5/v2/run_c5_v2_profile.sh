#!/usr/bin/env bash
# C5 v2 configured danger attribution (root runs on m8i, then m5a). Tree: the
# C5 v2 snapshot of nav-source-cache (C2 over f9dff753 plus v2 markers and
# harness row marker/counters). Every command's exit code is recorded
# explicitly; nothing is discarded. Traced row timings are attribution only
# (they include tracing overhead) and are never a pair comparator; root's
# unprofiled C2/C3 comparisons remain authoritative.
set -uo pipefail
tree="${C5_TREE:-$HOME/coworld-nav-source-cache}"
run_dir="${C5_RUN_DIR:-$HOME/nav-throughput-results-20260909/C5-v2-profile}"
cpu="${C5_CPU:-5}"
pool_index="${C5_POOL_INDEX:-3}"   # configured index 3 = br-gen-5120
cd "$tree" || { echo "no tree" >&2; exit 2; }
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { # record <name> <exit>
  printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"
}
git rev-parse HEAD > "$run_dir/base-commit.txt"; record git-rev-parse $?
git status --porcelain > "$run_dir/git-status.txt"; record git-status $?
sha256sum src/shell/body_nav.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"; record source-hashes $?
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
# 1. traced (markers on, counters off): attribution trace + per-row JSON
"$NIM" c $FLAGS -d:ProfileTracePath="$run_dir/configured-trace.json" --nimcache:"$run_dir/cache-traced" -o:"$run_dir/bench-traced" tools/bench_body_nav_rework.nim > "$run_dir/build-traced.log" 2>&1; record build-traced $?
taskset -c "$cpu" "$run_dir/bench-traced" --configured-tick --pool-index "$pool_index" > "$run_dir/configured-traced.json" 2> "$run_dir/configured-traced.stderr"; record run-traced $?   # exit 1 = gate failed, expected on non-passing hosts; still valid output
# 2. counted (counters on, trace off): hits/misses per row after timing
"$NIM" c $FLAGS -d:dangerSourceCacheCounters --nimcache:"$run_dir/cache-counted" -o:"$run_dir/bench-counted" tools/bench_body_nav_rework.nim > "$run_dir/build-counted.log" 2>&1; record build-counted $?
taskset -c "$cpu" "$run_dir/bench-counted" --configured-tick --pool-index "$pool_index" > "$run_dir/configured-counted.json" 2> "$run_dir/configured-counted.stderr"; record run-counted $?
python3 "$(dirname "$0")/attribute_clears.py" "$run_dir/configured-trace.json" > "$run_dir/clear-attribution.json"; record attribute-clears $?
sha256sum "$run_dir"/bench-* "$run_dir/configured-trace.json" > "$run_dir/result-hashes.txt"; record result-hashes $?
printf 'C5 V2 PROFILE DONE\n' > "$run_dir/DONE"
cat "$run_dir/exit-codes.txt"
