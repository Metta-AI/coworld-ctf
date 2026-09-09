# Spatial knowledge for Season 2 plays

**Status:** PROPOSED, awaiting James's ratification

**Date:** 2026-09-08

**Scope:** design and measurements only; no engine behavior changes
**Evidence checkout:** `f374a18b2cffa6b1106c5ac3d81fd248018f378d`

All repository `path:line` citations in this document refer to that evidence
commit. The measurements are from an Apple M4 Pro, arm64 macOS 15.5, Nim 2.2.6,
wasi-sdk 33 (`clang 22.1.0`) and Wasmtime 48.0.1. The research report (`docs/reports/s2-cog-body-tick-2026-09-03.md`)
supplied by James was read for its sections 4.3–4.4, 7, and Appendix C; it is
background, not a committed source.

## Recommendation

Adopt one small hybrid surface:

1. Give every play a public, episode-static **32 px advisory walkability
   bitmap** in binary `PlayContext`, retained in raw form and indexed on demand.
   Keep `MaxBinaryContextBytes` at 8,192.
2. Add five bounded host queries: `room_of`, `line_of_sight`, `danger_at`,
   `route_distance`, and `nearest_choke`. Cheap reads get a new shared cap of
   eight per step. Rays and route distance share the existing heavy cap of two
   with `nearest_reachable` and `nearest_cover`.
3. Extend the nav rework's existing `target_class` field; do not create another
   goal mechanism. Add `room`, `choke`, `cover_facing`, and `flee_from` values,
   while keeping the literal point mandatory as the deterministic fallback.
4. Give the slower JSON `PlayContext` the compact room/choke graph so an LLM can
   name stable region IDs. Add `self.room` and `world.nearest_choke_dist` to
   guards. Do not put that graph or the cover atlas in guest binary context.

This is intentionally asymmetric. The policy gets rich static topology once;
the tick-rate guest gets a small orientation map plus bounded exact questions;
the engine remains the only navigation authority.

## 1. Concrete failures reproduced on pool maps

`tools/spatial_surface_census.nim --cases` repeats the reference plays' point
arithmetic, calls `BodyMap.validateGoal`, and gets route length from the real
route-field minter and `peekRouteDistance`, not Euclidean estimates
(`src/shell/body_map.nim:397-416`; `src/shell/body_cache.nim:193-208`).

| Play/family | Named map and coordinates | What the current play does | Terrain-aware answer |
|---|---|---|---|
| `edge_ride` | `br-gen-505`; self `(196,20)`, 220 px margin point `(196,240)`, snapped `(196,245)` | The point is behind a wall. Straight distance is 220 px; the route is 285.25 px. | Score reachable points on the same margin band by route cost. |
| `supply_run`; also `loot` and the starter item gate | `br-gen-5040`; self `(468,1108)` | Chooses medkit `(553,1435)` because 337.87 px is less than 338.11 px. It is behind a wall and routes 475.65 px. | Choose `(164,1256)`: line-clear and 366.96 route px, 108.69 px shorter. |
| `jackal`; same projection flaw affects `bodyguard` | `br-gen-505`; self `(140,440)`, enemy `(86,1195)` | The 500 px Manhattan-normalized loiter projection is `(119,729)`, inside wall; validation moves it 56 px to `(63,729)` without preserving the tactical relation. Route: 332.45 px. | Resolve a room/choke or `cover_facing` goal with the route and cover seams. |
| `scatter`; same blind-point family affects `crossfire` | `br-gen-505`; self `(1149,504)`, enemy `(870,1017)` | The 320 px flee point `(1301,223)` enters a leaf room with one choke. A 319.48 px displacement becomes a 596.45 px route. | `flee_from` scores only current/adjacent room peaks and rejects a leaf-room regression. |

`pact` and `target_law` are targeting overlays and emit no destination, so
there is no terrain-wrong point to reproduce. The starter harness also computes
item, partner, and enemy distances as straight-line values
(`policies/starters/common/starter_harness.py:580-640`); the medkit case shows
why those values may open the wrong ladder rung.

These failures sit above route following. `nearest_reachable` can move a point
out of wall, but it cannot recover the tactical meaning of “near the margin,”
“short detour,” “loiter,” or “flee.” The Season 2 mechanics inventory reaches
the same boundary for zone movement, loot, ground items, handoff, and spawn
seeding (`docs/designs/s2-mechanics-that-move-the-destination.md`, PR #419,
unmerged at the time of writing).

