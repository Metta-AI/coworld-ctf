#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/coworld-nav-throughput-20260909"
run_dir="$HOME/nav-throughput-results-20260909/C0"
mkdir -p "$run_dir"
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api"
export LD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim_bin="$HOME/.nimby/nim-2.2.6/bin/nim"
git diff > "$run_dir/source.patch"
sha256sum Dockerfile nimby.lock src/shell/body_nav.nim src/shell/body_route_query.nim tools/bench_body_nav_rework.nim > "$run_dir/source-hashes.txt"
"$nim_bin" --version > "$run_dir/native-compiler.txt"
gcc --version >> "$run_dir/native-compiler.txt"
"$nim_bin" c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --nimcache:"$run_dir/cache-native" -o:"$run_dir/bench-native" tools/bench_body_nav_rework.nim > "$run_dir/build-native.log" 2>&1
sudo docker build --target build --build-arg NimMain=tools/bench_body_nav_rework.nim --tag coworld-nav-c0 . > "$run_dir/build-docker.log" 2>&1
image_id=$(sudo docker image inspect --format '{{.Id}}' coworld-nav-c0)
printf '%s\n' "$image_id" > "$run_dir/image-id.txt"
sudo docker run --rm "$image_id" sh -c 'nim --version; gcc --version' > "$run_dir/docker-compiler.txt"
for repeat in 1 2 3; do
  date -u > "$run_dir/r$repeat-host.txt"
  uptime >> "$run_dir/r$repeat-host.txt"
  set +e
  taskset -c 5 "$run_dir/bench-native" --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/native-r$repeat.json" 2> "$run_dir/native-r$repeat.stderr"
  echo "$?" > "$run_dir/native-r$repeat.exit"
  sudo docker run --rm --cpuset-cpus=5 --cpus=1 "$image_id" ./ctf --tick --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/docker-r$repeat.json" 2> "$run_dir/docker-r$repeat.stderr"
  echo "$?" > "$run_dir/docker-r$repeat.exit"
  set -e
done
set +e
sudo docker run --rm --cpuset-cpus=5 --cpus=1 "$image_id" ./ctf --quality --activation --corpus tests/fixtures/shell/nav_route_corpus.json > "$run_dir/docker-quality-activation.json" 2> "$run_dir/docker-quality-activation.stderr"
echo "$?" > "$run_dir/docker-quality-activation.exit"
set -e
printf 'C0 DONE\n' > "$run_dir/DONE"
