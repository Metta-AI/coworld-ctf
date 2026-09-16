# C9_MICRO_READY: first-hit conversion cost micro (tools only, conditional fallback)

Peer (Claude) per `C9_MICRO_REVIEW.md`, in `nav-source-cache` only. The
corrected C7 source was preserved and is restored in the tree (hash
1f3805ed..., in `SHA256SUMS`); the frozen C2 parent was materialized only
to build this diagnostic (`micro/snapshots/parent-body_nav.nim`). No
booldefines, no production, cap or policy change, no native job.

## 1. What the micro measures (`micro/bench_danger_lazy_list.nim`)

On the C2 parent (bitmap recording untouched), C6 v2 evenly spread origins
with precomputed cells, warmed by production misses outside timing; one
preallocated list store of `origins * capacity` entries with capacity =
nonzero kernel count (54,173 at 1300 px, 5,385 at 331 px); lengths reset
outside timing. Three operations, order rotating across batches
(`bitmap,conversion,list` then `conversion,list,bitmap` then
`list,bitmap,conversion`), five batches of 20 repeats, clear and hash
outside timing, no clocks inside:

- bitmap: the production `replayVisibleCells` (C2);
- conversion: a simulated first hit, one row-major traversal of the
  bitmap that adds every set cell and appends each nonzero
  (gridIndex, weight) entry to the list; one add per cell per source
  makes the row-major list exact regardless of C7's ray order;
- list: a subsequent hit replaying the list entries.

Generated C (native gate flags, `local-mac/convertAndReplay.c`,
`replayList.c`): neither per-cell routine contains an `eqcopy`,
`eqdestroy`, or a `DangerSourceCache` or `ListStore` local; the store is a
`var` parameter and the cache is read through the seat field.

## 2. Exactness

For every origin the bitmap replay, the conversion-plus-replay and the
list replay produce the same raster bits, and the list's index set equals
the bitmap's nonzero-weight cells; per-batch raster hashes of all three
arms are identical; origin lists identical across rounds; all 24 local
runs exit 0 (`local-mac/exits.txt`).

## 3. Mac results (informational; medians over three rounds)

| map | range px | origins | bitmap bits per origin | list cells per origin | bitmap ns | conversion ns | list ns | incremental conversion cost | list / bitmap | exact |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| br-gen-5001 | 1300 | 44 | 9,924 | 9,279 | 161,480 | 167,617 | 14,574 | 0.038 | 0.090 | True |
| br-gen-5120 | 1300 | 44 | 9,903 | 9,154 | 162,286 | 171,561 | 14,347 | 0.057 | 0.088 | True |
| br-gen-5204 | 1300 | 45 | 11,852 | 10,982 | 195,554 | 202,266 | 17,292 | 0.034 | 0.088 | True |
| br-gen-5263 | 1300 | 49 | 8,707 | 7,959 | 142,439 | 150,132 | 12,519 | 0.054 | 0.088 | True |
| br-gen-5001 | 331 | 44 | 2,932 | 2,829 | 48,259 | 51,537 | 4,222 | 0.068 | 0.087 | True |
| br-gen-5120 | 331 | 44 | 3,037 | 2,938 | 49,043 | 51,140 | 4,295 | 0.043 | 0.088 | True |
| br-gen-5204 | 331 | 45 | 3,382 | 3,259 | 54,639 | 57,205 | 4,741 | 0.047 | 0.087 | True |
| br-gen-5263 | 331 | 49 | 2,770 | 2,679 | 44,445 | 47,405 | 4,130 | 0.067 | 0.093 | True |

On this host the incremental conversion cost is well under the 0.30 screen
limit on every map and range, and list replay is about 0.08 to 0.09 of
bitmap replay, under the 0.50 limit; both far inside the count model's
weakest first-hit allowance. These are Mac numbers with a Mac bitmap
baseline; the native list/bitmap ratio was about 0.41 to 0.51, so the
list column will read differently on m8i and m5a, and the conversion
column is the one this micro was built to measure there.

## 4. Screen limits, restated as preregistered

Native advancement only if, on every 1300 px map, the incremental
conversion cost is at most 0.30 and list/bitmap at most 0.50, with 331 px
reported under the same limits. These are count-model screen limits, not
whole-body acceptance; failing them closes C9 without relaxing them, and
a positive result still faces the full real-trace, miss, ledger and
whole-body gates. Root runs `micro/run_c9_micro.sh` only if the corrected
C7 result leaves C9 as the fallback.

## 5. Freeze

`micro/snapshots/parent-body_nav.nim`, `micro/bench_danger_lazy_list.nim`,
`micro/run_c9_micro.sh`, `micro/SHA256SUMS`, `micro/local-mac/` (results,
table, summary, exits, build log, C snippets). The tree's
`src/shell/body_nav.nim` is the corrected C7 candidate again.

C9 MICRO READY
