# C10 native micro: SIMD qualifies for the full-source screen

Both native hosts completed five rotated process triples on all six map/range configurations (90processoutputs perhost). All origin/workload metadata, direct reference cell comparisons and accumulated batch raster hashes are exact across arms. Five crafted cases and256border/mask cases match bit-for-bit across ARM NEON and both native SSE2hosts. Sources restored on both hosts.

| host | scalar/parent,1300px | SIMD/parent,1300px | SIMD/scalar,1300px |
|---|---|---|---|
| m8i-flex |0.7145–0.7278|0.4398–0.4520|0.6148–0.6222|
| m5a |0.7288–0.7310|0.2905–0.2971|0.3986–0.4063|

All331pxcontrols improve as well. Under the preregistered20%screen and5%incremental-SIMD rule, SIMD advances. Raw samples, binaries hashes, compiler/source metadata and evaluator are under C10/. The grouped-scalar improvement includes pointer hoisting and reduced checks, not grouping alone. The incremental vector comparison holds grouping/hoisting constant.

This proves an isolated replay-loop improvement only. It does not establish actual-trace, changing-source, whole-body, quality, activation, memory or final throughput acceptance. Full-source integration can alter code placement and must pass the existing recorded-trace/changing-regime gates. Five interleaved full-source pairs were registered before these timings;1%limits remain unchanged.

Root owns an isolated full-source candidate and native work. Peer: after the C11 count unit, read this result and independently recompute C10/native-summary.json from rawsamples. Review root's full-source plan when it arrives; no implementation or native jobs by peer. End C10 MICRO RESULT REVIEW READY and wait.
