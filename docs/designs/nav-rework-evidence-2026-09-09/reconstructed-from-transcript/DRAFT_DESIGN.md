# Draft design: shared precomputed cog navigation (nav rework)

Author: Claude (for James). Status: DRAFT for Codex critique. Repo commit fad3029f (origin/main, 2026-09-04).
Asana parent task 1218165906459726 is the contract; this draft proposes the concrete mechanism.

## 0. Non-negotiables from the task (do not re-litigate)

- One episode-shared deterministic route index built at map install (after BodyMap geometry, before cogs activate). HPA*-style room/portal hierarchy over BodyMap's existing rooms and chokes. No Recast, no new dependency, no JPS as primary.
- One immutable zone hazard overlay attached when the sim's paint-arrival raster exists.
- During active play: NO full-board A*/Dijkstra/route-field mint/resumable search. Only bounded small-graph queries, scoring precomputed segments, following precomputed local fields, local steering.
- A living cog with a valid goal begins safe progress immediately (spawn case AND arrived-at-old-endpoint case). Deterministic 8-octant local steering when no advancing route exists.
- Routes may differ from the current 4 px A* but must be legal, reach the same validated goal/component, and pass: weighted-cost inflation p95 <= 3.0 %, max <= 10.0 % (overall and per roster x profile x dynamic-state x near/far stratum).
- Complete FirstLight body slice on linux/amd64 release: p95 <= 4.0 ms, max <= 5.0 ms for 16 and 32 seats. Activation (map + index) <= 2x current BodyMap baseline on pool maps, <= 3x colossal. Retained shared nav data <= 16 MiB pool maps, <= 32 MiB colossal. Per-seat query state must not contain arrays sized by map width/height/fine-node count.
- Keep destination selection (cover-hold) separate from route execution. Nav treats every ValidatedGoal identically.
- Lifecycle: coalesce equivalent goals against the last accepted route anchor; epoch/provenance alone never replans; profile change or material target change does; keep an advancing old route until an atomic replacement is ready (an arrived endpoint is not an advancing route); death clears all per-life nav state; inactive seats do no nav work.
- Retain from PRs 408-410: finite zone risk (price, never prune), fog-safe integer safety hints, navigate_to target_class=zone_safe_ground with required literal fallback and stable target identity.

## 1. What exists today (verified against source)

BodyMap (src/shell/body_map.nim) is immutable per episode and already computes: 1 px wall + clearance raster (chessboard EDT, 1-Lipschitz), pixel connected components, an 8 px nav grid (`NavCell = 8`, `walkable` = clearance at the cell CENTER > PlayerHalf(6)), watershed rooms over clearance with chokes at room contacts deduped at 64 px (`GateSeparationPx`), cover atlas, validator EDT tables, home fields. `roomLabelAt` gives the room for any pixel. `BodyRoom.chokes` lists that room's chokes; `BodyChoke` has `pos`, `clearance`, `roomA/roomB`.

Planner (src/shell/body_planner.nim): resumable weighted A* on a 4 px lattice (`PlanStepPx = 4`), edge legality = `canStand` + `segmentClear` per pixel; cost = step * (1 + profileDangerWeight * danger(midpoint)) x8 on the blocked-penalty cell; heuristic = max(Euclid, 0.999 * route-field distance if a field is minted); fallback halves the step on failure (2 px, 1 px). Per-seat fixed workspace sized to the FULL 4 px lattice.

Coordinator (src/shell/body_nav.nim): per-seat BodySeatCache (4 route-field rasters, each map-sized), BodyPlanner, plan job, mint job, danger field (map-sized, per seat, rebuilt every 32 ticks staggered), follower (path buffer sized to the full lattice, cursor, corridor 20 px, stuck 8 ticks, blocked penalty 96 ticks), and the 256-units-per-seat pooled round-robin scheduler. `navigationWaypoint` decides replans (goal moved > 2 cells, profile change, no path, stuck, moving target every 12 ticks, plan lost) and returns `path[cursor]` or SELF when `pathLen == 0`. `setStandingIntent` (body.nim:565-590) cancels any pending plan unconditionally.

