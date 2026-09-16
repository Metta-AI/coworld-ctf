# W2 review: direct wall reads inside `rayClear`, and whether the checks may go

Written 2026-09-09 by Claude (peer) before any check-removal implementation, at Codex's
request. Source review only; no edits. Context: W1 first three m5a pairs (Codex): every
encoded mask and pop array identical between arms; parent worst 13.820/15.464 ms, candidate
11.448/12.763 ms; weapon p95 worst 11.891 to 9.520 ms. Those are Codex's numbers and are not
re-derived here.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. The candidate
Inside `rayClear`, after the public refusal of any out-of-bounds endpoint (which stays),
replace the per-sample `isWall(point)` (which re-checks `inBounds`, computes a checked
`y * mapWidth + x`, and reads `wall` with a bounds check) by a direct `wall[y * mapWidth + x]`
read with `mapWidth` hoisted; then, if a proof allows, drop the overflow and bounds checks on
that index for the loop body.

## 2. The invariant that makes the direct read exact
Every sampled point lies inside the axis-aligned box spanned by the endpoints. Per axis the
exact value `a + dx k / steps` with `0 <= k <= steps` lies in the closed interval between `a`
and `b`; nearest-with-ties-to-even of a value inside a closed integer interval stays inside
it (the interval ends are integers, so rounding can never move past them, including at a
half-integer tie next to an end). Since both endpoints pass `inBounds`, every sampled point is
in bounds, `isWall`'s `inBounds` branch is never taken inside the loop, and `wall[index]` is
always in range. Therefore the direct read returns exactly what `isWall` returned on every
sample: exact by construction, no rounding involved.

## 3. The checks, one by one
- `inBounds(point)` per sample: provably always true inside the loop (section 2); removing
  it is exact.
- Overflow on `y * mapWidth + x`: with `y, x, mapWidth <= 2^23` the index is below 2^47,
  nowhere near `int64`; `nimMulInt`/`nimAddInt` cannot fire. Exact to remove.
- Bounds check on `wall[index]`: `wall.len == mapWidth * mapHeight` is set at map
  construction and never changed (the field is private to `body_map`), and `index < wall.len`
  follows from the point being in bounds. Exact to remove under the invariant.
So all three checks are redundant under the endpoint validation, and removing them changes no
result on any input that reaches the loop.

## 4. What removal changes that is not a result
Removing a bounds check changes the failure mode of a future bug from a raised `Defect` to a
silent out-of-range read. The invariant is sound today; the risk is a later edit (a different
step rule, a map whose `wall` length disagrees with its dimensions, an endpoint path that
skips the refusal). Recommendations, in order:
1. Measure before removing. Do W2 as two candidates: W2a, direct read with the checks left on
   (the calls are gone; the remaining checks are two predictable compares and one
   multiply-add), and W2b, W2a plus a tightly scoped `{.push boundChecks: off,
   overflowChecks: off.}` / `{.pop.}` around the loop body only. If W2a already captures the
   gain within the A/A spread, W2b is not worth its failure-mode change.
2. If W2b is kept, put the proof of section 2 in a comment above the pragma, and keep the
   invariant executable somewhere: either an `assert` inside the loop that is compiled only in
   a named test define (so release carries nothing), or, cheaper, a test that runs the
   checked reference `rayClear` against the unchecked one on segments whose endpoints sit on
   all four borders and corners of a map plus seeded interior pairs, on a map with dimensions
   that are not multiples of each other (to catch a swapped width/height), so an invariant
   break shows as a test failure rather than a silent read.
3. Keep `wall` private and keep `mapWidth * mapHeight == wall.len` as a construction
   assertion in `newBodyMap` (it may already be implicit; make it explicit if W2b lands).
4. Do not extend the pragma beyond the loop; `inBounds(a)`, `inBounds(b)` and the `steps == 0`
   path keep their checks.

## 5. Exactness gate for the W2 run
Same as W1: every encoded mask (initial, warm-ups, samples) and pop array identical to the
parent at the same range; corpus route hash and per-case danger hashes unchanged; the ray
suite green including its two out-of-bounds refusals; and, for W2b, the border-segment
differential test of section 4 item 2. Timing: the W1 protocol on m5a, parent = W1
checkpoint, reporting the weapon slice per row and repeat against the A/A spread.
