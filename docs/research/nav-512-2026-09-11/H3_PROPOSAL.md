# H3 candidates pending sampling evidence

No implementation or timing authorization yet. Choose after H1/H2 results and
P1 sampling, preserving one mechanism per experiment.

1. Sparse-record lookup: current primary lattice capacity is 344,487 on the
   practice map, while hashKeys/hashRecords/hashGeneration allocate 1,048,576
   entries each (24 MiB per seat on amd64). A direct lookup can improve locality
   but must support 2px and 1px fallback without changing record insertion order,
   fixed-capacity errors or suspension fingerprints. Full-resolution uint64
   generation plus int32 record arrays would cost about 63 MiB on this map
   (int64 records would make it about 84 MiB);
   memory is therefore a real tradeoff, allowed only within the user's 4x
   non-colossal allowance and measured against the full existing workspace.
   Preserve 64-bit generations; do not assume a narrower stamp never wraps.

2. Tiny heap helper call cost: nodeLess is a pure four-field comparator and
   setPosition writes two indexed fields. Nim's local compiler cgen.nim
   genProcBody emits an entry/exit frame when optStackTrace is enabled,
   irrespective of the inline calling convention. Adding inline alone is not
   evidence that stack bookkeeping disappears. If sampling points here,
   evaluate an explicit template for the pure comparator, preserving global
   production flags. That would remove this tiny helper's separate diagnostic
   frame while retaining its caller's; document and review that tradeoff.
   Do not silently disable stack traces over the planner or change compile flags.

Source observations are hypotheses about cost, not measured attribution.
