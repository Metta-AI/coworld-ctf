# A1 code review: exact straight two-edge bridge shortcut

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff of
`src/shell/body_route_query.nim` against `A1-parent-body_route_query.nim`, confirmed
byte-identical to HEAD at 872e5499 (A0 retained): one hunk of ten lines at the top of
`findBodyBridge`, after the bounding-box computation and before the BFS arrays. Also
`A1_PREREG.md`. Production source read-only; no timing claims.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact. The shortcut fires only for a displacement that is exactly twice one `NavNeighbors`
delta, requires the same two legality bits the BFS would traverse, returns the path the BFS
would have returned first, and falls through to the unchanged BFS in every other case. The
proof is the one in `ACTIVATION_REVIEW.md` section 3, and the all-map check retained as
`peer-proofs/activation_legality_bridge_check.nim` (22,958,138 bridges, 22,447,020 shortcut
hits, 0 mismatches against a verbatim BFS replica) used precisely this condition. Both
focused suites pass here. The m8i all-array comparison is the in-tree gate.

## 2. The code, line by line
- The loop over `NavNeighbors` tests `targetX - startX == 2 * delta.x and targetY - startY ==
  2 * delta.y`. The eight deltas are distinct, so at most one direction matches, and the
  `break` after the first match leaves the loop whether or not the shortcut was taken; the
  BFS then runs unchanged on a miss. Non-regular displacements match nothing and skip the
  block entirely.
- `middle = startNode + delta.y * table.width + delta.x` is the node one step from the start
  in that direction. Start and target are lattice nodes with the target two steps away
  along the delta, so the midpoint lies strictly between them on the same row, column or
  diagonal and is inside the lattice; the `legal[middle]` read is in range (sequence bounds
  check kept in `-d:release` regardless).
- The two bit tests are `legal[startNode]` bit `direction` (start to middle) and
  `legal[middle]` bit `direction` (middle to target): exactly the two directed edges the
  straight path uses, in the table's own per-node-per-direction encoding. With A0's symmetric
  construction these bits are the same values as before, so A1 does not depend on A0.
- Return value `@[middle, target]` matches the BFS's path convention: the source excluded,
  the target included, in walk order; length 2, within the caller's `high(uint8)` cap.

## 3. Why the BFS would return the same path (tie ordering)
- Axis displacement, for example `(+2, 0)`: the BFS's layer 1 is the start's legal neighbours
  in `NavNeighbors` order; the target can only be inserted while expanding `(1, 0)` (index 1),
  `(1, -1)` (index 6) or `(1, 1)` (index 7), and `(1, 0)` is dequeued before both diagonals;
  the only node dequeued before it, `(-1, 0)`, cannot reach the target. So when both straight
  edges are legal the BFS finds the target while expanding the midpoint and returns
  `[midpoint, target]`. If either straight edge is illegal, the shortcut declines and the BFS
  finds whatever it finds today. The same holds for the other three axis directions by the
  index positions of their cardinal midpoints (0, 2, 3 precede every diagonal 4 to 7).
- Diagonal displacement, for example `(+2, +2)`: a two-step path must move both axes on both
  steps, so the midpoint `(1, 1)` is the only two-hop route; with both diagonal edges legal
  the BFS finds the target at the second layer from that node, and no shorter path exists.
- The 128-node cap and the `seen` scan cannot change this: the target is found before the
  third dequeue.

## 4. Bounds and callers
`findBodyBridge` has a single production caller, the anchor-to-anchor loop in
`newBodyMixedGraph`, which passes anchors of adjacent cells; regular anchors (cell centres)
differ by exactly twice a delta, irregular ones fall back. The `startNode == targetNode`
early return precedes the shortcut. No graph layout, memory, cost or query path changes;
`bridgeNodes`, offsets and lengths are identical by construction, so the route hash and the
ledger are unchanged.

## 5. Independent evidence
- `tests/test_shell_body_nav_rework.nim` 16 of 16, `tests/test_shell_body_route_index.nim`
  7 of 7, here with A1 (on top of A0).
- The retained all-map check: every stored bridge equal to a verbatim BFS replica, and on
  every regular displacement with both straight bits set the replica's path equal to
  `[midpoint, target]`; 97.8 percent of bridges hit the shortcut; BFS node insertions fall from
  400.8 M to 49.8 M across the 75 pool and giant maps. That check predates this diff but
  tests exactly its condition; the m8i all-array hashes are the confirmation on the real
  binaries.

## 6. What remains
The m8i 76-map array comparison, the three interleaved activation pairs with ratios reported
explicitly, the full quality run and the configured diagnostic, per the prereg. A1 removes
about 88 percent of BFS insertions in graph construction; how much of the mixed-nav 190 ms
that is on map 48 is what the pairs measure.
