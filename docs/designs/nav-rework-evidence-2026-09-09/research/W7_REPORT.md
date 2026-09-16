# W7: clearance-based skipping of provably empty ray samples

Three interleaved native m5a CPU5 pairs, B1,024/range1,300, Nim2.2.6 release/useMalloc/noSignalHandler. W6 is the parent; all other source and harness are common. Every recorded mask and pop array matches.

The weapon-stage worst p95 falls3.206897->0.638566ms, about5x for that stage. Whole-body worst p95/max is5.881750/5.931860ms for the parent and5.957923/6.044486ms for the candidate. Thus the targeted stage improves strongly, but the worst whole-body timing does not improve in these pairs; danger rebuilding is now the limiting stage. Do not call this a whole-body doubling or a tick-gate pass, and do not attribute the small whole-body difference to noise without evidence.

The discrete ray proof is in CLEARANCE_SKIP_REVIEW.md. Differential tests pass262,144 small rays,20,000 long/reversed rays, and196 saturation/border/zero-length pairs. The independent clearance verifier passes all76 maps and261,581,865 pixels: wall/zero equivalence, border clearance<=1, and every eight-neighbor edge differs by at most1. These local inequalities prove the distance field cannot overestimate distance to a wall or outside-map pixel.

Full native m8i quality passes 3072 cases, zero missing/illegal, 37637596 pops, route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. All65 original activation rows pass. Configured-map raw rows still use the historical16 MiB shared limit; MEMORY_CAP_RULING.md supersedes that limit. No memory allocation is added by W7.

One verifier repair was required: the initial tool treated configured pool entries as wrapped specs, while that file stores direct specs. The failed run is preserved in W7-m8i-attempt1 with original source W7-clearance-initial.nim. The corrected run is W7-m8i, remote W7-repaired. No timing was run until the corrected clearance verifier passed. W7_CODE_REVIEW.md is complete; final combined qualification remains outstanding. Retain provisionally for its exact stage improvement; investigate the remaining danger floor before selecting a budget.
