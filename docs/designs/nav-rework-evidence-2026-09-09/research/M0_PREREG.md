# M0: close inherited shared-memory qualification gap

Parent: 20234cc7, default Dial ring 262144; candidate default 131072.
Existing constructor and exact absolute-f queue semantics stay unchanged.
Peer source review: MEMORY_REVIEW.md. Saving expected: 1572864 bytes.
Acceptance: identical complete corpus hash, zero missing/illegal, existing
per-stratum inflation thresholds, every pool shared retained upper bound <=
16777216 bytes and colossal total <=268435456 bytes. Shared upper bound
includes all allocator overhead, conservatively including seat allocations.
Add a two-bucket collision equivalence test against both large ring sizes.
Compare parent and candidate on c6a with matched Nim 2.2.6 and B1024,
three interleaved fresh processes each; retain all whole-body and per-pop
rows. Candidate must retain 3.6/4.5 ms headroom on every row. Record any
per-pop slowdown rather than masking it with unrelated changes.
No claim of throughput research success: this is inherited qualification.
