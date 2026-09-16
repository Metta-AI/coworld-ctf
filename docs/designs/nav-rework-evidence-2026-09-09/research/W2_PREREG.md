# W2: direct wall lookup for an already bounded ray

Parent W1 integer sampler with M1 ownership and M2 counters, common harness. Candidate changes only the per-sample isWall call into a direct private wall-table lookup. Public endpoint bounds refusal, zero-length behavior, integer overflow checks and sequence bounds checks remain. The sampled coordinates lie between in-bounds integer endpoints, so repeated inBounds checks add no new validation.

Run differential ray tests first. Then three interleaved fresh parent/candidate1300pxm5a CPU5 processes, B1024, sameNim2.2.6/release flags. Require every emitted mask and pop array identical; measure weapon and whole-body p95/max per row/repeat. No improvement assumed. The frozen full corpus remains a regression check; this change does not alter pathfinding costs.

Before-run clarification: both arms include the same M3 ledger/harness correction, which changes neither tick masks nor the timed ray implementation. Only body_map differs between arms. Exact source patches are captured before building.
