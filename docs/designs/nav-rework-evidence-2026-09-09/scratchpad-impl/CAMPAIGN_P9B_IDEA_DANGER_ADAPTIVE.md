IDEA D (from James): hierarchical A* with higher granularity around danger fields — danger-adaptive resolution.

Premise: danger is the only per-seat dynamic cost term, and the seat's danger raster is known per 32-tick generation. Fine resolution is needed only where danger is nonzero (plus a margin), because that is where wall-hugging LOS-shadow lanes decide the weighted cost; everywhere else the coarse structure is already within the no-danger inflation numbers.

Shape to measure (after H1/H2 results, or as part of them if 4 px confirms H1):
1. Per seat, per danger generation, compute the HOT set: nav cells with danger > 0 dilated by 1-2 cells (bounded pass over the raster at rebuild time; store as a bitset, 42k bits = 5 KB pool / 49 KB colossal per seat, or derive from the per-room summary from CAMPAIGN_P9B idea 1).
2. Three-level search, top-down:
   - Room/side graph for rooms with no hot cells (static segments, static lengths, zero danger) — as today.
   - 8 px cell A* over legalMoves inside rooms that are hot but where the route does not need to pass through hot cells... or simply:
   - 4 px lattice nodes ONLY inside hot cells (each hot 8 px cell expands to its 4 sub-lattice points with exact segmentClear legality, computed lazily from the clearance raster, no precomputed storage); 8 px anchors elsewhere. Edges between an 8 px anchor and a neighbouring 4 px sub-point are legal iff segmentClear. One A* over this mixed graph with the same Q4 cost terms; heuristic octile in px.
3. Bound: pops cap plus the hot-set size; report hot-cell counts per case (mean/max), pops, ns per query, inflation per stratum. Compare against: pure 8 px (round 1), pure 4 px (H1), anchors (H1a).
4. Variant: hot region = danger > 0 within the corridor rooms only (combine with corridor restriction) to keep the search small on far routes.

Expected: near-4 px quality on danger strata at a fraction of 4 px pop counts, because fine nodes exist only in the LOS footprint. Record as scoreboard rows "D1..Dn". If it wins, this becomes the production search: coarse everywhere, fine where it matters, with the hot set refreshed at the danger cadence.