## 2. What the engine already knows

The engine already builds one immutable `BodyMap` from the real `CtfMap` and
exposes room labels, rooms, chokes, pixel rays, and the cover atlas
(`src/shell/body_map.nim:41-70,115-207,755-915`). Per seat it owns a four-slot
route cache and a fog-derived danger field (`src/shell/types.nim:441`;
`src/shell/body_planner.nim:28-31,134-138`). `setStandingIntent` is the body
installation seam (`src/shell/body.nim:571-596`). No new engine hook is needed
to measure or later implement the proposed surface.

The guest does not receive this. Binary context currently has only section IDs
101–103 and the SDK decodes only section 102
(`src/shell/binary_view.nim:47-66,558-572`;
`play_sdk/play.nim:1122-1145`). The current SDK allocation arena is 32 KiB and
must hold parameters and context in the same init batch
(`play_sdk/play.nim:7-9,368-425`). That is a tighter practical bound than the
64 KiB JSON cap.

## 3. Static context measurements

The census reads all 64 ledger entries through `loadBrS2PoolRaw` rather than a
hand list (`src/ctf/br_map_pool.nim:117-124`; `tests/test_br_s2_map_pool.nim`).
The supported two-team colossal case is generated with seed 4242 and
`MapGenOverrides(size: "colossal")`; it is 6422×3427. Each map is passed through
`newBodyMap(CtfMap)`.

The candidate binary graph uses packed little-endian records: 20 bytes per room,
16 per choke, and 2 per room-to-choke index, plus three 12-byte section entries.
The compact JSON graph uses arrays rather than repeated property names. Bitmap
sizes include their 12-byte section entry. A coarse bit is set if **any 8 px
body-nav cell** in that coarse cell is walkable. This is advisory orientation,
never proof that a path or exact pixel is valid.

| Added static data | 64-map S2 pool min / median / max | Colossal | Decision |
|---|---:|---:|---|
| Room/choke binary graph | 936 / 1,516 / 2,476 B | 30,816 B | Reject from binary context: scale-dependent and over 8 KiB. |
| Compact JSON graph object | 1,097 / 1,830 / 3,043 B | 44,506 B | Accept in JSON context; still below 65,536 B. |
| 64 px bitmap | 98 B | 694 B | Too coarse to distinguish common corridors. |
| **32 px bitmap** | **350 B** | **2,726 B** | Accept; bounded on every measured shape. |
| 16 px bitmap | 1,361 B | 10,816 B | Reject: colossal exceeds the current cap. |
| 8 px bitmap | 5,408 B | 43,073 B | Reject: colossal and init allocation do not fit. |
| Cover posts (position + 16 reaches) | 59,332 / 68,012 / 77,932 B | 627,172 B | Reject; query-dependent ranking and area scaling remain decisive. |

Pool topology ranged from 13–33 rooms and 31–92 chokes. Colossal had 302 rooms,
1,237 chokes, and 15,679 thinned cover posts. Full per-map rows are emitted by
the tool. To test the actual JSON cap, the tool also builds today's canonical
context with 32 maximum-length (64-byte) roster names, then adds the graph. The
pool total is 4,990 / 5,723 / 6,936 B min / median / max; colossal is 48,409 B,
leaving 17,127 B below `MaxContextBytes`.

### 3.1 Fuel: decode versus retain raw

The test-only `context_meter.nim` was compiled twice from the same source. Full
decode materializes typed room/choke records or expands bitmap bits to booleans.
Raw mode copies the frame into persistent guest memory, retains section offsets,
and indexes one record or bit in `play_step`.

| Candidate frame | Bytes | Full typed init | Retain-raw init | One later lookup, full / raw |
|---|---:|---:|---:|---:|
| Largest pool graph, `br-gen-23712` | 2,508 | 86,133 fuel | 26,193 fuel | 167 / 515 fuel |
| Colossal graph | 30,848 | **traps at 500,000** | 309,593 fuel | n/a / 515 fuel |
| Pool 32 px bitmap | 384 | 103,228 fuel | **4,335 fuel** | 85 / **118 fuel** |
| Colossal 32 px bitmap | 2,760 | **traps at 500,000** | **28,095 fuel** | n/a / **118 fuel** |

