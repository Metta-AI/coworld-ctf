#!/usr/bin/env bash
# Compile and RUN a native test module against the wasm32 target, inside the
# same pinned emsdk+nim toolchain the shipped viewer is built with.
#
# Why this exists separately from tools/wasm_replay_smoke.cjs: that script
# exercises the shipped BUNDLE end to end, which only covers arithmetic a
# fixture replay happens to reach. The geometry kernels carry their own
# wasm32 hazard notes — src/ctf/hex.nim's half-plane products and
# map_art.nim's distance transform both document magnitudes that clear int32
# by a bounded factor — and the tests that pin those magnitudes run 64-bit in
# CI, where `int` is 64 bits and the trap they guard against cannot fire.
# A test that passes natively proves nothing about either.
#
# Usage:
#   tools/wasm_unit_smoke.sh                     # default: the hex kernel
#   tools/wasm_unit_smoke.sh tests/test_hex.nim tests/test_render_scale.nim
#
# Requires docker. Builds the toolchain image from Dockerfile.replay-viewer
# (cached after the first run).

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

# Only modules whose import graph is free of the SERVER dependencies can be
# built for wasm at all: anything reaching `ctf/global` pulls in mummy, which
# refuses to compile without --threads:on. That rules out test_render_scale
# (pure arithmetic, adequately covered by the native suite) and leaves the
# geometry kernel, which is exactly the one with the int32 hazard.
modules=("$@")
if [[ "${#modules[@]}" -eq 0 ]]; then
  modules=(tests/test_hex.nim)
fi

image_tag="coworld-ctf-wasm-unit-smoke"
docker build --platform linux/amd64 \
  --file "${repo_dir}/Dockerfile.replay-viewer" \
  --target replay-viewer-builder \
  --tag "${image_tag}" "${repo_dir}" >/dev/null

fail=0
for module in "${modules[@]}"; do
  echo "=== wasm32: ${module} ==="
  # -d:release matches the shipped viewer (replay-viewer/config.nims), so the
  # check configuration under test is the one that actually ships.
  if ! docker run --rm --platform linux/amd64 -w /workspace/ctf "${image_tag}" \
      bash -c "export PATH=/root/.nimby/nim/bin:\$PATH; \
        nim c --os:linux --cpu:wasm32 --cc:clang \
          --clang.exe:emcc --clang.linkerexe:emcc \
          --mm:arc --exceptions:goto -d:noSignalHandler -d:release \
          -d:useMalloc --threads:off --hints:off --path:src \
          --nimcache:/tmp/nc-\$\$ -o:/tmp/unit-\$\$.js \
          --passL:'-s ALLOW_MEMORY_GROWTH -s ENVIRONMENT=node -s EXIT_RUNTIME=1' \
          ${module} >/dev/null && node /tmp/unit-\$\$.js"; then
    echo "FAIL: ${module} did not pass under wasm32"
    fail=1
  fi
done

exit "${fail}"
