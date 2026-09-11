#!/bin/sh
set -eu
# Run as root only after the unprofiled H1 screen is complete.
results=/home/ubuntu/nav512-p1-results
mkdir -p "$results"
test ! -e "$results/game-r1-b512-s32"
cp /home/ubuntu/nav512-h1-results/parent/server-512 "$results/server-512"
cp /home/ubuntu/nav512-h1-results/parent/presence "$results/presence"
perf --version > "$results/perf-version.txt"
perf record -o "$results/perf.data" -e cpu-clock:u -F 99 -a -C 5 --call-graph dwarf -- sleep 150 > "$results/perf-record.log" 2>&1 &
sampler=$!
trap 'kill -INT "$sampler" 2>/dev/null || true' EXIT
sleep 1
kill -0 "$sampler"
docker run --rm --network host \
 -e WASMTIME_C_API=/wasmtime \
 -v /home/ubuntu/nav512-h1-parent:/workspace/ctf \
 -v "$results":/results \
 -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api:/wasmtime:ro \
 coworld-nav-budget:20260911 python3 /results/run_p1.py
kill -INT "$sampler"
sampler_status=0
wait "$sampler" || sampler_status=$?
printf '%s\n' "$sampler_status" > "$results/sampler-exit.txt"
trap - EXIT
case "$sampler_status" in 0|130|143) ;; *) exit "$sampler_status" ;; esac
mkdir -p "$results/symfs/results"
ln -s "$results/server-512" "$results/symfs/results/server-512"
perf report -i "$results/perf.data" --symfs "$results/symfs" --stdio --no-children --sort symbol --percent-limit 0.5 > "$results/perf-report-resolved.txt"
perf report -i "$results/perf.data" --symfs "$results/symfs" --stdio --no-children --call-graph none --sort symbol --percent-limit 0.2 > "$results/perf-flat.txt"
