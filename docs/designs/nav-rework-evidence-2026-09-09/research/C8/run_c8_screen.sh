#!/usr/bin/env bash
# C8 native screen (root runs). Parent = C8/snapshots/parent-body_nav.nim
# (frozen C2 plus inert C5 markers); candidate = C8/snapshots/candidate-body_nav.nim
# (parent plus the zero-weight omission). Each copied over src/shell/body_nav.nim
# in its own checkout (C8_TREE_PARENT / C8_TREE_CANDIDATE). Timed binaries carry
# no counters or trace defines; the counted replay build is separate.
# Every exit code is recorded. Root supplies the trace/regime timing runner it
# used for C3 (run_c3.sh shape) with these two trees; this script covers the
# exactness and count part that must precede timing.
set -uo pipefail
tree_parent="${C8_TREE_PARENT:-$HOME/coworld-nav-source-cache-c8-parent}"
tree_candidate="${C8_TREE_CANDIDATE:-$HOME/coworld-nav-source-cache-c8-candidate}"
run_dir="${C8_RUN_DIR:-$HOME/nav-throughput-results-20260909/C8-screen}"
cpu="${C8_CPU:-5}"
traces="${C8_TRACES:-$tree_parent/docs/designs/nav-rework-evidence-2026-09-09/research/C2/traces}"
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
for arm in parent candidate; do
  if [ "$arm" = parent ]; then tree="$tree_parent"; else tree="$tree_candidate"; fi
  ( cd "$tree" && sha256sum src/shell/body_nav.nim ) > "$run_dir/source-hash-$arm.txt"; record "source-hash-$arm" $?
  ( cd "$tree" && "$NIM" c -d:release --hints:off -o:"$run_dir/test-cache-$arm" tests/test_shell_body_danger_source_cache.nim && "$run_dir/test-cache-$arm" ) > "$run_dir/test-cache-$arm.log" 2>&1; record "test-cache-$arm" $?
  ( cd "$tree" && "$NIM" c -d:release --hints:off -o:"$run_dir/test-nav-$arm" tests/test_shell_body_nav_rework.nim && "$run_dir/test-nav-$arm" ) > "$run_dir/test-nav-$arm.log" 2>&1; record "test-nav-$arm" $?
  # counted replay (diagnostic only): chains + hits/misses for the nine traces
  ( cd "$tree" && "$NIM" c $FLAGS -d:dangerSourceCacheCounters --nimcache:"$run_dir/cache-replay-$arm" -o:"$run_dir/replay-counted-$arm" tools/replay_danger_source_trace.nim ) > "$run_dir/build-replay-$arm.log" 2>&1; record "build-replay-$arm" $?
  : > "$run_dir/chains-$arm.txt"
  for t in s2_16_679962:br-gen-5204:16 s2_16_679963:br-gen-5263:16 s2_16_679964:br-gen-5204:16 s2_16_679965:br-gen-5001:16 s2_32_679962:br-gen-5204:32 s2_32_679963:br-gen-5263:32 s2_32_679964:br-gen-5204:32 s2_32_679965:br-gen-5001:32 smoke_s2_16_randomized:br-gen-5001:16; do
    IFS=: read -r n m s <<< "$t"
    (cd "$tree" && taskset -c "$cpu" "$run_dir/replay-counted-$arm" "$traces/$n.navsrc.txt" "$m" "$s" 1300 2>>"$run_dir/replay.stderr") | tr '\n' ' ' | sed "s/^/$n /" >> "$run_dir/chains-$arm.txt"; echo >> "$run_dir/chains-$arm.txt"; record "replay-$arm-$n" $?
  done
done
diff "$run_dir/chains-parent.txt" "$run_dir/chains-candidate.txt" > "$run_dir/chains-diff.txt"; record chains-diff $?   # must be empty: rasters, hits, misses identical
printf 'C8 SCREEN EXACTNESS DONE\n' > "$run_dir/DONE"; cat "$run_dir/exit-codes.txt"
