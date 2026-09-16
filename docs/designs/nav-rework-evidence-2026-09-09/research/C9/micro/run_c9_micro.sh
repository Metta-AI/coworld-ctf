#!/usr/bin/env bash
# C9 native conversion-cost micro (root runs only if needed after the C7
# corrected result). Tools only. Tree: a checkout carrying the frozen C2
# parent (C9/micro/snapshots/parent-body_nav.nim over src/shell/body_nav.nim)
# and tools/bench_danger_lazy_list.nim. No defines. Every exit code recorded.
# Screen limits (count-model, not acceptance): incremental conversion cost
# (conversion - bitmap)/bitmap <= 0.30 and list/bitmap <= 0.50 on every
# 1300 px map; 331 px reported under the same limits.
set -uo pipefail
tree="${C9_TREE:-$HOME/coworld-nav-source-cache-c2-parent}"
run_dir="${C9_RUN_DIR:-$HOME/nav-throughput-results-20260909/C9-micro}"
cpu="${C9_CPU:-5}"
if [ -e "$run_dir" ]; then echo "run dir exists" >&2; exit 2; fi
mkdir -p "$run_dir"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
NIM="$HOME/.nimby/nim-2.2.6/bin/nim"
FLAGS="-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on"
lscpu > "$run_dir/lscpu.txt"; record lscpu $?
( cd "$tree" && sha256sum src/shell/body_nav.nim tools/bench_danger_lazy_list.nim ) > "$run_dir/source-hashes.txt"; record source-hashes $?
( cd "$tree" && "$NIM" c $FLAGS --nimcache:"$run_dir/cache" -o:"$run_dir/bench" tools/bench_danger_lazy_list.nim ) > "$run_dir/build.log" 2>&1; record build $?
grep -c 'eqcopy\|eqdestroy' "$run_dir"/cache/*bench_danger_lazy_list.nim.c > "$run_dir/generated-c-owner-calls.txt" 2>&1; record generated-c-grep $?   # informational; per-function check is in C9_MICRO_READY.md
: > "$run_dir/micro_results.jsonl"
for round in 1 2 3 4 5; do
  for cfg in br-gen-5120:1300 br-gen-5204:1300 br-gen-5263:1300 br-gen-5001:1300 br-gen-5120:331 br-gen-5204:331 br-gen-5263:331 br-gen-5001:331; do
    m="${cfg%%:*}"; r="${cfg##*:}"
    out=$(cd "$tree" && taskset -c "$cpu" "$run_dir/bench" "$m" "$r" 1400 5 20 2>>"$run_dir/micro.stderr"); rc=$?
    record "micro-$m-$r-round$round" $rc
    printf '%s\n' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); d['round']=$round; print(json.dumps(d))" >> "$run_dir/micro_results.jsonl"
  done
done
python3 - "$run_dir/micro_results.jsonl" > "$run_dir/micro_table.txt" <<'PY'
import json, sys, statistics
rows=[json.loads(l) for l in open(sys.argv[1])]; by={}
for r in rows: by.setdefault((r['map'], r['range_px']), []).append(r)
for k in sorted(by, key=lambda k:(-k[1], k[0])):
    v=by[k]
    b=statistics.median(r['bitmap_ns_median'] for r in v); c=statistics.median(r['conversion_ns_median'] for r in v); l=statistics.median(r['list_ns_median'] for r in v)
    ok=all(r['set_mismatches']==0 and r['raster_mismatches']==0 and r['hashes_equal'] for r in v)
    print(k, 'bitmap_ns', round(b), 'conversion_ns', round(c), 'list_ns', round(l), 'incremental_conversion_cost', round((c-b)/b,3), 'list/bitmap', round(l/b,3), 'pass_screen', (c-b)/b <= 0.30 and l/b <= 0.50, 'exact', ok)
PY
record micro-table $?
printf 'C9 MICRO DONE\n' > "$run_dir/DONE"; cat "$run_dir/exit-codes.txt"
