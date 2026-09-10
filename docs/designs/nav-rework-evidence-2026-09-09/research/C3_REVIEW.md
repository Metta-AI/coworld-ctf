# C3_REVIEW: monotone row cursor in the cache-hit replay

Peer (Claude) read-only review of `C3_REVIEW_REQUEST.md`. No source edit.
Subject: replacing `kernelIndex div diameter` per set bit in
`replayVisibleCells` (`body_nav.nim`, C2 hit path) with a row cursor that
advances while `kernelIndex >= rowEnd`. No speed claim; root measures.

## 1. What the loop guarantees today

The scan visits words in ascending `wordIndex`, and inside a word takes
`countTrailingZeroBits` and clears the lowest set bit, so `kernelIndex =
wordIndex * 64 + bit` is strictly increasing over the whole bitmap. Padding
bits above `d * d - 1` in the last word are never set (only
`addVisibleCell` writes bits, at indices below `d * d`), so every visited
`kernelIndex` is inside the box, and every recorded cell is in-grid for
this origin (C2 invariant, tested). The float operation per bit is
`values[index] += kernel[kernelIndex]`; only `index` is computed
differently by C3.

## 2. Exactness of the recurrence

Let `d = 2r + 1`, `base = (oy - r) * W + ox - r`, and for a set bit `k`
let `ky = k div d`, `kx = k - ky * d`. The current index is
`(oy - r + ky) * W + ox - r + kx = base + ky * (W - d) + k`, using
`kx = k - ky * d`.

The cursor keeps `rowEnd = (row + 1) * d` and `gridOffset = base +
row * (W - d)`, starting at `row = 0`. On each set bit, `while k >= rowEnd`
increments `row` once per iteration. Because the bits are ascending, `row`
never needs to decrease, and after the loop `row = k div d` exactly: the
loop exits when `k < (row + 1) * d` and entered only while `k >= row * d`
(each earlier `rowEnd` was `row * d` at some point or `row` was already
correct for a smaller `k`). So `gridOffset + k = base + (k div d)(W - d) + k`,
identical to the current formula for every `k`. Gaps and empty words only
make the while loop advance several rows in one bit; `row` still ends at
`k div d`. Diameters below 64 put several rows in one word; the argument
is per bit and does not care. The total number of row advances over one
replay is at most `d - 1`, since `rowEnd` never exceeds `d * d`.

Signed arithmetic: `base` is negative when the box extends above or left
of the grid, and `W - d` is negative when the box is wider than the grid
(small maps, 1300 px). Both are fine in Nim `int`; the final `gridOffset +
k` equals the old value, which is a valid index for every set bit by the
C2 invariant. Nothing here can overflow (`d * d` is 106,929 at 1300 px).

Verified by exhaustive integer comparison
(`peer-proofs/c3_row_cursor_check.py`, output in `.out`): 14 radii from 1
to 200 including 32, 42, 63, 64, 65 and 163; grids narrower than, equal
to, and wider than the box (including 20, 60, 401 cells); six origins per
grid including negative row bases and origins outside the grid; every
`k` in `0 ..< d*d` in order, plus random sparse subsets, row-boundary-only
subsets (`ky*d` and `ky*d - 1`), the last bit alone, and the empty set.
588 combinations, 16,058,910 index comparisons, all equal, and the
advance count is exactly `d - 1` on the full set and at most `d - 1` on
every subset.

## 3. Nothing else changes

The bitmap, the cache policy, the per-source floor interleaving, source
order, the set of adds and their float order (row-major within a source,
identical to C2), and the kernel values are untouched; the recurrence
changes integer index arithmetic only. The existing C2 tests (byte-for-byte
raster equality against a fresh system, packed weights, the trace replay
with hash chains) are exactly the right regression for it and should be
rerun unchanged; the corpus quality hash must stay at the C2 value.

## 4. Existing patterns

The repo has no row-cursor helper to reuse; the closest existing code is
the same word/ctz scan in `replayVisibleCells` itself (added by C2) and
the `index div width` row extraction in `body_map.nim` (lines 623, 653,
674) which is the pattern being strength-reduced. A local cursor inside the
one proc, as proposed, is the right size; a new abstraction would be
larger than the code it replaces.

## 5. Implementation notes for root

- Initialise `rowEnd = diameter` and `gridOffset = (origin.y - radius) *
  gridW + origin.x - radius` once per replay (per source), before the word
  loop; `kernelIndex` stays as computed today.
- Keep the loop `while kernelIndex >= rowEnd` (not `if`): a gap can span
  many rows.
- Add one exhaustive Nim test that runs the two formulas over every `k`
  for a few `(radius, gridW, origin)` triples including a negative base
  and `gridW < diameter`, mirroring the Python check, so the property is
  pinned in the suite rather than only in a proof note.
- Preregister the paired m5a measurement as configured 1300 px worst p95
  and the danger slice, parent C2 versus C2 plus C3, with the real-trace
  regime; the prediction is "not slower", and any gain is bounded by the
  hit share of rebuild time. C3 does not touch the miss path, so the
  0 of 11 configured tick-gate status cannot change from it alone.

C3 REVIEW DONE