Measured per-seat memory on a giant pool map (3211x1713; 85,814 nav cells; 344,487 lattice nodes; capacity = 344,487; hash capacity = 1,048,576):
- planner heap nodes 40 B x 344,487 = 13.8 MB; positions + generation 5.5 MB; hash tables 3 x 8 B x 1,048,576 = 25.2 MB; keys/closed/gScore/cameFrom 8.6 MB; resultPath 5.5 MB
- follower path buffer 5.5 MB; 4 route-field slots x 85,814 x 9 B = 3.1 MB; danger + visited 0.7 MB
- total ~68 MB per seat -> ~2.2 GB for 32 seats. Matches the 2.37 GB RSS in the task.

Nav census (tools/bench_body_port.nim nav-census, uncommitted, this machine, commit fad3029f). Columns: label, w, h, navCells, planNodes, components, rooms, chokes, intraRoomChokePairs, maxRoomChokes, portalFieldCells(sum over rooms of degree x roomNavCells), atlasPosts, bodyMapBuildMs. See nav_census.tsv. Highlights:
- giant pool maps (3211x1713): rooms 43-107, chokes 212-369, intra-room pairs 2.6k-4.4k, max room degree 34-46, portal-field cells 1.28M-1.96M, BodyMap build ~505 ms (arm64 release).
- huge (2223x1186): rooms 23-37, chokes 113-155, pairs 1.6k-2.0k, portal-field cells 0.5M-0.95M, build ~215 ms.
- colossal (6422x3427): 302 rooms, 1,237 chokes, 13.7k pairs, max degree 55, portal-field cells 9.5M, build 2,411 ms. 9 components.
- Some pool maps have many components (pool:17 = 19, pool:18 = 7): pits/islands. Validated goals are always in the requester's component.

Speed: MaxSpeed 704 / MotionScale 256 = 2.75 px/tick top speed (sim_types.nim:514-518).
Zone: `ensureZoneArrivalField` builds a once-per-episode uint16 paint-arrival raster on a 4 px grid (`ZoneFieldCellPx = 4`, sentinel `ZoneNeverArrives = 0xFFFF`), src/ctf/zone_field.nim:65,263,1645. PR 408's `projectHazardField` does a conservative MIN projection onto the 8 px nav grid; reuse that function shape.

## 2. Proposed architecture (the concrete mechanism)

### 2.1 BodyRouteIndex (built once per map install, immutable)

Built from BodyMap immediately after `newBodyMap`, inside the same activation barrier. Deterministic: every loop is in room index / choke index / row-major cell order; no hashing of pointers, no tables keyed by non-deterministic order.

Data (all `seq` allocated once; sizes in the census units):

1. `legalMoves: seq[uint8]` per nav cell. Bit i set when the move to Neighbors[i] is collision-legal: both cells walkable AND `segmentClear(center, neighborCenter)` (pixel-exact, same predicate the current planner uses) AND for diagonals both orthogonal neighbors walkable (no corner cutting). One byte per nav cell (86 KB giant, 343 KB colossal). This is THE legality oracle for build-time Dijkstra, the follower, the local steering, and the local search. Nothing during play ever calls `segmentClear` on a long segment except the optional smoothing lookahead.
   Why: 8 px cell centers with clearance > 6 do NOT guarantee the 8 px segment between them is standable (clearance is 1-Lipschitz, so the midpoint may have clearance as low as 3). The current route-field Dijkstra ignores this; a route built from it would not be collision-legal.

