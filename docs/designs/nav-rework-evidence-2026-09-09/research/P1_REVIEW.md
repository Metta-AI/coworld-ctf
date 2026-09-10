# P1 review: separable streaming 3 x 3 hot-bit dilation in `rebuildPackedWeights`

Written 2026-09-09 by Claude (peer) for `P1_REVIEW_REQUEST.md`. Source review only; no
edits, no timing claims. Current code: `body_route_query.nim`, `rebuildPackedWeights`
(pass 1 packs every cell with `packedDangerQ8`; pass 2, for every cell with `value <= 0`
false, ORs `0x8000` into the in-bounds 3 x 3 neighbourhood, computing the cell's `x`, `y`
by `mod` and `div` and bounds-checking each neighbour).
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact as a boolean operation, with one predicate condition: the streaming form must decide
"positive" with the same expression the current pass uses, `not (value <= 0)`, not
`value > 0`, or it changes behaviour on NaN. With that, every border, corner, one-wide,
one-high, zero, tiny-positive and range-boundary case matches, no memory is added, and the
raise path is unchanged in effect. Whether it is faster is regime-dependent (section 5); the
smallest literal differential test is in section 6.

## 2. The operation, stated
For cell `p`: `hot(p) = exists q in-bounds with Chebyshev(p, q) <= 1 and positive(q)`,
where `positive(q)` is `not (q <= 0)`; the low 15 bits are `packedDangerQ8(value(p))`
independent of `hot`. That is a binary dilation of the positive mask by the all-ones 3 x 3
structuring element, restricted to the map (SciPy `binary_dilation` with a 3 x 3 ones
structure and default border, OpenCV `dilate` with a 3 x 3 rectangle: same square
neighbourhood; neither library is worth a cross-toolchain dependency for one fixed-size
boolean pass in a Nim sim that also compiles to wasm, and the proposal's loop is a dozen
lines). The current pass computes it as a scatter from positive cells; the proposal computes
it as a gather per output cell. Both are the same set.

## 3. Border and degenerate cases, checked against the scatter
- Rows: for output row `y`, `columnHot(x) = positive(y-1, x) or positive(y, x) or
  positive(y+1, x)` with out-of-range rows replaced by row `y` (or simply omitted). The scatter
  skips out-of-bounds neighbours; the gather's duplicated row contributes only terms already
  present, so by idempotence of OR the two agree. Omitting instead of clamping is equally
  exact and avoids one branch; either is fine.
- Columns: `hot(x) = columnHot(x-1) or columnHot(x) or columnHot(x+1)` with out-of-range
  columns false; the scatter never writes across a row boundary because it bounds-checks
  `next.x`, and neither does the gather, so the wrap that a flat-index gather would risk
  does not arise.
- Corners: both a row and a column term drop; the remaining 4-cell neighbourhood matches
  the scatter's in-bounds subset.
- One-wide (`gridWidth == 1`): `columnHot(x +- 1)` are false; `hot = columnHot(0)`; the scatter
  skips `dx = +-1`. Match. One-high: rows clamp or omit to the single row; `columnHot = positive(x)`.
  Match. One-by-one: `hot = positive(0)`. Match.
- Zero and negative: `positive` is false; contributes nothing in both.
- Tiny positive (for example 1e-6): `packedDangerQ8` gives 0 in the low bits (scaled below
  0.5) but `positive` is true, so the cell and its neighbours are hot in both; the proposal
  correctly insists on the raw predicate for the high bit, not the packed value.
- Range boundary: `packedDangerQ8` raises above `0x7fff` exactly as now; the only difference is
  the scratch table's partial contents at the moment of the raise (pass 1 had written low
  bits without hot bits; the stream would have written some cells with hot bits). The raise
  propagates out of `publishDangerGeneration` before the L1 swap, so the seat's table is
  untouched either way and the scratch is fully overwritten on the next rebuild. Not
  observable.
- NaN: today `NaN <= 0` is false, so a NaN cell is treated as positive by pass 2 and reaches
  `packedDangerQ8` (undefined conversion, `S1_REVIEW.md` section 3). A stream written with
  `value > 0` would treat NaN as non-positive: a behaviour change on an input outside the
  contract, but a change. Keep the identical expression, `not (value <= 0)`, and the two are
  equal on every bit pattern, NaN included. This is the one thing to get right.

## 4. Memory and structure
Per row: three row base offsets and, per cell, three loads for `columnHot(x + 1)`, a three-way
OR of carried booleans, one `packedDangerQ8`, one write. No allocation, no scratch; the
`weights.len != cellCount` reallocation and the raster length check stay as they are. One
write per cell instead of one write plus up to nine read-modify-writes; no `div` or `mod`.

