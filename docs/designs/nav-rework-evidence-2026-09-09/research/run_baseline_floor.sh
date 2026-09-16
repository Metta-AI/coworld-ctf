#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH"
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/B0-floor"
mkdir -p "$run_dir"
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
git rev-parse HEAD > "$run_dir/source-head.txt"
lscpu > "$run_dir/lscpu.txt"
nim --version > "$run_dir/nim-version.txt"
sha256sum nimby.lock tests/fixtures/shell/nav_route_corpus.json > "$run_dir/input-hashes.txt"
cp src/shell/body_route_query.nim "$run_dir/body_route_query.original.nim"
trap 'cp "$run_dir/body_route_query.original.nim" src/shell/body_route_query.nim' EXIT
for budget in 0 256 512; do
  python3 - "$budget" "$run_dir/body_route_query.original.nim" <<'PY'
import sys,re,pathlib
text=pathlib.Path(sys.argv[2]).read_text()
text,n=re.subn(r'BodyRoutePopBudgetPerTick\* = [\d_]+',f'BodyRoutePopBudgetPerTick* = {sys.argv[1]}',text)
assert n==1
pathlib.Path('src/shell/body_route_query.nim').write_text(text)
PY
  git diff > "$run_dir/b${budget}.patch"
  nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -o:"$run_dir/bench-b${budget}" tools/bench_body_nav_rework.nim > "$run_dir/build-b${budget}.log" 2>&1
  sha256sum "$run_dir/bench-b${budget}" > "$run_dir/b${budget}-binary.sha256"
  for repeat in 1 2 3; do
    date -u > "$run_dir/b${budget}-r${repeat}-host.txt"
    uptime >> "$run_dir/b${budget}-r${repeat}-host.txt"
    ps -eo pid,pcpu,comm --sort=-pcpu | head -20 >> "$run_dir/b${budget}-r${repeat}-host.txt" || true
    set +e
    taskset -c 5 "$run_dir/bench-b${budget}" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/b${budget}-r${repeat}.json" 2> "$run_dir/b${budget}-r${repeat}.stderr"
    echo "$?" > "$run_dir/b${budget}-r${repeat}.exit"
    set -e
  done
  set +e
  "$run_dir/bench-b${budget}" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/b${budget}-burst.json" 2> "$run_dir/b${budget}-burst.stderr"
  echo "$?" > "$run_dir/b${budget}-burst.exit"
  set -e
  echo "BUDGET $budget DONE"
done
printf 'B0 FLOOR DONE\n' > "$run_dir/DONE"
