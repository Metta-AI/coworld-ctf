#!/usr/bin/env bash
# C6 native micro screen (root runs, m8i CPU 5). Parent = frozen C2 (C5 v2
# bytes, arm off); candidate = same source with -d:DangerReplayFullWords=true.
# No diagnostic counters or trace defines in either binary. Five paired runs
# per arm, interleaved; identical batch raster hashes and zero reference
# mismatches are required; then the nine real-trace chains.
set -uo pipefail
tree="${C6_TREE:-$HOME/coworld-nav-source-cache}"
run_dir="${C6_RUN_DIR:-$HOME/nav-throughput-results-20260909/C6-micro}"
cpu="${C6_CPU:-5}"
traces="${C6_TRACES:-$tree/docs/designs/nav-rework-evidence-2026-09-09/research/C2/traces}"
cd "$tree" || exit 2
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
git rev-parse HEAD > "$run_dir/base-commit.txt"; record git-rev-parse $?
sha256sum src/shell/body_nav.nim tools/bench_danger_replay.nim tools/replay_danger_source_trace.nim > "$run_dir/source-hashes.txt"; record source-hashes $?
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
"$NIM" c $FLAGS --nimcache:"$run_dir/cache-parent" -o:"$run_dir/bench-parent" tools/bench_danger_replay.nim > "$run_dir/build-parent.log" 2>&1; record build-parent $?
"$NIM" c $FLAGS -d:DangerReplayFullWords=true --nimcache:"$run_dir/cache-candidate" -o:"$run_dir/bench-candidate" tools/bench_danger_replay.nim > "$run_dir/build-candidate.log" 2>&1; record build-candidate $?
: > "$run_dir/micro_results.jsonl"
for round in 1 2 3 4 5; do
  for arm in parent candidate; do
    for cfg in br-gen-5120:1300 br-gen-5120:331 br-gen-5204:1300 br-gen-5204:331 br-gen-5263:1300 br-gen-5263:331; do
      m="${cfg%%:*}"; r="${cfg##*:}"
      out=$(taskset -c "$cpu" "$run_dir/bench-$arm" "$m" "$r" 1400 5 20 2>>"$run_dir/micro.stderr"); rc=$?
      record "micro-$arm-$m-$r-round$round" $rc
      printf '%s\n' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); d['round']=$round; d['binary']='$arm'; print(json.dumps(d))" >> "$run_dir/micro_results.jsonl"
    done
  done
done
# Real-trace chains, both arms, no counters.
"$NIM" c $FLAGS --nimcache:"$run_dir/cache-replay-parent" -o:"$run_dir/replay-parent" tools/replay_danger_source_trace.nim > "$run_dir/build-replay-parent.log" 2>&1; record build-replay-parent $?
"$NIM" c $FLAGS -d:DangerReplayFullWords=true --nimcache:"$run_dir/cache-replay-candidate" -o:"$run_dir/replay-candidate" tools/replay_danger_source_trace.nim > "$run_dir/build-replay-candidate.log" 2>&1; record build-replay-candidate $?
for arm in parent candidate; do
  : > "$run_dir/chains-$arm.txt"
  for t in s2_16_679962:br-gen-5204:16 s2_16_679963:br-gen-5263:16 s2_16_679964:br-gen-5204:16 s2_16_679965:br-gen-5001:16 s2_32_679962:br-gen-5204:32 s2_32_679963:br-gen-5263:32 s2_32_679964:br-gen-5204:32 s2_32_679965:br-gen-5001:32 smoke_s2_16_randomized:br-gen-5001:16; do
    IFS=: read -r n m s <<< "$t"
    taskset -c "$cpu" "$run_dir/replay-$arm" "$traces/$n.navsrc.txt" "$m" "$s" 1300 2>>"$run_dir/replay.stderr" | sed "s/^/$n /" >> "$run_dir/chains-$arm.txt"; record "replay-$arm-$n" $?
  done
done
diff "$run_dir/chains-parent.txt" "$run_dir/chains-candidate.txt" > "$run_dir/chains-diff.txt"; record chains-diff $?
sha256sum "$run_dir"/bench-* "$run_dir"/replay-* > "$run_dir/result-hashes.txt"; record result-hashes $?
printf 'C6 MICRO DONE\n' > "$run_dir/DONE"; cat "$run_dir/exit-codes.txt"
