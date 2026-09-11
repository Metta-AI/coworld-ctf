#!/bin/sh
set -eu
nim=/root/.nimby/nim/bin/nim
flags='-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime'
cd /parent
nimby --global sync nimby.lock
$nim c -r $flags -d:expectLeafFrame --nimcache:/tmp/h3-parent-checks --out:/tmp/h3-parent-diagnostic docs/research/nav-512-2026-09-11/H3/diagnostic_probe.nim > /results/parent/diagnostic.log 2>&1
$nim c -r $flags --nimcache:/tmp/h3-parent-checks --out:/tmp/h3-parent-fingerprints docs/research/nav-512-2026-09-11/H1/crossbuild_fingerprints.nim > /results/parent/fingerprints.log 2>&1
cd /workspace/ctf
nimby --global sync nimby.lock
python3 /prepare.py
$nim --version > /results/candidate/compiler.txt
gcc --version > /results/candidate/gcc-version.txt
for suite in test_shell_body_heap_exact test_shell_body_segment_exact test_shell_body_nav; do
 $nim c -r $flags --nimcache:/tmp/h3-test-cache --out:/tmp/$suite tests/$suite.nim > /results/candidate/$suite.log 2>&1
done
$nim c -r $flags --nimcache:/tmp/h3-test-cache --out:/tmp/h3-diagnostic docs/research/nav-512-2026-09-11/H3/diagnostic_probe.nim > /results/candidate/diagnostic.log 2>&1
$nim c -r $flags --nimcache:/tmp/h3-test-cache --out:/tmp/h3-fingerprints docs/research/nav-512-2026-09-11/H1/crossbuild_fingerprints.nim > /results/candidate/fingerprints.log 2>&1
python3 - <<'PY'
from pathlib import Path
import re
parent=re.search(r'^ticks=.*$',Path('/results/parent/fingerprints.log').read_text(),re.M).group()
candidate=re.search(r'^ticks=.*$',Path('/results/candidate/fingerprints.log').read_text(),re.M).group()
assert parent==candidate,(parent,candidate)
Path('/results/fingerprint-parity.txt').write_text(parent+'\n')
PY
sed 's/ColdPlanBudgetPerTick\* = 256/ColdPlanBudgetPerTick* = 512/' src/shell/body_nav.nim > /tmp/body_nav_512.nim
cp /tmp/body_nav_512.nim src/shell/body_nav.nim
$nim c $flags --nimcache:/nimcache/server --out:/results/candidate/server-512 src/ctf.nim > /results/candidate/build-512.log 2>&1
sha256sum /results/candidate/server-512 > /results/candidate/server-512.sha256
