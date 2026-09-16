# C4 rejected before implementation

Exact ordered-source raster reuse is too rare in the recorded episodes to justify a full-raster cache. At capacity 8, nonempty hits are only 2.20–7.31% across the nine traces, below the preregistered 20% threshold on every map and roster. Empty rebuilds are excluded from useful hits. No source change, no cache allocation, no cap increase and no timing claim. The available larger memory allowance is not a reason to add a cache unsupported by actual reuse.

C4-trace-screen.json retains all four capacities, raw trace names, map/roster, counts and rates; c4_trace_screen.py is the reproducible model. This rules out this exact-key screen, not all possible raster algorithms. Source order cannot be normalized without proving float/floor equivalence.

Documentation audit: this count-only rejection changes no production behavior, commands, schemas, or caps. The report, preregistration, model output, and scoreboard are the complete documentation surface for the experiment. Verified nine traces at four capacities with nonempty rebuilds as the denominator.

Parser correction: NAVSRC pts entries are x:y:seatId. The first model accidentally kept all three components in the key, although seat identity does not affect a raster after source selection. Corrected the model to key only ordered x:y pairs and reran all four capacities on all nine traces: all 36 result rows are unchanged, so the rejection and reported range stand. C4-screen-v1.py and C4-trace-screen-v1.json preserve the original mistake; current c4_trace_screen.py implements the intended exact-pixel key.