The standalone frames include the 32-byte frame header, hence the 32-byte
difference from “added bytes” above. Full bitmap expansion is especially poor:
fuel follows output cells, not compressed input bytes. Raw retention keeps the
recommended colossal frame at 5.6% of `InitFuel` and its lookup at 0.24% of
`StepFuel` (`src/shell/types.nim:400-405`). Therefore the SDK should expose a
raw bitmap view, not a decoded boolean array. `MaxBinaryContextBytes` remains
8,192; raising it buys no recommended data and weakens allocation hygiene.

## 4. Host-query measurements and quota

Release measurements ran 10,000 calls per row on giant pool map `br-gen-505`
(3211×1713, 27 rooms, 95 chokes). Random arguments cover the full map. The
max-length ray cases are known-clear segments `(140,440)`–`(140,109)` and
`(1399,113)`–`(1399,1137)`, so they force every pixel sample. Times measure the
engine-side operation; Wasmtime crossing cost is not included.

| Candidate | Random p50 / p95 | Adversarial p50 / p95 | Recommendation |
|---|---:|---:|---|
| `room_of` | 0.042 / 0.125 µs | 0 / 0.042 µs | Add, light. |
| `line_of_sight`, 331 px | 0.792 / 1.583 µs | 1.167 / 1.250 µs | Add, heavy. |
| `line_of_sight`, 1024 px | 0.792 / 3.666 µs | 3.666 / 3.791 µs | Add with 1024 px hard cap, heavy. |
| `danger_at` | 0 / 0.083 µs | 0 / 0.042 µs | Add, light and fog-derived. |
| current `route_distance`, arbitrary goal | 0 / 0.042 µs | 100% miss | Do not expose today's cache as if it were an oracle. |
| current `route_distance`, four warm goals | 0.083 / 0.333 µs | — | Add only with nav rework's bounded route index, heavy. |
| `nearest_choke`, linear over 95 | 0.250 / 0.334 µs | 0.209 / 0.250 µs | Add, light; implement on the shared index when available. |

The approved navigation rework's portal probe is not on this commit. The
`route_distance` contract therefore has a **landing gate**, not a fabricated
number: the shared index implementation must measure at or below 13.3 µs p95,
the already-budgeted `nearest_cover` ceiling. Until then the import is absent,
and `target_class` resolution uses the literal fallback on today's planner.

With 32 seats × 3 guest steps, a light cap of eight and the measured worst
light p95 (0.334 µs) costs 256.5 µs. The heavy cap is already two; its existing
worst case remains 192 × 13.3 µs = 2,553.6 µs. Together they are 2,810.1 µs,
70.3% of the 4 ms runtime share. Rays and route queries replace heavy calls;
they do not add another cap.

## 5. Normative ABI delta

This section is the contract proposed for a later implementation. Nothing here
is implemented by this design task.

### 5.1 Imports

All imports remain in module `play`, legal only during `play_step`. IDs are
one-based; zero means “no room/choke.” Negative results keep the existing
spatial convention: −1 no answer, −2 quota, −3 invalid scalar/domain.

| Import | Signature | Return and work |
|---|---|---|
| `room_of` | `(x: i32, y: i32) -> i32` | One-based watershed room ID, or 0 for standable terrain with no room label. O(1), light. |
| `line_of_sight` | `(ax: i32, ay: i32, bx: i32, by: i32) -> i32` | 1 clear, 0 wall-blocked. Euclidean endpoint distance must be ≤ `MaxSpatialRayPx = 1024`. Pixel ray, heavy. |
| `danger_at` | `(x: i32, y: i32) -> i32` | Seat danger value rounded to millionths; reads only that seat's current fog-derived field. O(1), light. |
| `route_distance` | `(ax: i32, ay: i32, bx: i32, by: i32) -> i32` | Topology/public-zone route length rounded up in pixels; −1 if no path. Shared nav index only, heavy, gated at ≤13.3 µs p95. |
| `nearest_choke` | `(x: i32, y: i32) -> i32` | One-based nearest choke ID, squared-distance then ID tie-break; 0 if the map has none. Light. |

