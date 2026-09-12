# Current-main m5a held-out result: PASS

All36 full games passed the frozen six-cell protocol. No frame, run or tail
was excluded. Base58e6c947 runtime sources remain unchanged through upstream
983880f5; candidate source is c651dec9. Source default remains256.

Percent change is the median of three paired candidate512/original256 ratios.

| Workload | Total | p50 | p95 | Maximum | Worst misses, original → candidate |
|---|---:|---:|---:|---:|---:|
| map505-s16-edge-r331 | -6.2% | -10.4% | -6.8% | -9.2% | 3 → 3 |
| map5001-s32-edge-r1050 | -15.1% | -7.3% | -32.5% | -8.8% | 57 → 8 |
| scale29-s32-edge-r497 | -13.2% | -18.5% | -13.8% | -9.5% | 352 → 228 |
| map505-s32-moving-r497 | -17.9% | -18.3% | -32.8% | -10.4% | 1008 → 600 |
| map5001-s16-moving-r331 | -17.4% | -23.8% | -37.7% | -8.3% | 10 → 1 |
| scale29-s32-moving-r1050 | -15.4% | -18.0% | -15.6% | -8.3% | 1061 → 834 |

Every individual pair improved all four frame-time metrics. All variants
repeat exactly within each workload. The separate12-game same-budget256
campaign established original/candidate exact semantic equality. No play fault
or incomplete coverage occurred. Six current-base training games passed first.

This is a comparative speed result, not a promise that every frame meets its
deadline: both32-seat moving stress workloads still have many late frames.
The moving play is suspended during existing reflex windows, which remain
included. Memory activation checks are separate from peak gameplay memory.

Raw54 games (12 correctness,6 training,36 held-out), logs and result JSONs
are preserved in raw-games.tar.gz with its sidecar hash. C6a pinned and unpinned qualification subsequently passed; Intel subsequently passed its four registered cells. No publication or default change has occurred.

Claude independently recomputed all36 raw-game metrics and confirmed the pass
(HELD_OUT_PEER_VERDICT.md). The raw archive sidecar was added while that review
ran, closing its remaining packaging observation.

Navigation diagnostic caveat: moving-cell stale seat-ticks rose at512
(13,623 vs9,285;6,883 vs4,745;8,232 vs6,360), while pending/no-path time fell
and movement counts rose (16,263 vs10,747;8,511 vs5,903;10,014 vs7,643).
More movement during frequent replanning is a plausible explanation, not a
proved causal decomposition or independent route-quality improvement. These
counters do not replace the same-budget exactness and route-legality checks.

STALE_COUNTER_REVIEW.md traces the exact counter definitions. Stale/no-path
are measured before planning; pending is measured afterward; movement records
direction bits from any source. These counters are not nested, and aggregates
cannot establish a per-request latency improvement. Same-budget512 exactness
was directly observed on training screens; held-out direct exactness used256.
Budget-independent mechanism proofs support preservation more broadly, but
that expectation must not be mislabeled as a held-out512 observation.
