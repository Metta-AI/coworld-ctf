#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/bench_danger_list_replay.nim
test ! -e tools/check_danger_list_capture.nim
run_dir="$HOME/nav-throughput-results-20260909/C7-micro"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/c7-input/base.nim"
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim; rm -f tools/bench_danger_list_replay.nim tools/check_danger_list_capture.nim' EXIT
cp "$HOME/c7-input/bench_danger_list_replay.nim" tools/
cp "$HOME/c7-input/check_danger_list_capture.nim" tools/
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/c7-input/"*.nim > "$run_dir/input-hashes.txt"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
for arm in c2 c8; do
 cp "$HOME/c7-input/$arm.nim" src/shell/body_nav.nim
 git diff > "$run_dir/$arm.patch"
 for mode in bench check; do
  if [ "$mode" = bench ]; then tool=bench_danger_list_replay; else tool=check_danger_list_capture; fi
  set +e
  "$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -d:DangerReplayArmLabel="$arm" --nimcache:"$run_dir/cache-$arm-$mode" -o:"$run_dir/$mode-$arm" "tools/$tool.nim" > "$run_dir/build-$arm-$mode.log" 2>&1
  rc=$?
  set -e
  record "build-$arm-$mode" "$rc"
  test "$rc" -eq 0
 done
 taskset -c 5 "$run_dir/check-$arm" > "$run_dir/check-$arm.json" 2> "$run_dir/check-$arm.stderr"
 record "check-$arm" 0
done
for repeat in 1 2 3 4 5; do
 arms="c2 c8"
 if [ $((repeat % 2)) -eq 0 ]; then arms="c8 c2"; fi
 for arm in $arms; do
  for cfg in br-gen-5120:1300 br-gen-5120:331 br-gen-5204:1300 br-gen-5204:331 br-gen-5263:1300 br-gen-5263:331; do
   map_name="${cfg%%:*}"
   range_px="${cfg##*:}"
   taskset -c 5 "$run_dir/bench-$arm" "$map_name" "$range_px" 1400 5 20 > "$run_dir/$arm-$map_name-$range_px-r$repeat.json" 2> "$run_dir/$arm-$map_name-$range_px-r$repeat.stderr"
   record "$arm-$map_name-$range_px-r$repeat" 0
  done
 done
done
sha256sum "$run_dir/bench-"* "$run_dir/check-"c2 "$run_dir/check-"c8 > "$run_dir/executable-hashes.txt"
printf 'C7 MICRO DONE\n' > "$run_dir/DONE"
