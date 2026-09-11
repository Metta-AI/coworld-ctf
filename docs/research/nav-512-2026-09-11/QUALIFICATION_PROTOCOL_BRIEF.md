# Bounded held-out protocol review while native correctness runs

PROCEED P8, read-only. Root is running H3 native checks/build; no H3 timings
have been seen. Review HELDOUT_DRAFT.md and QUALIFICATION_PLAY.md, including
root qualification-maps/attempts.json and converted map-scale29.json. The first
passing scale2.9 draw is5120918; all prior rejections are retained. The moving
guest's native real-runtime probe now passes5/5 on Nim2.2.4/Wasmtime48.0.1.

Propose a small, concrete held-out real-game matrix using existing runner/input
seams, two distinct checked-in maps plus the larger draw,16/32 seats,
331/497/1050 range coverage and edge_ride versus nav_research_moving. Include
one all-alive stress case (hitPoints1000) to preserve replan load. Do not invent
new production knobs. Exact masks/paths are required at equal budgets;512 vs256
may change the world trajectory, which cannot be hidden by comparing unequal
tick counts. Specify fixed finite coverage, repetitions, order, whole-frame
and navigation gates, and what a failed/early-ending run means. Avoid a huge
Cartesian grid. A later common-fleet-family check should be explicit but not
claimed complete on m5a alone. Keep the existing no-slowdown thresholds; do not
exclude guest bursts or redefine units. No benchmark, game run, native use,
code change, commit or publication. Write QUALIFICATION_PROTOCOL_REVIEW.md,
end literal PHASE 8 READY and wait.
