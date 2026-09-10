# P1: streaming square dilation improves packed refresh

Three interleaved native m5a CPU5 pairs, B1024/range1300, D0a parent (D1 rejected): worst whole-body p95/max5.828086/5.878588 ->5.242172/5.274622 ms. Packed-weight refresh worstp95 falls1.092082->0.423183 ms; inclusive danger3.522271->2.864982 ms. Do not subtract these percentiles. All recorded masks and pop arrays match. The 4/5 ms tick gate still fails, so no budget selection or final acceptance is established.

Separate synthetic402x215-cell packer regimes (120 samples,10calls/sample,3freshpairs) retain identical checksums. Worst p95 percall: zero0.903795->0.892242 ms, singlepositive0.902863->0.894501 ms, dense24.245533->1.184002 ms. No sparse/empty regression is observed in these runs. These artificial regimes are diagnostics, not representative whole-body gains; their grid dimensions are explicit in raw JSON.

Full native m8i3072 case records and route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500` are unchanged from D0a, with zero missing/illegal and37637596 pops. All65 retained ledgers match exactly. Focused16/16 and body-seat29/29 tests and both server compile shapes pass. Independent actual-code review also compares22 raw rasters at varied densities/ranges with the parent packer, no differences.

Two test-setup failures are preserved: attempting to initialize private BodyMap fields, then using a nonstandable spawn. Corrected fixtures use real public map construction with valid standable spawns and exact cell-grid dimensions; the failed logs are not counted as passes. No production code changed for those setup repairs.

Retain P1. It changes the traversal of an existing fixed3x3 binary dilation, with no new memory, dependency or output contract. Sources and dependency rationale are in P1_REVIEW_REQUEST.md and P1_REVIEW.md. Existing memory cap remains32MiB shared/256MiBtotal. Final configured timing, activation ratios, canonical Docker, containment, version/fixtures and Phase10/11 remain incomplete.
