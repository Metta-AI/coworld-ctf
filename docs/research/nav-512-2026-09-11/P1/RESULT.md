# P1 diagnostic sampling

Baseline512, same finite 32-seat game, sampled separately after all H1 timing
runs. Native m5a, userspace CPU-clock, CPU5, 99Hz, DWARF stacks. 4,098 samples,
zero lost samples. Includes activation and gameplay: percentages are sampled
CPU share over that process, not playing-frame fractions or measured speedups.

Resolved report: perf-flat.txt; stacks: perf-report-resolved.txt. Initial
reports lacked symbols because /results/server-512 existed only inside Docker.
A private symfs/results/server-512 symlink to the exact host binary resolved
symbols; no sampling rerun was needed. Adding the binary to buildid-cache alone
did not resolve it because its build ID was absent from the original record.

Leading shares: applyFovCone20.74%, planEscapeThroughStage4.95%,
clearanceAt4.83%, canStand3.15%, siftDown2.98%, setPosition2.37%, swapNodes2.27%,
advanceMintSearch1.95%, cellWalkable1.49%, routeDistanceAt1.49%, hashSlot1.17%.
The clearance/canStand stacks mostly lead through segmentClear/advanceAstar.
This supports H2; it does not prove how much helper self time is frame
bookkeeping versus useful work. nodeLess is not a leading standalone symbol;
C inlining can move its cost into siftDown, even when generated C defines it
as a non-inline proc. Compiler-generated C alone cannot establish final call
or stack-bookkeeping cost.

The game completed normally. Ending perf's sleep workload after the game
returned143 to the shell, so the initial script stopped before report output.
The completed data was then processed explicitly; this is a sampler shutdown
status, not a game failure. Raw logs and data are retained. No profiling timing
is used in any acceptance gate.

Semantic navigation/movement/install stream is byte-identical to baseline512,
verified from the archived log and zero-exit game record (counter-parity.json).
raw-profile.tar.gz includes the actual perf.data, resolved reports and exact
binary symbol table/hash. The root-owned perf.data required sudo when archiving;
the incomplete first archive was replaced and membership verified. The current
run_p1_native.sh includes the observed sampler exit handling and symfs mapping;
the raw archive preserves the original invocation.
