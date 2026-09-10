#!/usr/bin/env bash
# C7 native micro (root runs, m8i CPU 5). Tools only; no production source
# change. Two bitmap arms from the frozen C8 snapshots copied over
# src/shell/body_nav.nim in two checkouts: C7_TREE_C2 (C8/snapshots/parent =
# frozen C2 plus inert C5 markers) and C7_TREE_C8 (C8/snapshots/candidate =
# zero-weight omission). Each build times the production bitmap replay of its
# source AND the diagnostic ray-order nonzero list replay on the same C6 v2
# evenly spread origins. Labels are tools-only strdefines. Exit codes recorded.
set -uo pipefail
tree_c2="${C7_TREE_C2:-$HOME/coworld-nav-source-cache-c8-parent}"
tree_c8="${C7_TREE_C8:-$HOME/coworld-nav-source-cache-c8-candidate}"
run_dir="${C7_RUN_DIR:-$HOME/nav-throughput-results-20260909/C7-micro}"
cpu="${C7_CPU:-5}"
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
for arm in c2 c8; do
  if [ "$arm" = c2 ]; then tree="$tree_c2"; else tree="$tree_c8"; fi
  ( cd "$tree" && sha256sum src/shell/body_nav.nim tools/bench_danger_list_replay.nim tools/check_danger_list_capture.nim ) > "$run_dir/source-hashes-$arm.txt"; record "source-hashes-$arm" $?
  ( cd "$tree" && "$NIM" c $FLAGS -d:DangerReplayArmLabel=$arm --nimcache:"$run_dir/cache-bench-$arm" -o:"$run_dir/bench-$arm" tools/bench_danger_list_replay.nim ) > "$run_dir/build-bench-$arm.log" 2>&1; record "build-bench-$arm" $?
  ( cd "$tree" && "$NIM" c -d:release --hints:off -d:DangerReplayArmLabel=$arm -o:"$run_dir/check-$arm" tools/check_danger_list_capture.nim && "$run_dir/check-$arm" > "$run_dir/check-$arm.json" ) > "$run_dir/build-check-$arm.log" 2>&1; record "check-$arm" $?
done
: > "$run_dir/micro_results.jsonl"
for round in 1 2 3 4 5; do
  for arm in c2 c8; do
    if [ "$arm" = c2 ]; then tree="$tree_c2"; else tree="$tree_c8"; fi
    for cfg in br-gen-5120:1300 br-gen-5120:331 br-gen-5204:1300 br-gen-5204:331 br-gen-5263:1300 br-gen-5263:331; do
      m="${cfg%%:*}"; r="${cfg##*:}"
      out=$(cd "$tree" && taskset -c "$cpu" "$run_dir/bench-$arm" "$m" "$r" 1400 5 20 2>>"$run_dir/micro.stderr"); rc=$?
      record "micro-$arm-$m-$r-round$round" $rc
      printf '%s\n' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); d['round']=$round; print(json.dumps(d))" >> "$run_dir/micro_results.jsonl"
    done
  done
done
python3 - "$run_dir/micro_results.jsonl" > "$run_dir/micro_table.txt" <<'PY'
import json, sys, statistics
rows=[json.loads(l) for l in open(sys.argv[1])]; by={}
for r in rows: by.setdefault((r['map'], r['range_px']), {}).setdefault(r['bitmap_arm'], []).append(r)
for k in sorted(by):
    c2=by[k]['c2']; c8=by[k]['c8']
    c2b=statistics.median(r['bitmap_per_replay_ns_median'] for r in c2); c8b=statistics.median(r['bitmap_per_replay_ns_median'] for r in c8)
    lst=statistics.median(r['list_per_replay_ns_median'] for r in c2+c8)
    ok=all(r['set_mismatches']==0 and r['raster_mismatches']==0 and r['hashes_equal'] for r in c2+c8)
    oeq=all(r['origin_list']==c2[0]['origin_list'] for r in c2+c8)
    print(k, 'C2_bitmap_ns', round(c2b), 'C8_bitmap_ns', round(c8b), 'list_ns', round(lst), 'list/C2', round(lst/c2b,3), 'list/C8', round(lst/c8b,3), 'C8/C2', round(c8b/c2b,3), 'exact', ok, 'origins_equal', oeq)
PY
record micro-table $?
printf 'C7 MICRO DONE\n' > "$run_dir/DONE"; cat "$run_dir/exit-codes.txt"
