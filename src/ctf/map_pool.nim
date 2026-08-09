## The curated terrain pool: seeds whose SHIPPED map (best-of-K, i.e.
## `generateCtfMap` / `poolCtfMap`) validates, under size-class and
## endzone-shape quotas. The pool entry IS the map the pool serves.
##
## The first 20 seeds are `gen_map_pool.nim`'s upward-scan curation (do not
## re-order or drop them by hand — regenerate that block with the tool). The
## seeds below the divider were added by a TARGETED SEED-HUNT (tools/sweep_seeds.nim,
## cubi-softmaxwell/tasks#49) to fill EMPTY playtype cells the upward scan never
## reaches: the tool curates by size + endzone shape only, so the pool was 0%
## siege / 0% rush. These seeds each ship (best-of-K) the labeled playtype with a
## clean `validateGeneratedMap` and staticScore > 0.5 — verified individually,
## not scanned. They are named explicitly because the quota scan cannot target a
## playtype, so it would never pick them.

const MapPoolSeeds*: array[23, int] = [
  1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010,
  1011, 1012, 1013, 1014, 1015, 1016, 1017, 1020, 1021, 1041,
  # --- seed-hunt additions (tasks#49): fill empty siege / rush cells ---
  1306,  ## hub / standard / siege — chokeCount 8, staticScore 0.902 (first
         ## siege in the pool; siege is ~1/5000 seeds because best-of-K's
         ## chokeCount soft-cap de-selects pinch-heavy candidates)
  1256,  ## three-lane / small / rush — chokeCount 0, routeMin 2, score 0.949
  1946,  ## three-lane / small / rush — chokeCount 0, routeMin 2, score 0.921
]
