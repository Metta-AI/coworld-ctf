#!/usr/bin/env bash
# Compile the starter playbook: EVERY reference play under play_sdk/reference/.
#
# The PoC's build script names its two plays explicitly; this one discovers
# them, so when a new reference play lands (target_law, bodyguard, jackal,
# supply_run, crossfire are expected), a rebuild bakes it automatically. The
# harness then refuses to start until policies/starters/common/plays.py
# carries a manifest row for it -- that pairing is the prompt/playbook drift
# guard.
#
# Usage:
#   ./build_playbook.sh [output-dir]
#
# WASI_SDK_PATH must point at wasi-sdk 33; when unset it is discovered via
# tools/runtime_spike/fetch_deps.sh, same as the rest of the repo.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
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

# A reference play is a .nim with a .nims build recipe beside it (the recipe
# carries the wasm32/wasi flags); panicoverride.nim and other support files
# have no recipe and are skipped by construction.
built=0
for recipe in play_sdk/reference/*.nims; do
  play="$(basename "$recipe" .nims)"
  echo "building $play"
  nim c -f --hints:off "play_sdk/reference/$play.nim"
  cp "play_sdk/.build/$play.wasm" "$out_dir/$play.wasm"
  built=$((built + 1))
done
if [ "$built" -eq 0 ]; then
  echo "no reference plays found under play_sdk/reference/" >&2
  exit 1
fi

echo "playbook in $out_dir:"
ls -l "$out_dir"/*.wasm