Validation order is fixed: (1) call outside `play_step` faults; (2) increment
and test the relevant shared quota, returning −2 before further work; (3)
validate every coordinate in map and the ray length, returning −3; (4) perform
the bounded operation. There are no guest pointers. Integer differences and
squares use 64-bit intermediates.

`room_of`, `danger_at`, and `nearest_choke` share new
`MaxSpatialReadsPerStep = 8`. `line_of_sight` and `route_distance` join
`nearest_reachable` and `nearest_cover` under the unchanged
`MaxSpatialCallsPerStep = 2` (`src/shell/abi.nim:78-123`;
`src/shell/types.nim:418-425`). The module allowlist remains exact and merely
adds signatures (`src/shell/module_interface.nim:86-93,195-204`).

### 5.2 Binary and JSON context

Add binary section `BvContextWalkable32 = 104`. It has stride 1 and count equal
to the payload byte count. Bits are row-major coarse cells, least-significant
bit first; unused final bits are zero. Grid width and height are
`ceil(mapWidth/32)` and `ceil(mapHeight/32)` from section 103. It is present
exactly once in every valid play context. Readers that do not know 104 skip it.

Add JSON object `terrain` with:

- `rooms`: array order defines room IDs 1..N. Each row is
  `[peak_x, peak_y, peak_clearance, area, component, choke_ids]`.
- `chokes`: array order defines choke IDs 1..N. Each row is
  `[x, y, clearance, room_a, room_b]`.

The compact-array shape is the measured 1.1–3.0 KiB / 44.5 KiB representation.
It is static and untrimmed; context construction fails if the complete payload
exceeds `MaxContextBytes`, as it does today (`src/shell/view.nim:1097-1110`).

### 5.3 Intent `target_class`

Add optional string `target_class` to `navigate_to`; omit it on `hold`. The
literal `point` remains required. These are the exact values:

| Value | Resolver | Determinism key | Failure/fallback |
|---|---|---|---|
| `zone_safe_ground` | Existing nav-rework resolver. | Existing class + public zone overlay version/time bucket + source. | Literal point. |
| `room:<id>` | Peak of one-based room ID, then ordinary goal validation. | class + ID + map fingerprint. | Literal point if ID/peak is invalid. |
| `choke:<id>` | Position of one-based choke ID, then validation. | class + ID + map fingerprint. | Literal point. |
| `cover_facing:<brads>` | Cover scorer anchored at the literal point, bearing 0..255, using the cover-hold-owned destination contract. | class + bearing + literal point + map fingerprint + accepted belief epoch. | Literal point if no cover answer. |
| `flee_from:[x,y]` | Current and adjacent room peaks only; discard candidates that reduce route distance from `[x,y]`, then maximize route distance with room ID tie-break. | class + explicit point + source room + map fingerprint + public-zone bucket. | Literal point if no improving candidate. |

Parsing and scalar/domain checks belong in emit validation. Resolution belongs
at body installation, where the nav index, seat danger/cover state, and standing
goal live (`src/shell/emit_validator.nim:315-340,371-410`;
`src/shell/body.nim:571-596`). A resolver failure does not reject an otherwise
valid emission: the literal point is validated and accepted, so old behavior is
the explicit fallback. Re-resolution occurs only when the determinism key
changes; identical keys cannot churn a route.

The navigation task owns the route oracle. The cover-hold task owns cover
destination choice. This design only names their seams and does not redesign
either.

### 5.4 Budget rows

| Budget | Proposed value |
|---|---:|
| `MaxBinaryContextBytes` | **8,192, unchanged** |
| `MaxSpatialReadsPerStep` | **8**, shared across three light reads |
| `MaxSpatialCallsPerStep` | **2, unchanged**, now also rays and route distance |
| `MaxSpatialRayPx` | **1,024** |
| `route_distance` acceptance | **≤13.3 µs p95** on the shared-index benchmark before import landing |

## 6. Fog and provenance

