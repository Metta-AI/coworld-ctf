# D0a code review: incremental danger-ray decision

Written 2026-09-09 by Claude (peer) after PROCEED. Reviewed the working-tree diff of
`src/shell/body_nav.nim` against `D0-parent-body_nav.nim`, which I confirmed is byte-identical
to HEAD's file at addaad7a (the W7 checkpoint), so the reviewed change is D0a alone: 6
insertions, 1 deletion, inside `castRay`. Also read `D0_PREREG.md` and the CAP32 harness
change (`PoolSharedCap` 16 MiB to 32 MiB, nothing else). No source edits, no timing claims.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact and minimal. The recurrence is correct, every visit and check keeps its order, the
integer bound is small on every supported configuration, and the change adds no memory. The
focused suites pass here and an exhaustive branch-sequence comparison found no difference.
One optional note in section 5.

## 2. The recurrence, checked
Parent: `decision = (1 + 2 ix) ny - (1 + 2 iy) nx` recomputed each iteration.
Candidate: `decisionX = 2 ny`, `decisionY = 2 nx`, `decision = ny - nx` before the loop (the
value of the formula at `ix = iy = 0`); after the X branch (`inc ix`) `decision += decisionX`;
after the Y branch (`inc iy`) `decision -= decisionY`; after the diagonal branch (both)
`decision += decisionX - decisionY`. Each update is exactly the formula's difference for that
increment, so by induction `decision` equals the parent's value at the top of every
iteration. The branch tests (`== 0`, `< 0`, else) are unchanged and read the same value, so
the branch taken at every step is the same.

## 3. Ordering of visits and checks
The diff touches only the three update lines and the initialisation. In the diagonal branch
the two side-cell blocked checks (x side first), the two `addVisibleCell` calls (x side
first), the move and the `inc` calls all keep their order, and the update is placed after
them; the axis branches keep move then `inc` then update; the common post-branch blocked
check and `addVisibleCell` of the new cell, and the early `break`, are untouched. The
perimeter iteration order, `nextVisitGeneration`, the close-floor loop and the final passes
are outside the diff. So the cell sequence, the truncation point, and the float accumulation
order are identical to the parent.

## 4. Integer bounds on supported configurations
`|decision| <= max((2 nx + 1) ny, (2 ny + 1) nx)` with `nx, ny <= radius = ceil(range / 8)`:
at 331 px (radius 42) under 3,600; at the configured 1,300 px (radius 163) under 53,400; the
`decisionX`/`decisionY` constants are at most 326. Nim's `int` is 64-bit on the servers and
32-bit on wasm32; both hold these values with room to spare, and overflow checks are still
compiled in for `-d:release`, so even a future radius increase could not overflow silently.
No conversion or narrowing is introduced.

## 5. Independent evidence
- `tests/test_shell_body_nav_rework.nim`: 15 of 15 pass here with the change;
  `tests/test_shell_body_seat.nim`: 29 of 29.
- Standalone comparison of the parent and candidate walks as branch sequences (X, Y, XY),
  exhaustive for every `(nx, ny)` with `0 <= nx, ny <= 300` except `(0, 0)` (90,600 pairs),
  plus every actual perimeter offset at radius 42 (236) and radius 163 (924): 0 mismatches.
  Since the branch sequence for a fixed `(nx, ny)` determines the cell sequence for every
  origin and sign, this covers every ray the geometry can cast at both ranges and any
  intermediate range.
- The corpus's per-case danger-hash assertions in the m8i quality run are the in-tree
  exactness gate; they should pass by construction.
- Optional note: a unit test asserting the two walks agree over the perimeter (a few
  hundred iterations) would pin the recurrence inside the suite; the differential above is
  cheap to port.

## 6. Preregistration and what remains
`D0_PREREG.md` matches the change: no kernel-index change, no hoisting, no table; three
interleaved m5a pairs at B = 1,024 and 1,300 px with masks, pops and retained bytes
identical; whole-body and inclusive danger p95/max reported separately from weight refresh
and never subtracted. The CAP32 harness change is common to both arms and affects only the
shared-memory pass rule, not any workload. Nothing here predicts the timing outcome; two
multiplies per step are removed, and only the m5a rows say what that is worth.
