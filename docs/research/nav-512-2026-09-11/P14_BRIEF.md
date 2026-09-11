# P14: simplify the diagnostic, no production change

Use Nim's existing std/importutils privateAccess instead of layout mirrors and
casts. I verified it in /Users/jamesboggs/.nimby/nim/lib/std/importutils.nim:
privateAccess(BodyPlanner), privateAccess(typeof(planner.heap)), etc grant
field access in the diagnostic scope without hand-maintained object layouts.
Also privateAccess(BodyPlanJob) lets the probe use job.targetIndex, job.step
and job.latticeW to print the ACTUAL target point used by heuristic, rather
than a proxy to unsnapped job.goal. Keep both goal and target labels explicit.

Replace the diagnostic mirrors, regenerate the three-tick local-original dump
and verify equality with local H3 if practical. Keep old mirror output under
an explicitly superseded name, not as current evidence. This is diagnostic
code only; no production edit, native access, commits or more than3ticks.
Write CROSS_ARCH/first_divergence/REPORT.md ending PHASE 14 READY and wait.
Include a short suggested comparison separating raw float changes from actual
heap/record integer changes. Existing helper can cover private nested types
via typeof values; no need export production internals.
