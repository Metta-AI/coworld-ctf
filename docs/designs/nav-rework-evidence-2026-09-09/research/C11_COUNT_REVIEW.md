# C11 close-floor row intervals: exactness and count proof

Documents and one stdlib Python enumeration; no source change, no timing,
no native job. Artifacts: `C11/c11_close_floor_intervals.py`,
`C11/c11_results.json`, `C11/c11_run.log`, `C11/SHA256SUMS` (results
288b3209..., script cce0d899...). Membership hash over every tested case,
in a fixed order: `1ec9d38e55e81521...` (full value in the JSON). Root's
`C11_COORDINATE_NOTE.md` is addressed in section 3.

## 1. The predicate as the primary code computes it

From `rebuildDangerFromPoints` (primary body_nav.nim, lines 575 to 587) and
`body_map.nim`: `NavCell = 8`, `DangerClosePx = 190`, `DangerCloseFloor = 0.5`;
`closeRange R = min(190, seat.dangerRangePx)`, `closeCells cc = (R + 7) div 8`,
`closeSquared = R*R`; `origin = cellOf(source)`, which is `source div 8`
clamped to the grid; the loop walks `gy` in `max(0, oy-cc) .. min(H-1, oy+cc)`
and `gx` in `max(0, ox-cc) .. min(W-1, ox+cc)`, takes the cell centre
`(8gx+4, 8gy+4)`, forms `dx, dy` against the original source pixel, and
adds 0.5 to the cell when `dx*dx + dy*dy <= R*R`. This runs once per
source, after that source's kernel additions (replay or rays) and before
the next source. Configured ranges are 331 and 1300 px, so production R is
190 and cc is 24 (a 49 by 49 box, 2,401 predicate evaluations per source).

## 2. Interval formula proved equivalent

Per row `gy`: `dy = 8gy + 4 - sy`, `rem = R*R - dy*dy`. If `rem < 0` the row is
empty. Otherwise `L = isqrt(rem)` and, because `dx` is an integer,
`dx*dx <= rem` holds exactly when `|dx| <= L`. With `dx = 8gx + 4 - sx` that is
`gx` in `[ceil((sx - 4 - L)/8), floor((sx - 4 + L)/8)]`, intersected with
the same box the primary walks, `[ox-cc, ox+cc]` and `[0, W-1]`. Within
the box the two predicates are the same set, so membership is identical
by construction; the enumeration checks it anyway.

Enumeration (all with the reference loop implemented literally as above
and the interval formula as stated, compared as cell sets):

| block | cases | membership differences |
|---|---:|---:|
| every R in 0..190, all 64 source phases in the cell, box fully in grid | 12,224 | 0 |
| clipping: 12 by 12 grid, R in {0, 5, 8, 37, 100, 190}, origins at 4 corners, 4 side midpoints, interior, all 64 phases | 3,456 | 0 |
| off-map sources (section 3): every R in 0..190, 125 source pixels with x or y outside the map by 1 to 2,000 px, origin clamped | 23,875 | 0 |
| total | 39,555 | 0 |

Covered by construction of the cases: empty rows (24,148 of 313,280 rows
in the first block; at R = 0, 63 of 64 phases produce no cell at all and
the phase (4, 4) produces exactly one), rows whose `rem` is a perfect square
(8,344 rows; these are the exact-circle boundaries where `L*L == rem`, and
1,705 cells lie exactly on the circle), small radii 0 to 8 (members over
64 phases: 1, 5, 13, 29, 49, 81, 113, 149, 197), and the disc-inside-box
property: for in-map sources no cell outside the `closeCells` box is ever a
member (checked two cells beyond the box on every side for every R and
phase), so clipping to the box removes nothing for in-map sources and is
kept only to mirror the primary.

## 3. Coordinate domain (root's note)

`cellOf` clamps but the floor measures from the original pixel, and
`DangerInput` candidates are not range-checked, so an off-map source has
a box centred on the clamped origin and distances from the real pixel. The
interval formula is written in source-pixel terms (`sx`, `sy` and the
clamped `ox`, `oy`), never in terms of a 0..7 phase, so it needs no caller
contract: the 23,875 off-map cases above (x from minus 1,000 to 1,096 px
and y from minus 300 to 2,096 px on a 96 px map, all radii) show zero
differences. Consequence for any table form: a table indexed by the 64
in-cell phases does not cover this domain. Either the runtime form (no
table) is used everywhere, or a phase table is used only when
`0 <= sx - 8ox < 8` and `0 <= sy - 8oy < 8` with the runtime form otherwise.
That branch is a domain selection for exactness, not new input validation.
I recommend the runtime form first; the table is an optimization of an
already small pass and should be justified by the micro, not assumed.

## 4. Order of additions and float exactness

Nothing about the accumulation changes. For each cell the sequence of
additions stays: for source 1, its kernel value if visible then 0.5 if
inside; for source 2, the same; and so on in source order. The interval
form changes only which loop discovers each inside cell, not whether or
when it is added, so every cell's float sequence is identical and the
raster is bit-identical. The per-source order kernel-then-floor must be
kept explicitly: the floor pass for source i runs after `replayVisibleCells`
or the ray casts for source i and before source i plus 1, as today.

## 5. Operation counts (R = 190, per source, from the enumeration)

| quantity | primary loop | interval form |
|---|---:|---:|
| predicate evaluations (2 subtractions, 2 multiplies, 1 add, 1 compare each) | 2,401 | 0 |
| rows visited | 49 | 49 |
| per-row work | none | 1 multiply, 1 subtract, 1 integer square root (47.6 rows on average; 1.6 rows are empty), 2 floor divisions, 4 clamps |
| 0.5 additions | 1,771 on average (min and max depend on phase) | 1,771, identical cells |

