# W7 code review: clearance-skip ray sampling as implemented

Written 2026-09-09 by Claude (peer). Reviewed the working-tree `rayClear`,
`advanceRayCoordinate` and `roundedRayCoordinate` in `src/shell/body_map.nim`, the third
test in `tests/test_shell_body_ray.nim`, and `tools/investigate_body_ray_clearance.nim`.
No source edits. Independent checks on this Mac: the ray suite passes 3 of 3 and the map
suite that imports it 18 of 18; a standalone differential of the working-tree `rayClear`
against a copy of the original float sampler on real geometry (s2 pool maps 15 and 29, giant
map 5; seeded endpoint pairs within 1,300 px and within 40 px; 700,000 pairs) found 0
mismatches. No timing is claimed; the m5a pairs decide that.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact. The implementation matches the proof in `CLEARANCE_SKIP_REVIEW.md` point for point,
the 64-bit arithmetic is explicit where it must be, the endpoint and zero-length paths are
unchanged, and the all-map verifier checks the exact soundness conditions the skip relies on
rather than trusting the transform's exactness. Two notes in section 5, neither blocking.

## 2. The loop, checked against the proof
Per branch (major axis x or y): `sample = 0`; loop while `sample <= steps`:
- read `clearSteps = clearance[pixelIndex(x, y)]` at the current sample, with the minor
  coordinate from `roundedRayCoordinate(lower, remainder, steps)` (W1's exact rule, full
  coordinate parity);
- `0` returns `false`: identical to the old sampler's wall test, since `clearance == 0` iff
  `wall` (verified in section 4);
- `clearSteps > steps - sample` returns `true`: the remaining samples are at most
  `steps - sample <= clearSteps - 1` samples away, hence within the clear square;
- otherwise `sample += clearSteps`, the major coordinate advances by `stepX * clearSteps`
  (integral on the major axis), and the minor state advances by `clearSteps` exactly.
The loop reads the sample at index `steps` (the endpoint) when a jump lands on it, and never
reads out of the endpoint box. Termination is strict because `clearSteps >= 1`. The trailing
`true` is unreachable in practice but harmless.

## 3. `advanceRayCoordinate` with `advance > 1`
`accumulated = remainder.int64 + delta.int64 * advance.int64`; `whole = floorDiv(accumulated,
steps.int64)`; `lower += whole.int`; `remainder = (accumulated - whole * steps).int`. This is
`floorMod` written out, so `remainder` lands in `[0, steps)` for negative deltas too, and
`(lower, remainder)` is the exact rational state W1 would reach after `advance` unit steps.
Widths, stated exactly (correcting my first draft): `|delta| <= steps <= 2^23 - 1` and
`advance <= 255`, so `|delta * advance| <= 255 * (2^23 - 1) = 2,139,094,785`, and with
`remainder < 2^23` the accumulated value is at most 2,147,483,391 in magnitude, which is
inside a signed 32-bit `int` by only 256 units. The explicit `int64` is therefore not
strictly required at the supported bound, but it is the right choice: the margin is too thin
to rely on, and any future increase in the clearance saturation or the dimension bound would
overflow a 32-bit `int` on wasm32 silently. `whole` is at most 255 in magnitude and
`remainder` below `2^23`, so the two `.int` conversions are safe on 32-bit targets. The `advance == 1` branch keeps W1's single correction, which is the cheaper
path for clearance 1. Both branches compute the same state; my per-point differential in
`W1_REVIEW.md` covered the incremental form, and the 700,000-pair real-map run covers the
jump form on the outcome.

## 4. Soundness of the clearance bound, as verified
The verifier (`investigate_body_ray_clearance.nim`) checks on every pool map, the 11 giant
maps and colossal: `clearance == 0` iff `isWall`; border pixels at most 1; and for the four
undirected edge directions that cover all eight neighbours, `|clearance(p) - clearance(q)| <=
1`. Those three facts imply `clearance(p) <= Chebyshev(p, nearest wall or edge)` by induction
along any shortest 8-connected path, which is exactly the lower-bound property the skip uses;
exactness of the transform is not needed and not assumed. Codex reports all 76 maps pass
after repairing the pool reader (the first attempt misread the giant pool's bare specs; that
failure is retained). This is the right verification shape: it is checkable per map and
survives any future change to `buildClearance` that keeps the three properties.

## 5. Tests and notes
- New test: a 640 x 640 open map with two wall pixels pins exact clearances (255 saturated
  at (300, 300), 100 and 99 near a wall), then compares `rayClear` with the float reference
  over all 196 pairs of 14 points including corners, borders, the wall pixels and the
  saturated interior. It exercises saturation, border, exact-distance and diagonal cases in
  one map. Together with the existing 262,144 single-wall small rays and 20,000 seeded long
  rays, and the real-map differential above, coverage of the outcome contract is good.
- Note 1: the suite compares outcomes; the jump-state equality (one `advance = k` call
  equals `k` unit advances) is not asserted directly. I ran that check standalone on copies
  of the working-tree helpers: exhaustive for `steps` 1..300, every `delta`, `k` in
  {2, 3, 7, 100, 255}, from a fresh state and from a mid-ray state; 200,000 seeded triples
  with `steps` up to 2^23 - 1 and negative deltas; and the two extreme cases at the bound.
  1,306,004 comparisons, 0 mismatches. Adding the same check to the suite is cheap and would
  make it prove the state equality itself rather than infer it from outcomes.
- Note 2: `rayClear`'s doc comment still describes the single-correction rule; a sentence on
  the clearance jump and its 1-Lipschitz dependency (with a pointer to the verifier) would
  tell a future editor of `buildClearance` what they must preserve.

## 6. Effect of the memory cap ruling
`MEMORY_CAP_RULING.md` (James, 2026-09-09) raises the non-colossal shared cap to 32 MiB and
retires the 16 MiB structural programme. It changes nothing in W7: W7 adds no memory (it
reads the existing clearance table) and its acceptance remains the exactness gate plus the
timing pairs.

## 7. What remains
The m5a timing pairs (W6 parent versus W7) and the m8i full quality and activation runs are
the acceptance evidence; the exactness gate is the same as W1 and W2 (all masks and pop
arrays identical, corpus and danger hashes unchanged). Nothing in this review predicts the
timing outcome; W7 trades per-visit cost for fewer visits and only the loaded rows say which
wins.
