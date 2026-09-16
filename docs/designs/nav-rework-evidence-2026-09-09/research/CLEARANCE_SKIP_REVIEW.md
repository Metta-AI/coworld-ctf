# Clearance-skip review (W7): safe sample skipping from the existing chessboard transform

Written 2026-09-09 by Claude (peer) for `CLEARANCE_SKIP_REVIEW_REQUEST.md`. Source review
and proof attack only; no edits, no timing claims. W6 (major-axis specialisation) is the
exact baseline this would be measured against; W7 is not implemented.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict: GO, with three conditions
The rule "at sample `i` read `d = clearance[P_i]`; `d == 0` blocks; otherwise the next sample
that must be checked is `i + d`, and if `i + d > steps` the ray is clear" returns exactly what
the current sampler returns on every input, provided (a) the jump coordinates are computed
with the same exact rational rule and ties convention as W1 using 64-bit intermediates,
(b) the sampler keeps reading the same pixel sequence (the skipped pixels are never read, but
the ones read are the same pixels the old sampler read), and (c) the implementation falls back
to the incremental step for small `d`, which is a performance choice, not a correctness one.
Each attack below either fails or yields a condition already listed.

## 2. What `buildClearance` computes (`body_map.nim:290-311`)
Two-pass sequential chamfer with the full 8-neighbour mask and unit weights: forward pass
over walkable pixels takes `min(255, 1 + min(left, up, up-left, up-right))`; backward pass
takes `min(current, 1 + min(right, down, down-right, down-left))`; non-walkable pixels stay
0; neighbours outside the map read as 0. For the chessboard metric this two-pass algorithm
(Rosenfeld and Pfaltz's sequential distance transform; SciPy's `distance_transform_cdt` with
the 8-connected structure computes the same quantity: each foreground element's shortest
chessboard distance to the nearest zero) is exact: `clearance[p]` equals the Chebyshev
distance from `p` to the nearest pixel that is a wall or lies outside the map, saturated at
255. Consequences used below:
- `clearance[p] == 0` iff `wall[p]`, because `wall[i] = not pixelWalkable[i]` (966) and the
  transform assigns every walkable pixel at least 1 and every non-walkable pixel exactly 0.
- `clearance[p] = d >= 1` implies every in-map pixel within Chebyshev distance `d - 1` of `p`
  is walkable; with saturation, `d = 255` implies the true distance is at least 255, so the
  radius-254 square is walkable: saturation is conservative.
- Both `wall` and `clearance` are written once in `newBodyMap` from the same input raster
  and never again (the only writes are lines 966-967); the map is immutable, so there is no
  stale state to consider.

## 3. The skip invariant, attacked

### 3.1 Consecutive samples move at most one pixel per axis
The major axis advances exactly one pixel per sample (W6 form). On the minor axis the exact
value advances by `delta = |dy| / steps <= 1` per sample. For `delta < 1`: if `round(v) = n`
then `v <= n + 1/2`, so `v + delta < n + 3/2`, and `round(v + delta) <= n + 1` unless
`v + delta = n + 3/2` exactly with `n + 1` odd, which would need `v = n + 3/2 - delta > n +
1/2`, contradicting `round(v) = n` except at the tie `v = n + 1/2` (rounded to even `n`), and
that case needs `delta = 1`. For `delta = 1` (pure diagonal, `|dy| = steps`) every exact
value is an integer, no ties occur, and the coordinate advances by exactly 1. Monotonicity
gives the lower bound 0. So `Chebyshev(P_i, P_{i+j}) <= j` for every `j >= 0`. This is the
discrete Lipschitz bound that plays the role of the unit-Lipschitz distance field in Hart's
sphere tracing; it is proved here for this sampler, not borrowed.

### 3.2 The jump is exact
With `d = clearance[P_i] >= 1`, every `P_{i+j}` for `1 <= j <= d - 1` lies within Chebyshev
distance `d - 1` of `P_i`, hence is walkable, hence would not have blocked. Checking
`P_{i+d}` next skips only pixels the old sampler would have found clear. If `i + d > steps`,
all remaining samples have `j <= steps - i <= d - 1` and are clear, so returning `true` is
what the old loop would have returned. Result equality holds on every ray.

### 3.3 Saturation
Covered: 255 is a lower bound on the true distance, so the jump of 255 is within the proved
radius. No ray ever needs more than 255 samples skipped at once to be correct; it only needs
the skip to be no larger than the true clearance, which saturation guarantees.

### 3.4 Map boundary
`rayClear` refuses out-of-map endpoints before sampling, and every sample lies in the closed
box between the endpoints (`W2_REVIEW.md` section 2), so no read is out of range. At the
border the transform treats outside as 0, so a walkable border pixel has clearance 1 and the
skip degenerates to one step. Conservative; no special case needed. `steps == 0` keeps its
existing branch (`not isWall(a)`, equivalently `clearance[a] == 0`), unchanged.

### 3.5 Diagonal steps
A diagonal move changes both coordinates by 1; Chebyshev distance counts that as 1, which
section 3.1 already bounds. The old sampler never checked corner pixels between diagonal
neighbours, and neither does this; the set of pixels whose wall status decides the result is
unchanged (it is the sample set, of which the read subset is a superset of the blockers).

