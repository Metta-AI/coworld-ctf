# WF0: exact wavefront danger screen rejected

The isolated candidate reproduces the reference danger raster and maximum bit for bit in all 14 sampled configurations, but loses on 13 of 14 m5a rows. Do not integrate this implementation into production.

## Measurement

Native m5a.4xlarge, EPYC 7571, CPU 5, Nim 2.2.6/GCC 11.4; parent source 067a4af2. Seven maps at each of 331 and 1300 px gun range, one seeded source configuration per map/range, 30 interleaved reference/candidate rebuilds. Reference calls the real rebuildDanger; the candidate uses its selected sources and includes raster clear, close floor and maximum scan. Reference source selection is included only in its arm. Geometry construction is outside rebuild timing and reported separately. This is a diagnostic screen, not a whole-body or general equivalence gate.

| Map | Range px | Parent p95 ms | Candidate p95 ms | Candidate / parent |
| --- | ---: | ---: | ---: | ---: |
| pool:0 | 331 | 1.877082 | 2.182780 | 1.163 |
| pool:29 | 331 | 1.804720 | 2.168300 | 1.201 |
| pool:48 | 331 | 1.893702 | 2.204221 | 1.164 |
| configured:0 | 331 | 2.118988 | 2.292333 | 1.082 |
| configured:5 | 331 | 1.915843 | 2.419957 | 1.263 |
| configured:10 | 331 | 1.973945 | 2.498909 | 1.266 |
| colossal | 331 | 4.323620 | 4.011822 | 0.928 |
| pool:0 | 1300 | 6.278354 | 16.923550 | 2.696 |
| pool:29 | 1300 | 6.665715 | 21.154297 | 3.174 |
| pool:48 | 1300 | 6.222133 | 17.459585 | 2.806 |
| configured:0 | 1300 | 6.986954 | 24.943133 | 3.570 |
| configured:5 | 1300 | 6.968734 | 20.790277 | 2.983 |
| configured:10 | 1300 | 6.654475 | 19.773019 | 2.971 |
| colossal | 1300 | 12.813800 | 25.532006 | 1.993 |

At 331 px, six maps regress and only colossal improves. At 1300 px, all seven regress by 1.99–3.57x. The Mac peer run passes the same differential checks and has a more favorable 331 px pattern; it does not override the bottleneck-host result. The likely cause is scanning inactive shell cells after walls have killed most rays. This is an inference from the algorithm and range-dependent result, not a measured hardware-counter attribution.

Extra diagnostic geometry is 272,320 bytes at radius 42 and 4,032,480 bytes at radius 163, excluding the separately reported active-ray words. These are ordinary-integer prototype allocations, not a production ledger or justification for another memory-cap increase. Production source and the 32 MiB shared non-colossal cap are unchanged by WF0.

## Reproduction and artifacts

`tools/bench_body_danger_wavefront.nim` contains the screen. `run_wf0_screen.sh` records exact build/run commands. `WF0-screen-m5a/` retains JSON samples, stderr, exit status, source copy/hash, executable hash, compiler log, base commit and CPU inventory. The native executable and cache remain local/remote build artifacts, not committed evidence. `WF0_SCREEN_CODE_REVIEW.md` and `peer-proofs/wf0_screen_local_mac.json` record independent review and the Mac differential run. The preregistration is `WF0_SCREEN_PREREG.md`.

A follow-up must have a concrete work-reduction argument and its own preregistration; simply compressing this geometry will not establish a speed gain. Root asked the peer to evaluate bounded active-shell work and exact zero-contribution tail pruning before another screen.

## Documentation audit

The new tool is an isolated research diagnostic, documented here and in its preregistration. No gameplay API, configuration, runtime behavior, visibility semantics or final qualification claim changes. Existing design/phase documents remain pending final budget selection. Main was merged through cf416937 during result collection; incoming changes affect baseline protocol, viewer popup presentation and stranger-walk tooling, not this screen's navigation source or map/gun-range inputs.
