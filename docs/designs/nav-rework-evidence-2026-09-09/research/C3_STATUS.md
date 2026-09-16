# C3 rejected: exact arithmetic, no useful recorded-trace gain

Frozen C2 baseline, m8i CPU 5, three pairs across all nine recorded traces. All input orders, source counts, cache hit/miss counts and raster hash chains remain exact. Total candidate/parent time is 0.9939–1.0182; p95 is 0.9727–1.0806, with 23/27 pairs slower at p95. Repeated-source diagnostic totals improve to 0.8736–0.9527 of parent; changing-source totals are 0.9736–0.9902. The observed changing-source movement also cautions against attributing every difference to the hit-path arithmetic: the miss code is unchanged.

The arithmetic proof establishes correctness but not a useful production speedup. All three configured m5a pairs are complete: 179/198 p95 rows improve, median ratio 0.987507, but 0/11 maps pass every repeat. The worst p95 remains 6.343519–6.374466 ms. Root and peer agree to reject C3; primary source and viewer are restored to retained C2. The new multi-range/border/empty-word cache regression is retained. Combined full quality matches C2+H1 in every field.

The first C3 command labeled linked inherited no WASMTIME_C_API and therefore checked the stub again. A fresh explicitly configured runtime-linked check replaces that file. C2's prior linked artifact remains unchanged; its separate compile size can be compared with the stub. Never infer linked mode from the output filename.

All 198 configured masks/pop rows and all 33 map-repeat ledgers agree. Worst parent p95 by repeat is 6.479911/6.480587/6.480794 ms versus candidate 6.357101/6.374466/6.343519 ms. These small gains move no gate. Combined C3 local quality is exactly equal to C2+H1 in every quality field; 9 cache and 17 navigation tests, both explicit server compile shapes, and viewer QA pass.

See [final peer review](C3_FINAL_REVIEW.md) and the three native summary JSON files. Rejection concerns measured workload benefit, not correctness. No production cap, budget, gameplay, or API change remains.
