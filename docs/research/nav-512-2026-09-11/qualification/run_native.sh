#!/bin/sh
set -eu
phase=$1
sudo docker run --rm --network host -e WASMTIME_C_API=/wasmtime \
 -v /home/ubuntu/nav512-h3-candidate:/workspace/ctf \
 -v /home/ubuntu/nav512-h1-results/parent:/original:ro \
 -v /home/ubuntu/nav512-h3-results/candidate:/candidate:ro \
 -v /home/ubuntu/nav512-qualification-results:/qualification-results \
 -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api:/wasmtime:ro \
 coworld-nav-budget:20260911 python3 docs/research/nav-512-2026-09-11/qualification/run_campaign.py "$phase"