| Surface | Provenance | Fog rule |
|---|---|---|
| 32 px bitmap; JSON rooms/chokes | Immutable map geometry | Public and unfogged. |
| `room_of`, `line_of_sight`, `nearest_choke` | Immutable map geometry | Public; no entity input or output. |
| `danger_at` | This seat's visible tracks after team/no-shoot/protect filtering | Fogged; never accepts a seat reference. |
| `route_distance` | Static topology plus public zone overlay | Public; excludes hidden entities and private enemy danger. |
| `room` / `choke` goal | Static map | Public. |
| `cover_facing` | Static atlas plus this seat's accepted belief | Fogged to the caller; no foreign-seat selector. |
| `flee_from` | Explicit coordinate already supplied by the play plus static/public route data | Cannot look up the entity that may have produced the coordinate. |
| `self.room` guard | Self position + static room label | Fog-legal. |
| `world.nearest_choke_dist` guard | Self position + static chokes | Fog-legal. |

No query takes a seat, team, or entity reference. Static facts reveal terrain,
not occupancy. This preserves the current rule that plays see only their own
fogged body state while public zone geometry remains public.

## 7. LLM and guard surface

**JSON graph: yes.** The measured compact graph object is at most 44,506 bytes
on colossal. More importantly, the complete canonical context plus that graph
is 48,409 B even with 32 maximum-length roster names, leaving 17,127 B under
the 65,536-byte cap. It lets the policy put stable room/choke IDs into play
parameters without asking a tick-rate guest to decode the graph. `ParamSpec`
needs no new kind: IDs and `target_class` remain ordinary bounded number/string
parameters (Appendix P.1 of the living design).

**Guards: yes, two paths only.** Add numeric `self.room` (0 outside a labeled
room) and `world.nearest_choke_dist` (pixels, −1 if no choke). Their measured
engine costs are 0.125 µs and 0.334 µs p95. Evaluated once for each live seat,
the pair costs at most about 14.7 µs for 32 seats, before ordinary expression
evaluation. Do not add a general terrain expression language.

## 8. Compatibility and determinism

- ABI version stays 1. New imports are allowlisted additions; old modules do
  not import them. Section 104 is skipped by old readers. JSON context already
  allows added properties.
- The strict Intent schema must add `target_class`, canonical encoding, parse,
  and byte goldens together. Old plays omit it and remain byte-for-byte valid
  (`src/shell/types.nim:80-118`; `src/shell/emit_validator.nim:315-340`).
- No `GameVersion` bump: direct-input simulation behavior does not change.
  Once implemented, semantic goals may change live play-seat masks; replays
  still record masks and never re-execute plays.
- Add shell goldens for section 104, unknown-section skipping, all import return
  codes/order/quota boundaries, target classes and literal fallback, JSON graph
  maximum, and fog provenance. Do not recut existing replay fixtures merely for
  this additive play-seat surface.
- Any later `src/*.nim` implementation rebuilds the viewer under the repository
  rule. This design-only change has no `src/` edit and no viewer rebuild.
- Context room/choke IDs derive from deterministic `BodyMap` order and are
  scoped by map fingerprint. They are not stable across different geometry.

## 9. Migration plan

| Consumer | Proposed migration |
|---|---|
| `edge_ride` | Use bitmap to reject obviously mixed bands, `line_of_sight` for exact candidates, then route-aware `room`/`choke` goal. |
| `supply_run` | Compare eligible medkits with `route_distance`; keep current Euclidean order only when the shared index reports no answer. |
| `loot` | Same as `supply_run` for every eligible item. |
| `jackal` | Replace blind loiter projection with `cover_facing` or an LLM-supplied room/choke class. |
| `scatter` | Emit `flee_from:[x,y]`; the bounded resolver avoids leaf-room regressions. |
| `bodyguard` | Check projected leash/interpose points with ray and route distance; use `cover_facing` without redefining cover selection. |
| `crossfire` | Compare the two perpendicular candidates by ray and route distance before choosing the angle. |
| `pact`, `target_law` | No movement change; rebuild only to consume a shared SDK version if desired. |
| `play_sdk/play.nim` | Add imports/results, raw section-104 view, target-class builders, and document persistent-copy lifetime. Do not expose a decoded bitmap array. |
| `play_sdk/README.md` | Document query quotas/errors, bitmap bit order, raw retention fuel, and semantic fallback. |
| `policies/starters/common/plays.py` and prompts | Describe terrain-aware play parameters and replace straight-distance gate claims with route-aware wording when the imports land. |

Today's planner can support the bitmap, map-only queries, `room`, `choke`, and
`cover_facing`. Useful arbitrary `route_distance` and bounded `flee_from`
require the approved shared route index; before that dependency lands, their
literal fallback preserves behavior.

