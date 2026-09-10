# A8 bounded 128 x 64 failed-key array: peer review of the plan

Reviewed: `A8_FULL_COUNT_RESULT.md`, `A8_ROOT_REVIEW.md`, my earlier
`A8_IMPLEMENTATION_REVIEW.md`, and the current primary `pixelPathInBox`,
`initPixelSearchScratch` and `beginSearch` in `src/shell/body_route_index.nim`
(read only). Documents only; no implementation; root owns code and native
jobs.

## 1. Verdict

The plan is sound and I accept it over my earlier per-start table
recommendation. The 76-map counts settled the two things my review could
not: repeats are exact repeats of early failures on the only map that has
them, so a no-eviction first-N array of 128 records serves every measured
hit (189 of 189 on map 48), and the fixed inline array makes the transient
cost exactly `sizeof` rather than a library table capacity that cannot be
read. My earlier "small bounded linear cache serves near zero" applied to a
recency ring (LRU), which the count model confirms (LRU 16 and 64 give 0);
first-N admission is a different policy and the counts show it works.

Six specific points follow; none blocks the plan. Two are exactness
conditions I verified from the current source, four are wording or test
details for root's implementation and report.

## 2. Exactness conditions, verified from source

- The search is a pure function of the key. `pixelPathInBox` reads only
  `index.map.canStand`, `index.map.width` and `height`, `routePoint(target)`
  and the arguments `start`, `center`, `targets`, `exactEdges`. `routePoint`
  decodes a reference arithmetically (non-negative: coarse cell centre;
  negative: the self-decoding 4 px lattice) from immutable map dimensions,
  so it cannot change during construction. Nothing built incrementally by
  the constructor is read. A failure for a key therefore stays a failure,
  and the exact-key comparison (start, center, exactEdges, count, ordered
  targets) covers every input. This is what the zero result and dequeue
  mismatches across 1,991 searches were measuring; the source confirms it.
- The failed return is the default `PixelPath`. Before `reached >= 0` the
  proc writes nothing into `result`, and the `reached < 0` return leaves it
  default, so returning a default `PixelPath` on a memo hit is the same
  value. Root's plan also keeps the valid-start check and `beginSearch`
  before the memo scan, so the generation counter advances and rolls
  exactly as the raw failed call would; the scratch stamp arrays are not
  read across calls (every read is guarded by the current generation or
  is inside the box the same call wrote), so skipping the fill and the walk
  changes no later result.

## 3. Details for the implementation

- Record layout and size. `BodyPoint` is `tuple[x, y: int]`, 16 bytes.
  A record of start, center, count, exactEdges and 64 `int32` targets is
  about 296 bytes with padding; order the fields so the bool and the count
  share one 8-byte slot (targets first, then the two points, then count and
  bool) and report the actual `sizeof` on both architectures as planned.
  The array is roughly 38 KB inline in `PixelSearchScratch`, which is a
  stack value created by `initPixelSearchScratch` and passed only as
  `var`. The one copy risk is the by-value return of `initPixelSearchScratch`;
  check the generated C for a `memcpy`/`nimCopyMem` of the scratch there
  (one copy per construction would be harmless but should be known), and
  confirm there is no other by-value use.
- Accounting. Fold `sizeof(array) + sizeof(count)` into the existing
  `max` in `initPixelSearchScratch` next to the six per-cell arrays; the
  existing arrays account `PixelConnectorMaxCells` times 21 bytes per
  scratch, so the addition is a visible but bounded transient change and
  no retained payload changes. `transientPeakBytes` is expected to change
  and is outside identity, as the plan says.
- Scan cost. The scan compares only `used` records (0 on maps with no
  failures), and count, mode and points before targets, so the per-call
  cost is at most 128 short compares. Against the 805,625 dequeues of map
  48 that is noise, and on maps with failures but no repeats it is bounded
  by the same 128 compares per call. This is fine; the native pair decides.
- Generality statement for the report. First-N admission is fitted to the
  observed order on map 48 (repeats are among the first 128 failures; 253
  unique failed keys in total). It cannot serve a map whose repeats arrive
  after 128 unique failures; that costs nothing but the scan. Say this in
  the report and preserve the "no repeats on maps 3, 5, 6" negative. The
  per-start latest-failure model having identical counts is worth one
  sentence so nobody re-proposes replacement logic.
- Tests. In addition to root's list (hit, rollover, full cache, oversize
  list, mode/center/order distinction): a counted build on map 48 should
  report exactly 189 memo hits and 356,784 saved dequeues against the
  count model, the way C9 checked conversions against its model; and the
  full-cache test should show the 129th unique failure runs raw and the
  cache stays exact afterwards.
- Base. Agreed: the count snapshot f9dff753 predates A4 and pixel counts
  do not depend on A4, but both native arms must carry the primary current
  `body_route_index.nim` with the A4 validator; label f9dff753 as pre-A4
  counts, not as an A4 baseline.

## 4. Expectation, so the result is read correctly

The benefit is confined to map 48 geometry and to the pocket pixel stages
(about 80 ms of the 252 ms m8i index on map 48 from A5, the BFS being a
part of that), so the plausible index-time effect is single digit percent
and the 5 percent advancement criterion is genuinely at risk. A miss is a
valid negative to preserve. Whatever map 48 shows, the 76-map activation
report must show no map slower by more than noise, since the scan is the
only new cost, and the m5a activation ratio for map 48 is reported as
measured and expected to stay above 2.0x. Final activation gates are
absolute and unchanged.

A8 ARRAY PLAN READY
