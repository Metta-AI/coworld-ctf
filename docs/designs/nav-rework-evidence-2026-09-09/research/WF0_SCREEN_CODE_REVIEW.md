# WF0 screen code review: the isolated wavefront diagnostic

Written 2026-09-09 by Claude (peer) for `WF0_SCREEN_REVIEW_REQUEST.md`. Reviewed
`tools/bench_body_danger_wavefront.nim` (untracked, 255 lines) against the exact visitor in
`body_nav.nim` and the proof in `DANGER_WAVEFRONT_REVIEW.md`, plus `WF0_SCREEN_PREREG.md` and
`WF0_IMPLEMENTATION_PLAN.md`. Source read-only. Independent check: I built and ran the
diagnostic on this Mac; every bitwise raster and maximum assert passed on all 14 rows, and the
JSON is retained as `peer-proofs/wf0_screen_local_mac.json`. Mac timings are informational
and are quoted only to illustrate the counter-hypothesis, never as a result.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
The diagnostic is a faithful implementation of the reviewed method and a fair screen. Its
differential compares the full float raster bit for bit and the maximum against the real
`BodyNavSeat.rebuildDanger` through the production source selection, with the perimeter,
kernel and close-floor constants replicated literally so any drift fails the assert. Four
notes in section 5 (one seeded configuration per row, a small timing asymmetry, the
ordinary-integer geometry size, and the early-break scope), none of which invalidates the
screen. The m5a rows decide; section 6 says what my local run suggests about the
counter-hypothesis.

## 2. Construction, checked against the proof
- `rayCells` iterator: D0a's decision recurrence; on a diagonal it yields the x-side cell,
  then the y-side cell, then moves and yields the target; on an axis step it moves and yields
  the cell. That is exactly the event set and order of `castRay`, so per-ray memberships are
  the ray's checked-and-added cells.
- Perimeter: `evenRound` is `pyRound` (floor, fraction, ties to even); the two include loops
  and the dedupe bitmap reproduce `initDangerGeometry`'s set. The list is then sorted by
  `angleOrder` (half-plane flag, then cross-product sign for counter-clockwise order, then
  coordinate tie-break; integer only, no `atan2`, no hashing): deterministic, and permissible
  because the wavefront's result does not depend on ray order (proof section 2).
- Memberships as CSR: counts per relative cell over the `(2 r + 1)^2` box, prefix sums, fill in
  sorted-ray order so each cell's member list is ascending, then contiguous runs become
  inclusive `(first, last)` ranges with a per-cell `firstRange ..< afterRange`; range count is
  computed before allocation and the final arrays are `newSeqOfCap` of exact size, so capacity
  equals length.
- Shells: for `shell` in `1 .. 2 r`, `x` in `[-min(r, shell), min(r, shell)]`, `y = +-(shell -
  |x|)` with `y = 0` emitted once and cells beyond the radius box or with no members skipped;
  `shells[shell]` is the start index and `shells[^1]` the end. This enumerates every cell at
  each Manhattan distance exactly once.
- Kernel: a literal copy of `attenuation` (`> min(1050, gunRange)` gives 0; `<= 400` gives 1;
  otherwise `1 - ((d - 400) / 650) * 0.4` in float64 then float32), indexed like the
  production kernel; the assert on the full raster is what proves the copy is bitwise right.
- `blocked`: `isWall(cellCenter(cell))` per cell, the same predicate R1's `sightBlocked`
  table holds; out-of-grid cells are treated as blocked at runtime.

## 3. Runtime, checked against the proof
Per source: zero raster once per rebuild (before the source loop, as the original); origin
add unconditional (the original's `addVisibleCell(origin)` with a fresh stamp); all active
words set with the last word masked to `rayCount mod 64` bits (skipped when the count is a
multiple of 64); per shell, pass 1 clears every member range of every blocked or out-of-grid
cell, then an exact early exit if no word is set, then pass 2 adds the kernel once to every
cell with an active member. Pass 2 does not re-check bounds, and does not need to: an
out-of-grid or blocked cell had all its members cleared in pass 1, so `activeCell` is false
and no index is formed. `wordMask` builds the per-word mask with shifts in `0 .. 63` only
(`first mod 64` and `63 - last mod 64`), so the "shift by 64" hazard is avoided, and it
handles first and last in the same word. The close-floor pass and the final maximum scan
are the original's, in the original order (after all rays of the source; maximum after all
sources). Source order is the production selection's order. This is the algorithm the proof
covers, and the 14 asserted rows (three frozen pool maps, three configured maps and colossal
at 331 and 1,300 px, with 8 selected sources from 16 seeded candidates) confirm bitwise
equality on real geometry, as did the 885 standalone trials.

## 4. Timing protocol
Thirty interleaved samples per row, parent then candidate, on the same seat and buffers,
sorted, p95 taken at index 28 (nearest rank of 30, matching the harness). Geometry
construction is timed separately and excluded. The candidate reuses its `active` and
`values` buffers; the parent reuses the seat's. Both include raster zeroing and the close
floor.

## 5. Notes (none blocking)
1. One seeded source configuration per map and range (`initRand(401)`, a 32 px lattice of
   standable points). That is enough to screen, and the full-integration plan has the 76-map
   differential with many placements; the screen's exactness claim should be worded as
   "14 rows, one configuration each", not as map coverage.
2. Timing asymmetry: the parent call is `rebuildDanger`, which includes `selectDangerSources`
   over 16 candidates; the candidate is handed the already-selected list. The selection is a
   16-element insertion sort, negligible next to the rebuild, but the parent arm carries it
   and the candidate does not. Worth a sentence in the report.
3. Geometry size: `RayCell` is `point: BodyPoint` (two `int`) plus two `int` fields, 32 bytes,
   and `RayRange` is two `int`, 16 bytes, so the tool reports about 3.9 MB at radius 163 and
   266 KB at 42 (`extra_geometry_bytes`, at capacity). The plan's "about 4 MiB with ordinary
   integers" and its 36 MiB cap remark come from this layout; a production layout with
   `int16` coordinates and `uint16` ray ids is about 0.7 MB at 163
   (`DANGER_WAVEFRONT_REVIEW.md` section 5). Do not let the diagnostic's layout size the cap.
4. The early exit fires only when every active word is zero, that is when all 924 rays are
   dead. Rays that reach their perimeter targets stay set, so on open ground the loop always
   scans every remaining shell; this is by design in the proof but it is exactly where the
   counter-hypothesis lives.

## 6. What my local run suggests about the counter-hypothesis (informational only)
On this Mac, at 331 px the candidate's p95 was below the parent's on all seven rows
(ratios 0.51 to 0.82); at 1,300 px it was above on all seven (1.20 to 1.93). Mac numbers
are not gate evidence, but the pattern is what the prereg's counter-hypothesis predicts: at
the larger radius most rays die at real walls well before the perimeter, the ray walk stops
paying for them, and the wavefront keeps scanning the inactive part of every shell (all
83,928 cells) with a range test per cell. The m5a screen should report the 331 and 1,300 px
rows separately and, if the split is the same there, the plan's next step is not
integration but a cheaper per-cell inactive test (or a per-shell active-range narrowing,
which is exact because dead rays never revive) before any further measurement. Reject
consistently slower rows per the prereg; do not average across ranges.

## 7. Artifacts
`peer-proofs/wf0_screen_local_mac.json`: the diagnostic's full JSON from my local run
(14 rows, all `equal: true`, 30 samples per arm, geometry bytes, construction times).
