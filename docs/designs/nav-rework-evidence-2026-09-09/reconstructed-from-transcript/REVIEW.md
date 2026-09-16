# Round 1 review: shared precomputed cog navigation

## 1. Fact check

1. **The proposed overlay reads the wrong zone array.** `ZoneArrivalField` has two surfaces: `damage` is the ungated surface used by `zoneDamageByPaint`, while `arrival` is render-gated and may say `ZoneNeverArrives` under wall art (`src/ctf/zone_field.nim:1593-1616`). `zonePaintedForDamageAt` reads `damage`, not `arrival` (`src/ctf/zone_field.nim:1762-1796`), while the currently exported cell accessor returns `arrival` (`src/ctf/zone_field.nim:1745-1757`). Section 2.2 must consume an immutable snapshot of `damage`; using `arrival` creates false safe lanes. Install it only when `zoneDamageByPaint` is armed, or nav will price a visual effect that does no damage.

2. **The ETA in 2.3.6 is not derated.** `704 / 256 = 2.75 px/tick` is the configured top speed (`src/ctf/sim_types.nim:514-518`). Dividing by 2.75 is optimistic about acceleration, turns, collisions, and follower wander. PR 408's retained argument used three quarters of top speed, 2.0625 px/tick. Use that integer ratio, not 2.75, and state that it is a conservative-late estimate suitable only for a finite price.

3. **“Bounded ring <= EndpointSnapPx as today” is false.** `EndpointSnapPx` bounds only resolution of a non-standable start (`src/shell/body_planner.nim:335-383`). The lattice connector can expand to the full lattice (`src/shell/body_planner.nim:385-435`), and `BodyMap.nearestWalkable` can scan to the larger map dimension (`src/shell/body_map.nim:418-427`). The new endpoint attach needs its own explicit bound and failure contract.

4. **Room identifiers have two bases, and room labels are not defined for every pixel.** `roomLabelAt` returns zero off-map/wall and a one-based raster label (`src/shell/body_map.nim:190-192`, `src/shell/body_map.nim:655-658`); `BodyRoom` and `BodyChoke.roomA/roomB` use zero-based sequence indices (`src/shell/body_map.nim:194-205`, `src/shell/body_map.nim:633-654`). `roomOf` must specify which representation it stores. The probe found zero center-walkable cells without a room on all sampled maps (`cell_probe.tsv:3-10`), so the speculative nearest-room BFS is not presently justified.

5. **The colossal graph has at least 13,730 undirected intra-room portal pairs, not “~9k edges.”** That is the census value (`nav_census.tsv:26`); an adjacency list normally carries 27,460 directed entries. Also, the census does not measure total segment cells or longest route, so neither “~40 cells per segment” nor “longest legal route ~1,500 cells” is evidence-backed. On colossal, the explicitly listed fixed arrays already total about 23.48 MB decimal before segment cells and metadata: legal moves, `roomOf`, `localIndex`, `roomCells`, 9,507,875 `uint16` portal-field entries, and the overlay. An average near 175 cells across 13,730 segments consumes the remaining 32 MiB budget. Measure the actual flat segment length and allocated capacities.

6. **“Per-seat under 1 MB” is false on colossal if the current danger representation remains.** Each seat currently owns both a `float32` danger raster and a `uint32` visited raster sized to the nav grid (`src/shell/body_nav.nim:46-49`, `src/shell/body_nav.nim:164-170`, `src/shell/body_nav.nim:221-233`). At 343,256 cells that pair alone is 2,746,048 bytes per seat, before route and segment-cost state. Either scope the claim to giant pool maps or redesign danger storage; also resolve whether the non-negotiable ban on per-seat map-sized query arrays includes these coarse rasters.

7. **The zone field is not guaranteed to exist at nav activation today.** It is lazily built by `ensureZoneArrivalField` (`src/ctf/zone_field.nim:1644-1662`), normally through rendering or damage. FirstLight constructs `BodyMap` and nav directly during reset (`src/ctf/server.nim:3857-3870`), and `initFirstLightEpisode` immediately allocates the nav system (`src/shell/episode.nim:310-344`). The design needs an explicit server seam: ensure the field, snapshot `damage`, then construct the overlay before any body can activate.

8. **The replay count is nine, not eight.** The project contract enumerates all nine (`AGENTS.md:377-401`), and the replay test recursively checks every committed `.bitreplay` (`tests/test_replay.nim:29-53`). Section 2.7 must say GameVersion bump, all nine fixtures, and viewer rebuild.

9. **`BodyHazardOverlay` is not immutable as specified.** Its arrival projection and segment extrema are immutable, but `safeDistPx`/`safeNext` are recomputed on every bucket roll. Make that a separate episode-shared mutable `BodySafeCache` keyed by `(hazard fingerprint, horizon bucket)`. Otherwise the ownership and lifecycle claims contradict the data model.

## 2. Simplifications

