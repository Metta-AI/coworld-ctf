# P22: tighten unsupported counter-review claims

Your P21 definitions and refusal to normalize stale/moving are useful. Please
revise STALE_COUNTER_REVIEW.md before closing it:
1. Aggregate pending/no-path declines do NOT establish "each plan lands sooner".
   Different trajectories/request populations prevent that per-request claim.
2. Do not introduce an A* cost-optimal-route guarantee without proving actual
   heuristic, termination, simplification and mutable-field assumptions. State
   the algorithm/cost model are unchanged and retain their existing guarantees.
3. Same-budget512 semantic experiments cover training screens, not all six
   current-main held-outs. Separate observed exactness from the structural
   expectation that output-preserving H1-H3 produce baseline behavior at512.
4. Stale is revision mismatch, not necessarily a presently pending request:
   requests can fail/retry. Use the exact predicate, avoid promising outstanding
   requests on every stale tick unless you traced all transitions.
No new experiment/gate change needed. Keep the findings, correct the causal and
quality overclaims. End PHASE 22 READY; wait. No native/source edits or commit.
