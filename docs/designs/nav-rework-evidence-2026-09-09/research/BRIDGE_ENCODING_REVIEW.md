# Bridge encoding review: one direction byte per bridge step

Historical proposal from before the expanded memory allowance. It is not implemented and is no longer required to meet the measured memory gate; see MEMORY_CAP_RULING.md.

Written 2026-09-09 by Claude (peer) for `BRIDGE_ENCODING_REVIEW_REQUEST.md`. Source review
only; no edits. Corrections to `GIANT_MEMORY_PLAN.md` are applied there in a dated section.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Recommended as the first memory unit. Encoding each bridge step as a `NavNeighbors` direction
byte reproduces the same node and point sequence exactly, removes the per-step `finePoint`
division and modulo in the bridge cost walk, keeps the target check before the walk, and
reconstructs in reverse into the existing `reconstruct` storage without new per-seat state or
any change to the overflow rule. Saving on the giant maps: 3,779,136 bytes at the present
retained capacity (1,259,712 x 3), and 3.1 to 3.4 MB at exact allocation together with G1.
It supersedes G2's per-cell base offset as the first bridge item (G2 still applies on top).

## 2. Why every step is one direction
`findBodyBridge` (`body_route_query.nim:180-232`) is a breadth-first search from the source
anchor node over `legal` bits, each expansion being `node + delta` for one `NavNeighbors`
entry (`body_map.nim:95-97`: the eight unit offsets, indices 0..7), bounded to a lattice box
around source and target. The returned path is the parent chain from the target back to,
but excluding, the source (`while cursor > 0`), reversed, so `path[0]` is adjacent to the
source and `path[^1]` is the target, and every consecutive pair is one lattice-neighbour
move. Length is at most 255 (the builder rejects longer paths, 303). So the path is
losslessly the sequence of directions taken, and decoding from the source anchor by
`node += delta.y * latticeWidth + delta.x` per byte reproduces the identical node indices;
points follow by `point += 4 * delta`, which equals `finePoint` of the decoded node because
`finePoint` is `(node mod width, node div width) * 4` and the BFS box keeps every node inside
the lattice, so no row wrap can occur.

## 3. The three consumers, checked
- Target check before the walk (pop loop, 662-672): today `target = bridgeNodes[offset +
  len - 1]`. With direction bytes the target is not stored, but the builder defines it as
  `anchorForCell[next cell]` for the cell in the current direction (296-300), which is
  exactly the last node of the path (the BFS stops on `nextNode == targetNode`). So the
  closed-state check can read `anchorForCell[cell + delta]` before decoding; identical value.
