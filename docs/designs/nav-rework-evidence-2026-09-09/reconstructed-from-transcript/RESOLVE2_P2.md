RESOLVE2 P2: derive portals from the index's own coarse room raster; BodyMap chokes become hints, not truth.

Decision. A portal side pair must be a fact about the 8 px room raster (`roomOf`) and the legal-move graph, not about BodyMap's pixel-level choke labels. Build portals in two passes, all deterministic:

Pass A (coarse boundary portals). Scan every legal 8 px move (u -> v) with roomOf(u) != roomOf(v), in row-major order of u then NavNeighbors order. Group these boundary moves by unordered room pair (a, b). Within a pair, cluster boundary moves spatially: a move joins an existing cluster of the same pair if its u cell is within GateSeparationPx (64 px, i.e. 8 cells Chebyshev) of the cluster's representative; otherwise it starts a new cluster. Each cluster becomes one portal whose anchors are the cluster's representative move (u, v): representative = the boundary move with the largest min(clearance(u), clearance(v)), ties by row-major u then neighbour order. The crossing is that single legal move. Sides = (a, u) and (b, v). No BodyMap choke is consulted.

Pass B (fine-gap portals from chokes). For each BodyMap choke, if no Pass-A portal of ANY room pair has an anchor within the +-4-cell box around the choke pixel, run the existing bounded crossing search from the choke: nearest walkable coarse cell A in ring order, then a bounded 8 px (64 pops) and 4 px (256 pops) search inside the box for the nearest walkable coarse cell B with roomOf(B) != roomOf(A). If found, add a portal with sides (roomOf(A), A) and (roomOf(B), B) and the found crossing (fine points allowed). If not found, or if roomOf(B) == roomOf(A) for every reachable cell, the choke is dropped and counted (dropped_chokes column). The choke's own roomA/roomB are never used.

Consequences you must handle and report:
- Portal count may exceed choke count (long boundaries produce several clusters). Report portals, sides, max room degree and arcs per map; if max degree or arcs grow beyond ~2x the census figures, raise the cluster separation to 128 px as a single build constant and report both.
- The connectivity proof is unchanged and now holds by construction for coarse adjacency: every legal move between rooms is inside some portal's cluster. Pockets and 4 px-only gaps still go through the fine mechanism you already built.
- Dedupe: two Pass-B portals with identical side pairs and anchors collapse to one.
- PortalAnchorRingCells stays 4 and is now used only by Pass B; do not widen it.

Commit the derivation as its own checkpoint, then rerun the full qualification (64 published + arena + colossal) and finish Phase 2 as planned. End with the literal line PHASE 2 DONE.
