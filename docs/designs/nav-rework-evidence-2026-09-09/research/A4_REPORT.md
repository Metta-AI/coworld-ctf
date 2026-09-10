# A4: retain equivalent validation with one geometry check per edge pair

Every directed coarse edge still requires an in-bounds endpoint and its reverse bit. Since the existing unit8px legalNavMove predicate is symmetric, the lower-index endpoint evaluates geometry once for the pair. All other validator passes remain unchanged. This changes which error can be reported first for a corrupt index, not its acceptance.

The independent diagnostic matches the original full-eight-direction predicate on2,164mutations:1,152directed-bit toggles and1,012symmetric-pair additions,452accepted/1,712rejected. Bounds, asymmetric bits and illegal symmetric pairs are exercised. Focused route-index tests pass. A4_CODE_REVIEW.md independently proves the three obligations and checks the diagnostic; tests are evidence alongside the proof, not an exhaustive enumeration of every possible graph.

## Native activation

Frozen f9dff753 parent, m8iCPU5, Nim2.2.6, three interleaved pairs:

| Repeat | Map48 parent/candidate index ms | Candidate total/BodyMap | Colossal parent/candidate index ms | Candidate total/BodyMap |
| --- | ---: | ---: | ---: | ---: |
|1|275.415 /251.486|1.904319|4513.603 /4262.268|2.049669|
|2|275.392 /251.391|1.890187|4536.188 /4269.262|2.005983|
|3|274.646 /252.211|1.908306|4516.161 /4269.851|2.027652|

Full activation plus configured maps pass time76/76 and memory76/76 on this host. All76retained ledgers exactly match A2. Full3072quality preserves37,637,596pops and hash5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500. The candidate does not change constructed graph arrays or route decisions; its only source delta is in validation.

This is not fleet-wide activation acceptance. V1's A2-based m5a screen still fails65/76activation rows, with map48at2.412084419x; A4 has not yet been measured on that host. Native final compiler and production-family qualification remain open. Configured tick diagnostics remain a separate failure, not an activation optimization claim.

## Integration and documentation audit

Integrated with retainedV1 in the root worktree. Focused route-index tests and both server compile shapes pass; Docker viewer rebuild and module/GV/sim-source-stamp QA pass. The diagnostic tools/check_body_index_validation.nim, raw mutation output, runner and native JSON are retained. Source comments state the symmetry invariant. No public config, gameplay, budget, cap or GameVersion changes; no final fixture qualification claim. The report and scoreboard describe the new validation execution and its limits. Final combined canonical quality and fleet timing are still required.