So the interval form removes about 2,400 scalar predicate evaluations per
source (19,000 per fill tick of 8 sources) and adds about 48 row
computations per source; the additions themselves are unchanged and become
contiguous runs. The Fluffy `danger.closeFloor` figure (430 to 436 µs per
fill tick on m5a) is attribution only and predicts nothing until the micro
runs.

## 6. Table storage (corrected per `C11_ROOT_REVIEW.md`) and root's smaller table

Corrections to my first version: `L` ranges 0..190, so an `L`-only table
needs `uint8`, not `int8`; and the full endpoint table is 3,136 pairs
(64 phases times 49 rows), 6,272 signed 8-bit values, 6,272 bytes.
Endpoints relative to the origin cell lie in -24..24 and fit `int8`.

| table | entries | width | bytes | covers off-map sources |
|---|---:|---|---:|---|
| root's `halfWidth[abs(dy)]`, dy 0..R | 191 | uint8 | 191 | yes (indexed by the actual pixel displacement) |
| `L` per (subY, row) | 392 | uint8 | 392 | no (phase-indexed) |
| full `(xlo, xhi)` per (phase, row) | 3,136 pairs | int8 | 6,272 | no (phase-indexed) |

Root's table is the right one: `halfWidth[d] = max x >= 0 with x*x + d*d <= R*R`
for `d` in 0..R, built by the bounded monotone construction (start at
`x = R`, for each `d` decrement while `x*x + d*d > R*R`), no square root,
no package. Per row: if `abs(dy) > R` the row is empty, otherwise
`L = halfWidth[abs(dy)]` and the same floor/ceil endpoints from the actual
`source.x`, clipped to the existing box and map. No phase assumption and
no off-map fallback.

Independent verification (`C11/c11_halfwidth_table.py`,
`c11_halfwidth_results.json`, hashes in `C11/SHA256SUMS`):

- Table against `math.isqrt(R*R - d*d)` for every R in 0..190 and d in
  0..R: 18,336 entries, 0 mismatches; maximum stored value 190; the
  construction performs at most 190 decrements for any R (at most R, as
  root stated).
- Membership with the table-driven interval on all 39,555 cases of the
  isqrt proof (all radii and phases, clipping, off-map sources): 0
  differences, and the membership hash equals the isqrt run's hash
  (`1ec9d38e55e81521...`), so the two formulations select identical cells
  everywhere.

Geometry/range contract, verified from the constructor: `newBodyNavSystem`
builds one `DangerGeometry` from `liveGunRangePx` and gives every seat that
geometry and `dangerRangePx: liveGunRangePx` (body_nav.nim lines 364 to
374); nothing else assigns either, so a per-geometry table keyed by
`closeRange = min(190, liveGunRangePx)` is consistent with every seat's
range. A fixed `array[191, uint8]` in `DangerGeometry` (191 bytes) would be
covered by the existing `sizeof` accounting of `sharedDangerGeometry`;
initialize only 0..R and index only after `abs(dy) <= R`.

This remains an unimplemented proposal; no source edit is authorized.

## 7. Unresolved concerns before any implementation

- Nim integer division truncates toward zero; `sx - 4 - L` and `sx - 4 + L`
  are negative for sources near the left or top edge and for off-map
  sources, so the implementation must use floor division (`floorDiv` from
  std/math or an equivalent bias), or the endpoints are wrong by one cell.
  The Python proof uses floor semantics throughout.
- Nim's standard library has no integer square root. `L` must be an exact
  integer floor of the square root: a float `sqrt` followed by an integer
  correction (`while L*L > rem: dec L; while (L+1)*(L+1) <= rem: inc L`) is
  exact for these magnitudes (rem at most 36,100); a table of `L` is the
  alternative. Either way the exactness test must compare cell sets
  against the literal predicate, as this proof does, not trust the sqrt.
- The proof covers the predicate and membership; it does not cover the
  implementation. A Nim tools-only check must repeat the comparison
  against the primary loop on real maps with real and crafted sources,
  including off-map pixels, before any timing.

## 8. Proposed native screen for this distinct mechanism (not authorized)

- Tools-only, no production change: an arm that replaces only the close
  floor loop in a materialized `rebuildDangerFromPoints`, parent being the
  retained primary. Per process: assert bit-identical rasters against the
  parent for every source of the workload before any clock (real maps,
  standable sources including edge cells, plus crafted off-map sources).
- Timing: the same danger micro structure as C5/C10 (three maps, 1300 px,
  64 even-spread origins, hits warmed so the replay is identical in both
  arms), five rotated process pairs per host, CPU 5, no counters.
- Screen, fixed now: median `danger.closeFloor`-equivalent time per
  source at most 0.50 of parent on each map on both hosts (a pass that
  only removes predicate evaluations should be large; if it is not, the
  mechanism is wrong), and the whole-rebuild median not slower than 1.01
  on any map. Then the nine actual-source traces and both regimes with
  the unchanged limits; this pass is regime-independent, so the
  changing-source rows are a no-regression check, not a benefit claim.
- Expectation stated plainly: about 0.3 ms per fill tick on m5a if the
  stage time is what Fluffy attributes; that is a stack member for the
  configured gate, never a gate closer, and no whole-body claim follows
  from the micro.

C11 COUNT REVIEW READY

C11 TABLE REVIEW READY
