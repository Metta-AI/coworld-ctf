#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test ! -e tools/bench_danger_lazy_list.nim
run_dir="$HOME/nav-throughput-results-20260909/C9-micro"
test ! -e "$run_dir"
mkdir -p "$run_dir"
cp src/shell/body_nav.nim "$run_dir/original.nim"
cmp "$run_dir/original.nim" "$HOME/c9-input/base.nim"
trap 'cp "$run_dir/original.nim" src/shell/body_nav.nim; rm -f tools/bench_danger_lazy_list.nim' EXIT
cp "$HOME/c9-input/parent-body_nav.nim" src/shell/body_nav.nim
cp "$HOME/c9-input/bench_danger_lazy_list.nim" tools/
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
sha256sum "$HOME/c9-input/"*.nim > "$run_dir/input-hashes.txt"
git diff > "$run_dir/parent.patch"
record() { printf '%s exit=%s\n' "$1" "$2" >> "$run_dir/exit-codes.txt"; }
set +e
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache" -o:"$run_dir/bench" tools/bench_danger_lazy_list.nim > "$run_dir/build.log" 2>&1
rc=$?
set -e
record build "$rc"
test "$rc" -eq 0
for repeat in 1 2 3 4 5; do
 for cfg in br-gen-5120:1300 br-gen-5204:1300 br-gen-5263:1300 br-gen-5001:1300 br-gen-5120:331 br-gen-5204:331 br-gen-5263:331 br-gen-5001:331; do
  map_name="${cfg%%:*}"
  range_px="${cfg##*:}"
  set +e
  taskset -c 5 "$run_dir/bench" "$map_name" "$range_px" 1400 5 20 > "$run_dir/$map_name-$range_px-r$repeat.json" 2> "$run_dir/$map_name-$range_px-r$repeat.stderr"
  rc=$?
  set -e
  record "$map_name-$range_px-r$repeat" "$rc"
  test "$rc" -eq 0
 done
done
sha256sum "$run_dir/bench" > "$run_dir/executable-hashes.txt"
printf 'C9 MICRO DONE\n' > "$run_dir/DONE"
