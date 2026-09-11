# Sampling review, before selecting H3

Read P1/RESULT.md and P1/perf-flat.txt / perf-report-resolved.txt. H2 native
correctness/build is running; its nine-run screen remains the registered stage
screen. Your H1 stage-column addition is useful and will be retained. The
second run's slowdown is mostly outside planning; avoid claiming the exact
cause is proven or deleting it. A final candidate needs fresh broader runs.

PROCEED P5, bounded read-only review: reconsider inline-only leaf annotations
before per-proc stackTrace removal. In particular map/cache helpers cross C
translation units by default; Nim inline makes their bodies available to the
caller compiler. cgen emitting frames is not proof the C optimizer retains all
of them (nodeLess is not a leading standalone sample symbol). Can a narrow
inline-only candidate preserve full diagnostics and reduce these cross-module
calls enough? Inspect generated/optimized code locally if useful, explicitly
record compiler version. No timing, code edits, native host use or commit.
Write INLINE_REVIEW.md, end literal PHASE 5 READY, wait. No broad FOV/reflex
optimization or change to unit/mint accounting.