- **One legality implementation.** Move/export the exact short-segment predicate and one canonical neighbor order from `body_map`; today `Neighbors` is duplicated (`src/shell/body_map.nim:24-27`, `src/shell/body_planner.nim:20-22`) and `segmentClear` is private to the planner (`src/shell/body_planner.nim:298-329`). Build `legalMoves`, local search, smoothing, and steering from that one oracle.

- **Assert room coverage before adding repair machinery.** The measured `cellsNoRoom` count is zero (`cell_probe.tsv:3-10`). Build from the existing one-based room raster, assert every chosen anchor has a room, and add a deterministic repair only if a committed corpus case proves it is needed.

- **Do not store `portalArrival`.** It is a direct lookup in the immutable projected array. Keep per-segment min/max only if profiling proves they avoid enough cell scans.

- **Do not put the bucket in semantic target identity.** Use `(target class, resolved source cell)`. The bucket is cache provenance, not intent identity; including it forces a replan every 48 ticks even when the target is unchanged.

- **Remove prefix truncation.** It adds a second query/install lifecycle for a case the draft says cannot occur. Prefer streaming the selected portal sequence one segment at a time, or measure a supported-map maximum and size/assert the fixed buffer from that result. Never silently accept a prefix as a route.

- **Resolve `zone_safe_ground` before the arrived test.** `seatTick` currently checks arrival against the literal `standingGoal` before it asks nav for a waypoint (`src/shell/body.nim:1312-1322`). Class resolution must produce the effective validated goal first; otherwise being near the fallback can suppress movement toward the class target.

## 3. Missing risks and mitigations

- **One portal cell may not connect both rooms.** Chokes are contacts in a one-pixel watershed raster, but the chosen 8 px cell belongs to only one room. Store and validate a deterministic anchor on each side plus the legal crossing edge. Activation must assert that every portal edge reaches both incident rooms and that the abstract graph preserves each represented pixel component.

- **The 8 px graph already loses topology.** On `pool:0`, one pixel component becomes two legal 8 px components; sampled maps also have 442-3,946 standable coarse cells whose centers are not standable (`cell_probe.tsv:3-10`). A single “best anchor” may still choose incompatible anchors in adjacent cells. Mitigation: one-byte anchored cells as the first tier, followed by a sparse 4 px micro-corridor graph only where component/endpoint coverage fails. Activation should compare pixel components, anchored graph components, spawns, portals, and the goal corpus; a missing route is a gate failure, never an excluded sample.

- **A single static shortest segment cannot preserve dynamic weighted cost.** Pricing the one stored path does not let the query choose a different intra-room path around current danger, paint, or the blocked cell. The same-room straight-line fast path ignores all three weights. This is the largest 3%/10% risk. Mitigation: make the straight route merely a candidate, retain alternate abstract edges where topology permits, and use bounded weighted room-local refinement at the two endpoint rooms and any ambiguous/high-penalty segment. Compare against an offline full-resolution weighted A* using the exact same cost units.

- **Hazard is missing from attachments.** Step 3 prices start/goal chains for danger and blockage only, although those chains can cross paint. Hazard is also directional because ETA changes along traversal; the reversed goal chain cannot reuse a directionless total. Score every traversed cell in route order after the portal sequence is known, including exact endpoint connectors.

- **Exact goals can be lost at cell anchoring.** `ValidatedGoal` proves a standable pixel in the requester's component (`src/shell/body_map.nim:397-416`), and the current planner appends that exact pixel to the path (`src/shell/body_planner.nim:666-676`). The new route must prove a legal connector from the final anchor to `goal.goalPoint` and end at that exact point. “Nearest walkable cell” is not an equivalent goal.

- **Cost arithmetic is underspecified and float-sensitive.** `uint16` “pixels” cannot exactly encode both 8 and `8*sqrt(2)`; using diagonal cost 11 makes Euclidean A* inadmissible, while float32 segment sums can change tie outcomes. Define integer fixed-point edge units, an admissible heuristic in those units, saturation behavior, cost-term scaling, and stable tuple tie-breaks. Use the same arithmetic in the offline oracle and route-inflation report.

- **Safe-ground coverage is incomplete.** Dry portals plus a radius-six local scan can report unreachable even when dry ground exists deeper in the same room, and “<= 6 cells” is ambiguous between six candidates and a six-cell radius. Add at least one threshold-safe room target/source when a room contains dry cells, prove the chosen source satisfies the seed predicate, and retain the literal fallback on any unresolved or invalid target.

- **Wrong clock/gate will silently corrupt zone decisions.** Zone damage compares the field against elapsed schedule time, not absolute sim tick (`src/ctf/zone_field.nim:1762-1769`). Store the episode's zone-clock origin at installation and use elapsed ticks for hazard risk, safe buckets, and hints. An absent field must be a typed dark state, not “never arrives.” Gate on `season2Shell && zoneDamageByPaint && zonePhases.len > 0` and snapshot the field fingerprint with the cache key.