## 5. Where it could lose (the counter-hypothesis)
The scatter's cost is proportional to the number of positive cells (nine bounded RMWs and one
`div`/`mod` each); the gather's cost is proportional to all cells (three loads and compares
each, on top of pass 1's one load). On a raster with few positives, notably a seat with no
visible threat (all zero) or a seat whose threats are far from it, pass 2 is nearly free
today and the gather adds about 2N loads. On a raster where the LOS disc covers much of the
map (eight sources at 1,300 px, up to about 84k positive cells on a giant map of 86k), the
scatter does up to 9N RMWs plus N divisions and the gather wins clearly. Two facts narrow the
downside: L1 skips the whole rebuild when the table is unchanged, so steady-state rebuilds are
the changed ones, and the loaded rows are the ones that fail the gate. But the counter-case
is real and the preregistration should measure both regimes: the 1,300 px loaded rows and a
row whose seats see no threats (the harness's tracks can be dropped for that row, or the
weight slice read from a seat with an empty selection). Scalar short-circuit in the OR chain
does not change the load count materially because `columnHot(x + 1)` must be evaluated for
the next cell anyway; a branch-free OR of three loads is the likely codegen and is
predictable.

## 6. Smallest independent differential test with literal expected masks
Do not test the stream against a second implementation of itself. Use hand-derived expected
tables on tiny rasters through the public `rebuildPackedWeights` on a graph whose grid has the
chosen dimensions (`openMap()`-style helper maps of 5 x 4, 1 x 3 and 3 x 1 cells; or a
minimal `BodyMixedGraph` over such a map), checking the packed table cell by cell:

Raster A, 5 wide x 4 high (row-major, `.` = 0, values in danger units):
```
row 0:  1.0  .    .    .    .
row 1:  .    .    0.5  .    1e-6
row 2:  .    .    .    .    .
row 3:  .    .    .    .    2.0
```
Expected low 15 bits: (0,0) 256; (2,1) 128; (4,1) 0 (tiny rounds to zero); (4,3) 512; all
others 0. Expected hot mask (H = hot):
```
row 0:  H  H  H  H  H
row 1:  H  H  H  H  H
row 2:  .  H  H  H  H
row 3:  .  .  .  H  H
```
Derivation: (0,0) hots (0..1, 0..1); (2,1) hots (1..3, 0..2); (4,1) hots (3..4, 0..2); (4,3)
hots (3..4, 2..3). This pins a corner with two dropped sides, an interior cell, a tiny
positive that is hot with zero low bits, the opposite corner, and cells hot only through a
neighbour (for example (1,2), (3,2), (4,2)).
Raster B, 1 wide x 3 high: values `[0, 0.25, 0]` top to bottom; expected low bits `[0, 64, 0]`,
hot `[H, H, H]`.
Raster C, 3 wide x 1 high: values `[0, 0, 0.25]`; expected low bits `[0, 0, 64]`, hot `[., H, H]`.
Raster D, 1 x 1: value 0.25; low bits 64, hot H. Value 0: 0, not hot.
Raster E, range: a cell at `32767.5 / 256` raises `BodyMapError` as today (already covered by
the S1 test; keep one case so the stream's raise path is exercised).
Raster F, NaN (documentation of the retained contract, not a new one): one NaN cell; expect
the hot mask to be identical to the current implementation's on the same raster, which with
the `not (value <= 0)` predicate is "hot neighbourhood"; if Codex prefers not to encode
undefined behaviour in a test, assert only that the predicate expression in the source is
`not (value <= 0)` by review, and leave NaN untested.
Plus the exactness gate that already exists: the corpus's per-case danger hashes do not see
the packed table, so add the L1 test's raster-to-table comparison against a forced rebuild
with the parent packer on the two-source fixture, or simply the full corpus route hash and
`pops_per_tick` equality, which do depend on the hot bits through `mixedActive`.

## 7. Preregistration notes (Codex owns)
Parent: D1 checkpoint. Exactness: route hash, pop arrays, masks, per-case danger hashes,
retained ledger unchanged (no allocation), and the literal tests above. Timing: the weight
slice (`weight_refresh_p95_ns`) is the primary row; three interleaved m5a pairs at 1,300 px,
plus one no-threat regime as in section 5; report the danger slice inclusive and the weight
slice separately, never subtracted. Prediction stated for falsifiability: the weight slice
falls on loaded rows and may rise on empty rows; whole-body changes are not predicted.
