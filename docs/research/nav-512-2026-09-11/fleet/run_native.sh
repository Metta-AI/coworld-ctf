#!/bin/sh
set -eu
family=$1
nav_image_id=$(cat /home/ubuntu/nav512-main58-qualification/image-id.txt)
sudo docker run --rm --network host -e WASMTIME_C_API=/wasmtime \
 -v /home/ubuntu/nav512-main58-candidate:/workspace/ctf \
 -v /home/ubuntu/nav512-main58-results/parent:/original:ro \
 -v /home/ubuntu/nav512-main58-results/candidate:/candidate:ro \
 -v /home/ubuntu/nav512-main58-qualification:/reference:ro \
 -v /home/ubuntu/nav512-fleet-results:/fleet-results \
 -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api:/wasmtime:ro \
 "$nav_image_id" python3 docs/research/nav-512-2026-09-11/fleet/run.py "$family"
