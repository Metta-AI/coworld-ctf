# A6_SCREEN_REPORT: three-arm box-standability screen (isolated, local counts and exactness)

Peer (Claude) screen per `A6_ROOT_REVIEW.md`, in `nav-validation-symmetry`
only (A4 baseline f9dff753 plus root's A4 diff, A5 markers preserved and
snapshotted in `A6/a5-snapshot/`). No root, cache, or remote edits; nothing
committed. Mac timings are informational; root owns native timing and
adoption. Arms are selected at compile time by
`-d:PixelStandabilityArm=eager|direct|lazy` (default eager, the parent),
and every counter is under `-d:pixelStandabilityCounters`.

## 1. Arms (patches over A4 in `A6/patches/`, materialized snapshots in `A6/snapshots/`)

- eager (parent): fill `scratch.standable` for the whole box once per
  search, then read it. `eager-over-A4.patch` is the A5 markers plus
  counters only; no behaviour change.
- direct: no fill; every neighbour and `exactEdges` side read calls
  `map.canStand(point)` directly. No new memory.
- lazy: no fill; a `standableGeneration` stamp array in the scratch,
  bumped and rolled over with the existing generation, computes
  `canStand` on first read per pixel per search and caches the byte.
  Adds 4 bytes per box pixel to the transient scratch.

All three read exactly `canStand(point)` for the same in-box points; the
early invalid-start return, box bounds, target marking, queue order,
parent links, `exactEdges` semantics and path encoding are shared code.
The single screen source (`screen-body_route_index.nim`) carries the three
`when` branches; each materialized snapshot resolves them to plain code and
passes `nim check` (`local-mac/check_snap_*.log`).

## 2. Exactness

| check | eager | direct | lazy |
|---|---|---|---|
| selected route-index arrays on all 76 maps (`check_body_route_index_identity`: SHA-256 of legal moves, room of, local index, room cells, cell component, side component, segment cells, pocket cells; counts only for pockets, segments, arcs, sides, fine points, graph components; not every index array, so strong evidence, not complete byte identity) | reference | identical | identical |
| crafted searches: closed pocket (fails), corner pinch plain and exact (both fail), start outside box, start on wall, open success, five searches across a forced generation rollover (4294967294 to 1) | reference | identical | identical |
| 173,424 real searches on map 48 (every 24th standable pixel, plain and exact edges, 170,726 reached), one hash chain over every result | 4D841154B18CFF53 | same | same |
| focused route-index suite (eager default) | 7 of 7 | | |
| A4 validator mutation diagnostic (eager default) | 2,164 of 2,164 match | | |

Transient peak bytes are identical across arms in the identity report
because the scratch accounting maximum is dominated by another array;
the lazy arm's extra 16,900 bytes is real and is counted in
`initPixelSearchScratch`.

Limit: the crafted corner pinch did not separate plain from exact edges
(clearance-based standability makes a one-pixel diagonal squeeze
non-standable, so both fail). `exactEdges` equivalence therefore rests on
the 86,720 exact-edge real-map searches in the chain above and on the 172
exact-edge searches that occur during the 76-map identity build, not on
a hand-built pinch.

## 3. Counters: the fill is not where the pixel-stage time goes

Map 48 constructor, five builds, totals divided by five:

| counter per build | eager | direct | lazy |
|---|---:|---:|---:|
| `pixelPathInBox` searches | 457 | 457 | 457 |
| exact-edge searches | 3 | 3 | 3 |
| box pixels (sum of box areas) | 1,928,290 | same | same |
| eager fills | 1,928,290 | 0 | 0 |
| standability read requests (BFS neighbours and sides) | 6,301,197 | same | same |
| actual `canStand` evaluations | 1,928,290 | 6,301,197 | 849,575 |

Two corrections to `A5_NATIVE_REVIEW.md` section 3 follow from this:

- The join loop's 6,167 `pixelPocketPath` calls per build do not each run
  a pixel search. Only 457 searches per build reach `pixelPathInBox` at
  all (from every caller combined), so most join calls return at
  `targets.len == 0` before any fill. The "26 million reads" bound was
  an upper bound on the wrong quantity; the real fill is 1.9 million
  reads per build.
- The BFS reads 3.3 times as many standability values as the box has
  pixels, so the searches that do run explore essentially the whole box
  (failed searches exhaust it). The fill is about a fifth of the
  standability traffic, and the BFS itself, not the fill, is the pixel
  work.

Across the 76-map identity build: 1,991 searches, 8.29 million fills,
10.27 million reads, lazy evaluations 1.49 million. Same shape.

## 4. Local timing (Mac arm64, informational only, five builds of map 48)

| stage mean ms | eager | direct | lazy |
|---|---:|---:|---:|
| index.complete | 420.7 | 469.8 | 425.7 |
| index.pocketConnectors | 229.5 | 277.7 | 232.1 |
| pocket.graphJoins | 50.5 | 64.0 | 51.1 |
| pocket.coverage.resolvePending | 58.6 | 77.4 | 60.1 |
| pocket.finalPending | 38.9 | 44.6 | 37.5 |
| pocket.coverage.pixelScan | 77.4 | 87.5 | 79.1 |
| index.validate | 61.1 | 61.0 | 61.2 |

On this host the direct arm is slower in every pixel stage (3.3 times the
`canStand` calls, each a bounds check plus a byte load), and the lazy arm
is indistinguishable from eager within run-to-run noise. This is a single
Mac run and decides nothing on its own; it is consistent with the counters.

## 5. Recommendation to root

Do not adopt either arm on this evidence. The exactness evidence is the
selected-array digests plus counts above and the search-level chains; a
full-array identity would need segments, arcs, sides and fine anchors
digested as well. The screen shows the fill is exact to remove but small (about 1.9 million byte reads per map 48
construction, one fifth of the standability traffic), the direct arm
triples the reads, and the lazy arm trades the fill for a stamp check on
every one of 6.3 million reads. If root still wants a native number, the
lazy arm is the only one worth a paired m8i/m5a run, with the prediction
"no measurable change"; a positive native result would be a surprise and
should be re-checked before adoption.

Evidence-backed next questions (attribution only):

1. Per-stage search counts: which of the 457 searches per build come
   from the join loop, the coverage resolve, and the final resolve, and
   how many fail. The current counters are per binary, not per stage.
2. Failed-search exhaustion: reads per search (13.8 thousand) says failed
   searches explore the whole 65 by 65 box. Repeated failed searches from
   nearby starts inside the same enclosed region re-explore the same
   pixels; whether an exact region memo across starts is possible without
   changing results is a design question, not a measurement, and is out
   of scope here.
3. The join loop's 6,167 calls per build against 457 searches means most
   join candidates fail at goal selection (`pocketGoals` ring scan plus
   fine-target box test). That is 6,167 times 81 ring cells of
   `componentOf` and `cellComponent` reads; cheap per call, unmeasured in
   total.

## 6. Cleanup and ownership

Isolated tree state: A4 diff (byte-exact, see `A5/baseline`), A5 markers,
A6 arm selector and counters in `src/shell/body_route_index.nim`; three
diagnostic tools; `tmp/a6/` binaries and raw outputs (copied to
`A6/local-mac/`). Reverting A6 alone is applying `screen-source-over-A4.patch`
in reverse and re-applying `A5/A5-markers-over-A4.patch`; the A5 snapshot
in `A6/a5-snapshot/` is the exact pre-A6 state.

A6 SCREEN READY
