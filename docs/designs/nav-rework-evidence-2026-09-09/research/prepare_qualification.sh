#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH"
cd "$HOME/coworld-nav-throughput-20260909"
test -f "$HOME/nav-throughput-results-20260909/B0/DONE"
run_dir="$HOME/nav-throughput-results-20260909/QUALIFICATION"
mkdir -p "$run_dir" bin
sudo apt-get update > "$run_dir/apt.log" 2>&1
sudo apt-get install -y --no-install-recommends libudev-dev libevdev-dev libpcre3 netcat-openbsd >> "$run_dir/apt.log" 2>&1
# Match this source's CI pin. B0 deliberately used2.2.6 for the inherited comparison.
nimby use 2.2.10 > "$run_dir/compiler-setup.log" 2>&1
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export WASI_SDK_PATH="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasi-sdk"
export C_INCLUDE_PATH="$WASMTIME_C_API/include" LIBRARY_PATH="$WASMTIME_C_API/lib" LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim --version > "$run_dir/nim-version.txt"
nim check -d:noSignalHandler --threads:on src/ctf.nim > "$run_dir/server-linked-check.log" 2>&1
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim > "$run_dir/server-stub-check.log" 2>&1
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -d:ctfSimSourcesStamp="$(tools/sim_sources_stamp.sh)" --out:bin/ctf-server src/ctf.nim > "$run_dir/build-server.log" 2>&1
nim c -d:release -d:useMalloc -d:buildDefines="-d:release -d:useMalloc" --opt:speed --stackTrace:on --out:players/baseline/baseline.out players/baseline/baseline.nim > "$run_dir/build-baseline.log" 2>&1
for shard in 1 2 3 4; do
  nim c -d:release --hints:off -d:noSignalHandler --threads:on -d:useMalloc -o:"$run_dir/shard_$shard" "tests/shard_$shard.nim" > "$run_dir/build-shard_$shard.log" 2>&1 &
  shard_pids[$shard]=$!
done
failed=0
for shard in 1 2 3 4; do
  if wait "${shard_pids[$shard]}"; then echo 0 > "$run_dir/build-shard_$shard.exit"; else echo "$?" > "$run_dir/build-shard_$shard.exit"; failed=1; fi
done
if [ "$failed" != 0 ]; then exit 1; fi
printf 'QUALIFICATION PREP DONE\n' > "$run_dir/PREP_DONE"
