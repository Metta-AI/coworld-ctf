#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
nim=/root/.nimby/nim/bin/nim
flags='-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime'
if [ "$1" = candidate ]; then
 sed -i 's/ColdPlanBudgetPerTick\* = 512/ColdPlanBudgetPerTick* = 256/' src/shell/body_nav.nim
 for suite in test_shell_body_heap_exact test_shell_body_segment_exact test_shell_body_nav; do
  $nim c -r $flags --nimcache:/nimcache/checks --out:/tmp/$suite tests/$suite.nim > /results/$suite.log 2>&1
 done
fi
$nim c $flags --nimcache:/nimcache/checks --out:/tmp/memory-activation docs/research/nav-512-2026-09-11/qualification/memory_activation.nim > /results/memory-build.log 2>&1
/tmp/memory-activation docs/research/nav-512-2026-09-11/qualification/memory-scale29.json > /results/memory-scale29.log 2>&1
/tmp/memory-activation tests/fixtures/gen-colossal-4team.bitreplay > /results/memory-colossal.log 2>&1
