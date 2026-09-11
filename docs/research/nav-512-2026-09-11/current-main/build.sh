#!/bin/sh
set -eu
cd /workspace/ctf
nimby --global sync nimby.lock
python3 docs/reports/nav-budget-screen-2026-09-11/prepare_native.py
nim=/root/.nimby/nim/bin/nim
flags='-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -d:shellStaticWasmtime'
$nim --version > /results/compiler.txt
gcc --version > /results/gcc-version.txt
for budget in "$@"; do
 python3 - "$budget" <<'PY'
from pathlib import Path
import re,sys
p=Path('src/shell/body_nav.nim');s=p.read_text()
s,count=re.subn(r'ColdPlanBudgetPerTick\* = (256|512)', 'ColdPlanBudgetPerTick* = '+sys.argv[1],s)
assert count==1
p.write_text(s)
PY
 sha256sum src/shell/*.nim src/ctf/server.nim src/ctf/glory.nim nimby.lock > /results/source-$budget.sha256
 $nim c $flags --nimcache:/nimcache/server --out:/results/server-$budget src/ctf.nim > /results/build-$budget.log 2>&1
 sha256sum /results/server-$budget > /results/server-$budget.sha256
 done
