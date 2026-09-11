#!/bin/sh
set -eu
cd /workspace/ctf
: "${WASMTIME_C_API:?Mount Wasmtime and set WASMTIME_C_API}"
: "${WASI_SDK_PATH:?Mount WASI SDK and set WASI_SDK_PATH}"
test -f /results/body_nav_base.nim
nimby --global sync nimby.lock
python3 /prepare.py
nim=/root/.nimby/nim/bin/nim
$nim c -f --hints:off play_sdk/reference/edge_ride.nim > /results/guest-build.log 2>&1
$nim c -d:release --hints:off --path:src -o:/results/presence tools/shell_presence.nim > /results/presence-build.log 2>&1
for budget in 256 512 1024; do
 sed "s/ColdPlanBudgetPerTick\* = 256/ColdPlanBudgetPerTick* = $budget/" /results/body_nav_base.nim > src/shell/body_nav.nim
 $nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime --nimcache:/tmp/server-budget-cache --out:/results/server-$budget src/ctf.nim > /results/server-build-$budget.log 2>&1
 sha256sum /results/server-$budget > /results/server-$budget.sha256
done
cp /results/body_nav_base.nim src/shell/body_nav.nim