### 3.6 Nearest-even ties at the jump target
The sample at index `k = i + d` must be the same pixel the incremental sampler would reach.
Closed form per axis: `q = delta_axis * k`, `lower = a + floorDiv(q, steps)`, `remainder =
floorMod(q, steps)`, then W1's `roundedRayCoordinate(lower, remainder, steps)` with the parity
of the full coordinate. Because W1's incremental state is exactly `(lower, remainder)` of the
same rational, the closed form lands on the identical value and the identical tie decision.
Two traps: Nim's `div` and `mod` truncate toward zero, so negative `q` needs `floorDiv` and
`floorMod` (std/math) or an explicit correction; and the parity test must use the full
coordinate `lower`, as W1 does, not the quotient alone.

### 3.7 Integer width, wasm, long maps
`delta_axis * k` is at most `D^2` with `D` up to 2^23 on the supported bound
(`W1_REVIEW.md`), that is up to 2^46: it must be computed in `int64`. Nim's `int` is 64-bit
on the server targets but 32-bit on wasm32; if any wasm build (the replay viewer or a runtime
target) compiles `body_map.nim`, an `int` product would overflow silently there. Use `int64`
explicitly for `q` regardless of target; `lower`, `remainder` and coordinates then fit `int`
on every target (they are bounded by `2 * D`). This is condition (a).

### 3.8 Endpoint handling
The last sample is index `steps`, the endpoint `b` itself. If a jump lands exactly on
`steps`, the endpoint is read as before. If it overshoots, section 3.2 covers the endpoint.
The first sample is `a`, read at `i = 0` before any skip, so a wall at the origin still
blocks as today.

### 3.9 Zero-length and degenerate rays
`steps == 0`: unchanged early branch. `steps == 1`: `i = 0` reads `a`; `d >= 1` jumps to
`i = 1 = steps`, reads `b`; identical. A ray along the border: clearance 1 everywhere on it;
the loop degenerates to W6 exactly.

### 3.10 Stale or mutable clearance
None: single construction, private field, no writers, map immutable by design. If a future
feature ever mutated `wall` without rebuilding `clearance`, the skip would become unsound;
a construction-time assertion that `clearance[p] == 0 iff wall[p]` for all `p` (cheap, one
pass) pins the coupling, and a comment on `wall` should say the ray skip depends on it.

## 4. What it does to the work, without numbers
Visited samples fall from `steps + 1` to roughly the number of clearance-sized jumps along
the ray: in open ground one read per up to 255 pixels, in corridors of width `w` one read per
about `w / 2` pixels. The per-visit cost rises from an add-and-compare to an `int64`
multiply, a floor division and modulo, and the rounding test; so in tight corridors (clearance
1 or 2) W7 does more work per pixel than W6. Condition (c): keep W6's incremental step for
`d` below a small threshold (2 or 3) and jump only above it; the threshold changes nothing
about correctness. Whether the net is positive on the loaded 1,300 px rows is what the
measurement decides; it is plausible because those rays cross open ground.

## 5. Focused tests before any timing
1. Transform property, all pool maps and the 11 giant maps: for every pixel `p`,
   `clearance[p] == 0` iff `wall[p]`; and for every `p` with `d = clearance[p] > 0`, every
   in-map pixel within Chebyshev distance `d - 1` is walkable (a bounded neighbourhood scan;
   cap `d` at a small value for the exhaustive form and sample the rest).
2. Differential rays against W6 on the existing 262,144 single-wall small rays and the 20,000
   seeded long rays, plus the per-axis coordinate comparison from `W1_REVIEW.md` extended to
   jump targets: for random `(a, delta, steps, k)`, the closed form equals the incremental
   state after `k` advances (including negative deltas and tie cases with even and odd
   `lower`).
3. Wall placement at exactly `d` and `d - 1` from a sample on a straight and on a diagonal
   ray, both orientations, verifying the block is found (at distance `d`) or correctly
   skipped (at `d - 1` is impossible by the transform; the test asserts the transform value).
4. Saturation: a 600 x 600 open map with one wall pixel; rays that pass within and beyond
   255 pixels of it; results equal W6.
5. Border rays and the `steps` in {0, 1, 2} cases.
6. An `int64` overflow guard test on a synthetic large-dimension `BodyMap` is impractical
   (the map would be huge); instead a unit test of the closed-form helper with `delta` and
   `k` near 2^23 against a Python-checked expectation, run on the native target, plus a static
   check that the helper's product type is `int64`.

## 6. Sources
- Hart, "Sphere Tracing: A Geometric Method for the Antialiased Ray Tracing of Implicit
  Surfaces", The Visual Computer 12(10), 1996 (the linked Stanford copy): safe step size from
  an unbounding-sphere distance bound with a Lipschitz-1 field. Used here only as the
  analogy; the discrete guarantee is section 3.1.
- SciPy `scipy.ndimage.distance_transform_cdt` documentation: the chessboard variant replaces
  each foreground element with its shortest distance to the nearest zero element using the
  8-connected structure. Confirms the quantity `buildClearance` computes; no dependency
  needed since the transform already exists in the map.
- Rosenfeld and Pfaltz, "Sequential Operations in Digital Picture Processing", JACM 13(4),
  1966: the two-pass sequential algorithm computes the exact chessboard distance with the
  8-neighbour mask. Cited from knowledge of the paper, not re-fetched.
