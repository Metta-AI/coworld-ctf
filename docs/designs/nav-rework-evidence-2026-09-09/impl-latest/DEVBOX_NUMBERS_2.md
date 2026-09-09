DEVBOX x86 rows, finer budgets (same setup as DEVBOX_NUMBERS_1: one pinned Ice Lake core, p95/max ms, 16 seats then 32 seats):
B=1,024: first 2.15/2.17, moving 3.89/4.65, stuck 2.26/2.29 | first 2.41/3.75, moving 5.36/5.45 (FAIL), stuck 2.50/2.58
B=2,048: first 2.79/4.07, moving 4.61/5.28 (FAIL), stuck 2.96/3.12 | first 2.96/2.98, moving 6.12/6.28 (FAIL), stuck 3.28/3.37
B=3,072: first 3.32/3.39, moving 5.36/6.28 (FAIL), stuck 3.78/3.89 | first 3.56/3.61, moving 7.11/7.59 (FAIL), stuck 3.96/4.94
B=4,096: first 3.91/3.93, moving 6.15/6.85, stuck 4.49/7.29 | first 4.11/4.15, moving 7.44/7.69, stuck 7.79/8.12

Two findings that decide what to fix:
1. Budget-independent floor. Extrapolating first_goals to B=0 gives a non-search body cost of roughly 1.7 ms (16 seats) / 2.0 ms (32 seats) on this core. So the search can have about 2-3 ms per tick here, i.e. B in the 2,048-3,072 range for the first/stuck rows.
2. moving_goals carries a large cost that does NOT scale with B: at B=1,024 it is +1.7 ms (16 seats) / +3.0 ms (32 seats) over first_goals. With replans every 12 ticks that is ~1 ms per replan REQUEST outside the pop budget: endpoint attach (ring scan + exact connectors), SJF estimate, restart handling, per-seat weight-table refresh at the danger generation (172k int16 entries per seat), descriptor reconstruction + validateBodyRoute + install. This is the thing to profile and shrink; it decides whether any B passes the moving-goals row on x86.
3. Containment on HEAD, pinned to 4 cores: max_body 9.36 ms, essentially identical to unpinned (9.6) and uniform across waves: a fixed per-tick cost. The origin/main baseline on the same box is being built now; if main is similar, the containment gate is host-calibrated and not attributable to nav; if main is much lower, something in the cutover added a fixed cost to input-only episodes.

Requests (measurement first, then fix, own commits):
a. Instrument the tick harness rows with the split: search pops ns, per-request overhead ns (attach, SJF, restart, reconstruct/validate/install), weight/hot-set refresh ns, steering ns, rest-of-body ns. Claude reruns on x86.
b. Profile and cut the per-request overhead: candidates — validateBodyRoute re-walking the full route with exact segmentClear on install (make it a debug-only assertion or check only the reconstructed fine segments), the ring-scan attach doing pixel segmentClear per candidate, the per-seat 4 px weight table rebuilt wholesale at every danger generation (rebuild only hot cells; the cold anchors need only the 8 px value), SJF octile estimate cost (trivial), and any per-request allocation. Target: per-request overhead <= 100 us.
c. Then Claude picks B from x86 rows again. Expect B around 2,048-3,072 if (b) succeeds; report the route-latency tail at that B from the P10.0 tables.

UPDATE — containment baseline on the SAME devbox: origin/main max_body_us = 16,353 unpinned and 16,057 pinned to 4 cores (scaled gate 5,636), body_pass=false; worst waves stack_recursion 16,353 / trap 16,311 / call_free_loop 15,971. HEAD was 9,644 unpinned / 9,358 pinned. So on real x86 the containment body gate fails on main by ~3x and HEAD is ~40 % cheaper than main; the ~9.4 ms fixed cost is the existing body/activation work on this hardware, not a nav regression. Treat the containment gate as host-calibrated evidence (pair it with main), never as a nav pass/fail on x86.

When the split instrumentation and the per-request overhead fix are ready, end that reply with the literal line X86 OVERHEAD DONE (before finishing Phase 10), so Claude can rerun the x86 rows and pick B.
