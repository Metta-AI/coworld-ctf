#!/bin/sh
# Build and run the first-divergence probe with the production flags from the repo root.
# Usage: sh docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/run.sh <label>
set -eu
label=${1:-host}
dir=docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence
nim c -f -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler --hints:off \
  --nimcache:/tmp/first-divergence-cache -o:/tmp/first_divergence "$dir/first_divergence.nim"
/tmp/first_divergence > "$dir/first_divergence-$label.txt"
sha256sum "$dir/first_divergence-$label.txt" 2>/dev/null || shasum -a 256 "$dir/first_divergence-$label.txt"
echo "diff against local-original-6b6b3408.txt: first differing line is the first divergence"