## 10. Decision record

These are proposals. The living design remains authoritative until ratified.

1. **§5 “context carries no navigation raster”
   (`docs/designs/strategy-play-calling-shell-2026-08-29.md:1216-1231`) — supersede
   narrowly.** Add one advisory 32 px bitmap because it costs only 350 B on the
   64-map pool and 2,726 B on colossal. Exact validation remains engine-side.
2. **§5 “atlas deliberately not in context”
   (`docs/designs/strategy-play-calling-shell-2026-08-29.md:1293-1302`) — reaffirm, not
   supersede.** Measured cover payloads are 59–78 KiB on the pool and 627 KiB
   colossal, and ranking remains query-dependent.
3. **§6.1 “four imports” and its import table
   (`docs/designs/strategy-play-calling-shell-2026-08-29.md:1522-1526,1562-1572`) —
   supersede.** Add five exact allowlist entries while retaining ABI 1 because
   modules opt into imports.
4. **§6.1 symmetric 8 KiB context cap rationale
   (`docs/designs/strategy-play-calling-shell-2026-08-29.md:1762-1765`) — replace the
   rationale, keep the value.** Measurement now derives the cap decision: the
   chosen bitmap fits, while scalable graph/atlas payloads do not.
5. **Task citation H.3 — citation drift.** The buffer-versus-getter ruling is
   now in H.4 (`docs/designs/strategy-play-calling-shell-2026-08-29.md:3536-3539`); current
   H.3 records superseded architectures.
   Narrow that ruling: bulk view and static bitmap stay buffer-shaped, while
   bounded derived spatial operations are host calls. This follows the already
   ratified `nearest_reachable`/`nearest_cover` precedent rather than creating
   getter-per-view-field ABI.

## 11. Proposed implementation split

Each task belongs to exactly one Layer.

1. **Shell & Plays — static context and light queries.** Add section 104, JSON
   graph, `room_of`, `line_of_sight`, `danger_at`, `nearest_choke`, guards,
   SDK bindings, schemas, and goldens. Depends on neither route nor cover work.
2. **Shell & Plays — semantic goals and route distance.** Extend the nav
   rework's `target_class`, add the shared-index `route_distance`, and implement
   bounded `flee_from`. Depends on navigation task `1218165906459726`; the
   `cover_facing` arm also depends on cover task `1218165969208626` and must use
   its destination contract.
3. **Bots & Policies — migrate controllers and starters.** Update the seven
   movement reference plays and starter gates/prompts after tasks 1–2. The two
   targeting overlays require no destination change.
4. **Docs & Comms — publish the ratified contract.** Replace stale living-design
   rulings, update SDK/reference docs, and file the implementation evidence only
   after James ratifies this proposal.

## 12. Open question for ratification

Does James ratify the minimal hybrid above: 32 px raw bitmap, compact JSON graph,
five bounded queries, and region goals on `target_class`, while keeping the
binary context cap at 8 KiB and the cover atlas engine-side?

## Reproduce the evidence

```sh
nim c -d:release -o:/tmp/spatial_surface_census tools/spatial_surface_census.nim
/tmp/spatial_surface_census --all-pool-maps

WASI_SDK_PATH=/path/to/wasi-sdk nim c -f -d:contextFullDecode play_sdk/test_fixtures/context_meter.nim
WASI_SDK_PATH=/path/to/wasi-sdk nim c -f play_sdk/test_fixtures/context_meter.nim

WASMTIME_C_API=/path/to/wasmtime-c-api \
  C_INCLUDE_PATH=/path/to/wasmtime-c-api/include \
  LIBRARY_PATH=/path/to/wasmtime-c-api/lib \
  DYLD_LIBRARY_PATH=/path/to/wasmtime-c-api/lib \
  nim c -d:release -d:spatialFuel --threads:on -d:noSignalHandler \
  -o:/tmp/spatial_surface_fuel tools/spatial_surface_census.nim
DYLD_LIBRARY_PATH=/path/to/wasmtime-c-api/lib \
  /tmp/spatial_surface_fuel --fuel \
  play_sdk/.build/context_meter_full.wasm \
  play_sdk/.build/context_meter_raw.wasm
```