2. Room compaction: `roomOf: seq[uint16]` per nav cell (room of the cell center pixel; 0 = none), `roomCellStart: seq[int32]` per room (offset into `roomCells`), `roomCells: seq[int32]` (nav cell indices of each room, row-major), `localIndex: seq[int32]` per nav cell (index within its room's slice, or -1). Cells whose center is walkable but not inside a room label (should be rare; verify) are attached to the nearest room by BFS at build time.

3. Portals = BodyMap chokes. `portalCell: seq[int32]` (nav cell of the choke position; if that cell is not walkable, the nearest walkable cell in fixed ring order), `portalRooms` = (roomA, roomB) from the choke. A portal belongs to both rooms' portal lists (`roomPortals`, in choke-index order).

4. Portal fields: for each (room r, portal p in r) one `seq[uint16]` of length roomCells(r) = legal-move geodesic distance in 8 px cell units x 8 (i.e. px, capped at 65,534) from each room cell to portal p, computed by ONE Dijkstra per (room, portal) restricted to the room's cells plus the portal cell. Sentinel 65535 = unreachable within the room. Stored as `portalFieldStart: seq[int32]` per (room, portal) into one flat `portalField: seq[uint16]`. Size = portalFieldCells x 2 B: giant 2.6-3.9 MB, colossal 19 MB.
   No hop byte stored: the descent step from a cell is derived at use time as the legal neighbor with the smallest field value (ties broken by fixed Neighbors order). Saves one third of the memory and keeps the field the only source of truth.

5. Intra-room segments: for every pair (p, q) of portals of the same room with p < q, the cell path from p to q obtained by descending q's... (from p's field starting at q's cell), stored as a flat `segmentCells: seq[int32]` with `segmentStart/segmentLen` and `segmentLengthPx: uint16` (static geodesic length), plus a 4 x uint16 bounding box for the blocked-penalty membership test. Pairs unreachable inside the room get no segment. Count = intraRoomChokePairs (giant <= 4.4k; colossal 13.7k). Estimated size: pairs x ~40 cells x 4 B = 0.7 MB giant, 2-3 MB colossal.
   The same Dijkstra that produced the field yields all of that room-portal's segments, so build cost is exactly one Dijkstra per (room, portal): giant ~740 room-bounded Dijkstras over ~1-5k cells = ~16M relaxations (est. 100-250 ms); colossal ~2.5k Dijkstras = ~76M relaxations (est. 0.5-1.2 s). Both inside the 2x / 3x activation caps (current BodyMap build 505 ms / 2,411 ms). Transient build workspace = one heap + one distance array over ONE room, reused.

6. Portal graph: adjacency = for portal p, every segment that has p as an endpoint (both rooms). Nodes <= 1,237 (colossal). Also a portal-level `component` and a room-level `component` copied from BodyMap so cross-component queries fail in O(1).

Total retained on giant ~5 MB, colossal ~24 MB. Under the 16 / 32 MiB limits.

### 2.2 BodyHazardOverlay (built once per episode when the arrival raster exists, immutable)

- `arrival: seq[uint16]` per nav cell = MIN over the 4 px source cells the nav cell covers (PR 408's projection; conservative). 172 KB giant.
- `portalArrival: seq[uint16]` per portal (arrival at its cell).
- `segmentArrivalMin/Max: seq[uint16]` per segment (min and max over its cells). Lets a query price a segment without touching cells in the common cases (ETA well before min -> 0 risk; ETA after max -> saturated risk) and sample cells only in the ambiguous band.
- Safe-ground support (for PR 409/410 contracts): per horizon bucket (48 ticks, PR 408's `SafeHorizonBucketTicks`), the set of DRY portals (arrival > bucketEnd + horizon) seeds ONE multi-source Dijkstra over the portal graph (static lengths) producing `safeDistPx[portal]` and `safeNext[portal]`. Recomputed once per bucket roll (1,237 nodes, ~9k edges: microseconds), not stored for every bucket. No full-grid safe field is ever built.
  Per-seat answer for the hints: if my cell is dry -> ticks_to_safety 0. Else the nearer of (a) a fixed-radius local ring scan (<= 6 cells) for a dry cell reachable by legal moves (bounded), and (b) min over my room's portals of (portalField distance to p + safeDistPx[p]). Direction = first step of whichever wins (octant, integer). `zone_safe_ground` target = that cell (local) or the dry portal / the dry cell adjacent to it (portal route), validated through `validateGoal` like any literal, with identity = (class, bucket, chosen source cell). If nothing resolves, the play's literal fallback point stands (PR 410 rule).

### 2.3 Live route query (synchronous, bounded, per goal change)

Inputs: seat position, ValidatedGoal, CostProfile, seat's danger field, blocked-penalty cell, hazard overlay, current tick.

1. Resolve start cell and goal cell (nearest walkable cell in fixed ring order, bounded ring <= EndpointSnapPx as today). Component check via BodyMap; mismatch -> no route (cannot happen for a ValidatedGoal from the same component, but keep the assert).
2. Same-room fast path: if start and goal are in the same room and `lineLegal(start, goal)` (walk cells along the Bresenham line and check `legalMoves`; bounded by room diameter) -> route = the straight line. Otherwise fall through to 3 (the portal graph still reaches a same-room goal via portals; see open question A for the bounded local search alternative).
3. Attach: for each portal p of the start room, attachCost(start -> p) = danger-weighted cost of the descent chain (walk the chain, sum step x (1 + w x danger(mid)) x blocked factor); chain length is bounded by the room diameter and the number of portals by maxRoomChokes (<= 55). Same for the goal room (chain from goal cell toward each of its portals; the route will follow it reversed).
4. Search: A* over the portal graph with start and goal as virtual nodes. Edge cost = precomputed static length + profile-weighted danger sum + blocked factor + hazard risk. Heuristic = Euclidean px to goal (admissible for static length; the danger terms are >= 0 so it remains admissible for the weighted cost). Tie-break by (cost, portal index). Hard cap on expansions (constant, e.g. 2,048 pops > portal count of any supported map, so the cap only guards bugs). Workspace: arrays sized by portal count, SHARED across seats (queries are synchronous and sequential), generation-stamped so no clearing per query.
5. Danger-weighted segment costs are NOT computed inside the query: each seat keeps `segmentDangerCost: seq[float32]` sized by segment count (17 KB per seat on giant) that is refreshed when that seat's danger field is rebuilt (every 32 ticks, staggered; cost = sum of segment cells ~175k reads ~0.2 ms, which is inside the existing danger-rebuild slot). The query reads it. The blocked-penalty factor (x8) is applied at query time only to segments whose bounding box contains the blocked cell AND whose cell list contains it (linear scan of that segment only).
6. Hazard risk per segment at query time: ETA at segment entry = gStaticLength / 2.75 px per tick (the derated speed from PR 408 can be reused as a constant); if ETA_exit + ramp < segmentArrivalMin -> 0; if ETA_entry > segmentArrivalMax -> saturated; else sample the segment's cells (bounded). Finite price, never a prune.
7. Materialise: concatenate start chain + segment cell lists (in order, with the endpoint dedup) + reversed goal chain into the seat's FIXED route buffer (`MaxRouteCells`, e.g. 4,096 cells x 4 B = 16 KB; the longest legal route on colossal is ~1,500 cells). If the route exceeds the buffer, keep the prefix and mark the route `truncated`; the follower re-queries when it reaches the prefix end (bounded, deterministic, and only possible on maps larger than supported).
8. Install atomically (swap buffers, cursor 0, anchor = goal cell, revision).

Cost estimate per query on giant: attach <= 2 x 46 chains x ~100 cells = ~10k reads; A* <= 369 nodes / ~8.7k directed edges with O(1) edge cost; materialise <= 1,500 cells. Tens of microseconds; a 32-seat simultaneous burst is well under 1 ms. The corpus benchmark (subtask 09) is the proof, not this estimate.

### 2.4 Following and immediate movement (every navigate tick)

- The follower keeps the CURRENT shape (path buffer + cursor + corridor + stuck counters) but over 8 px cell centers instead of 4 px lattice points. Waypoint advance rule unchanged (within one NavCell). Optional smoothing: look ahead up to K = 6 cells and target the farthest cell reachable by a legal straight line (`legalMoves`-walk along Bresenham, bounded by K). This removes portal-point kinks and octile zig-zags; it is what keeps the cost inflation under 3 % on short gate crossings.
- `advancingWaypoint`: the route is usable only while `path[cursor]` is farther than the arrive radius from self AND the cursor has not reached the last point while standing on it. An arrived endpoint is NOT an advancing route.
- Local steering when there is no advancing route (spawn, arrived-at-old-endpoint while the goal changed, truncated prefix exhausted, or route failed): evaluate the 8 octants in Neighbors order; candidate = self + octant x 8 px; reject if not `canStand` or the pixel segment is not clear (`segmentClear` on an 8 px segment is bounded and cheap) or the candidate is the blocked-penalty cell; score = progress (distance-to-target reduction toward the current target: next waypoint if any, else goal) - profile weight x danger(candidate) - hazard price; choose max, ties by octant order; if no candidate progresses, stand (recorded as `bnsNoProgress`, distinct from `bnsNoPath`). Mask = octant bits. Deterministic, allocation-free, O(8).
- Because the route query is synchronous, steering is only needed on ticks where the query did not produce a route (failed / truncated / no goal). It still runs for the spawn tick order: a new goal at tick t installs a route at tick t and moves at tick t.

### 2.5 Request lifecycle (replaces setStandingIntent cancel + navigationWaypoint replan rules)

- `setStandingIntent` no longer touches the nav seat except to record the goal pin. The nav coordinator owns request decisions.
- Route anchor = goal cell of the last ACCEPTED route (installed or failed). A new intent replans iff: no route for this life, OR goal cell differs from the anchor by more than `ReplanGoalCells` (2) in either axis, OR profile changed, OR stuck for `StuckTicks`, OR movingGoal and 12 ticks since the last query, OR the route was truncated and the prefix is exhausted. Sub-threshold goal moves do NOT move the anchor (so drift accumulates and eventually triggers). Epoch/provenance changes are invisible to nav.
- Because queries are synchronous there is no "pending" state and nothing to cancel; "keep an advancing old route until an atomic replacement is ready" is satisfied trivially (the replacement is ready in the same call). The old-route rule still matters for a FAILED query: keep the old route only while it advances; otherwise steer.
- Death (`resetAfterDeath`/`setSeatActive(false)`): clear route buffer, cursor, anchor, revision, lastXy, stuckTicks, blocked penalty, lastQueryTick, follow counters, semantic target identity, segmentDangerCost validity, and desired profile/moving flags. Inactive seats are skipped by the danger rebuild and never queried. Shared immutable map and hazard indexes may remain.

### 2.6 What is deleted

BodyPlanner (per-seat lattice A* and its workspace), BodyFieldMinter, route-field slots in BodySeatCache (`MaxRouteFieldsPerSeat`, `pinStandingGoal`, `peekRouteDistance`), plan/mint jobs, `ColdPlanBudgetPerTick`, `runPlanningTick`, `prewarmColdPlans`, plan budget events and traces, `planCursor/mintCursor`, the `stale_path` diagnostic state (replaced by following / steering / no-progress / arrived). Duck cache stays (cover-hold owns it).
Per-seat memory drops from ~68 MB to under 1 MB (danger field dominates).

### 2.7 Determinism and replay

No clocks, threads, hash-iteration order, or pointer identity anywhere in route choice. Replays re-drive masks, so nav is native-only (verified in PR 408: no body_* module in the wasm build). Movement masks change -> GameVersion bump + 8 fixture re-records + viewer rebuild per the task.

## 3. Open questions for Codex (please argue, with numbers where possible)

A. Same-room goals without a legal straight line. Options: (1) route via portals only (may loop out and back: ugly and can blow the 10 % max inflation on short routes); (2) a bounded local A* on the nav grid restricted to the room's cells with a fixed node cap (e.g. 4,096) using `legalMoves`, shared generation-stamped workspace; fall back to (1) if the cap is hit; (3) per-room precomputed all-pairs is impossible. I lean (2). Is there something simpler?

B. Cell resolution. 8 px cells with center anchors lose 4 px-only corridors (the current planner falls back to 2 px / 1 px lattices). Options: (1) accept and measure "missing route" in the corpus gate (a miss fails the gate); (2) per-cell standable ANCHOR point (best 4 px sub-lattice point when the center is not standable) so narrow corridors keep connectivity, at +1 byte per cell; (3) build the whole index on the 4 px lattice (4x the field memory: colossal ~76 MB, over the limit). I lean (2) plus the gate.

C. Big rooms with 40-55 portals: attach cost walks up to 55 chains. Is the chain walk (danger-weighted) worth it versus static distance x (1 + w x danger at start)? The exact walk keeps the 3 % gate honest near enemies; the approximation is O(1). I lean exact (bounded and tiny).

D. Should danger-weighted segment costs be refreshed at danger-rebuild time (my proposal) or computed lazily in the query with a per-seat memo keyed by danger generation? Rebuild-time is simpler and puts the cost where the existing cadence already is.

E. Smoothing lookahead K and whether to smooth at query time (materialise a smoothed polyline) or follow time (waypoint lookahead). Follow-time keeps the buffer small and needs no extra legality machinery; query-time makes the corpus cost measurement match what the cog actually walks. Which?

F. Anything in 2.x that is more complex than it needs to be? The goal is the simplest design that meets the gates.
