#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/S1"
test -f "$HOME/nav-throughput-results-20260909/C0/DONE"
mkdir -p "$run_dir"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
cp "$HOME/nav-throughput-results-20260909/C0/bench-native" "$run_dir/bench-parent"
cp src/shell/body_route_query.nim "$run_dir/source-parent.nim"
trap 'cp "$run_dir/source-parent.nim" src/shell/body_route_query.nim' EXIT
python3 - <<'INNER'
from pathlib import Path
p=Path('src/shell/body_route_query.nim')
s=p.read_text(); assert s.count('let lower = floor(scaled).int') == 1
p.write_text(s.replace('let lower = floor(scaled).int','let lower = scaled.int'))
INNER
git diff > "$run_dir/source.patch"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-candidate" -o:"$run_dir/bench-candidate" tools/bench_body_nav_rework.nim > "$run_dir/build-candidate.log" 2>&1
sha256sum "$run_dir/bench-parent" "$run_dir/bench-candidate" > "$run_dir/binary-hashes.txt"
for repeat in 1 2 3; do
  for arm in parent candidate; do
    set +e
    taskset -c 5 "$run_dir/bench-$arm" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/$arm-r$repeat.json" 2> "$run_dir/$arm-r$repeat.stderr"
    echo "$?" > "$run_dir/$arm-r$repeat.exit"
    set -e
  done
done
set +e
taskset -c 5 "$run_dir/bench-candidate" --quality --activation --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/quality-activation.json" 2> "$run_dir/quality-activation.stderr"
echo "$?" > "$run_dir/quality-activation.exit"
set -e
printf 'S1 DONE\n' > "$run_dir/DONE"
