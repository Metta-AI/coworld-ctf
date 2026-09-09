# S1: positive Q8 conversion

Parent: local L1 checkpoint d88fe68d, budget 1024. Replace floor(scaled).int with scaled.int after the nonpositive guard. Positive finite conversion truncates toward zero, equal to floor; retain ties-to-even rounding and range rejection. No compiler or CPU flags change.

Hypothesis: removing a per-cell libm call reduces packed-weight refresh on baseline amd64. No search-pop speedup or whole-body qualification is assumed. Run focused rounding boundaries, then three interleaved fresh parent/candidate whole-body processes on m5a CPU 5 after C0 completes. Same Nim 2.2.6 and release flags, fresh caches. Compare all six rows, weight refresh, whole-body p95/max and pop arrays. Run full quality and activation; require identical route hash, zero missing/illegal, unchanged allocation. Record every failure and repeat. Production compiler confirmation follows only if the native result warrants it.

Acceptance: exactness checks must pass; carry the candidate only if weight refresh improves beyond observed paired variation. The original whole-body 4/5 ms and selection 3.6/4.5 ms gates remain unchanged. This experiment does not change SJF, route expiry, fleet membership or final shipping requirements.
