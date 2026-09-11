# P11 bounded design follow-up, no implementation yet

H3 timing final repetition in progress. Root agrees minter hoisting is narrower
than generic heap refactor if p50 remains short. Do not state an unmeasured
residual is impossible to close; estimates are not impossibility proofs.

For primary record lookup, inspect whether existing hashRecords/hashGeneration
arrays can serve direct primary-lattice indexing without allocating any new
arrays. Their capacity already exceeds every primary key. The current odd
multiplicative hash is also collision-free for that key domain, so expected
benefit is locality, less bookkeeping and arithmetic, not primary collisions.
Fallback searches reset generation, so per-search direct/sparse mode may reuse
the same arrays. Verify all callers, reset/fallback transitions and capacity
errors. Compare minimal conditional hashSlot direct branch against storing a
mode and changing public-ish private helper signatures; preserve original
fallback hashing. Do not change generation widths, record IDs or accounting.

Write DIRECT_LOOKUP_REVIEW.md with smallest credible shape, invariants and
counterexamples/oracle tests needed. No edit to production, tests or commits.
End PHASE 11 READY and wait.
