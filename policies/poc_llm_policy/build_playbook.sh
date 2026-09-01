#!/usr/bin/env bash
# Compile the PoC's playbook -- the wasm play modules that get baked into the
# image and uploaded over the wire at match start.
#
# Both modules come from the repo's reference plays under play_sdk/reference/,
# built with the same wasi-sdk recipe the engine's own first-light demo uses
# (play_sdk/play.nims). Nothing here is PoC-specific: these are the shipped
# reference plays, compiled unchanged.
#
# Usage:
#   ./build_playbook.sh [output-dir]
#
# WASI_SDK_PATH must point at wasi-sdk 33. If it is unset, this script asks
# tools/runtime_spike/fetch_deps.sh for it, which is what the rest of the repo
# does; that path downloads and checksum-verifies the SDK on first use.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
out_dir="${1:-$script_dir/playbook}"

if [ -z "${WASI_SDK_PATH:-}" ]; then
  fetch_log="$(mktemp)"
  "$repo_root/tools/runtime_spike/fetch_deps.sh" >"$fetch_log"
  WASI_SDK_PATH="$(awk -F= '$1=="WASI_SDK_PATH"{print substr($0, index($0, "=") + 1)}' "$fetch_log")"
  rm -f "$fetch_log"
fi
if [ ! -x "$WASI_SDK_PATH/bin/clang" ]; then
  echo "WASI_SDK_PATH does not look like wasi-sdk 33: $WASI_SDK_PATH" >&2
  exit 1
fi
export WASI_SDK_PATH

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"   # the build below runs from the repo root
cd "$repo_root"

for play in edge_ride pact; do
  echo "building $play"
  nim c -f --hints:off "play_sdk/reference/$play.nim"
  cp "play_sdk/.build/$play.wasm" "$out_dir/$play.wasm"
done

echo "playbook in $out_dir:"
ls -l "$out_dir"/*.wasm
