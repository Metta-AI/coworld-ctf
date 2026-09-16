# Current-planner optimization screen

Registered before collecting timings, 2026-09-11.

Baseline: bf5eadc895c7a06baa4a7e1d0168de8e210e2e32. Candidate: the
body_map/body_nav optimization port on james/nav-runtime-benefits. Both use
the same updated bench_body_port driver, committed BR golden map, seed 4242,
5 warmups and 50 samples. This is one map, not a multi-map qualification.

Run natively on the owned m5a.4xlarge, CPU 5, one timing process at a time.
Use production Nim 2.2.4, release/useMalloc/threads/speed/stackTrace flags.
Five process pairs alternate baseline-first and candidate-first. Retain raw
samples, source hashes, compiler version and machine details. Compare each
pair's medians and p95s for danger ranges 331, 1050, 1300 and 4,096 fixed rays.

Required: matching output fingerprints/counts for every pair; exact ray and
danger oracle tests on arm64 and amd64; no greater than 5% regression in the
median of paired median ratios in any measured row; a clear improvement in
at least one changed stage. Report p95 separately. This screen measures stage
cost, not complete game ticks or the archived routing rewrite's 2x target.
Any miss remains a miss; investigate or remove the offending change rather
than changing this threshold after observing results.
