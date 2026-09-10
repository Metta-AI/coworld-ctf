# C7_MICRO_READY: ray-order nonzero list replay versus C2 and C8 bitmap replay (tools only)

Peer (Claude) per `C7_RESUME.md` and `C7_ROOT_REVIEW.md`, in
`nav-source-cache` only. C8 snapshots and the tree's screen source were
preserved first (`C7/baseline/`, hashes; the screen source is unchanged
after this unit, 74d5efeb...). No production source, cap, policy, or
native change; two tools were added. Mac numbers are informational; root
runs `run_c7_micro.sh` natively.

## 1. What the micro measures

`tools/bench_danger_list_replay.nim` (include, diagnostic) builds one nav
system per map and range, samples the C6 v2 evenly spread origins (all
stride-selected standable cells, at most 64 evenly spaced, coordinates
recorded), warms every origin with the production miss rebuild outside
timing, then captures a per-origin list of (absolute grid index int32,
weight float32) with a verbatim copy of the production first-visit ray
walk (`castRay` and `addVisibleCell` bodies, the seat's own visited stamps
and a fresh generation, origin cell first then every perimeter ray) that
records nonzero weights only. List capacity is the number of nonzero
entries of the actual kernel counted at initialization: 54,173 at 1300 px,
5,385 at 331 px; no observed-source bound, no overflow rule, no sorting.
Batches alternate the production `replayVisibleCells` of the build's source
and the list replay; clear and hash are outside timing; one clock per
batch; no counters.

Two builds: `c2` over the C8 parent snapshot (frozen C2 plus inert C5
markers, bitmaps include zero-weight cells) and `c8` over the C8 candidate
snapshot (zero-weight cells omitted). Both tools carry a tools-only
`-d:DangerReplayArmLabel` and were built and run against each materialized
snapshot copied in place (`local-mac/snapbuild_*.log`), then the screen
source was restored and hash-verified.

## 2. Proof (crafted and per-origin)

`tools/check_danger_list_capture.nim`: crafted 1024 by 768 px map with
interior walls, ten origins per range including all four corners, three
edges and the centre (19 of 20 cases have a kernel box clipped by the
grid), at 331 and 1300 px, both builds. Every case: list length within
the nonzero-kernel capacity, no repeated grid index, first entry is the
origin cell, every weight equals `kernel[offset]` bit for bit, the index
set equals the production bitmap's nonzero-weight cells, and replaying
the list reproduces the production replay raster with zero float-bit
mismatches (`local-mac/check_c2.json`, `check_c8.json`). In the microbench
the same set and raster checks run for every sampled origin before timing
(zero mismatches on all six map and range pairs, both builds), and the
per-batch raster hashes of bitmap and list replay are identical.

Limit stated plainly: the list's order is production's first-visit order
by construction (a copy of the walk on the same stamps), not re-derived
by an independent oracle; exactness needs only the one-add-per-cell set
and the raster, which are checked.

## 3. Mac results (informational; medians over three interleaved rounds)

| map | range px | origins | list cells per origin | C2 bitmap ns | C8 bitmap ns | list ns | list / C2 | list / C8 | C8 / C2 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| br-gen-5120 | 1300 | 44 | 9,154 | 159,320 | 148,546 | 12,746 | 0.080 | 0.086 | 0.932 |
| br-gen-5204 | 1300 | 45 | 10,982 | 190,799 | 177,356 | 15,314 | 0.080 | 0.086 | 0.930 |
| br-gen-5263 | 1300 | 49 | 7,959 | 142,651 | 129,657 | 11,150 | 0.078 | 0.086 | 0.909 |
| br-gen-5120 | 331 | 44 | 2,938 | 48,737 | 46,348 | 4,046 | 0.083 | 0.087 | 0.951 |
| br-gen-5204 | 331 | 45 | 3,259 | 54,232 | 52,220 | 4,508 | 0.083 | 0.086 | 0.963 |
| br-gen-5263 | 331 | 49 | 2,679 | 44,299 | 42,644 | 3,729 | 0.084 | 0.087 | 0.963 |

On this host the list replay is about 8 percent of the C2 bitmap replay
time per source (a 12x reduction) at every map and range, and the C8
bitmap (zero omission alone) is 7 to 9 percent faster than C2 at 1300 px
and 4 to 5 percent at 331 px, in line with its 6 to 10 percent fewer
adds. So the representation change dominates the zero-omission
ablation by a wide margin here. The bitmap's per-cell cost on this host
(about 16 ns: word scan, trailing-zero, division, bounds checks, kernel
lookup, add) against about 1.4 ns per list entry is the whole difference;
a native host with different division and streaming costs will move
these numbers, which is why root runs it. The preregistered advancement
threshold (at least 20 percent lower median replay time versus C2 on
each 1300 px map, no material 331 px regression) is exceeded on the Mac by
an order of magnitude; that is the hypothesis for m8i, not a result.

## 4. What this does not establish

- No whole-body claim: the replay is the hit share of a rebuild (25 to 58
  percent of sources on real traces, 96 percent on the configured first
  fills), and a first-fill tick also spends a quarter of its danger time
  packing weights (`C5_M5A_REVIEW.md`).
- No miss-path claim: recording a list on misses (append per first-visit
  cell) is not timed here and must be measured in a full-trace pair
  before any policy decision.
- No cache policy or memory decision: 32 slots times 54,173 entries times
  8 bytes is 13,868,288 bytes at 1300 px before per-slot length and owner
  metadata (27,736,576 at 64 slots); the exact ledger on all 76 maps,
  configured 1300 px and colossal is a separate gate, and the integrated
  total to compare against is 229,158,347 bytes.
- Real-trace hit rates at 32 versus 64 slots are already quantified in
  `C7_RESEARCH_REVIEW.md` section 6 and are not changed by this micro.

## 5. Recipe

`run_c7_micro.sh`: two checkouts carrying the C8 parent and candidate
snapshots, both tools built per arm with the tools-only label, the crafted
check run per arm, five interleaved rounds over six map and range pairs
on CPU 5, every exit code recorded, and a summary table with list / C2,
list / C8 and C8 / C2 per pair plus exactness and origin-equality flags.

C7 MICRO READY
