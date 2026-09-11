#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
python3 /prepare.py
nim=/root/.nimby/nim/bin/nim
$nim --version > /results/candidate/compiler.txt
for suite in test_shell_body_heap_exact test_shell_body_nav; do
 $nim c -r -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime --nimcache:/tmp/h1-test-cache --out:/tmp/$suite tests/$suite.nim > /results/candidate/$suite.log 2>&1
done
sed 's/ColdPlanBudgetPerTick\* = 256/ColdPlanBudgetPerTick* = 512/' src/shell/body_nav.nim > /tmp/body_nav_512.nim
cp /tmp/body_nav_512.nim src/shell/body_nav.nim
$nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime --nimcache:/tmp/h1-candidate-cache --out:/results/candidate/server-512 src/ctf.nim > /results/candidate/build-512.log 2>&1
sha256sum /results/candidate/server-512 > /results/candidate/server-512.sha256
