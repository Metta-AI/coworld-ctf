#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
for tool in bench_danger_replay check_danger_fullword_replay bench_body_danger_trace; do test ! -e "tools/$tool.nim"; done
run_dir="$HOME/nav-throughput-results-20260909/C6-micro"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original-nav.nim"
trap 'cp "$run_dir/original-nav.nim" src/shell/body_nav.nim; rm -f tools/bench_danger_replay.nim tools/check_danger_fullword_replay.nim tools/bench_body_danger_trace.nim' EXIT
for tool in bench_danger_replay check_danger_fullword_replay bench_body_danger_trace; do cp "$HOME/c6-input/$tool.nim" "tools/$tool.nim"; done
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/c6-input/"*.nim "$HOME/c6-input/traces/"*.txt > "$run_dir/input-hashes.txt"
for arm in parent candidate; do
 cp "$HOME/c6-input/$arm-body_nav.nim" src/shell/body_nav.nim
 git diff > "$run_dir/$arm.patch"
 for tool in bench_danger_replay check_danger_fullword_replay bench_body_danger_trace; do
  "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell "-d:DangerReplayArmLabel=$arm" --nimcache:"$run_dir/cache-$arm-$tool" -o:"$run_dir/$arm-$tool" "tools/$tool.nim" > "$run_dir/build-$arm-$tool.log" 2>&1
 done
 taskset -c 5 "$run_dir/$arm-check_danger_fullword_replay" > "$run_dir/$arm-correctness.json" 2> "$run_dir/$arm-correctness.stderr"
done
python3 - "$run_dir" <<'PYVERIFY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
a = json.loads((root / 'parent-correctness.json').read_text())['cases']
b = json.loads((root / 'candidate-correctness.json').read_text())['cases']
assert a == b and len(a) >= 5
assert all(row['cell_mismatches'] == 0 for row in a)
assert any(row['row_crossing_full_words'] > 0 for row in a if row['diameter'] == 327)
assert any(row['row_crossing_full_words'] > 0 for row in a if row['diameter'] < 64)
PYVERIFY
for repeat in 1 2 3 4 5; do
 if (( repeat % 2 )); then arms='parent candidate'; else arms='candidate parent'; fi
 for arm in $arms; do
  for map in br-gen-5120 br-gen-5204 br-gen-5263; do
   for range in 331 1300; do
    taskset -c 5 "$run_dir/$arm-bench_danger_replay" "$map" "$range" 97 5 4 > "$run_dir/$arm-$map-$range-r$repeat.json" 2> "$run_dir/$arm-$map-$range-r$repeat.stderr"
   done
  done
  if [ "$repeat" -le 3 ]; then
   for trace in "$HOME/c6-input/traces/"*.txt; do
    tag="$(basename "$trace" .navsrc.txt)"
    taskset -c 5 "$run_dir/$arm-bench_body_danger_trace" "$trace" > "$run_dir/$arm-trace-$tag-r$repeat.json" 2> "$run_dir/$arm-trace-$tag-r$repeat.stderr"
   done
  fi
 done
done
sha256sum "$run_dir/parent-bench_"* "$run_dir/candidate-bench_"* > "$run_dir/executable-hashes.txt"
printf 'C6 MICRO DONE\n' > "$run_dir/DONE"
