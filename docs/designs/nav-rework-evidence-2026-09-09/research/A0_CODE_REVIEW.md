# A0 code review: four-direction fine legality with mirrored reverse bits

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff of
`src/shell/body_route_query.nim` against `A0-parent-body_route_query.nim`, confirmed
byte-identical to HEAD at 782af867: one hunk in `buildBodyFineLegality` (four forward
directions, each setting its own bit and the neighbour's reverse bit). Also
`tools/check_body_graph_identity.nim` (new, untracked) and `A0_PREREG.md`. Source read-only;
no timing claims.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact. The four pairs are true opposites in `NavNeighbors`, every undirected edge is
evaluated exactly once with the same predicate the parent used, the mirrored write cannot
interfere with the loop, and the result equals the parent table bit for bit. Independent
evidence: an eight-direction reference built only from the public `canStand` and
`segmentClear` matches the candidate's `legal` and `standable` on every node of all 76 maps
(16,361,517 nodes, 0 differences, colossal included), and both focused suites pass here.
The identity tool is sound for its purpose; two notes in section 5.

## 2. The change
Old: for each standable node, all eight `NavNeighbors` directions; bit set iff the neighbour
is in range, standable, and `segmentClear(point, nextPoint)`.
New: for each standable node, directions 1, 3, 6, 7 only; on success set bit `direction` on
the node and bit `reverse` on the neighbour, with pairs (1, 0), (3, 2), (6, 5), (7, 4).

## 3. Why it is the same table
- Pairs are opposites: `NavNeighbors` is `0:(-1,0) 1:(1,0) 2:(0,-1) 3:(0,1) 4:(-1,-1)
  5:(-1,1) 6:(1,-1) 7:(1,1)`, so 1/0, 3/2, 6/5 and 7/4 are exact negations. Checked against
  `body_map.nim:95-97`.
- Coverage: every undirected edge `{n, m}` has exactly one of its two directions in the
  forward set (the forward set contains one direction of each opposite pair), so it is
  evaluated once, from whichever endpoint sees it as forward. Both endpoints must be
  standable in the old code (the outer `continue` and the `standable.fineBitAt(nextNode)`
  test), and the new loop keeps both tests, so an edge with a non-standable endpoint gets no
  bits in either version.
- Predicate symmetry: the old table set `legal(m, reverse)` iff `segmentClear(point(m),
  point(n))`, and the new code sets it iff `segmentClear(point(n), point(m))`. For the two
  offsets legality uses (4 px axis and 4 px diagonal) `segmentClear`'s supercover walk visits
  the same pixel set from either end and checks `canStand` at each, so the two calls are
  equal (`ACTIVATION_REVIEW.md` section 2; 91,240,212 directed edges with 0 asymmetries on the
  parent table). Therefore every bit is the same.
- Write ordering is safe: the mirrored write targets `nextNode`, which for directions 1, 3, 7
  is a later node and for direction 6 an earlier node; the loop never reads `legal` of any
  node while building, only ORs bits into it, so an earlier or later write cannot change a
  decision. Bounds: `nextNode` is range-checked before use; the sequence bounds check on the
  write stays on in `-d:release`.
- Nothing else in the graph changes: anchors, wall band, bridges and `fineForCell` are
  computed from `legality` and the map exactly as before, so equal legality implies equal
  arrays, which the identity tool will show hash-for-hash between the parent and candidate
  binaries on m8i.

## 4. Independent evidence
- Reference check (`peer-proofs/a0_legality_reference_check.nim`, stdout retained): for each
  of the 64 pool maps, 11 configured maps and colossal, rebuild the expected `legal` byte
  for every node with the eight-direction rule using only public predicates and compare with
  `graph.legality.legal`, and compare `standable` bits with `canStand`: 76 maps,
  16,361,517 nodes, 0 differences. This does not share the candidate's loop structure, so it
  is independent of the mirroring logic.
- `tests/test_shell_body_nav_rework.nim` 16 of 16, `tests/test_shell_body_route_index.nim`
  7 of 7, both here with A0.
- The identity tool ran here on the candidate (76 rows, per-array SHA-256, retained as
  `peer-proofs/a0_identity_tool_candidate_local.json`); the parent hashes come from the m8i
  parent build per the prereg, and the comparison there is the in-tree exactness gate for the
  whole graph.

## 5. The identity tool
`check_body_graph_identity.nim` hashes each retained graph array with SHA-256 over its raw
bytes (`legal`, `standable`, `cellForNode`, `fineForCell`, `anchorForCell`, `anchorNode`,
`wallBand`, `bridgeOffset`, `bridgeLen`, `bridgeNodes`) plus `bridgeNodes.len` and the graph
activation time, over the 64 pool maps, the 11 configured maps and colossal. The element
types are fixed-width integers or arrays of them (`int32`, `uint8`, `array[4, int32]`,
`array[8, int32]`, `array[8, uint8]`), so raw-byte hashing has no padding or native-width
issue, and all targets are little-endian as the comment says. Two notes:
1. It hashes `bridgeNodes` over `len`, not capacity, which is right for content identity;
   the capacity question is the ledger's, not this tool's.
2. `graph_activation_ns` is a per-map wall time inside a tool that also builds the `BodyMap`
   outside the timed region; it is informational and must not be read as the activation gate,
   which the harness's rows define with map, index, nav, hazard and cache all timed.
The tool is common to both arms, as the prereg requires.

## 6. What remains
The m8i parent-versus-candidate hash comparison on all 76 maps, the three interleaved
activation pairs with the ratios reported explicitly (the activation row's `pass` is memory
only), and the full 3,072-case quality run. No speed is claimed here; A0 halves
`segmentClear` calls in legality construction and touches nothing else.
