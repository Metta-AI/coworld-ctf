# P1 code review: streaming 3 x 3 hot-bit dilation as implemented

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff of
`src/shell/body_route_query.nim` against `P1-parent-body_route_query.nim`, confirmed
byte-identical to HEAD at 490a96be (the D1-rejection checkpoint, D0a source intact): one
hunk, 20 insertions, 15 deletions, entirely inside `rebuildPackedWeights`. Also the new
literal test in `tests/test_shell_body_nav_rework.nim`. Source read-only; no timing claims.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact and correctly bounded. The stream uses the parent's predicate verbatim, clamps rows,
treats outside columns as false, cannot wrap a row, writes each cell once with the unchanged
Q8 low bits, adds no memory, and keeps the raise behaviour. The literal tests pin the cases
that matter with hand-derived expectations, and their map construction is sound. Both
focused suites pass here and a differential against the parent scatter on real and
synthetic rasters found no difference.

## 2. The implementation, line by line
- `width`, `height` from `graph.map.gridWidth/gridHeight`; `cellCount = width * height` is
  checked against `danger.values.len` before the loop (unchanged), so every index below is in
  range by construction.
- Per row `y`: `above = max(0, y - 1) * width`, `row = y * width`, `below = min(height - 1,
  y + 1) * width`. Clamping duplicates the edge row into the OR, which is exact by
  idempotence (`P1_REVIEW.md` section 3).
- `columnHot(x)`: `not (values[above + x] <= 0) or not (values[row + x] <= 0) or not
  (values[below + x] <= 0)`. This is the parent's `value <= 0` test negated, so NaN is
  classified exactly as before (positive). Correct, and the one point I flagged.
- `leftHot = false`, `centerHot = columnHot(0)`: column -1 is outside and false; `width >= 1`
  always (`navWidth = max(1, width div 8)`, `body_map.nim:981`), so `columnHot(0)` is in range.
- Per `x`: `rightHot = x + 1 < width and columnHot(x + 1)`; the `and` short-circuits before
  the template reads, so no read at column `width`. `packed = packedDangerQ8(values[row + x])`
  (unchanged S1 packer, unchanged raise), OR `0x8000` iff any of the three flags, one
  `int16` store, then shift the flags. Each cell's low bits come from its own value and its
  high bit from the 3 x 3 in-bounds neighbourhood: the same set the scatter produced.

## 3. Row wrap and size assumptions
All reads are `base + x` with `base` in `{above, row, below}` (each a multiple of `width`
for a valid row) and `0 <= x < width`, so a read never crosses into the next row and never
exceeds `cellCount - 1`; the only column that could tempt a wrap, `x + 1 == width`, is
excluded by the short-circuit. Degenerate grids: `width == 1` gives `rightHot` false
everywhere and `hot = columnHot(0)`; `height == 1` gives `above == row == below`. No
assumption is made about the pixel dimensions beyond `gridWidth * gridHeight == values.len`,
which the guard enforces, so the clamped boundary columns and rows of odd-sized maps
(`BRIDGE_ENCODING_REVIEW.md` section 6) are irrelevant here: the packer works on the cell
grid only.

## 4. The literal test
`checkGrid(width, height, values, expected)` builds an all-walkable public `BodyMap` of
`8 n + 7` by `8 m + 7` pixels so that `gridWidth == n` and `gridHeight == m`
(`(8 n + 7) div 8 == n`), with spawn `(7, 7)`, which on an all-walkable map of at least
15 x 15 pixels has clearance 8 (distance to the border plus one) and is standable
(`> PlayerHalf = 6`). It wraps the map in a `BodyMixedGraph(map: map)` with no other fields,
which is enough because `rebuildPackedWeights` reads only `graph.map`. Expected tables,
checked by hand against the scatter: the 5 x 4 raster (corner 1.0 at 0x8100, interior 0.5 at
0x8080, tiny 1e-6 at 0x8000 with zero low bits, opposite corner 2.0 at 0x8200, the two
non-hot cells at (0, 2) and (0..2, 3), and every neighbour-only hot cell) matches my own
derivation in `P1_REVIEW.md` exactly; the 1 x 3, 3 x 1 and 1 x 1 cases (including zero and
negative) are right. The range-boundary raise is exercised by the pre-existing S1 test, which
now runs through the stream. NaN is left untested, as advised. The two retained setup
failures (private fields, then a non-standable spawn) are the kind of thing worth keeping in
the log; the final constructor is the public one and the dimensions are chosen so the grid
size is exactly what the literal tables assume.

## 5. Independent evidence
- `tests/test_shell_body_nav_rework.nim` 16 of 16, `tests/test_shell_body_seat.nim` 29 of 29,
  both here with P1.
- Standalone differential (not in the tree): a verbatim copy of the parent scatter versus the
  working-tree `rebuildPackedWeights`, on real rasters from `initializeDanger` with eight
  sources at random positions (six trials each on s2 pool map 15 at 331 px and giant map 5 at
  1,300 px), an empty raster on each, and synthetic rasters at densities 0.001, 0.05, 0.5 and
  1.0 with one percent negatives and one percent tiny positives: 22 rasters, 0 mismatched
  cells.
- The corpus route hash and `pops_per_tick` equality in the m8i and m5a runs remain the
  in-tree exactness gate, since `mixedActive` reads the hot bit.

## 6. What remains
Timing in both regimes, as the preregistration says: the loaded 1,300 px rows where the
scatter does up to nine read-modify-writes per positive cell, and the sparse or empty case
where the stream's three loads per cell are new work. The Mac packer diagnostic is
informational only. No direction is predicted here for whole-body rows; the weight slice is
the primary observable and it must be reported separately from the inclusive danger slice.

Artifacts: the standalone script behind this review is preserved in `peer-proofs/` (see its `README.md` for the file, the command, and the provenance note that the original stdout was transcribed, not saved).
