# C7 v2 native micro: passes advancement threshold

Native m8i CPU5, five repeats, three maps at331/1300px. All60rows use correctedv2 protocol with alternating bitmap/list batch order and precomputed origin cells. All origin selections, one-add-per-cell sets and raster hashes match; crafted checks pass both materialized C2/C8 builds. Runner DONE and clean source restoration verified.

At1300px, list/C2 median ratios by5120/5204/5263 are0.4924/0.4138/0.4793; at331px0.5104/0.5107/0.5085. All exceed the preregistered20% reduction threshold without331px regression. Versus C8 bitmap the list ratios are0.4335–0.5329. This is roughly2x native replay throughput, not the12x Mac diagnostic gain and not whole-body throughput. Exact per-arm medians and all raw rows are in C7-m8i-summary.json and C7-m8i/.

Advance to a full source-cache implementation only in the isolated tree, after memory review selects slot count. Miss recording, full nine-trace pairs, both ranges, all memory caps and integrated whole-body/native fleet qualification remain required. No production cap or source change yet.

Native m5a replicate completed60rows, five repeats per map/range/bitmap arm, all exact. See C7-m5a-summary.json for per-arm medians. All six list/C2 ratios pass20%reduction: br-gen-5120/331=0.4875, br-gen-5120/1300=0.4429, br-gen-5204/331=0.4826, br-gen-5204/1300=0.4454, br-gen-5263/331=0.4880, br-gen-5263/1300=0.4352. Source restored cleanly, then m5a started A7constructor comparisonPID64874.
