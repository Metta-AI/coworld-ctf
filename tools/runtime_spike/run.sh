#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
command_name=${1:-help}

usage() {
  cat <<'EOF'
usage: tools/runtime_spike/run.sh <command> [arguments]

commands:
  deps       download, verify, and extract the pinned toolchains
  toolchains sync nimby.lock and print the active compiler/toolchain versions
  smoke      phase 2 containment checks
  compile    phase 4 adversarial compile measurements
  memory     phase 3 pooling/RSS measurements
  tick       phase 5 isolated runtime-half worst-tick measurements
  all        phase 6 environment manifest + isolated/saturated rows
  help       show this message
EOF
}

host_target() {
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64) echo x86_64-linux ;;
    Linux:aarch64|Linux:arm64) echo aarch64-linux ;;
    Darwin:x86_64) echo x86_64-macos ;;
    Darwin:arm64|Darwin:aarch64) echo aarch64-macos ;;
    *)
      echo "unsupported runtime-spike host: $(uname -s) $(uname -m)" >&2
      exit 1
      ;;
  esac
}

build_smoke() {
  "$script_dir/fetch_deps.sh"
  target=$(host_target)
  deps_root=${RUNTIME_SPIKE_DEPS_DIR:-"$script_dir/.deps"}
  wasmtime_root="$deps_root/installed/$target/wasmtime-c-api"
  wasi_root="$deps_root/installed/$target/wasi-sdk"
  build_dir="$script_dir/.build"
  mkdir -p "$build_dir"

  WASI_SDK_PATH="$wasi_root" nim c "$script_dir/hello_play.nim"

  if [ "$(uname -s)" = Darwin ]; then
    nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on \
      --nimcache:"$build_dir/host-nimcache" \
      --passC:"-I$wasmtime_root/include" \
      --passC:"-I$script_dir" \
      --passL:"-L$wasmtime_root/lib" \
      --passL:-lwasmtime \
      --passL:"-Wl,-rpath,$wasmtime_root/lib" \
      --out:"$build_dir/runtime_spike" \
      "$script_dir/runtime_spike.nim"
    otool -L "$build_dir/runtime_spike" | grep -F libwasmtime
    otool -l "$build_dir/runtime_spike" | grep -F "$wasmtime_root/lib"
  else
    nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on \
      --nimcache:"$build_dir/host-nimcache" \
      --passC:"-I$wasmtime_root/include" \
      --passC:"-I$script_dir" \
      --passL:"-L$wasmtime_root/lib" \
      --passL:-lwasmtime \
      --passL:"-Wl,-rpath,$wasmtime_root/lib" \
      --out:"$build_dir/runtime_spike" \
      "$script_dir/runtime_spike.nim"
    ldd "$build_dir/runtime_spike" | grep -F libwasmtime
  fi
}

case "$command_name" in
  deps)
    shift
    exec "$script_dir/fetch_deps.sh" "$@"
    ;;
  toolchains)
    cd "$repo_root"
    nimby --global sync nimby.lock
    nim --version
    "$script_dir/fetch_deps.sh" --verify-only
    ;;
  smoke)
    shift
    if [ "$#" -ne 0 ]; then
      echo "usage: tools/runtime_spike/run.sh smoke" >&2
      exit 2
    fi
    build_smoke
    exec "$script_dir/.build/runtime_spike"
    ;;
  memory)
    shift
    build_smoke
    exec "$script_dir/.build/runtime_spike" memory "$@"
    ;;
  compile)
    shift
    build_smoke
    exec "$script_dir/.build/runtime_spike" compile "$@"
    ;;
  tick)
    shift
    build_smoke
    exec "$script_dir/.build/runtime_spike" tick "$@"
    ;;
  all)
    shift
    if [ "$#" -ne 0 ]; then
      echo "usage: tools/runtime_spike/run.sh all" >&2
      exit 2
    fi
    build_smoke
    exec "$script_dir/.build/runtime_spike" all
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
