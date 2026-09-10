# V1: retain byte visit stamps; throughput qualification remains open

Replace only danger visited/generation uint32 storage with uint8, retaining the full-clear-before-generation1 rollover and correcting allocation/ledger element size. Source/ray order and float arithmetic are unchanged. This is a measured storage reduction, not a claim that the working set fits Zen1L2.

## Exactness and retained memory

Full3072-case native m5a quality preserves37,637,596pops and hash5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500. All36paired short tick rows preserve masks and pops. The publicAPI rollover regression passes, while removing the clear makes it fail. The initial constant-source test did not detect that mutation; its ineffective result is preserved rather than concealed.

check_body_danger_rollover.nim compares each rebuild byte-for-byte with the production path given explicitly cleared reference stamps, outside the timed section. Mac76maps x96rebuilds give7,296exactrasters and228rollovers. Native m8iCPU5 three fresh parent/candidate process pairs each cover76maps:21,888exactrasters per arm and684actual candidate rollovers. Raw times and generation boundaries are in V1-rollover-m8i/. This tests the source rebuild, not whole-body acceptance. Rollover-boundary samples contain varying source work; compare identical sample indices across arms rather than subtracting unrelated percentile populations.

All76retained-ledger rows match A2 exactly except danger_workspaces and total: the workspace loses exactly3bytes per allocated cell per seat. Colossal total falls266,478,979 to229,098,883bytes, saving37,380,096bytes (35.65MiB). All76memory rows pass; shared non-colossal cap stays32MiB and total/colossal cap stays256MiB. Capacity accounting is not a physical RSS bound.

## Native timing and remaining failures

m5aCPU5, Nim2.2.6/GCC11.4, B1024, three interleaved pairs perrange:

| Range | Parent worst p95/max ms | Candidate worst p95/max ms |
| --- | ---: | ---: |
|331px|3.880099 /3.975531|3.860509 /3.889380|
|1300px|5.193323 /5.221613|5.168592 /5.250669|

Danger p95 improves18/18matched331px rows and13/18matched1300px rows; whole-body p95 improves17/18 and12/18. This is a small timing effect, not2x throughput.1300px stillfails4/5ms and331px misses3.6ms selection headroom.

The full m5a activation/configured screen passes memory76/76 but activation time only11/76.55of65frozen/colossal rows fail;10of11configured rows fail. Map48 is2.412084419x against2x. This is broader than A2's earlier m8i-only near-pass and remains an open host-specific gate, not proof that V1 caused a regression (activation was not paired here). The configured11-map tick diagnostic also passes0/11maps, with worstp95/max15.804094/16.082791ms. These are larger configured maps, not the frozen1300px short-row geometry. Final canonical compiler and production-family qualification must preserve these failures. A4 independently targets validator cost on its frozenA2source.

## Validation and documentation audit

Focused navigation tests, both server compile shapes, Docker viewer rebuild and module/GameVersion/sim-source-stamp QA pass. V1-focused-v2.log and V1-server-{linked,stub}.log carry results. The new diagnostic is documented above; run_v1.sh and run_v1_rollover.sh record exact native recipes. B1024 remains provisional, GV65 unchanged, and all nine final fixtures remain pending final integrated selection. No movement-mask change is observed or claimed. C2 and H1 remain isolated candidates.

This internal representation change adds no public configuration or gameplay behavior. The test, diagnostic, preregistration, this report and scoreboard cover its changed invariant and measurements. No broader public documentation claim is advanced before final qualification. Retain V1 for its exact memory reduction and small measured timing benefit; do not count it as passing the unfinished throughput/activation gates.