- Cost walk (676-681): `previous = fromPoint` (the source anchor's point), then per step
  `nextPoint = finePoint(bridgeNodes[...])` and `integratedMixedCost(previous, nextPoint)`.
  With directions: `nextPoint = previous + 4 * delta`, same points in the same order, same
  costs. `integratedMixedCost` itself still samples midpoints between the two points by its
  own arithmetic; unchanged.
- Reconstruction (747-758): the finish loop writes `cursor` (the bridge's target, already
  emitted), then the interior nodes in reverse (`countdown(length - 2, 0)`), then continues
  from `parent[cursor]` (the source). With directions the interior nodes are obtained by
  decoding forward from the source; to emit them in reverse without new storage, decode into
  `reconstruct[count + length - 2] .. reconstruct[count]` (writing position `count + length -
  2 - i` for decoded step `i`, `i` in `0 .. length - 2`) after first checking `count + length
  - 1 <= reconstruct.len`. Overflow semantics: today the per-node check fails at the first
  node that does not fit; the block check fails iff the same total does not fit, so the set
  of routes that fail is identical, and the failure code is unchanged. This is the "reverse
  positions" scheme in the request, and it needs a stack-free decode because the writes go
  backward while decoding goes forward: decode once forward into the target positions, which
  works because the target positions are known in advance from `length`.
- Directed asymmetry: bridges are stored per (source cell, direction); the reverse bridge is
  a separately searched path and may differ. Direction encoding does not change that: each
  stored path stays its own byte sequence, decoded only from its own source. No symmetry is
  assumed anywhere.

## 4. Storage layout
`bridgeNodes: seq[int32]` becomes `seq[uint8]` (or `seq[int8]`); `bridgeOffset` keeps
indexing into it; `bridgeLen` unchanged. G1 (exact capacity) and G2 (per-cell base offset,
valid because the builder appends per cell in direction order) compose with it. With G2 the
offset per direction is a prefix sum of at most seven `bridgeLen` bytes.

## 5. Tests the unit needs
- Round trip on every pool map and the 11 giant maps: decode every stored bridge and compare
  node by node with a parent build's `bridgeNodes`, and point by point with `finePoint`.
- Corpus route hash unchanged; `pops_per_tick`, masks, latency content identical to the
  parent; ledger shows exactly `3 x capacity` fewer bytes (or the exact-allocation figure).
- A reconstruction case with a bridge of length 1 (no interior nodes), length 2, and 255,
  crossing the block overflow boundary, asserting the same `brfDescriptorOverflow` outcome as
  the parent.

## 6. Corrections to the memory plan (also recorded in `GIANT_MEMORY_PLAN.md`)
- G3 and G4 were stated as unclamped identities; that is wrong at the map boundary. The
  nav grid is `navWidth = max(1, width div 8)` (`body_map.nim:949`, floor) while the fine
  lattice is `(width - 1) div 4 + 1` (ceil), so for widths not a multiple of 8 the last
  lattice column (and likewise the last row) lies beyond the last cell's span and `cellOf`
  clamps it into the final cell. On the giant maps, 3211 = 8 x 401 + 3, lattice column 802
  (x = 3208) clamps into cell column 400; 1713 = 8 x 214 + 1, lattice row 428 clamps into
  cell row 213. `cellForNode` therefore needs the clamp: `min(x div 2, navWidth - 1)`, which
  is still arithmetic and exact (G3 survives with the clamp). `fineForCell` is filled in node
  order with slot `((y mod 8) div 4) * 2 + (x mod 8) div 4`, so a clamped boundary node
  overwrites the slot of the interior node with the same slot in the final cell (for x =
  3208, slot 0 or 2 of cell column 400, replacing x = 3200). An arithmetic inverse must
  reproduce "last writer wins in row-major node order" on the last column and row, which is
  derivable but not an identity; the safe form of G4 is to keep `fineForCell` (1.37 MB) or
  keep only an explicit table for the boundary cells (401 + 214 cells on the giant maps) and
  derive interior cells. G4's saving is therefore either 0 or about 1.36 MB with the boundary
  table and a proof over all supported dimensions; it is demoted and not counted until proved.
- G8: store an `int8` direction with a `-1` sentinel and derive the source cell from
  `parent` (via the clamped G3), exactly as Codex proposes; no reverse lookup, no
  uniqueness argument. Saving 1,033,461 on the giant maps.
- Bridge items reordered: direction bytes (this review, 3.78 MB), then G1 exact capacity
  (0.57 to 0.88 MB on the byte stream becomes 0.14 to 0.22 MB), then G2 (2.40 MB).
- Revised Tier A sum on `br-gen-5204`: direction bytes 3.78, G2 2.40, G5 2.71, G3 1.38,
  G7 1.38, G8 1.03, G6 0.69, G11 0.60, G1 about 0.15: about 14.1 MB. Shared bound after
  Tier A: about 17.2 MB, so Tier B (G9 1.38, G10 0.79, G12 1.38) is still needed for a
  margin; with G9 and G10 about 15.1 MB, with G12 as well about 13.7 MB, before M3's overlay
  and cache and R1's 86 KB.

## Status note (2026-09-09, after MEMORY_CAP_RULING.md)
James authorised up to 4x the non-colossal memory caps; root is setting a 32 MiB shared limit (2x) after branch sync, with the 256 MiB total unchanged. The measured giant maps fit that limit, so the reductions in this document are no longer required for the obsolete 16 MiB target. The document is retained as an inventory of exact savings and their proofs; nothing in it is scheduled. All timing, quality, determinism and activation gates stay in force.
