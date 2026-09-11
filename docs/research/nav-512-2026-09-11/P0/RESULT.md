# P0 initial profile finding

Real32-seat game,1200ticks, all32 edge_ride guests. Diagnostic Fluffy only.
Same baseline source and budget variants as saved screen; timings not gates.

|Scope|256 total ms|512 total ms|256 max call ms|512 max call ms|
|---|---:|---:|---:|---:|
|nav.astarPlan|4292.3|5039.7|42.3|84.7|
|nav.fieldMint|3627.2|5621.3|8.6|17.0|
|shell.reflex|10383.0|10269.0|1.1|1.1|
|shell.ladder|2391.3|2415.5|244.1|255.0|
|nav.serverFrame|31679.6|35173.7|292.2|339.6|

Scopes nest; never add them indiscriminately. Important: much of512's extra
cost is minter, not only route A*. There are357/290 stepPlan calls and1118/886
stepMint calls. Candidate shared-heap improvements can benefit both. Static
legality caching helps A* only. Need exact counts/heap/route checks, plus same
budget unprofiled ablation and candidate512/baseline256 real-game comparison.
Root suspects hole-based fixed-heap sifting or narrower positions/stamps could
reduce memory traffic; rank against segment-legality precompute using evidence.
Profile files retained in this directory. Existing saved old games provide
unprofiled results. First trace compressed on native while second diagnostic
ran; neither profile is a throughput acceptance measurement.

Validation: extracted semantic lines (SHELL_PLAN_BUDGET, SHELL_NAV,
SHELL_INSTALL, SHELL_MOVEMENT) are byte-identical against the unprofiled
same-budget run:3249 lines at256,3080 at512. Zero play-fault lines. This
supports the profile workload, not timing equivalence or route-quality proof.
