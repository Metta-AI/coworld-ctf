#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
deps_dir=${RUNTIME_SPIKE_DEPS_DIR:-"$script_dir/.deps"}
checksums_file="$script_dir/checksums.txt"
mode=${1:-install}

case "$mode" in
  install|--verify-only)
    ;;
  *)
    echo "usage: $0 [--verify-only]" >&2
    exit 2
    ;;
esac

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    target=x86_64-linux
    wasi_target=x86_64-linux
    ;;
  Linux:aarch64|Linux:arm64)
    target=aarch64-linux
    wasi_target=arm64-linux
    ;;
  Darwin:x86_64)
    target=x86_64-macos
    wasi_target=x86_64-macos
    ;;
  Darwin:arm64|Darwin:aarch64)
    target=aarch64-macos
    wasi_target=arm64-macos
    ;;
  *)
    echo "unsupported runtime-spike host: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

wasmtime_archive="wasmtime-v48.0.1-$target-c-api.tar.xz"
wasi_archive="wasi-sdk-33.0-$wasi_target.tar.gz"
wasmtime_url="https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.1/$wasmtime_archive"
wasi_url="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/$wasi_archive"
archives_dir="$deps_dir/archives"
install_dir="$deps_dir/installed/$target"

expected_digest() {
  archive_name=$1
  digest=$(awk -v name="$archive_name" '$2 == name { print $1 }' "$checksums_file")
  if [ -z "$digest" ]; then
    echo "no pinned checksum for $archive_name" >&2
    exit 1
  fi
  printf '%s\n' "$digest"
}

actual_digest() {
  archive_path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive_path" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive_path" | awk '{ print $1 }'
  else
    echo "sha256sum or shasum is required" >&2
    exit 1
  fi
}

fetch_and_verify() {
  archive_name=$1
  archive_url=$2
  archive_path="$archives_dir/$archive_name"
  expected=$(expected_digest "$archive_name")

  if [ ! -f "$archive_path" ]; then
    partial_path="$archive_path.partial"
    curl --fail --location --show-error --output "$partial_path" "$archive_url"
    mv "$partial_path" "$archive_path"
  fi

  actual=$(actual_digest "$archive_path")
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $archive_name" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
  echo "verified $archive_name $actual"
}

mkdir -p "$archives_dir"
fetch_and_verify "$wasmtime_archive" "$wasmtime_url"
fetch_and_verify "$wasi_archive" "$wasi_url"

if [ "$mode" = "--verify-only" ]; then
  exit 0
fi

if [ ! -d "$install_dir/wasmtime-c-api" ]; then
  mkdir -p "$install_dir/wasmtime-c-api"
  tar -xJf "$archives_dir/$wasmtime_archive" \
    --strip-components=1 -C "$install_dir/wasmtime-c-api"
fi

if [ ! -d "$install_dir/wasi-sdk" ]; then
  mkdir -p "$install_dir/wasi-sdk"
  tar -xzf "$archives_dir/$wasi_archive" \
    --strip-components=1 -C "$install_dir/wasi-sdk"
fi

echo "WASMTIME_C_API=$install_dir/wasmtime-c-api"
echo "WASI_SDK_PATH=$install_dir/wasi-sdk"
