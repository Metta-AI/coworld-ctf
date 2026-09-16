# W1 review: integer ray sampling in `rayClear`

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff to `src/shell/body_map.nim`
(`rayClear` sampling only), the new `tests/test_shell_body_ray.nim`, its import into
`test_shell_body_map.nim`, and the harness mask recording in `tools/bench_body_nav_rework.nim`.
No source edits. Independent checks on this Mac: the new suite passes (2 of 2), the body-map
suite that imports it passes (17 of 17), and a standalone per-point comparison of the
incremental coordinate against the old float sampler over 176,137,197 sampled coordinates
found 0 mismatches (details in section 3).
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact. The incremental sampler reproduces every pixel the float interpolant sampled, in the
same order, for every in-bounds segment on any supported map, so `rayClear` returns the same
result on every input. The distance test, the wall predicate and the bounds handling are
untouched. The tests cover the ray outcome well; they do not directly pin the sampled
coordinates, which is the actual contract, and one cheap addition closes that (section 4).

## 2. Exactness argument, checked against the code
Let `steps = max(|dx|, |dy|) > 0`. The old sample on one axis at step `k` is
`pyRound(a + dx * k / steps)` in double arithmetic. The new code keeps `lower` and
`remainder` with the invariant `a + dx * k / steps == lower + remainder / steps`,
`0 <= remainder < steps`.
- Invariant: `remainder` starts at 0 with `lower = a` (step 0). `advanceRayCoordinate` adds
  `dx`; since `|dx| <= steps`, the sum lies in `[-steps, 2 * steps - 1]`, so one correction
  (`+= steps, dec lower` or `-= steps, inc lower`) restores `[0, steps)`. Verified by cases
  including `remainder == -steps` and `2 * steps - 1`. Negative `dx` and `a` are handled
  because the correction is by sign, not by division, and `lower and 1` on a negative
  two's-complement `int` gives the correct parity.
- Rounding: `roundedRayCoordinate` returns `lower + 1` if `2 * remainder > steps`, `lower +
  1` on an exact tie when `lower` is odd, else `lower`. That is nearest-with-ties-to-even on
  the exact rational, with parity taken on the full coordinate `lower = a + floor(dx k /
  steps)`, exactly as `pyRound` took it on `floor(value)`.
- Equality with the double path, stated for the supported bound rather than any particular
  map (correction after Codex: colossal is 6,422 x 3,427 and `MaxValidatorTableBytes` =
  268,435,456 admits larger; with an 8 px minimum dimension and at least one validator table,
  any dimension is at most D = 8,388,608 = 2^23 and the area at most 2^26). With
  `|a|, |dx|, steps, k <= D`: the product `dx * k` is at most 2^46, exact in a double; the
  quotient `q = dx * k / steps` has magnitude at most 2^23, so its correctly rounded error is
  at most 2^-30; the sum `a + q` has magnitude at most 2^24, so its rounding error is at most
  2^-29; total error at most 1.5 x 2^-29. The exact fractional part of `a + dx k / steps` is
  either 0, or exactly 1/2, or at least `1 / (2 * steps) >= 2^-24` from both. In the 0 and
  1/2 cases `q` is an integer or half-integer, representable, so the division is exact and the
  sum of two representable values with magnitude at most 2^24 is exact: both paths see the
  identical value and round it identically. Otherwise the double's error (at most 1.5 x
  2^-29) is about 21 times smaller than the 2^-24 margin, so it cannot cross a floor
  boundary or reach the half. In general the argument holds while `3 D 2^-53 < 1 / (2 D)`,
  that is `D < 2^25`, so the supported bound has headroom of a factor of about 4 in D. The
  integer path needs no bound beyond `int64`: `remainder < 2 * steps <= 2^24` and `lower`
  stays within `[-2^24, 2^24]`.
- No overflow: `remainder` stays below `2 * steps`; nothing multiplies coordinates.
- Zero delta on an axis: `remainder` stays 0, the coordinate stays `a`; matches.
- Everything else in `rayClear` (bounds refusal, `steps == 0` case, `isWall` per sample, early
  exit on the first wall) is unchanged.

## 3. Independent evidence
- New suite: `every small ray agrees for every single blocking pixel` (64 wall positions x
  4,096 endpoint pairs on a 64 x 64 map, all directions, lengths 0 to 7, plus two out-of-bounds
  refusals) and `seeded long rays preserve sampled walls in both directions` (10,000 seeded
  pairs on 3,312 x 96 with sparse walls, both orientations): pass here.
- Standalone check (not in the tree): the incremental coordinate versus `referenceRound(a +
  d * k / steps)` per sampled point, exhaustively for `steps` 1..400 and every `|d| <= steps`
  with origins 0, 1 and 3,211; 20,000 seeded `(a, d, steps)` triples with `steps` up to 3,312;
  and an exact-tie sweep at every even `steps` up to 3,312 with deltas that force
  `2 * remainder == steps`. 176,137,197 coordinates, 0 mismatches, about one second in
  release.

## 4. Test adequacy
What the two tests prove: identical ray outcomes on the small map for every short segment
(where each sampled pixel is individually load-bearing because the single wall pixel moves
over all 64 positions), and identical outcomes on long rays against sparse walls.

Gap: on the long-ray test a sampled-point difference only shows if it lands on one of the
sparse wall pixels (one per 97 columns), so most of a long ray's samples are not checked.
The contract is "same sampled points", and the cheapest direct test is the per-axis
comparison in section 3 (a few hundred million coordinate compares run in about a second in
release; a 1..400 exhaustive band plus seeded large cases and the even-`steps` tie sweep is
enough). Either expose the two coordinate helpers to the test or duplicate them in the test
against the old `referenceRound`. That makes the suite prove the contract rather than a
consequence of it. Also worth one explicit case each: a ray whose sampled coordinate crosses
a negative `lower` correction (`dx < 0` on a long ray), and a tie with even and odd full
coordinates at the same `remainder`, both of which the exhaustive band already contains but
the test names should say so.

Not needed: negative coordinates as endpoints (rejected by `inBounds` before sampling) and
NaN (no floats remain).

## 5. Harness mask recording
`tickRow` now records every encoded mask per seat per tick, including the initial step and the
warm-ups, into `masks_per_tick` (int16, `-1` for absent), captured after `episode.step` returns
and outside the body timing. It is common to both arms, so it costs the same in parent and
candidate and gives the exactness comparison the weapon change needs: identical
`masks_per_tick` across the 331 and 1,300 px rows between parent and candidate is the
observable that `rayClear` decisions did not change under the real scheduler. Good. The
comparison must be parent-versus-candidate at the same range, never across ranges.

## 6. What remains before W1 counts
- Remote parity: the proof is arithmetic and platform-independent, but the m5a run should
  show `masks_per_tick`, `pops_per_tick`, corpus route hash and per-case danger hashes all
  equal to the parent, then the weapon slice on the loaded 1,300 px rows versus the A/A
  spread, as in `WEAPON_RANGE_REVIEW.md` section 5. No timing is claimed here.
- W2 (direct wall-byte read inside the loop) and W3 (squared-distance gate) are still
  separate candidates; W1 alone leaves the per-sample `isWall` call chain in place.
