# Activation review: four-direction fine legality and the regular two-hop bridge shortcut

Written 2026-09-09 by Claude (peer) for `ACTIVATION_NEXT.md`. Source review plus a standalone
all-map check (`peer-proofs/activation_legality_bridge_check.nim`, raw stdout retained as
`activation_legality_bridge_check.out`). No production edits, no timing claims. Context: CAP32
m8i worst non-colossal activation ratio 2.409x on map 48 (BodyMap 349.8 ms, route index
300.5 ms, mixed nav 190.3 ms), about 143 ms above the inherited 2x with no waiver.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Both proposals are exact. Proposal 1 (evaluate each undirected fine edge once) is proved
from `segmentClear` for the only offsets legality uses and confirmed with zero asymmetric
bits over 91,240,212 directed legal edges on all 75 pool and giant maps. Proposal 2 (return
the straight two-node path for regular anchor deltas when its two edges are legal, else the
unchanged BFS) is proved from the BFS's queue order and confirmed with zero mismatches over
22,958,138 bridges; it applies to 97.8 percent of bridges and cuts BFS node insertions about
eightfold. Neither adds memory. Whether the two together recover 143 ms is a measurement;
section 5 says what to expect and what not to claim.

## 2. Proposal 1: legality symmetry for one-unit fine edges
`buildBodyFineLegality` sets bit `d` on node `n` iff `n` and its neighbour `m = n + delta_d`
are both standable and `segmentClear(point(n), point(m))`. `segmentClear` (`body_map.nim`)
is: `canStand(start)`, then the supercover walk from start to goal checking `canStand` at
every pixel it enters, with both side pixels checked before a diagonal move. For the two
offsets legality ever passes (4 px axis, 4 px diagonal) the walk is symmetric:
- Axis, `(4, 0)`: forward checks pixels 0 (as start) and 1, 2, 3, 4; reverse checks 4 (as
  start) and 3, 2, 1, 0. Same set.
- Diagonal, `(4, 4)`: `nx = ny` makes every decision zero, so each step checks the two side
  pixels then enters the corner: forward checks (0,0), (1,0), (0,1), (1,1), (2,1), (1,2),
  (2,2), (3,2), (2,3), (3,3), (4,3), (3,4), (4,4); reverse from (4,4) with negative steps
  checks the same thirteen pixels in the opposite order. Same set.
Every check is a `canStand` of a fixed pixel, so the conjunction is order-independent, and
both endpoints are standable by the outer guard. Hence `legal(n, d) == legal(m, opposite(d))`
for every edge, and computing the four "forward" directions (indices 1, 3, 6, 7 or any set of
one per axis pair) and mirroring is bit-for-bit the current table. General slopes are not
symmetric under this walk and are not needed; the proof is restricted to these two offsets
as the request asked.
Evidence: for every node and every set bit on all 64 s2 maps and 11 giant maps, the reverse
bit is set: 91,240,212 edges, 0 asymmetric.
Cost: halves `segmentClear` calls in legality construction (each is 5 or 13 `canStand`
pixel reads). This is the `legality` part of the mixed-nav 190 ms; how much of that 190 ms it
is has not been split out, and the anchor and bridge passes are separate (below).

## 3. Proposal 2: exact two-hop shortcut for regular anchors
Regular anchors are cell centres, so adjacent-cell anchors differ by exactly two fine units
per nonzero axis: deltas `(+-2, 0)`, `(0, +-2)`, `(+-2, +-2)`. `findBodyBridge` is a
breadth-first search from the source anchor over `legal` bits, expanding neighbours in
`NavNeighbors` order `(-1,0), (1,0), (0,-1), (0,1), (-1,-1), (-1,1), (1,-1), (1,1)`, marking
the target when it is first inserted, and returning the parent chain. Why the shortcut
returns exactly the BFS path:
- Axis delta, say `(+2, 0)`: only layer-1 nodes `(1,0)`, `(1,-1)`, `(1,1)` can insert the
  target; they are dequeued in insertion order, which is `NavNeighbors` order, and `(1,0)`
  (index 1) precedes both diagonals (indices 6, 7); nodes dequeued before it (`(-1,0)`) cannot
  reach the target. So if `legal(source, (1,0))` and `legal((1,0), (1,0))`, the BFS finds the
  target while expanding `(1,0)` and returns `[(1,0), (2,0)]`. If either edge is illegal, the
  BFS proceeds as today (fallback), so nothing changes there. The 128-node cap cannot fire
  before the second dequeue (at most 17 insertions), and the bounding box contains the
  midpoint.
- Diagonal delta `(+2, +2)`: any two-step path must advance both axes by one on each step,
  so the only two-hop path is via `(1,1)`; if both diagonal edges are legal the BFS finds it
  at the second-layer insertion from `(1,1)` and no shorter path exists; otherwise fallback.
- Irregular anchors (a cell whose centre is not standable takes another node) give other
  deltas and always fall back.
Evidence: on all 75 maps, every stored bridge equals my verbatim BFS replica (which validates
the replica), and for every regular delta with a legal straight path the shortcut equals the
BFS path: 22,958,138 bridges, 22,467,926 regular (97.9 percent), 22,447,020 shortcut hits
(97.8 percent), 0 mismatches of sequence or length. BFS node insertions (each with a linear
`seen` scan over the nodes inserted so far) fall from 400,802,853 to 49,755,677 across the
maps, about 8.1x fewer; on giant map 5 from 9,210,958 to 1,150,398.
Cost removed: for a hit, two `legal` bit tests replace a BFS that inserts about 17 nodes with
quadratic `seen` scanning. No memory, no bridge content change, `bridgeNodes`, offsets and
lengths identical, so the ledger and the route hash are unchanged by construction.

## 4. Tests each needs in the tree
- Proposal 1: for all 75 maps plus colossal, the new table equals the old table byte for
  byte (keep the old builder in the test as the reference, or compare against a table built
  by the eight-direction loop in the test itself); plus the corpus route hash.
- Proposal 2: for all 75 maps plus colossal, `bridgeNodes`, `bridgeOffset`, `bridgeLen`
  identical to a build with the shortcut disabled (a build flag or a test-only parameter),
  and a unit test on a small map with a blocked midpoint edge that forces the fallback and
  checks the BFS path is returned. Corpus route hash and `pops_per_tick` unchanged.
- Both: activation rows on m8i with `route_index`, `mixed_nav` and total ratios reported per
  map, the worst map named, against the unchanged 2x gate.

## 5. What to expect, and what not to claim
The gate is a ratio: `(map + index + mixed nav + hazard + cache) / map`. Proposals 1 and 2
touch only the mixed-nav term (190 ms on map 48); the route index (300 ms) and BodyMap
(350 ms) are untouched. Even if mixed nav fell to zero the ratio would be about 1.87x, so
the two proposals can in principle close the 143 ms gap, but only if most of the 190 ms is
legality and bridges. The BFS count suggests bridges are a large share (about 9 million
insertions with quadratic scans per giant map today), and legality is a few million pixel
reads; the anchor pass and the `fineForCell`/`bridgeNodes` filling are the rest. Nothing here
is timed; the m8i rows decide, and if the ratio still exceeds 2x after both, the remaining
term is the route index, which these proposals do not address and which no current unit
covers. No waiver is implied by any of this.

## 6. Artifacts
`peer-proofs/activation_legality_bridge_check.nim` (script, replicates `findBodyBridge`
verbatim and the bit tests) and `activation_legality_bridge_check.out` (raw stdout of the run
on 2026-09-09, per-map rows and totals).
