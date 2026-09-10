#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
for tool in c10_replay check_c10_replay bench_c10_replay; do
 test ! -e "tools/$tool.nim"
done
run_dir="$HOME/nav-throughput-results-20260909/C10-micro"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original-body_nav.nim"
cmp "$run_dir/original-body_nav.nim" "$HOME/c10-input/base-body_nav.nim"
trap 'cp "$run_dir/original-body_nav.nim" src/shell/body_nav.nim; rm -f tools/c10_replay.nim tools/check_c10_replay.nim tools/bench_c10_replay.nim' EXIT
cp "$HOME/c10-input/parent-body_nav.nim" src/shell/body_nav.nim
for tool in c10_replay check_c10_replay bench_c10_replay; do
 cp "$HOME/c10-input/$tool.nim" tools/
done
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
git diff > "$run_dir/parent-overlay.patch"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/c10-input/"*.nim > "$run_dir/input-hashes.txt"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
"$nim_bin" --version > "$run_dir/nim-version.txt"
"$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell --nimcache:"$run_dir/cache-correctness" -o:"$run_dir/check" tools/check_c10_replay.nim > "$run_dir/build-correctness.log" 2>&1
taskset -c 5 "$run_dir/check" > "$run_dir/correctness.json" 2> "$run_dir/correctness.stderr"
for arm in parent scalar simd; do
 "$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell -d:DangerReplayArmLabel="$arm" --nimcache:"$run_dir/cache-$arm" -o:"$run_dir/bench-$arm" tools/bench_c10_replay.nim > "$run_dir/build-$arm.log" 2>&1
done
for repeat in 1 2 3 4 5; do
 case "$repeat" in
  1) arms="parent scalar simd" ;;
  2) arms="scalar simd parent" ;;
  3) arms="simd parent scalar" ;;
  4) arms="simd scalar parent" ;;
  5) arms="parent simd scalar" ;;
 esac
 for arm in $arms; do
  for map in br-gen-5120 br-gen-5204 br-gen-5263; do
   for range in 331 1300; do
    taskset -c 5 "$run_dir/bench-$arm" "$map" "$range" 97 5 4 > "$run_dir/$arm-$map-$range-r$repeat.json" 2> "$run_dir/$arm-$map-$range-r$repeat.stderr"
   done
  done
 done
done
sha256sum "$run_dir/bench-parent" "$run_dir/bench-scalar" "$run_dir/bench-simd" "$run_dir/check" > "$run_dir/executable-hashes.txt"
printf 'C10 MICRO DONE\n' > "$run_dir/DONE"
