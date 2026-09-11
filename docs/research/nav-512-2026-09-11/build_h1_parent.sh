#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
python3 /prepare.py
nim=/root/.nimby/nim/bin/nim
$nim --version > /results/parent/compiler.txt
for budget in 256 512; do
 sed "s/ColdPlanBudgetPerTick\* = 256/ColdPlanBudgetPerTick* = $budget/" /results/parent/body_nav_base.nim > src/shell/body_nav.nim
 $nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime --nimcache:/tmp/h1-parent-cache --out:/results/parent/server-$budget src/ctf.nim > /results/parent/build-$budget.log 2>&1
 sha256sum /results/parent/server-$budget > /results/parent/server-$budget.sha256
done
cp /results/parent/body_nav_base.nim src/shell/body_nav.nim
