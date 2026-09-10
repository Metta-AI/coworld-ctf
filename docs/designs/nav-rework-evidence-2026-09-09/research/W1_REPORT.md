# W1: integer ray sampling

Three interleaved1300pxm5a CPU5 pairs atB1024: parent worst whole-body p95/max13.820488/15.464153ms; candidate11.448389/12.762947ms. Weapon p95 worst11.890562->9.519705ms. Every emitted input mask (initial tick, warmups and measured ticks) and per-tick pop count matches in every row and repeat. The whole-body gate still fails.

Focused differential rays, existing body-map and body-seat suites pass. Long-ray test coverage was extended to8192px and passes. Peer review checks the incremental invariant and176Mcoordinate comparisons, with a correction requested to its original3312px maximum assumption (colossal is larger).

Full3072corpus passes, zero missing/illegal, unchanged route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500` and37637596pops. This run used pre-capacity-correction memory accounting; those rows are not final allocation proof. M2 separately corrects capacities. W1 changes no visibility rule, target scoring, distance test or wall predicate.
