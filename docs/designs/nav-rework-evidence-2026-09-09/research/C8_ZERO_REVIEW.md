# C8_ZERO_REVIEW: omit zero-weight cells from the visibility cache (count and proof)

Peer (Claude) read-only screen per `C8_ZERO_REVIEW_REQUEST.md`. No source
change. Tool and raw outputs in `research/C8/` (`c8_zero_count.nim`, a
read-only include of the frozen C2 cache source; `c8_kernel.json`,
`c8_traces.json`, `c8_map3_1300.json`, `c8_map3_331.json`). Hit and miss
classification is the same sequential per-source LRU replay the C6 count
used, valid for these nine traces per `C6_COUNT_ROOT_CHECK.md`; not a
shortcut for new inputs.

## 1. The kernel's nonzero support (measured from `initDangerGeometry`)

| live range px | radius cells | box cells | nonzero kernel cells | max abs offset | square bound | min nonzero | negative or non-finite |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 331 | 42 | 7,225 | 5,385 | 41 | 6,889 | 1.0 | 0 |
| 1050 | 132 | 70,225 | 54,173 | 131 | 69,169 | 0.6000293 | 0 |
| 1300 | 163 | 106,929 | 54,173 | 131 | 69,169 | 0.6000293 | 0 |
| 1600 | 200 | 160,801 | 54,173 | 131 | 69,169 | 0.6000293 | 0 |

`attenuation` returns 0 when `distancePx > min(1050, range)`, 1 up to 400
px, and a linear ramp to 0.6 at the cutoff, so every kernel value is in
{0} or [0.6, 1]; none is negative, NaN or infinite. The support is fixed
once the range exceeds 1050 px: the nonzero cells are exactly those with
`hypot(dx, dy) * 8 <= 1050`, whose max axis offset is 131 (131 * 8 = 1048;
132 * 8 = 1056 > 1050), giving the 263 by 263 = 69,169 square the request
predicted; the measured maximum offset equals the predicted `min(1050,
range) div 8` at every range tested, including 331 where it is 41. The
float boundary is safe: integer `dx*dx + dy*dy = 17,226` gives 1049.98 and
17,227 gives 1050.01, both far from double rounding. This bound is for the
kernel only; the ray perimeter still grows with range (236 offsets at 331,
924 at 1300, 1,132 at 1600), so ray cost is not bounded by the square and
nothing here adds or implies a range limit.

## 2. Count: recorded cells whose kernel value is zero

| workload | sources | zero-kernel share of set bits | zero cells per source | nonzero per source | max nonzero per source |
|---|---:|---:|---:|---:|---:|
| s2_16_679962 hits (5204) | 75 | 0.079 | 1,205 | 14,087 | 16,981 |
| s2_16_679963 hits (5263) | 48 | 0.058 | 863 | 13,908 | 19,208 |
| s2_16_679964 hits (5204) | 77 | 0.076 | 1,054 | 12,834 | 17,064 |
| s2_16_679965 hits (5001) | 29 | 0.090 | 1,444 | 14,632 | 20,551 |
| s2_32_679962 hits | 375 | 0.080 | 1,113 | 12,878 | 17,040 |
| s2_32_679963 hits | 286 | 0.056 | 815 | 13,801 | 19,208 |
| s2_32_679964 hits | 295 | 0.081 | 1,117 | 12,723 | 17,040 |
| s2_32_679965 hits | 248 | 0.104 | 1,485 | 12,845 | 20,574 |
| smoke (randomized seed) hits | 33 | 0.096 | 1,442 | 13,627 | 20,356 |
| map 3 (5120) 1300 px, every 3rd standable cell | 22,513 | 0.088 | 989 | 10,218 | 22,631 |
| map 3 331 px, same origins | 22,513 | 0.034 | 109 | 3,057 | 5,165 |

Miss-path bitmaps show the same shares (0.063 to 0.092 at 1300 px). So at
the configured range 6 to 10 percent of recorded cells and replayed adds
are `+= 0.0`; at 331 px about 3 percent. Every one of them is a cell the
ray walk reached beyond 1050 px from the source.

## 3. Proof that omitting the zero adds is bit-exact

Per rebuild, `values[c]` is assigned `0` (float32 positive zero) and then
receives, in source order, at most one kernel add and at most one floor
add per source. All addends are nonnegative finite: kernel values are in
{0} or [0.6, 1] (section 1), the floor is 0.5, and no other write reaches
the raster before the final scan (`DangerLosWeight = 1.0`, so the scale
branch is compiled out). Claims:

- No negative or non-finite value ever appears: a sum of nonnegative finite
  float32 values in round-to-nearest is nonnegative and, with at most 8
  sources times 1.5 per cell (at most 12), finite.
- Negative zero never appears: `+0 + +0 = +0` in round-to-nearest, and any
  positive addend gives a positive result; there is no subtraction and no
  negative operand anywhere in the path.
- Adding positive zero is the identity on every value that can occur:
  `x + (+0.0) = x` exactly for every finite `x`, including `+0.0`. (The
  only case where adding a zero changes a float bit pattern is
  `-0.0 + +0.0 = +0.0`, and `-0.0` cannot occur.)

Therefore removing every `+= kernel[k]` with `kernel[k] == 0` leaves every
raster bit unchanged, hence `maximum`, the packed Q8 weights, the
fingerprints, and the corpus hashes unchanged. Omitting the bit from the
bitmap (or the cell from a list) removes exactly those adds and nothing
else, because the bitmap's only consumer is the replay. The visited stamp
and the ray traversal are unchanged, so miss-path control flow, stopping
points, and the visible set for stamping purposes are identical; only the
recorded set shrinks. Reference for the pattern, not for the proof:
scipy's `csr_matrix.eliminate_zeros` removes explicit zeros as a
representation choice; the float identity above is what makes it exact
here.

## 4. The two-line change (not applied; for root's preregistration)

In `addVisibleCell`, after the stamp is stored and `kernelIndex` computed:
`let weight = kernel[kernelIndex]`; `if weight == 0'f32: return` before
the bit set and the add (or equivalently guard both with the weight). The
stamp stays exactly where it is. Preregister: identical corpus hash,
identical nine-trace chains (the chains hash rasters, not bitmaps, so they
must not move), the C6 crafted diagnostic (which overwrites the kernel
with nonzero values and is therefore unaffected), and the focused suite.
Count the bitmap set bits before and after to confirm the 6 to 10 percent
reduction. Expected effect: 6 to 10 percent fewer replay adds and bitmap
bits at 1300 px, about 3 percent at 331; the miss ray walk is unchanged
in work except for skipping the store and add on those cells. Interaction
with C6: the zero cells sit at the far edge of the visible disc, so
removing them cannot create new full words and may break a few; C6's
share should be re-counted after the change, not assumed.

## 5. Consequences for C7 sizing

A nonzero-only list is bounded by the kernel support, 69,169 cells at any
range of 1050 px or more, and by 6,889 at 331 px: 32 slots times 8 bytes
times 69,169 is 17,707,264 bytes at 1300 px against 27,373,824 for the
full box. Observed nonzero maxima are lower still (22,631 on map 3, 21,141
on the traces) but must not be used as a cap. This bound holds for every
supported live range because the support depends only on the fixed 1050
px cutoff; the ray box, the perimeter count and the bitmap words still
grow with range.

C8 REVIEW READY
