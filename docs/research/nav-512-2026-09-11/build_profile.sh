#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
python3 /prepare.py
nim=/root/.nimby/nim/bin/nim
$nim --version > /results/compiler.txt
for budget in 256 512; do
 sed "s/ColdPlanBudgetPerTick\* = 256/ColdPlanBudgetPerTick* = $budget/" /results/body_nav_base.nim > src/shell/body_nav.nim
 $nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime -d:ProfileTracePath=/results/profile.json -d:ProfileTicks=0 --nimcache:/tmp/nav512-profile-cache --out:/results/server-$budget src/ctf.nim > /results/build-profile-$budget.log 2>&1
 sha256sum /results/server-$budget > /results/profile-$budget.binary.sha256
done
cp /results/body_nav_base.nim src/shell/body_nav.nim
