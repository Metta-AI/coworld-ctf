#!/usr/bin/env bash
# C6 native micro screen v2 (root runs, m8i CPU 5). Parent = frozen C2 (C5 v2
# bytes); candidate = C2 plus the full-word arm. Root builds each arm from
# its MATERIALIZED snapshot (snapshots/parent-body_nav.nim and
# snapshots/candidate-body_nav.nim copied over src/shell/body_nav.nim in two
# separate checkouts, C6_TREE_PARENT / C6_TREE_CANDIDATE). The tools take a
# tools-only label -d:DangerReplayArmLabel=<arm> for JSON metadata and never
# reference the screen-only production define. v2 sampling spreads origins
# evenly across the map and records their coordinates. No diagnostic
# counters or trace defines in either binary. Every exit code is recorded.
set -uo pipefail
tree_parent="${C6_TREE_PARENT:-$HOME/coworld-nav-source-cache-parent}"
tree_candidate="${C6_TREE_CANDIDATE:-$HOME/coworld-nav-source-cache-candidate}"
run_dir="${C6_RUN_DIR:-$HOME/nav-throughput-results-20260909/C6-micro-v2}"
cpu="${C6_CPU:-5}"
traces="${C6_TRACES:-$tree_parent/docs/designs/nav-rework-evidence-2026-09-09/research/C2/traces}"
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
for arm in parent candidate; do
  if [ "$arm" = parent ]; then tree="$tree_parent"; else tree="$tree_candidate"; fi
  ( cd "$tree" && git rev-parse HEAD ) > "$run_dir/base-commit-$arm.txt"; record "git-rev-parse-$arm" $?
  ( cd "$tree" && sha256sum src/shell/body_nav.nim tools/bench_danger_replay.nim tools/replay_danger_source_trace.nim ) > "$run_dir/source-hashes-$arm.txt"; record "source-hashes-$arm" $?
  ( cd "$tree" && "$NIM" c $FLAGS -d:DangerReplayArmLabel=$arm --nimcache:"$run_dir/cache-bench-$arm" -o:"$run_dir/bench-$arm" tools/bench_danger_replay.nim ) > "$run_dir/build-bench-$arm.log" 2>&1; record "build-bench-$arm" $?
  ( cd "$tree" && "$NIM" c $FLAGS --nimcache:"$run_dir/cache-replay-$arm" -o:"$run_dir/replay-$arm" tools/replay_danger_source_trace.nim ) > "$run_dir/build-replay-$arm.log" 2>&1; record "build-replay-$arm" $?
done
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
: > "$run_dir/micro_results.jsonl"
for round in 1 2 3 4 5; do
  for arm in parent candidate; do
    for cfg in br-gen-5120:1300 br-gen-5120:331 br-gen-5204:1300 br-gen-5204:331 br-gen-5263:1300 br-gen-5263:331; do
      m="${cfg%%:*}"; r="${cfg##*:}"
      out=$(cd "$tree_parent" && taskset -c "$cpu" "$run_dir/bench-$arm" "$m" "$r" 1400 5 20 2>>"$run_dir/micro.stderr"); rc=$?
      record "micro-$arm-$m-$r-round$round" $rc
      printf '%s\n' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); d['round']=$round; print(json.dumps(d))" >> "$run_dir/micro_results.jsonl"
    done
  done
done
for arm in parent candidate; do
  : > "$run_dir/chains-$arm.txt"
  for t in s2_16_679962:br-gen-5204:16 s2_16_679963:br-gen-5263:16 s2_16_679964:br-gen-5204:16 s2_16_679965:br-gen-5001:16 s2_32_679962:br-gen-5204:32 s2_32_679963:br-gen-5263:32 s2_32_679964:br-gen-5204:32 s2_32_679965:br-gen-5001:32 smoke_s2_16_randomized:br-gen-5001:16; do
    IFS=: read -r n m s <<< "$t"
    (cd "$tree_parent" && taskset -c "$cpu" "$run_dir/replay-$arm" "$traces/$n.navsrc.txt" "$m" "$s" 1300 2>>"$run_dir/replay.stderr") | sed "s/^/$n /" >> "$run_dir/chains-$arm.txt"; record "replay-$arm-$n" $?
  done
done
diff "$run_dir/chains-parent.txt" "$run_dir/chains-candidate.txt" > "$run_dir/chains-diff.txt"; record chains-diff $?
python3 - "$run_dir/micro_results.jsonl" > "$run_dir/origin-equality.txt" <<'PY'
import json, sys
rows=[json.loads(l) for l in open(sys.argv[1])]; by={}
for r in rows: by.setdefault((r['map'], r['range_px']), []).append(r['origin_list'])
for k, lists in sorted(by.items()): print(k, 'origins_identical_across_runs_and_arms=', all(l == lists[0] for l in lists), 'count=', len(lists[0]))
PY
record origin-equality $?
sha256sum "$run_dir"/bench-* "$run_dir"/replay-* > "$run_dir/result-hashes.txt"; record result-hashes $?
printf 'C6 MICRO V2 DONE\n' > "$run_dir/DONE"; cat "$run_dir/exit-codes.txt"
