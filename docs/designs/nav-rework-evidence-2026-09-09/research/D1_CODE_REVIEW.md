# D1 code review: incremental kernel index along each danger ray

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff of
`src/shell/body_nav.nim` against `D1-parent-body_nav.nim`, confirmed byte-identical to HEAD
at 8fe2cbad (the D0 checkpoint), so the change is D1 alone: 14 insertions, 11 deletions in
`addVisibleCell`, `castRay` and `rebuildDangerFromPoints`. Read `D1_PREREG.md`. No source
edits, no timing claims.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact. Every call site passes the index the old formula would have computed, the side-cell
indices use the pre-move state, the origin index is the kernel centre, every index stays
inside the kernel for every ray the geometry can cast, and the stamp guard, bounds checks
and float addition are unchanged. Both focused suites pass here and an exhaustive per-add
comparison found no difference. Nothing blocks the m5a and m8i runs.

## 2. The recurrence, checked
Old index for cell `(gx, gy)` from origin `(ox, oy)` with radius `r` and diameter
`D = 2 r + 1`: `(gy - oy + r) D + (gx - ox + r)`. New: `kernelIndex` starts at `r D + r`
(the origin cell, where `gx = ox`, `gy = oy`), and after each move changes by exactly the
formula's difference: `+stepX` for an X step (`gx` moves by `stepX`), `+stepY * D` for a Y
step, and their sum for a diagonal. Since `castRay` moves `x`, `y` by the same `stepX`, `stepY`
in the same branches, `kernelIndex` equals the formula at the new `(x, y)` after every update.
The update in the diagonal branch is placed after the two side adds and the move, matching
the fact that the side cells are addressed from the pre-move position.

## 3. Every call site
- `castRay`, diagonal side cells (436-437): `(sideX, y)` is the current cell moved by `stepX`
  in x only, so its index is `kernelIndex + stepX`; `(x, sideY)` is moved by `stepY` in y
  only, so `kernelIndex + kernelStepY` with `kernelStepY = stepY * D`. Both use the pre-move
  `kernelIndex`, as required. Correct.
- `castRay`, post-branch cell (456): `kernelIndex` after the branch's update, which is the
  moved cell. Correct.
- `rebuildDangerFromPoints`, origin (468): `radius * (radius * 2 + 1) + radius` = `r D + r`,
  the centre. Correct; it is the only caller outside `castRay`, and `addVisibleCell`'s old
  `origin` and `kernelRadius` parameters have no remaining users (the grep over `src`, `tests`
  and `tools` finds exactly these four calls).

## 4. Signs and bounds
`stepX`, `stepY` are in {-1, 0, 1} from `cmp`, so `kernelStepY` is in {-D, 0, D}. Every
perimeter offset satisfies `|dx|, |dy| <= r` (the offsets come from `pyRound(sqrt(r^2 - t^2))`
with `|t| <= r`), the walk never leaves the box between origin and target, and the side cells
lie one step inside that box along one axis, so every addressed cell has `|gx - ox| <= r` and
`|gy - oy| <= r`, hence `0 <= kernelIndex < D^2`. The `kernel[kernelIndex]` read keeps Nim's
sequence bounds check in `-d:release`, and the grid bounds check on `(gx, gy)` still precedes
it inside `addVisibleCell`, so an out-of-grid cell returns before any kernel read exactly as
before. The index value is at most `D^2 - 1` (106,928 at radius 163), trivially within any
`int`.

## 5. What is unchanged
The stamp guard (`visited[index] == visitGeneration` returns early), the grid bounds check,
the float32 `+=` with the identical kernel value, the perimeter order, the decision
recurrence from D0a, the blocked checks and early `break`, the close-floor pass, geometry
ownership and memory. No ledger line moves.

## 6. Independent evidence
- `tests/test_shell_body_nav_rework.nim`: 15 of 15; `tests/test_shell_body_seat.nim`: 29 of
  29, both here with D1.
- Standalone check replicating `castRay` with D0a and D1: for every perimeter offset at radii
  42 and 163 and three origins (including a negative one to exercise sign handling), compare
  the carried index with the old formula at every add, main and side cells: 612,372 adds,
  0 mismatches, 0 indices outside `[0, D^2)`.
- The corpus per-case danger hashes in the m8i run remain the in-tree exactness gate.

## 7. Preregistration and the counter-hypothesis
`D1_PREREG.md` states the negative correctly: the index is now maintained on every step,
including steps whose cell is already stamped, whereas the old multiply ran only after the
stamp check passed on first visits (about 44 percent of steps at 1,300 px per the counts in
`DANGER_PREFIX_REVIEW.md`). So D1 trades one multiply plus two subtractions on first visits
for one or two adds on every step; on the 56 percent of repeated-visit steps that is new
work, small but not zero. Whether the danger slice moves at all is what the three m5a pairs
decide; no direction is predicted here, and a negative result should be retained as the
prereg says.
