DEVBOX (real x86_64, m6i.8xlarge, Intel Xeon Platinum 8375C @ 2.9 GHz, Nim 2.2.6 linux/amd64, flags -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on, harness pinned to ONE core with taskset), branch 7d374682, tools/bench_body_nav_rework --tick:

B=16,384: 16 seats first 11.79/14.13 ms, moving 13.86/22.21, stuck 12.92/13.49; 32 seats first 12.00/12.48, moving 14.77/15.74, stuck 12.43/13.13 (p95/max). All fail.
B=8,192:  16: first 6.29/6.34, moving 8.88/9.09, stuck 7.03/8.03; 32: first 6.56/7.68, moving 10.16/10.71, stuck 7.65/9.18. All fail.
B=4,096:  16: first 3.91/3.93 (pass), moving 6.15/6.85, stuck 4.49/7.29; 32: first 4.11/4.15, moving 7.44/7.69, stuck 7.79/8.12. Only 16-seat first goals passes.
Quality on real amd64: 3,072 scored, 0 missing, 0 illegal, pass, route hash 5a1340213fe3... identical to the Mac. Activation: pass.
Containment (HEAD, unpinned, 32 vCPU box): every wave ~9.54-9.64 ms max_body, scaled gate 5.63 ms, FAIL; origin/main baseline on the same box is being measured now, plus B=2,048/3,072/1,024 rows.

Interpretation (Claude): this core is ~3x slower per pop than the M4, so the Mac-native rows over-estimated what the pod can afford. The production budget must be chosen from these x86 rows. Even at 4,096 the moving-goal and stuck rows exceed 5 ms, and the uniform ~9.5 ms containment waves suggest a large fixed per-tick cost on x86 that is not the attack itself.

Requests to Codex (measurement-first, no fixture re-record yet):
1. Add a nav-vs-non-nav split to the tick harness rows (search ns, steering ns, rest-of-body ns) so we can see how much of the x86 tick is the search versus the base body work; Claude will rerun it on the devbox.
2. Investigate x86 per-pop cost: on the Mac it is ~185 ns; estimate it on x86 from pops/tick and the search ns; look for cache-hostile access in the 4 px dense arrays and the Dial buckets (workspace ~4.3 MB; the Xeon's per-core L2 is 1.25 MB), and try a compact active-node indexing for the fine nodes (only cells in the hot set + wall band get dense slots) if it reduces misses. Measure on the Mac, Claude re-measures on x86.
3. Do not re-record fixtures until the x86 rows at the chosen B pass; Claude will send the 2,048/3,072 rows and the main-branch containment baseline next.
