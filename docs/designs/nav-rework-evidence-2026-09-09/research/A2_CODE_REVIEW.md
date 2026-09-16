# A2_CODE_REVIEW: build each coarse legality edge once (symmetric legalMoves)

Peer (Claude) read-only review of the A2 diff in `src/shell/body_route_index.nim`
against the parent snapshot `A2-parent-body_route_index.nim` (parent 3aeb0398),
per `A2_REVIEW_REQUEST.md` and `A2_PREREG.md`. No production change, no
timing claim. The native m8i comparison (PID 22532) is root's; nothing here
substitutes for it.

## 1. What changed

Only `buildLegalMoves` (lines 721 to 737). The parent evaluated all eight
`legalNavMove` directions per walkable cell and assigned the finished mask
with `index.legalMoves[cellIndex] = mask`. The candidate evaluates four
directions per walkable cell, `(direction, reverse)` pairs
`(1,0), (3,2), (6,5), (7,4)`, and ORs the forward bit into the cell and the
reverse bit into the neighbour. `index.legalMoves` is still zero-initialised
by `newSeq[uint8](index.stats.navCells)` at the top. The validator and every
public predicate are unchanged (diff shows no other hunk).

## 2. Direction pairing and coverage: correct

`NavNeighbors` (`src/shell/body_map.nim:95`) is
`0:(-1,0) 1:(1,0) 2:(0,-1) 3:(0,1) 4:(-1,-1) 5:(-1,1) 6:(1,-1) 7:(1,1)`.

| forward | delta | reverse | delta | opposite? |
|---|---|---|---|---|
| 1 | (1,0) | 0 | (-1,0) | yes |
| 3 | (0,1) | 2 | (0,-1) | yes |
| 6 | (1,-1) | 5 | (-1,1) | yes |
| 7 | (1,1) | 4 | (-1,-1) | yes |

The forward set {1,3,6,7} contains exactly one member of each of the four
opposite pairs, so every undirected unit edge {a,b} is evaluated exactly
once: from `a` if the a-to-b direction is in the forward set, otherwise
from `b`. If either endpoint is non-walkable the edge is skipped by the
`continue` (from that endpoint) or refused by the predicate (from the
other), and both of those are correct because `legalNavMove` requires both
endpoints walkable. No edge is evaluated twice and none is missed.

## 3. Predicate symmetry for restricted 8 px unit moves: exact

`legalNavMove(from, to)` (`src/shell/body_map.nim:289`) is, for a unit
delta:

1. `delta in NavNeighbors`: the table contains every opposite, so symmetric.
2. `cellWalkable(from) and cellWalkable(to)`: a conjunction, symmetric.
3. Diagonal side cells `(to.x, from.y)` and `(from.x, to.y)`: swapping the
   endpoints swaps the two cells; the same conjunction, symmetric.
4. `segmentClear(cellCenter(from), cellCenter(to))`: the integer sampler
   (`body_map.nim:253`) uses `decision = (1 + 2 ix) ny - (1 + 2 iy) nx`.
   Centres of unit moves differ by (±8,0), (0,±8) or (±8,±8).
   - Axis: one of nx, ny is zero, so the walk visits every pixel between the
     centres in order; the set is the same from either end, and `canStand`
     is tested on every pixel including both ends (start by the entry check,
     goal as the last loop pixel).
   - Diagonal: nx = ny = 8, so `decision == 0` at every step. Step k from
     `s` tests side pixels `(s+k+1, s+k)` and `(s+k, s+k+1)` and then the
     diagonal pixel `(s+k+1, s+k+1)`. From the goal `g = s + 8` moving
     negatively, step k tests `(g-k-1, g-k)` and `(g-k, g-k-1)` and then
     `(g-k-1, g-k-1)`. With j = 7 - k these are `(s+j, s+j+1)` and
     `(s+j+1, s+j)` and `(s+j, s+j)`, the same pixel sets over k, j in 0..7.
     Both endpoints are tested in both directions.

   So the predicate is a conjunction over the same pixel set from either
   end, hence exactly symmetric. This is the same argument as the A0 review
   (`A0_CODE_REVIEW.md`), now applied to the restricted 8 px table.

## 4. Neighbour bounds: safe

`index.cellIndex(next)` is only reached when `legalNavMove(cell, next)`
returned true, which requires `cellWalkable(next)`, which requires
`0 <= next.x < navWidth` and `0 <= next.y < navHeight`. `cellIndex` uses
`map.gridWidth`, and `gridWidth` is `map.navWidth` (`body_map.nim:120`), the
same stride `cellWalkable`'s `gridIndex` uses. `stats.navCells` is
`gridWidth * gridHeight` (`body_route_index.nim:1790`), so the neighbour index
is always inside `legalMoves`. No out-of-range write is possible.

## 5. Accumulated masks are never overwritten: confirmed

After the zero-initialising `newSeq`, the only writes are the two
`or` assignments. There is no plain assignment in the loop, so a reverse bit
written into cell b while processing an earlier cell a survives when b is
later processed, and a forward bit written into b survives writes from any
later neighbour. The parent's whole-mask assignment is gone, which is the
line that would have clobbered earlier reverse bits; the diff removes it.

One ordering difference worth naming: in the parent every cell's mask was
complete as soon as that cell was visited; in the candidate a cell's mask is
complete only after the loop ends. Nothing reads `legalMoves` inside
`buildLegalMoves`, and the next consumer (`boundaryClusters`, line 752) runs
after the proc returns, so the difference is unobservable.

## 6. Bit-for-bit equality claim

Given sections 2 to 5, for every cell and direction the candidate bit equals
`legalNavMove(cell, cell + delta)`, which is what the parent computed. The
independent check in `tools/check_body_index_legality.nim` asserts exactly
that against `legalMovesAt` for every cell of every pool, configured, and
colossal map. The local `A2-check-tool.log` in the evidence folder contains
only the compile transcript (no result rows), so the 76-map equality is not
yet evidenced locally; it is the m8i run's output. The focused suite
(`A2-focused.log`) shows seven OK rows including "canonical legality matches
the old planner predicate" and "index validates and is deterministic".

## 7. Verdict and caveats

- Exactness: the change is exact on the evidence above. No storage, topology,
  gameplay, budget, or cap change; the validator still runs in full.
- Cost: this halves the number of predicate calls; it does not halve the
  stage time, since the per-call diagonal work is unchanged and the
  reverse-bit write adds a scattered store. The prereg already says a halved
  49 ms stage may not close the map 48 gap; no timing is claimed here.
- Nothing in this diff touches the fine 4 px band, bridges, or portals; the
  symmetry argument is specific to unit moves in the 8 px table and must
  not be reused for multi-cell segments without re-proving the sampler
  argument.

A2 CODE REVIEW DONE
