# Intel c8i-flex qualification: PASS

All 24 games passed the frozen fleet card with full coverage and no faults.
Every variant repeats exactly and equals its same-budget m5a reference.
Claude independently reproduced every raw metric and confirmed the verdict.
All 12 individual pairs improved all four frame-time metrics.

Median paired candidate 512 / original 256 percent change:

| Workload | Placement | Total | p50 | p95 | Maximum | Worst misses, original → candidate |
|---|---|---:|---:|---:|---:|---:|
| map5001-s32-edge-r1050 | pinned | -12.0% | -6.8% | -25.9% | -6.5% | 3 → 2 |
| scale29-s32-moving-r1050 | pinned | -10.7% | -12.3% | -12.0% | -6.5% | 2 → 2 |
| map5001-s32-edge-r1050 | unpinned | -12.0% | -7.1% | -25.8% | -6.6% | 3 → 2 |
| scale29-s32-moving-r1050 | unpinned | -11.0% | -12.4% | -12.5% | -5.3% | 2 → 2 |

Host: owned c8i-flex.4xlarge, Intel Xeon 6975P-C, 8 cores / 16 threads,
same Docker image and binary bytes as AMD campaigns. Host metadata and
lifecycle CPU counters are archived. No run was filtered or replaced.

Limits remain the frozen card: two selected 32-seat workloads, pinned server
CPU 5 and normal scheduler placement, synthetic clients pinned to CPUs 6/7.
These are representative native hardware checks, not production contention
or deployment. Source default remains 256.

Exact raw records: c8i-raw.tar.gz with c8i-raw.sha256.

The peer found at most0.01 seconds of lifecycle CPU steal per game. This is
context, not proof that every form of frequency or flex throttling was absent.
No results were filtered. The peer review is C8I_PEER_VERDICT.md one level up.
