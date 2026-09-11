# H3: omit only tiny helper stack frames, retain bounds checks and callers

Registered before implementation/timing. Candidate starts from H1+H2 and adds
inline plus stackTrace:off only on this named leaf set:
body_planner: nodeLess, setPosition.
body_map: inBounds, clearanceAt, canStand, cellWalkable, cellOf,
gridWidth.
body_cache: routeDistanceAt, setRouteDistance, clearRouteCell.
No module-wide pragma, no compiler flag changes, no narrowed data/checks,
no cost/quality/accounting/queue/budget change. Every other proc retains its
production frame. A defect in a leaf loses that innermost trace line; its
framed caller and the bounds check remain. The P1 and local assembly findings
justify testing this explicit diagnostic tradeoff, but do not prove a win.

Correctness before timing: native heap/segment differential, navigation suite,
baseline-identical cross-build fingerprints, and a deliberately failing
leaf-boundary diagnostic proving the caller's stack trace remains. Verify
native GCC/Nim version and generated code on the actual pinned toolchain.

Nine fresh finite games,32 seats,1200 ticks, exact H1 inputs/affinity/flags.
Variants: P256=original6b6b3408 at256; P512=accepted H1+H2 at512 (the H2
candidate binary); H512=new H3 at512. This differs deliberately from H2's
original512 comparator and measures H3's incremental effect.
Orders: P256,H512,P512; P512,H512,P256; H512,P256,P512.

Intermediate H3 gate: median paired H512/P512 total<=0.98, p50/p95/max<=1,
worst deadline misses<=parent; exact same-budget semantic streams and no faults.
Target gate: median paired H512/P256 total/p50/p95/max<=1, worst deadline
misses<=parent. All frames and all runs retained. No outlier exclusions or
resampling to replace misses. Report stage totals alongside whole-frame rows,
without substituting stage-only success for the whole-game target.

A pass is training-scenario evidence. Held-out maps/plays16/32 seats, common
production hardware, memory/legality/determinism/full tests and builds still
remain. No live budget change or publication is authorized by a screen pass.
