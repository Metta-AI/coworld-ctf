#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
nim=/root/.nimby/nim/bin/nim
flags='-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime'
python3 docs/research/nav-512-2026-09-11/CROSS_ARCH/hypot_probe.py > /cross/native-hypot-grid.json
$nim c -r $flags --nimcache:/tmp/cross-probe --out:/tmp/fma-probe docs/research/nav-512-2026-09-11/CROSS_ARCH/fma_probe.nim > /cross/native-fma-probe.log 2>&1
$nim c -r $flags --nimcache:/tmp/cross-probe --out:/tmp/split-probe docs/research/nav-512-2026-09-11/CROSS_ARCH/split_digest.nim > /cross/native-split-digest.log 2>&1
