# A6_PROPOSAL: lazy box standability in the pixel search (exact)

## 0. Revision 2: narrowed to the three-arm screen, and its outcome

Per `A6_ROOT_REVIEW.md` the proposal was narrowed to an isolated screen of
three arms (eager parent, direct `canStand` reads, lazy stamped memo) with
counters and exactness checks; the 5x stop rule below is withdrawn and the
one-nanosecond-per-read estimate is retracted. The screen ran:
`A6/A6_SCREEN_REPORT.md`. Result: all arms are exact on all 76 maps and on
173,424 real searches, but the counters show only 457 pixel searches per
map 48 construction and a fill of 1.9 million reads against 6.3 million
BFS reads, so the fill is one fifth of the standability traffic, the
direct arm triples the reads, and the lazy arm is timing-neutral on the
Mac. Recommendation: do not adopt; at most one native paired run of the
lazy arm with the prediction "no measurable change". Sections 1 to 5 below
are the original proposal, kept as the record of the hypothesis the screen
tested.


Peer (Claude) proposal from `A5_NATIVE_REVIEW.md`. One minimal exact
change, not implemented. Root implements and measures after the C2
checkpoint and C3.

## 1. The redundant work

`pixelPathInBox` (`body_route_index.nim`, pixel connector search) begins
every call with

```
for y in y0 .. y1:
  for x in x0 .. x1:
    scratch.standable[local(point)] = index.map.canStand(point)
```

4,225 reads for the full 65 by 65 box (`PixelConnectorMaxCells`), then a
BFS that reads `scratch.standable[nextLocal]` for each neighbour it
considers and, with `exactEdges`, for two side pixels per diagonal step.
`canStand` is a pure function of the immutable map (bounds plus one
clearance byte compared with `PlayerHalf`). Every box pixel the BFS never
reaches is filled for nothing. On map 48 the join loop performs 6,167 such
calls for one success (counters, `A5-m5a/run.log`), and the seed resolves
add more; failed searches in small pockets visit few pixels and pay mostly
for the fill.

## 2. The change

Replace the eager fill with the generation-stamped lazy pattern the same
scratch already uses for `visitedGeneration` and `targetGeneration`:

- Add `standableGeneration: seq[uint32]` to `PixelSearchScratch`, sized
  like `standable`, reset by the existing `beginSearch` generation bump
  (no clearing loop).
- Remove the fill loop.
- Read standability through one inline helper:
  `if scratch.standableGeneration[local] != scratch.generation:
     scratch.standableGeneration[local] = scratch.generation;
     scratch.standable[local] = index.map.canStand(pointAt(local))`
  then return `scratch.standable[local]`. Use it at the three read sites
  (`nextLocal`, and the two `exactEdges` side pixels).

No other line changes: box bounds, the start check, target marking, the
BFS queue order, parent links, `reachedTarget`, `exactEdges`, and the
result encoding are untouched. The scratch grows by 4 bytes per box pixel
(16,900 bytes) and is transient; `initPixelSearchScratch` already sizes
the other arrays the same way, and `transientPeakBytes` accounting must
include it.

## 3. Proof obligations (identical graph, identical quality)

1. Value equivalence: for every local pixel read during a call, the lazy
   value equals `canStand(pointAt(local))`, which is exactly what the
   eager fill stored. The helper computes it from the same function on
   first read and caches it under the current generation; generations
   are bumped per call by `beginSearch`, so no value leaks between calls
   or boxes. Pixels never read are never computed and never influenced
   the result before either.
2. Order equivalence: the BFS expands `NavNeighbors` in the same order and
   the same visited stamping; only the source of the boolean changes, so
   the queue sequence, `reached`, `targetRef` and `parent` chain are
   identical, hence the same `PixelPath`, the same `CrossingPath`, the
   same connectors and fine targets, the same graph joins and collapse.
3. Reset correctness: `beginSearch` must bump the generation before any
   read; the existing wraparound handling for `visitedGeneration` and
   `targetGeneration` (whatever it is) must cover the new array
   identically. Test: run one search past a forced generation wrap and
   compare.
4. Callers: `pixelPathInBox` is also used by `pixelCrossingPath` (sides)
   and any other `exactPixelPathInBox` caller; the same argument applies
   to all of them because the change is inside the one proc.

Tests to add in the isolated tree: (a) the full route-index fingerprint
(graph arrays, segments, arcs, pockets, fine anchors) equal parent versus
candidate on all 76 maps, reusing the A1 graph-array comparison; (b) the
existing focused route-index suite and validator mutation diagnostic
unchanged; (c) corpus `--quality` hash `5a1340...` and pops unchanged;
(d) a unit test on a small map with a pocket where the BFS fails, asserting
the returned empty path and that the number of standability evaluations
(define-gated counter) is below 4,225 and equals the visited neighbourhood
count.

## 4. Paired measurement (root, native)

- Counter first: a define-gated count of `canStand` evaluations inside
  `pixelPathInBox` per construction, parent versus candidate, on map 48
  and two typical maps. Prediction: parent equals calls times box area
  (about 26 million for the join loop alone on map 48); candidate equals
  the sum of visited neighbourhoods, an order of magnitude lower on failed
  searches. If the counter does not drop by at least 5x on map 48, stop.
- Then five paired constructions on m8i and m5a with the A5 profiler,
  reporting `pocket.graphJoins`, `pocket.coverage.resolvePending`,
  `pocket.finalPending`, `index.sides` and `index.complete`; and the full
  76-map activation ratios on both hosts. Prediction: those four pixel
  stages shrink in proportion to the counter; no other stage moves;
  memory ledgers unchanged except transient peak.
- Adoption only if fingerprints, quality, and the focused suites are exact
  and the 2x/3x ratios are met on the qualification host; the m5a ratio
  failure may persist if section 2 of the native review is right, and that
  is reported, not averaged.

## 5. Non-goals

No change to which searches run, to box size, to `exactEdges`, to
validation, to the join loop's candidate order, or to the two resolve
passes. Those are the next candidates only if this one is exact and the
counters say the remaining work is where the time is.

A6 PROPOSAL READY (revision 2: screened, see A6/A6_SCREEN_REPORT.md)
