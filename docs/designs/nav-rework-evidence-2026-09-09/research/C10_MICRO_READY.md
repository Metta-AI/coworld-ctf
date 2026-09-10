# C10 three-arm tools frozen for bounded peer review

C10/c10_replay.nim, check_c10_replay.nim, bench_c10_replay.nim and run_native.sh are frozen; hashes in C10/frozen-input-hashes.txt. Root code remains only nav-deferred-cache/tools, primary src unchanged. ARM correctness-v3.json passes all5craftedcases and256border/mask combinations at104/1300px, for both scalar and SIMD. Alternating negative zero and nonzero accumulators are compared bitwise. Native micro asserts zero real-map raster differences before starting clocks. Parent is retained C2+V1 body_nav; base snapshot is native f9 restore source. No timing run has started.

The grouped helper takes vectorized as a static parameter; both paths share identical group selection, safety predicate, hoisted kernel/raster pointers and lengths. Scalar uses checked group bounds followed by four independent guarded lane adds; SIMD uses vector add and masked result blend. Boundary fallback uses original checked sequences. No per-call sequence copy or per-cell ref-owner local. SSE mask uses an integer unaligned load plus bit cast. ARM uses existing NEON bindings.

Review only these four tools plus C10_MICRO_DECISION.md. Confirm correctness and fairness; point out concrete defects. Do not broaden research. End C10 MICRO REVIEW READY and wait. Root will launch five rotated process triples on both native hosts only after this review.
