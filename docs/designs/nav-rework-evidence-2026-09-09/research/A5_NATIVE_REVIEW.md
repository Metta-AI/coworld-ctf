# A5_NATIVE_REVIEW: map 48 constructor attribution on m5a and m8i

Peer (Claude) review of `A5-m5a/` and `A5-m8i/` (both DONE, five
constructions of map 48 `br-gen-24678`, grid 283 by 151, isolated A4 plus
A5 markers, identical source hashes on both hosts:
`body_route_index.nim` 317e3e92..., profiler 2be74c4c...). Durations nest;
stages are never added. Counters are identical on both hosts, as they must
be for the same binary and map. Documents only.

## 1. Stage means and host ratio

| stage | m5a ms | m8i ms | m5a / m8i |
|---|---:|---:|---:|
| index.complete | 840.828 | 252.443 | 3.331 |
| index.pocketConnectors | 445.193 | 133.749 | 3.329 |
| pocket.coverage | 274.474 | 82.365 | 3.332 |
| pocket.coverage.pixelScan | 164.416 | 48.097 | 3.418 |
| index.fieldsAndCountSegments | 160.335 | 50.796 | 3.156 |
| index.validate | 119.253 | 34.371 | 3.470 |
| pocket.coverage.resolvePending | 103.288 | 32.575 | 3.171 |
| pocket.graphJoins | 96.566 | 29.333 | 3.292 |
| index.legalMoves | 89.719 | 25.608 | 3.504 |
| pocket.finalPending | 71.155 | 21.183 | 3.359 |
| index.seedPixelComponents | 6.147 | 1.680 | 3.659 |
| index.sides | 5.871 | 1.853 | 3.169 |
| pocket.coverage.classify | 5.607 | 1.327 | 4.225 |
| index.fillSegmentsAndArcs | 4.407 | 1.145 | 3.848 |
| index.graphComponents | 4.232 | 1.532 | 2.762 |
| pocket.canonicalMapping | 2.874 | 0.801 | 3.589 |
| index.roomLayout | 2.872 | 0.851 | 3.374 |
| index.validatorAnchors | 2.576 | 0.704 | 3.659 |
| pocket.coverage.sort | 1.031 | 0.305 | 3.380 |
| index.fineAnchorIndex, pocket.collapse, pack, initialTargetsScratch | under 0.3 | under 0.15 | noise |

Root's reading is confirmed: every stage above ten milliseconds scales by
3.16 to 3.50, mean 3.33, with no stage standing out (the sub-10 ms rows
scatter from 2.76 to 4.23, which is timer noise at that size). The pixel-search stages
(pixelScan 3.42, resolvePending 3.17, graphJoins 3.29, finalPending 3.36)
sit inside the same band as the coarse passes (legalMoves 3.50, validate
3.47, fieldsAndCountSegments 3.16). The A5 question 5 hypothesis (pixel
work scaling worse on m5a) is rejected by this data.

## 2. Why m5a fails the ratio while m8i passes (inference, one artifact short)

The activation ratio is total activation over body-map construction. The
map 48 rows root pointed to (`V1-m5a/activation.json`, index at A2;
`A4-m8i/activation.json`, index at A4, so the two differ by A4 and the
index ratio below is not a pure host factor):

| term | m5a ns (V1 run) | m8i ns (A4 run) | ratio |
|---|---:|---:|---:|
| body map | 832,531,351 | 338,457,158 | 2.46 |
| route index | 919,671,800 | 252,055,974 | 3.65 (A2 versus A4 index) |
| mixed nav | 248,778,226 | 75,422,390 | 3.30 |
| total | 2,008,135,900 | 668,134,261 | 3.01 |
| ratio | 2.412 | 1.974 | |

Correcting the index term for A4 with the A5 profile's own map 48 numbers
(A4 index 251 ms on m8i versus about 275 ms for A2 per `A2_PROFILE_REPORT.md`)
puts the host factor for the index near 3.3, in line with the A5 stage
band and with the mixed-nav term. The body-map term scales by only 2.46.
So m5a fails the ratio because the denominator scales less than the
numerator on that host; index work must shrink roughly in proportion to
the whole index to pass there, not one stage. This still rests on two
runs that differ by A4 and should be re-read once an A4 m5a activation
exists.

## 3. What the counters say about the work

Per construction (totals divided by five): 42,733 cells classified;
11,808 need a pixel scan (27.6 percent); 766,656 pixels scanned; 8,224
deferred secondary points; 2,114 seeds unresolved after the scan, resolved
in 4 passes over 16,255 seed evaluations; 10,186 pending points leave
coverage and are all re-resolved in `finalPending`; the join loop calls
`pixelPocketPath` 6,167 times for 1 successful join; 11 pocket paths and
42 pocket points result.

Two facts from the code narrow where that work goes:

- The fine-target list is tiny on map 48: 15 initial entries plus at most
  46 pocket fine points (`peer-proofs/a6_fine_targets.out`, a read-only
  include of production source). The per-call linear scan of
  `fineTargets` in `pixelPocketPath` is therefore not the cost.
- `pixelPathInBox` (called by every `pixelPocketPath`, via
  `exactPixelPathInBox`, possibly twice when the first pass reaches a
  target without a legal path) fills `scratch.standable` for the entire
  65 by 65 box, 4,225 `canStand` reads, before any search, on every call,
  regardless of how many pixels the BFS then visits. In the join loop
  alone that is 6,167 calls times up to 4,225, about 26 million clearance
  reads per construction for one successful path; the seed resolves add
  more calls on top. How much of `graphJoins` is that fill and how much
  is the BFS itself is not identified by the current data; the A6 screen
  counters (eager fills, read requests, actual evaluations) will answer
  it, and no per-read cost is asserted here.

This is the evidence behind `A6_PROPOSAL.md`: the fill is provably
redundant for every box pixel the BFS never touches; whether removing it
is worth wall-clock time is what the screen measures.

## 4. What is not supported

- No claim that any stage can be skipped: the join loop's 6,166 failed
  calls, the second resolve pass over the same 10,186 points, and the
  27.6 percent scanned cells are all real work under the current
  algorithm, and their equivalence to something cheaper is not proven
  here except for the fill in section 3.
- No timing claim for A6; it is a hypothesis with a count-based bound.
- The m5a versus m8i explanation in section 2 is an inference pending the
  map-48 activation rows.

A5 NATIVE REVIEW DONE (revision 2: ten-millisecond band, map 48 rows, no per-read cost claim)