- **Latency estimates exclude the hard cases.** The new synchronous query runs inside `seatTick`, unlike current planning/danger work, which runs after all seat ticks (`src/shell/episode.nim:1213-1244`). Test inclusive FirstLight wall time, not only `result.bodyNanoseconds`: 16/32-seat simultaneous first goals, all moving-goal replans, bucket rollover, danger-generation rollover, stuck replans, and worst-degree rooms. Enforce p95 <= 4 ms and max <= 5 ms on linux/amd64 release.

- **Activation and memory are estimates on the wrong target.** The 100-250 ms / 0.5-1.2 s build claims are not measurements. Benchmark the actual build on linux/amd64 release, including legal-edge construction, portal repair, all fields, segment extraction, and hazard projection. Record peak transient RSS separately from retained bytes and enforce <=2x pool / <=3x colossal against the same-run `BodyMap` baseline.

- **Lifecycle clearing needs to reach scheduler ownership.** Today `setSeatActive` only flips a bool (`src/shell/body_nav.nim:305-306`); danger rebuild skips inactive seats (`src/shell/body_nav.nim:473-485`), but plan/mint scheduling does not check `active` (`src/shell/body_nav.nim:562-618`). On death, clear/cancel every route/query/cache item before setting inactive, and assert no inactive seat is queried or scheduled. On hold->navigate, reset stale progress counters without treating epoch/provenance as a route change. `setStandingIntent` currently cancels every pending plan (`src/shell/body.nim:565-590`); replacing that side effect is correct, but “record the goal pin” must also be removed because 2.6 deletes pins and route-field slots.

- **The cost gate needs a precise denominator.** Define the oracle route, proposed route, weighted-cost formula, missing-route handling, and executed-path legality before benchmarking. Report every required roster x profile x dynamic-state x near/far stratum separately; do not hide an empty or failed stratum in the overall percentile.

## 4. Open questions A-F

**A — Use bounded weighted room-local A*, but not only after an illegal straight line.** A legal straight line can still be much worse under danger/hazard. Treat it as one candidate, run a shared generation-stamped room-local search with a measured cap, and compare its result with portal candidates. `4,096` is a placeholder until max room cells and expansion tails are measured. If the cap is hit, portal fallback is legal, but the sample must still count against the 10% max gate.

**B — Do not accept option 1; option 2 alone is not a connectivity proof.** Use a packed subcell anchor plus explicit legal edges, then add sparse 4 px nodes only for disconnected narrow corridors/endpoints. The probe already proves center-only 8 px is incomplete (`cell_probe.tsv:3-10`). A full 4 px index misses the memory gate; adaptive fine nodes preserve the exception without paying 4x everywhere.

**C — Score exact attachment chains.** Goal changes are cold relative to following, and the 3% gate leaves little room for a start-sample approximation. Include danger, blockage, and directional hazard. First measure max, not average, total cells across all start/goal portal chains in the census corpus.

**D — Prefer lazy, generation-stamped segment-cost memoization.** Eager refresh touches every segment every 32 ticks even when no route query consumes it; on colossal that is at least 13,730 segments per active seat per generation, with an unmeasured cell total. Lazy evaluation touches only edges the portal search actually considers and amortizes repeated queries within a danger generation. Count sampled cells and include worst-case cold-cache bursts in the 5 ms gate; if that fails, the index needs fewer candidate edges, not an unbounded playing-tick sweep.

**E — Smooth at follow time with K=6 initially.** The follower must react to its actual, possibly off-polyline position. Check the exact pixel `segmentClear(self, candidate)`; walking `legalMoves` along a Bresenham cell sequence proves a staircase, not necessarily the straight movement chord. Measure the executed masks/path in the cost corpus, so follow-time smoothing is represented in the inflation result. Tune K only from that result.

**F — Simplify ownership, not the route-quality logic.** Canonicalize legality; separate immutable hazard data from mutable safe-cache state; remove `portalArrival`, speculative no-room repair, bucket-based semantic identity, and truncated prefixes. Keep exact dynamic scoring and bounded endpoint-room search because those are required by the cost gate, not optional sophistication.

## 5. Overall mechanism

I do not recommend a different overall family: the non-negotiables already select a room/portal HPA-style index, and the census supports a small abstract search (369 portals / 4,374 pairs on the largest giant pool sample; 1,237 / 13,730 on colossal: `nav_census.tsv:3`, `nav_census.tsv:26`). The simpler credible version is the corrected draft: anchored legal coarse graph plus sparse narrow-corridor nodes; two-sided portals; portal fields; bounded weighted endpoint-room refinement; a portal A*; and a follower that streams the chosen segments. It should not add another global routing mechanism. The design is ready for implementation planning only after the damage-surface seam, fixed-point cost model, topology/endpoint invariants, actual segment-byte census, and executable cost/latency gates are written down.
