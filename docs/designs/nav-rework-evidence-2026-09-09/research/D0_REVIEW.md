# D0 review: precomputed danger-ray step sequence versus an incremental decision

Written 2026-09-09 by Claude (peer) for `D0_REVIEW_REQUEST.md`. Source review only; no
edits, no timing claims. Context: after R1 and W7 the m5a worst whole-body p95 is about
5.96 ms with danger about 3.64 ms (of which about 1.08 ms is the packed-weight refresh), per
Codex's reports; the LOS walk is the remaining large term.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Both candidates are exact. Recommend the incremental decision update (D0a) as the first
ablation: it removes the same two multiplies per step as the table, needs no memory, no
activation work, no ledger line and about four changed lines, and it composes with a second
zero-memory ablation (D1, incremental kernel index) that removes the other multiply in the
step. The static move table (D0b) is also exact and small, but its only advantage over D0a is
replacing a sign test on an integer with a byte load and a switch, which is not an obvious win
and must be measured against D0a, not against the current code. Layout and accounting for
D0b are in section 4 in case the measurement favours it.

## 2. What one ray step does today (`castRay`, `body_nav.nim`)
Loop while `ix < nx or iy < ny`: `decision = (1 + 2 ix) ny - (1 + 2 iy) nx` (two multiplies),
three-way branch; on a diagonal step two side-cell blocked checks in a fixed order, two
`addVisibleCell` calls in a fixed order, then the move; on an axis step the move; then one
blocked check and one `addVisibleCell` for the new cell, with an early `break` on a blocked
cell. `addVisibleCell`: two bounds compares, a stamp load and compare, a stamp store, a kernel
index `kernelY * diameter + kernelX` (one multiply), and one float32 add. `sightCellBlocked`
after R1: two bounds compares and one byte load through `seat.dangerGeometry`.
So per step: three multiplies (two for the decision, one for the kernel index), roughly six
compares, three loads, up to two stores, one float add, plus a pointer dereference of
`seat.dangerGeometry` per blocked check because the geometry is re-read from the seat each
call.

## 3. D0a: incremental decision (recommended first)
`decision(ix, iy) = (1 + 2 ix) ny - (1 + 2 iy) nx`. Its change per branch is a constant:
after `inc ix` add `2 ny`; after `inc iy` subtract `2 nx`; after both add `2 ny - 2 nx`.
Initialise `decision = ny - nx` at `ix = iy = 0`. The branch structure, the three orders, the
bounds checks, the early break and every `addVisibleCell` call are untouched, so the cell
sequence is identical; the arithmetic is integer and exact; the magnitude is bounded by
`(2 nx + 1) ny <= 2 r^2 + r`, under 54,000 at radius 163, so there is no width concern on any
target. Cost removed: two multiplies per step. Cost added: one add per step (already free in
the branch). Memory: none. Activation: none. Ledger: unchanged.

D1, same spirit: carry the kernel index incrementally. `kernelIndex = (gy - oy + r) *
diameter + (gx - ox + r)` changes by `stepX`, `stepY * diameter`, or their sum per step, and
the diagonal side cells are `kernelIndex + stepX` and `kernelIndex + stepY * diameter` from the
pre-move index. Exact integer bookkeeping; removes the third multiply. It touches
`addVisibleCell`'s signature (pass the index) and is a slightly larger edit than D0a, so it is
the second ablation, not the first. Hoisting `seat.dangerGeometry` into a local once per
`castRay` (the R2 accessor point, not yet done) is a third free change.

## 4. D0b: static move table, if it is measured to beat D0a
Exactness: for a fixed `(nx, ny)` the decision sequence, hence the kind sequence (X, Y, XY),
is a pure function independent of origin and signs; signs are applied at runtime by `stepX`,
`stepY` exactly as now. A runtime that replays the stored kinds while keeping the same
per-kind order of checks, adds and moves produces the identical cell sequence, and the early
break simply abandons the rest of that ray's kinds (the next ray starts at its own offset), so
the truncation behaviour is unchanged. The perimeter list, iteration order and bounds checks
stay. The one thing to get right is the diagonal kind: it must perform the two side checks in
the existing order (x side first), then the two adds in the existing order, then the move and
the position check, exactly as the current `decision == 0` branch does.

Simplest layout: one `seq[uint8]` of kinds (0 = X, 1 = Y, 2 = XY) for all perimeter rays in
perimeter order, plus `seq[int32]` of `perimeter.len + 1` prefix offsets (ray `i` uses
`kinds[offsets[i] ..< offsets[i + 1]]`). No per-ray length field is needed. Build it with a
first pass that counts iterations per ray and a `newSeq` of the exact total, or `newSeqOfCap`
of the counted total, so capacity equals length (`CAPACITY_AUDIT.md`); building it is one dry
run of the current loop per ray with no map access, well under a millisecond at radius 163.
Store it in `DangerGeometry` (the M1 shared `ref`), count kinds and offsets at capacity in
`sharedDangerGeometry` with the sequence allowances, and add the two lengths to the ledger
self-test.

Size, from the geometry rather than guessed: iterations per ray equal `nx + ny - (number of
diagonal steps)`, and diagonal steps occur only where `(1 + 2 ix) ny = (1 + 2 iy) nx` has a
solution, so for most rays they are few; over a circle the mean of `nx + ny` is about
`4 r / pi`. At radius 163 with 924 perimeter offsets that is about 924 x 207, roughly 190 KB
of kinds plus 3.7 KB of offsets; at radius 42 with 236 offsets about 12.5 KB. Codex's 150 KB
estimate is the right order; the build should report the exact count. Against the 32 MiB
shared allowance this is immaterial, and it is added once per episode's nav system.

What D0b does not buy: it does not reduce the blocked checks, stamp loads or float adds,
which are the memory-touching part of the step; it only replaces the decision arithmetic and
branch with a sequential byte load and a switch on it. Sequential byte loads are cheap and
well predicted, and the switch is still a branch, so the delta against D0a is likely within
the A/A spread; that is the hypothesis to test, not a claim.

## 5. Preregistration for the ablations (Codex owns)
Parent: W7 checkpoint. Candidates in order, each its own binary and card: K1 = D0a; K2 = D0a
plus D1 plus the geometry hoist; K3 = D0b built on K2 (so its delta is table versus
incremental, not table versus multiplies). Exactness gate for each: per-case danger hashes
(the corpus asserts every raster), corpus route hash, all masks and pop arrays identical at
331 and 1,300 px, ledger unchanged for K1 and K2 and increased by exactly the table for K3,
with a unit test for K3 that replays every stored kind sequence against the recomputed
decisions for every perimeter offset at both radii and checks identical `(ix, iy)`
trajectories. Timing: the W7 protocol on m5a, three interleaved pairs at 1,300 px, reporting
the danger slice minus the weight-refresh slice, plus the whole-body rows; then c6a. The
decision rule is unchanged: carry a candidate only if the danger slice improves beyond the A/A
spread; prefer the candidate with the smaller code and no memory when two are within the
spread of each other.

## 6. Limits
Nothing here is measured. The walk's remaining cost after D0a and D1 is dominated by the
per-cell stamp and float traffic and the blocked-cell loads, which no arithmetic change
removes; the only exact way to touch that is to reduce the number of steps that reach cells
already visited by another ray of the same source, and that is a different (and harder)
design question than this unit.
