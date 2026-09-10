# A4_CODE_REVIEW: validate each undirected coarse move once

Peer (Claude) read-only review of the A4 candidate
(`A4-candidate-body_route_index.nim` versus `A4-parent-body_route_index.nim`,
parent identical to the research worktree's source at f9dff753) and of
`tools/check_body_index_validation.nim` in `nav-validation-symmetry`. No
source edits. Question asked: does the candidate `validateRouteIndex` accept
and reject exactly the same coarse bit arrays as the parent?

## 1. The change

One hunk inside the legal-move pass of `validateRouteIndex` (candidate lines
2085 to 2102). For every set bit `(cell, direction)`:

| step | parent | candidate |
|---|---|---|
| bounds of `next` | implicit: `legalNavMove` returns false when `next` is off-grid (`cellWalkable(to)`), raise "stores illegal move" | explicit grid test first, same raise |
| geometry | `legalNavMove(cell, next)` on every set bit | `legalNavMove(cell, next)` only when `cellIndex < nextIndex` |
| reverse presence | reverse bit at `next` must be set, raise "has asymmetric move" | same |

Nothing else in the validator or the file changes (the diff has this hunk
only). The loop still visits every cell of `navCells`, walkable or not.

## 2. Equivalence proof

Let B be the set of set bits. The parent accepts iff (P1) every `(c, d)` in
B has `legalNavMove(c, c + d)` and (P2) every `(c, d)` in B has
`(c + d, rev d)` in B. The candidate accepts iff (C0) every `(c, d)` in B
has `c + d` on the grid, (C1) every `(c, d)` in B with `index(c) <
index(c + d)` has `legalNavMove(c, c + d)`, and (C2) is P2.

Parent accepts implies candidate accepts. P1 implies C0 because
`legalNavMove` requires `cellWalkable(to)`, which requires `to` on the
grid. P1 implies C1 as a special case. P2 is C2.

Candidate accepts implies parent accepts. Take any `(c, d)` in B and let
`n = c + d`, on the grid by C0, with `index(n) != index(c)` because `d`
is non-zero. By C2, `(n, rev d)` is in B. Exactly one of the two endpoints
has the lower index. If it is `c`, C1 applied to `(c, d)` gives
`legalNavMove(c, n)`. If it is `n`, C1 applied to the set bit `(n, rev d)`
(whose `next` is `c` and whose index test is `index(n) < index(c)`, true)
gives `legalNavMove(n, c)`, and `A2_CODE_REVIEW.md` section 3 proves
`legalNavMove` is exactly symmetric for unit 8 px moves, so
`legalNavMove(c, n)` holds. Either way P1 holds for `(c, d)`. P2 is C2.

So the accepted sets are identical. The proof needs only: reverse presence
checked for every set bit (unchanged), bounds checked before any indexing
of `next` (now explicit), and unit-move symmetry (A2). It does not depend on
which endpoint is canonical; row-major lower index is fine because the
predicate is symmetric in both orientations.

## 3. The specific cases the request names

- Bounds: a bit whose `next` is off-grid is rejected by the explicit test
  before `cellIndex(next)` is evaluated. This matters for negative-direction
  bits at the left and top borders, where `y * W + (x - 1)` and
  `(y - 1) * W + x` are valid indices of other cells; the candidate never
  computes them for off-grid `next`. The parent also never did (its
  `legalNavMove` raise came first). Same outcome, same message.
- Pair geometry: an illegal but symmetric pair is caught from its lower
  endpoint by C1; the higher endpoint contributes only the reverse check.
- Asymmetric bits: a lone bit in either orientation is rejected by C2 at the
  cell that holds it, exactly as before.
- Corners and borders: covered by the bounds rule; no special case exists in
  either version.
- Canonical direction: `index(c) < index(n)` selects directions with
  `dy > 0`, or `dy == 0` and `dx > 0` (table indices 1, 3, 5, 7). Because
  both bits of every accepted pair are present, every pair is checked
  exactly once, never zero times.
- Non-walkable endpoints: `legalNavMove` requires both endpoints walkable;
  from whichever endpoint is lower, a pair touching a non-walkable cell is
  rejected, as in the parent.

## 4. One observable difference: the rejection reason, not the verdict

For a corrupt array that is both geometrically illegal and asymmetric at
the higher-index endpoint, the parent raises "stores illegal move" and the
candidate raises "has asymmetric move" (it reaches the reverse check first
because it skipped geometry there). Accept/reject is unchanged; only the
message can differ on already-corrupt input. The focused suite ("edge width
and named activation failures fail closed") passes, so no golden depends on
this ordering; worth knowing if a test ever asserts message text.

## 5. The mutation diagnostic

`check_body_index_validation.nim` includes the module (private access),
builds a 12 by 12 cell map with a wall block, and for every cell and
direction (1,152 directed toggles: flips one bit) and every in-grid
neighbour (1,012 paired additions: sets both bits of a pair) compares
`validateRouteIndex` acceptance with an independent reference that is the
parent's full eight-direction loop over the same bit array. All 2,164
decisions match (452 accepted, 1,712 rejected). Coverage is right for the
proof's three obligations: toggles create lone bits (C2), off-grid bits
from all four borders and corners (C0), and remove legitimate bits;
paired additions create illegal symmetric pairs across the wall and from
non-walkable cells (C1) as well as legitimate ones that must be accepted.
Two independent corruptions at once are not exercised, and the proof does
not need them. The reference is the parent predicate itself, so the tool
tests exactly the equivalence claimed.

## 6. Verdict

Equivalent accept/reject on every coarse bit array, with the bounds check
made explicit and geometry evaluated once per undirected pair. No other
validator pass changes. The only behavioural difference is the error
message chosen for some corrupt arrays. The native evidence (76 of 76 m8i
activation and memory, unchanged full quality, map 48 275 to 251 ms) is
root's; this review supports integrating A4 as exact, with m5a activation
still to be confirmed separately as the request says.

A4 CODE REVIEW DONE
