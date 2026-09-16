#!/bin/bash
# TEMPORARY: run the bounded trace batch sequentially (CACHE_TRACE_PLAN.md).
set -uo pipefail
cd "$(dirname "$0")/.."
E=docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace
port=21901
for seats in 16 32; do
  for seed in 679962 679963 679964; do
    tag="s2_${seats}_${seed}"
    echo "=== $tag port $port $(date -u +%FT%TZ)"
    NAVSRC_WAIT_LIMIT_S=2400 tools/nav_source_trace_run.sh "$E/cfg_${tag}.json" "$tag" "$port" || echo "run $tag FAILED exit $?"
    port=$((port + 1))
  done
done
echo "BATCH DONE $(date -u +%FT%TZ)"
