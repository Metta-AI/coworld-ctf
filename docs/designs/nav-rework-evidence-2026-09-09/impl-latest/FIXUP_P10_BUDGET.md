P10 BUDGET CORRECTION (Claude, after reading p10-native-tick-b4096/b1024 and p10-canonical-body-nav-gate(-b1024).json).

Facts from your artifacts:
- Native integrated whole-body tick, B=4,096: all 6 rows pass; worst 32-seat moving_goals 3.251/3.427 ms. B=1,024: all pass; worst 2.283/2.339 ms.
- Canonical linux/amd64 (emulated on this arm64 host, 1 CPU): B=4,096 fails moving_goals at 16 and 32 seats (5.34/6.26, 7.68/8.19) and 32-seat stuck (4.04/4.84); B=1,024 STILL fails 32-seat moving_goals (4.84/7.64). PLAN_P10.md and PHASE_9_REPORT.md both label emulated absolute latencies provisional. Lowering B to 1,024 therefore did not make the canonical gate pass and it multiplies the route-latency tail by ~16x versus the ruled budget. That reduction is rejected.

James's ruling is the rule: build at 16,384; the INTEGRATED measurement decides, and the decisive integrated measurement is the native one (production is not emulated). Do this, in order:
1. Stop the current tests/tests.nim run at B=1,024 (it is for the wrong budget).
2. Measure the native integrated whole-body tick (the same p10-native-tick harness, 16 and 32 seats, first/moving/stuck) at B = 16,384, 8,192 and 4,096 (reuse the existing 4,096 artifact). Also record, per row, the nav share versus the non-nav share of the tick so the report can show what the search costs inside the whole tick.
3. Set the production budget to the LARGEST of those whose native worst row has p95 <= 3.6 ms and max <= 4.5 ms (headroom under the 4/5 ms gate). If 16,384 passes that screen, keep James's number. State the route-latency tail at the chosen B from the P10.0 tables (first-goal p50/p95/max at 16/32 seats).
4. Re-record the nine fixtures and rebuild the viewer at that B (masks depend on B), keeping GV63 unless main has moved past it (rerun tools/ci/check_gameversion.sh origin/main).
5. Full tests/tests.nim once, both compile shapes, one isolated containment pair.
6. Canonical Docker rerun: quality/activation/memory rows are canonical; report the emulated tick rows verbatim but labelled provisional/host-limited, with the nav-vs-non-nav split from step 2 alongside so a reader can see that the non-nav body work alone exceeds the emulated budget where it does. Do not lower B to satisfy emulated rows.
7. Update PHASE_10_REPORT.md (durable dir) with a "Budget correction" section: the 4,096 and 1,024 checkpoints, why they were made, why 1,024 is reverted, and the native tables. Then finish Phase 10 and continue into Phase 11 as before. Sentinels unchanged.
Also: the 256 MiB BodyNavigationRetainedCap must be justified in the report by the measured colossal total (state the number and the rounding), per James's ruling ("set above the measured full total").
