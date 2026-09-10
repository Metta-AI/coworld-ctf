#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = 872e5499c0161dd669ef0c0769a3ec3c5862e031
run_dir="$HOME/nav-throughput-results-20260909/C1-repaired"
test ! -e "$run_dir"
mkdir -p "$run_dir"
git rev-parse HEAD > "$run_dir/base-commit.txt"
lscpu > "$run_dir/lscpu.txt"
export WASMTIME_C_API="$HOME/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
"$HOME/.nimby/nim-2.2.6/bin/nim" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-native" -o:"$run_dir/bench-native" tools/bench_body_nav_rework.nim > "$run_dir/build-native.log" 2>&1
sudo -n docker buildx build --load --platform linux/amd64 --target build --build-arg NimMain=tools/bench_body_nav_rework.nim --build-arg 'NimFlags=-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on' --tag coworld-nav-c1:872e5499 . > "$run_dir/build-docker.log" 2>&1
sudo -n docker image inspect --format '{{.Id}}' coworld-nav-c1:872e5499 > "$run_dir/image-id.txt"
sudo -n docker run --rm coworld-nav-c1:872e5499 sh -c 'nim --version; gcc --version; sha256sum ./ctf' > "$run_dir/docker-toolchain.txt"
sha256sum "$run_dir/bench-native" > "$run_dir/native-binary-hash.txt"
for range in 331 1300; do
 for repeat in 1 2 3; do
  set +e
  taskset -c 5 "$run_dir/bench-native" --tick --tick-gun-range "$range" > "$run_dir/native-$range-r$repeat.json" 2> "$run_dir/native-$range-r$repeat.stderr"
  echo "$?" > "$run_dir/native-$range-r$repeat.exit"
  sudo -n docker run --rm --cpuset-cpus=5 --cpus=1 coworld-nav-c1:872e5499 ./ctf --tick --tick-gun-range "$range" > "$run_dir/docker-$range-r$repeat.json" 2> "$run_dir/docker-$range-r$repeat.stderr"
  echo "$?" > "$run_dir/docker-$range-r$repeat.exit"
  set -e
 done
done
set +e
sudo -n docker run --rm --cpuset-cpus=5 --cpus=1 coworld-nav-c1:872e5499 ./ctf --quality --activation > "$run_dir/docker-quality-activation.json" 2> "$run_dir/docker-quality-activation.stderr"
echo "$?" > "$run_dir/docker-quality-activation.exit"
set -e
printf 'C1 DONE\n' > "$run_dir/DONE"
