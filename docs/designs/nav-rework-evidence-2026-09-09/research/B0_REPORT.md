# B0: corrected inherited Xeon baseline

Source `20234cc7`; m6i.8xlarge Xeon 8375C; CPU5 pin; three fresh processes per budget,
six sequential scenarios per process, 120 measured ticks per scenario after five warmups.
All registered pinned runs are included. The existing live tournament remained running.

| Pops/tick | Worst p95 ms | Worst max ms | 3.6/4.5 headroom | 4/5 tick gate |
|---:|---:|---:|:---:|:---:|
| 1024 | 2.541656 | 2.785248 | PASS | PASS |
| 2048 | 3.506657 | 4.994589 | FAIL | PASS |
| 3072 | 4.217238 | 5.597279 | FAIL | FAIL |
| 4096 | 4.996292 | 5.158245 | FAIL | FAIL |

Largest tested headroom-passing budget: **1,024**. Largest tested 4/5-passing budget: **2,048**.
These are different decisions. Neither is a complete production qualification or a proof of maximum capacity.
B0 uses the existing breakdown clocks and one map; first_goals resets life every tick.
Completion latency, instrumentation-off checks, current production instance types, full quality,
memory/determinism and remaining Phase 10/11 gates remain outstanding.

Raw rows and weighted search ns/pop are in B0_SUMMARY.json; unpinned burst files remain informational.
No confidence interval or stable speedup claim is inferred from only three processes.
