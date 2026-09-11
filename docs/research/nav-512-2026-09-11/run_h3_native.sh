#!/bin/sh
set -eu
sudo docker run --rm --network host \
 -e WASMTIME_C_API=/wasmtime \
 -v /home/ubuntu/nav512-h1-parent:/workspace/ctf \
 -v /home/ubuntu/nav512-h3-results:/results \
 -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api:/wasmtime:ro \
 coworld-nav-budget:20260911 python3 /results/run_h3.py
