# c6a qualification: PASS

All 24 games passed the frozen fleet card, with full coverage and no faults.
Each variant repeats exactly and equals its same-budget m5a behavior reference.
Claude independently reproduced every raw metric and the verdict.

Median paired candidate 512 / original 256 percent change:

| Workload | Placement | Total | p50 | p95 | Maximum | Worst misses, original → candidate |
|---|---|---:|---:|---:|---:|---:|
| map5001-s32-edge-r1050 | pinned | -13.2% | -6.8% | -23.8% | -10.6% | 3 → 3 |
| scale29-s32-moving-r1050 | pinned | -10.5% | -11.0% | -11.0% | -9.6% | 4 → 2 |
| map5001-s32-edge-r1050 | unpinned | -11.4% | -4.8% | -22.6% | -10.3% | 3 → 3 |
| scale29-s32-moving-r1050 | unpinned | -10.3% | -10.6% | -10.8% | -9.8% | 3 → 2 |

All 12 individual pairs improve all four metrics. Host: owned c6a.4xlarge,
AMD EPYC 7R13,8 cores / 16 threads, glibc 2.36, unchanged Docker image and binary bytes.
Full topology and lifecycle CPU counters are in the raw archive; recorded
steal is at most 0.01 seconds per game. These counters cover process lifecycle,
not just playing. No result is filtered by them.

Limits: two 32-seat workloads, synthetic presence clients pinned to CPUs 6/7,
both pinned server CPU 5 and ordinary scheduler placement. No production contention
or deployment is reproduced. The Intel family subsequently passed its four registered cells.

Peer minor-note correction: host.json DOES carry the image digest, nested at
instance.image_id. It is also present in the standalone instance record.

Exact raw records: c6a-raw.tar.gz with c6a-raw.sha256.
