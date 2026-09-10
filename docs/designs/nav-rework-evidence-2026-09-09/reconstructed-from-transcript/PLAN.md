    6214 /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/PLAN.md
# Implementation plan: precomputed shared cog navigation

Status: Phase 0 only. No implementation has started. This plan targets the
worktree `/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework`
and no other checkout.

## 0. Fixed inputs, base, and drift

- I fetched/pruned `origin` before planning. The worktree was clean but three
  commits behind, so I fast-forwarded `james/s2-nav-rework` from `429f4831` to
  current `origin/main` at `52103b107832e12f30a719dd299bc7636c3dd12f`.
  It is now `0 ahead / 0 behind`.
- The approved design was written against `fad3029f`. I diffed
  `fad3029f..52103b10` across `src/shell` and `src/ctf` and re-read each live
  seam this plan uses.
- Drift that changes insertion points, but not the approved mechanism:
  - `body.nim` now separates belief folding from actuation. Production calls
    `updateBelief` before the ladder and `actFromBelief(body, tick)` afterward.
    Navigation integration therefore belongs in `actFromBelief`, not in the
    old monolithic `seatTick` citation.
  - `BodyTickInputs` now includes fog-safe kill, aggressor, shout, grenade,
    blast, and spray observations. The danger-source contract remains the
    existing fog-filtered `DangerInput`; route scoring must not read the new
    observations directly or change fog/combat policy.
  - `episode.step` lazily builds guest views and `server.nim` now builds one
    immutable observation frame per tick. The body-slice timer must enclose
    only navigation/body work, not guest view creation or runtime work.
  - Upload admission now closes at `Playing`, and reconnect recovery now
    returns the accepted call and ready playbook. Navigation must not alter
    those lifecycles or signatures.
  - `Intent` has since gained the neutral `drop` field. All new canonical,
    schema, binary-view, and SDK work will preserve `drop` and its key order.
  - `.github/workflows/build.yml` now already contains the GameVersion
    tripwire that the older `AGENTS.md` prose called pending. Phase 10 will run
    it; it will not add a duplicate workflow step.
- The measured probes cover the legacy 20-entry `map_pool.nim` pool plus one
  generated colossal map. The actual published Season 2 gate corpus is the
  64 full specs in `data/br_s2_map_pool.json`. Probe numbers are sizing
  evidence only; phases 1, 2, and 9 will enumerate the 64 published specs.
- The hidden approved Markdown brief and HTML live in the protected main
  checkout and are read-only ground truth. Implementation documentation will
  update the tracked worktree files named below; it will not edit or copy files
  into the main checkout.

## 1. Phase map and dependency order

I will use eleven implementation phases, one per Asana subtask. Keeping 04 and
05 separate makes the immutable hazard ownership, public hints, and wire change
independently reviewable. Keeping 08 and 09 separate prevents regression breadth
from being confused with canonical performance qualification.

| Phase | Subtask | Dependency satisfied by | Checkpoint commit(s) |
|---|---|---|---|
| 1 | 01 freeze corpus; red liveness/no-live-search tests | Phase 0 plan approval | corpus/oracle; red tests |
| 2 | 02 immutable shared `BodyRouteIndex` | 1 | legality oracle; index + activation proof |
| 3 | 03 bounded hierarchical route query | 2 | query core + focused route tests |
| 4 | 04 danger scoring + immutable hazard overlay | 3 | danger memo; overlay/safe-cache split |
| 5 | 05 safety hints + zone-safe semantic source | 3, 4 | hint resolution; JSON/binary/SDK surface |
| 6 | 06 stable literal/semantic goal coalescing | 1 (implemented after 5 for less temporary code) | Intent contract; anchor lifecycle |
| 7 | 07 local steering + complete per-life reset | 3–6 | follower/steering integration; lifecycle |
| 8 | 08 route/hazard/wire/lifecycle/diagnostic regressions | 7 | regression matrix + shard wiring |
| 9 | 09 all-map quality/activation/memory/tick gates | 8 | harness; evidence-only gate commit if needed |
| 10 | 10 delete live full-grid planning; gameplay/wire version | 9 green | cutover/deletion/version/fixtures/viewer |
| 11 | 11 final server/shell/replay/viewer/docs verification | 10 | only fixes required by final verification |

Before every commit I will fetch, confirm the worktree path/branch/status, merge
`origin/main` if behind without discarding user changes, and use the required
`audit-documentation` skill. I will not push, open a PR, merge, label, approve,
edit Asana, or post externally.

Phase reports and the running decision ledger will be written under this
scratch directory. Implementation commits will touch only the nav-rework
worktree.

## 2. Phase-by-phase implementation

### Phase 1 — subtask 01: literal corpus and red tests

Files:

- Add `tests/fixtures/shell/nav_route_corpus.json`.
- Add `tests/nav_route_corpus_support.nim`, containing the checked-in corpus
  parser, the independent 4 px float oracle, deterministic resampling, and
  stratum aggregation.
- Add `tools/build_nav_route_corpus.nim`, an explicit writer used only to
  refresh the literal manifest; ordinary tests never rewrite it.
- Add `tests/test_shell_body_nav_rework.nim` with the two liveness failures and
  the active-tick full-grid-work failure. Do not import it from a shard until
  Phase 7 makes it green.
- Change no production source.

Test-only types and procs:

```nim
type
  NavCorpusProfile* = enum ncpDefault, ncpCarrier, ncpHunter
  NavCorpusDynamic* = enum ncdNone, ncdDanger, ncdBlocked, ncdBoth
  NavCorpusDistance* = enum ncrNear, ncrFar
  NavCorpusPoint* = object
    x*, y*: int
  NavCorpusCase* = object
    id*, mapName*, mapSha256*: string
    poolIndex*, rosterSize*, seatIndex*: int
    profile*: NavCorpusProfile
    dynamic*: NavCorpusDynamic
    distance*: NavCorpusDistance
    start*, requestedGoal*, validatedGoal*: BodyPoint
    component*: int
    dangerSources*: seq[DangerCandidate]
    dangerHash*: string
    blockedCell*: Option[BodyPoint]
    oracleCost*: float64
    oracleRouteHash*: string
  NavCorpus* = object
    schemaVersion*: int
    sourceCommit*, poolSha256*, oracleRules*: string
    cases*: seq[NavCorpusCase]

proc loadNavRouteCorpus*(path: string): NavCorpus
proc buildOracleDanger*(map: BodyMap; item: NavCorpusCase): BodyDangerField
proc oracleRoute4px*(map: BodyMap; item: NavCorpusCase): seq[BodyPoint]
proc resampleRoute4px*(route: openArray[BodyPoint]): seq[BodyPoint]
proc oracleFloatCost*(route: openArray[BodyPoint]; map: BodyMap;
  danger: BodyDangerField; profile: CostProfile;
  blockedCell: Option[BodyPoint]): float64
proc routeInflationPct*(candidateCost, oracleCost: float64): float64
```

Literal manifest design:

- Top level: `schema: "coworld_nav_route_corpus"`, `v: 1`, source commit,
  SHA-256 of `data/br_s2_map_pool.json`, a literal English/constant identifier
  for the oracle rules, and a literal `cases` array. No seed formula or runtime
  random choice is permitted in the reader.
- Exactly 3,072 cases: 64 published maps x roster sizes 16 and 32 x profiles
  default/carrier/hunter x dynamic snapshots none/danger/blocked/both x
  near/far. Every cross-product cell is present; duplicate IDs or an empty
  stratum are parse failures.
- Each case contains the literal pool index and map name/digest; start,
  requested goal, validator-normalized goal and component; seat index; profile;
  distance label; zero to eight literal danger sources `(seat,x,y)` plus the
  rebuilt danger-raster hash; optional literal blocked nav cell; and the
  expected oracle cost/route hash. The 16/32 roster rows use valid literal
  source seat IDs for their roster and are separate cases even where geometry
  is shared.
- Near/far pairs are selected once by the writer from same-component standable
  pixels in deterministic row-major order. `near` is at or below the per-map
  25th percentile and `far` at or above the 75th percentile of successful
  current-planner geodesic length. The chosen coordinates, not the selection
  rule, are the checked-in truth.
- For danger rows, sources are placed from literal same-component standable
  points around the middle third of the oracle route, sorted by
  `(distance-to-start, seat)`. The manifest stores their resulting raster hash;
  a later change in danger construction fails loudly instead of silently
  changing the corpus. Blocked rows name a literal nav cell traversed by the
  unblocked oracle route. `both` carries both literals.
- The denominator is the current 4 px weighted A* route under the case's own
  unquantized `float32` danger raster and blocked cell. Both its path hash and
  float64 cost are frozen. Candidate routes are executed through the follower,
  deterministically resampled at 4 px, and scored by Euclidean step length
  `*(1 + profileWeight * danger(midpoint))`, then `*8` when the midpoint's
  nav cell is the blocked cell. The oracle never adopts the new integer danger
  quantization. Missing/illegal/wrong-goal/wrong-component candidates are hard
  failures and never omitted from percentile input.
- The cover-hold cold-transition row is an explicit top-level TODO with task
  `1218165969208626`, `enabled: false`, and no fabricated sample. No other
  corpus row waits on that task.

Tests written first and expected red:

1. A living body with an accepted valid goal and no installed route emits a
   non-zero movement mask on that same action tick.
2. A living body at an exhausted old endpoint that receives a different valid
   goal emits a non-zero movement mask on that same tick.
3. An active navigation tick neither schedules nor advances a full-board
   planner/minter and exposes no per-seat route-query array sized from map
   width, height, nav-cell count, or 4 px lattice count.

Phase gate and commits:

- Run the standalone new test and record that all three post-change assertions
  fail for the expected current reasons. Run its corpus parser/oracle checks
  green and run the existing `test_shell_body_nav` green.
- There is a protocol tension: subtask 01 explicitly requires failing tests,
  while the general phase rule says phase tests pass. Decision: the red test is
  committed but not shard-imported; its exact expected failures close Phase 1,
  while every pre-existing shard remains green. Phase 7 removes that exception
  by making the test green and wiring it into a CI shard. I will not hide the
  failures with `skip`, invert their assertions, or weaken them.
- Commit A freezes the writer/support/manifest. Commit B adds the deliberately
  red standalone regression file.

### Phase 2 — subtask 02: immutable shared index

Files:

- Change `src/shell/body_map.nim` to export one canonical neighbour order and
  the exact body-clear segment predicate.
- Add `src/shell/body_route_index.nim`.
- Add `tests/test_shell_body_route_index.nim`.
- Add `tools/qualify_body_route_index.nim` for the exhaustive 64-map +
  colossal proof and retained/transient byte report.
- Change `src/shell/episode.nim` only enough to build one shared index inside
  the existing activation barrier; it will not yet replace production route
  following.

Production types and procs:

```nim
const
  NavNeighbors*: array[8, BodyPoint]
  PortalAnchorRingCells* = 4
  PortalCrossingBoxCells* = 4
  PortalCrossingMaxPops* = 64

proc segmentClear*(map: BodyMap; start, goal: BodyPoint): bool
proc legalNavMove*(map: BodyMap; fromCell, toCell: BodyPoint): bool

type
  BodyPortalSide* = object
    portal*, room*: uint16
    anchorCell*: int32
    fieldStart*: int32
  BodyRouteSegment* = object
    cellStart*: int32
    cellLen*: uint16
    staticLengthQ4*: uint32
    minX*, minY*, maxX*, maxY*: uint16
  BodyRouteArc* = object
    fromSide*, toSide*: uint16
    segment*: uint16
    reversed*: bool
  BodyRouteIndexStats* = object
    navCells*, walkableCells*, rooms*, portals*, sides*: int
    portalFieldCells*, segmentCells*, arcs*: int
    retainedBytes*, transientPeakBytes*: int64
  BodyRouteIndex* = ref object
    map*: BodyMap
    # private exact-sized packed arrays described in section 3

proc newBodyRouteIndex*(map: BodyMap): BodyRouteIndex
proc legalMovesAt*(index: BodyRouteIndex; cellIndex: int): uint8
proc roomForCell*(index: BodyRouteIndex; cellIndex: int): int
proc sideAnchor*(index: BodyRouteIndex; side: int): BodyPoint
proc segmentCells*(index: BodyRouteIndex; segment: int;
  reversed = false): lent openArray[int32]
proc routeIndexStats*(index: BodyRouteIndex): BodyRouteIndexStats
proc validateRouteIndex*(index: BodyRouteIndex)
```

Build rules:

- `roomOf` stores zero-based room indices and `high(uint16)` for no room.
  Every walkable coarse cell must have a room; activation fails by map name and
  cell if not.
- Deterministic loop order is room, portal/choke, then row-major cell. All
  priority ties use `(distance, row-major cell index)`, never table/hash order.
- Each choke gets two side anchors. The anchor search is rings 0..4 in a fixed
  clockwise order, accepting only a walkable cell carrying the required room.
  A direct legal move is preferred; otherwise the crossing search is confined
  to the +/-4-cell choke box and 64 pops. Failure names the choke and prevents
  activation. These bounds are design-brief omissions; they are deliberately
  fixed, not map-size-derived. An all-map failure stops the phase for review
  rather than silently raising them.
- One room-restricted Dijkstra per portal side fills a packed uint8 next-hop
  field. Transient `uint32` distances/parents and heap storage are sized to the
  largest one room and reused. Ties choose `NavNeighbors` order.
- A portal-pair path is extracted into one canonical-direction flat segment.
  Unreachable intra-room pairs have no edge. Crossing paths are ordinary
  segments. Graph nodes are portal sides; adjacency arcs name a segment and
  direction, so every room transition pays for its crossing.
- All arrays are counted in a first pass and allocated to final length before
  filling; production fill code does not grow them with unconstrained `add`.

Tests written first:

- Canonical legality matches the old planner predicate on every adjacent cell
  of representative open, diagonal-wall, pool, and BR maps.
- Room bases, two-sided anchors, crossings, next-hop chains, segment lengths,
  direction reversal, unreachable pair omission, graph components, and
  deterministic hashes.
- Exhaustively, for every standable pixel in all 64 published specs, arena,
  and the supported colossal fixture: a legal <=32 px connector reaches an
  anchored node in the same pixel component, and two anchored nodes are graph
  connected iff their pixel components are equal.
- Activation rejects a synthetic no-room cell, missing side anchor, broken
  crossing, over-wide ID count, and component mismatch with exact messages.

Gate and commits:

- The focused index test passes. The qualification tool prints one row per
  published map plus arena/colossal, with coverage counts, component hashes,
  retained bytes, transient bytes, and build/baseline time.
- If exhaustive coverage fails, Phase 2 remains open. I will add deterministic
  row-major 4 px micro-corridor nodes only in the failed pixel components,
  connect them with the same exact predicate, rerun the proof, and record the
  added types/bytes in `LEDGER.md`; I will not exclude the pocket or convert it
  into a corpus sampling issue.
- Commit A canonicalizes legality without behavior change. Commit B adds the
  index. Commit C adds any evidence-required sparse micro-node contingency and
  its proof. No GameVersion, fixtures, or viewer rebuild occurs yet per the
  explicit subtask-10/11 rule.

### Phase 3 — subtask 03: bounded hierarchical queries

Files:

- Add `src/shell/body_route_query.nim`.
- Change `src/shell/body_nav.nim` to own one shared query workspace and the
  bounded per-seat route descriptor, initially alongside the legacy planner.
- Add `tests/test_shell_body_route_query.nim`.

Production types and procs:

```nim
const
  RouteSidePopCap* = 4096
  RouteLocalPopCap* = 4096
  RouteLocalLegCap* = 512
  RouteEdgeCap* = 4096
  RouteSmoothLookahead* = 6

type
  RouteEdgeRef* = distinct uint16 # high bit is traversal direction
  BodyRouteFailure* = enum
    brfNone, brfStartAttach, brfGoalAttach, brfDisconnected,
    brfLocalCap, brfSideCap, brfDescriptorOverflow, brfValidation
  BodyRouteRequest* = object
    start*: BodyPoint
    goal*: ValidatedGoal
    profile*: CostProfile
    danger*: ptr BodyDangerField
    blockedCell*: Option[BodyPoint]
    elapsedZoneTick*: int
  BodyRouteDescriptor* = object
    edgeCount*, startLegLen*, goalLegLen*: uint16
    exactStart*, exactGoal*: BodyPoint
    # shared scratch owns variable storage during construction
  BodyRouteQueryResult* = object
    ok*: bool
    failure*: BodyRouteFailure
    descriptor*: BodyRouteDescriptor
  BodyRouteQueryScratch* = ref object
    # fixed-cap local search plus side-count generation-stamped arrays

proc newBodyRouteQueryScratch*(index: BodyRouteIndex): BodyRouteQueryScratch
proc queryBodyRoute*(index: BodyRouteIndex; scratch: BodyRouteQueryScratch;
  request: BodyRouteRequest): BodyRouteQueryResult
proc validateBodyRoute*(index: BodyRouteIndex; request: BodyRouteRequest;
  result: BodyRouteQueryResult): bool
proc installRoute*(seat: BodyNavSeat; scratch: BodyRouteQueryScratch;
  result: BodyRouteQueryResult; revision: uint64)
```

Tests written first:

- Bounded endpoint rings and exact pixel connectors, including a valid goal
  whose cell center is not standable; exact final point and component retained.
- Straight, same-room weighted local, via-portal, multi-room, two-sided
  crossing, reversed segment, blocked cell, cap-hit fallback, no-attach, and
  disconnected cases.
- Query determinism across repeated runs, seat order permutations, arm64 and
  later amd64 hashes; no pointer identity or hash iteration affects a tie.
- Transactionality: each failure leaves the previous advancing route bytes,
  cursor, anchor, and revision unchanged.
- Fixed arrays/caps are asserted; a synthetic graph over the simple-path bound
  fails activation rather than truncating a route.

Gate and commit:

- Focused query tests pass, every successful route validates every cell/segment
  and ends at the exact `ValidatedGoal`, and instrumentation proves <=4096 side
  pops and <=4096 local pops. Commit query core and integration together.

### Phase 4 — subtask 04: danger memo and immutable zone hazard

Files:

- Add `src/shell/body_hazard.nim`.
- Change `src/shell/body_route_index.nim` to retain segment arrival extrema.
- Change `src/shell/body_route_query.nim` for fixed-point danger, blockage,
  directional hazard, and the shared stamped memo.
- Change `src/ctf/zone_field.nim` to expose one read-only damage snapshot seam.
- Change `src/ctf/server.nim` and `src/shell/episode.nim` to install the
  snapshot after `ensureZoneArrivalField` and before nav construction when
  `season2Shell && zoneDamageByPaint && zonePhases.len > 0`; otherwise install
  a typed dark overlay. The elapsed tick is passed live to `episode.step`.
- Add `tests/test_shell_body_hazard.nim`.

Production types and procs:

```nim
const
  HazardNeverArrives* = 0xffff'u16
  HazardRiskRampTicks* = 96
  HazardRiskMaxMultiplier* = 12
  SafeHorizonTicks* = 48
  SafeBucketTicks* = 48

type
  ZoneDamageSnapshot* = object
    gridW*, gridH*, cellPx*: int
    fingerprint*: uint64
    damage*: seq[uint16]
  BodyHazardState* = enum bhsDark, bhsReady
  BodyHazardOverlay* = ref object
    state*: BodyHazardState
    fingerprint*: uint64
    arrival*: seq[uint16]
    segmentArrivalMin*, segmentArrivalMax*: seq[uint16]
    roomMaxArrival*: seq[uint16]
  BodySafeCache* = ref object
    overlayFingerprint*: uint64
    gameGeneration*: uint64
    bucket*: int
    safeDistQ4*: seq[uint32]
    safeNext*: seq[uint16]
    roomHasDry*: seq[bool]

proc zoneDamageSnapshot*(sim: SimServer): ZoneDamageSnapshot
proc newDarkBodyHazardOverlay*(): BodyHazardOverlay
proc newBodyHazardOverlay*(index: BodyRouteIndex;
  source: ZoneDamageSnapshot): BodyHazardOverlay
proc arrivalAt*(overlay: BodyHazardOverlay; cellIndex: int): uint16
proc hazardStepCostQ4*(overlay: BodyHazardOverlay; cellIndex: int;
  etaTick: int; physicalStepQ4: uint32): int64
proc refreshSafeCache*(cache: BodySafeCache; index: BodyRouteIndex;
  overlay: BodyHazardOverlay; elapsedTick: int; gameGeneration: uint64)
```

Tests written first:

- Min projection consumes `damage`, never render-gated `arrival`; dark gating,
  fingerprint stability, `ZoneNeverArrives` as infinity, room maxima, and
  segment min/max skip equivalence.
- Shared danger memo values and generation stamps are deterministic, include
  both traversal directions/crossings in their bound, and never become
  per-seat arrays.
- Directional hazard prices start at entry ETA and advance cell by cell; exact
  0/96/saturated ramp boundaries; painted cells are costly but legal.
- Adversarial two-prefix case where a dearer but physically shorter prefix
  reaches a later edge before paint. If one `(cost,length)` label fails, add
  one bounded earliest-arrival alternative label per side as VERDICT2 directs;
  never raise the pop cap.
- Elapsed time moving backward or generation changing rekeys the safe cache;
  a fingerprint mismatch asserts instead of serving stale data.

Gate and commit:

- Focused hazard/query tests pass in both compile shapes. The active query
  performs no source-field build and no full-grid scan. Commit overlay/cache
  ownership and server seam together.

### Phase 5 — subtask 05: stable hints and `zone_safe_ground`

Files:

- Change `src/shell/body_hazard.nim`, `body_nav.nim`, and `episode.nim`.
- Change `src/shell/view.nim`, `src/shell/binary_view.nim`,
  `src/shell/schemas/play_view.schema.json`, and `play_sdk/play.nim`.
- Change `docs/designs/BR_PLAYS.md` enough to mark the new surface as pending
  implementation; final authoritative rewrite occurs in Phase 10.
- Add/update `tests/test_shell_body_hazard.nim`,
  `tests/test_shell_view.nim`, `tests/test_shell_binary_view.nim`, and
  `tests/test_play_sdk.nim`.

Production types and procs:

```nim
type
  BodySafetyHints* = object
    ticksUntilPaintHere*: int32
    ticksToSafety*: int32
    safeDistPx*: int32
    retreatOctant*: int8       # -1 absent/already safe, else 0..7
    sourceCell*: Option[int32]
  PlayNav* = object
    ticksUntilPaintHere*, ticksToSafety*, safeDistPx*: int
    zoneSafeDirBrads*: int

proc safetyHintsFor*(system: BodyNavSystem; selfPos: BodyPoint;
  elapsedTick: int; gameGeneration: uint64): BodySafetyHints
proc zoneSafeTarget*(system: BodyNavSystem; selfPos: BodyPoint;
  elapsedTick: int; gameGeneration: uint64): Option[BodyPoint]
proc navHints*(episode: FirstLightEpisode; seatIndex: int;
  selfPos: BodyPoint; elapsedTick: int): Option[PlayNav]
```

Resolution rules and tests:

- Dry own cell returns zero distance/time and no direction. If the room has a
  dry cell, a fixed-cap 512-pop legal BFS chooses nearest dry by
  `(distance, row-major cell)`. Otherwise compare walked chain distance plus
  shared `safeDistQ4` across the room's portal sides. Every returned source is
  rechecked against the dry predicate. No source returns all `-1` and leaves a
  class target unresolved.
- `ticksUntilPaintHere = -1` for never; otherwise `max(0,arrival-elapsed)`.
  Distance uses ceil(Q4/16) px, time uses ceil(Q4/33) ticks, and direction uses
  the first legal neighbour converted through the engine's existing brads
  convention. These rounding decisions were not explicit in the design.
- Add optional JSON `nav`, append binary section ID 14 with the reference
  32-byte stride, and add `SdkNav`. Dark/non-zone frames omit the JSON key and
  binary section byte-for-byte. JSON/binary selected-row equivalence remains
  green.

Gate and commit:

- Hint tests cover dry, same-room, portal-routed, unreachable, bucket-stable,
  >65535 elapsed, and fog-negative cases. JSON/binary/SDK boundary goldens pass.
  Commit the computation and additive view surface together.

### Phase 6 — subtask 06: stable request anchors and semantic intent

Files:

- Change `src/shell/types.nim`, `emit_validator.nim`, `finisher.nim`,
  `binary_view.nim`, `view.nim`, and `body.nim`.
- Change `src/shell/schemas/intent.schema.json` and `play_sdk/play.nim`.
- Change `src/shell/body_nav.nim` for accepted anchors and semantic identity.
- Update intent/emit/body/view/SDK tests.

Production types and procs:

```nim
const
  NavTargetClassZoneSafeGround* = "zone_safe_ground"
  NavTargetClasses* = [NavTargetClassZoneSafeGround]

type
  NavTargetIdentityKind* = enum ntiLiteral, ntiZoneSafeGround
  NavTargetIdentity* = object
    kind*: NavTargetIdentityKind
    sourceCell*: int32
  NavRequestAnchor* = object
    goalCell*: BodyPoint
    identity*: NavTargetIdentity
    profile*: CostProfile
    moving*: bool

proc resolveEffectiveGoal*(body: SeatBody; elapsedTick: int;
  gameGeneration: uint64): tuple[goal: ValidatedGoal,
  identity: NavTargetIdentity]
proc shouldQueryRoute*(seat: BodyNavSeat; anchor: NavRequestAnchor;
  tick: int): bool
proc acceptRequestAnchor*(seat: BodyNavSeat; anchor: NavRequestAnchor;
  tick: int)
```

Contract decisions and tests:

- Add neutral `Intent.targetClass: string`; the only accepted value is
  `zone_safe_ground`, only on `navigate_to`. A literal point remains required
  and already validated; it is the fallback whenever class resolution fails.
- Resolve the class before the arrived test in `actFromBelief`. Identity is
  `(class, resolved source cell)`, not bucket/epoch/provenance. A literal goal's
  identity is its accepted goal cell. Sub-threshold moves do not move the
  accepted anchor, so cumulative drift eventually exceeds two cells.
- Query iff: no route this life; either axis differs by >2 cells; profile
  changed; stuck for 8 ticks; moving goal and 12 ticks since last query; or
  route exhausted. Failed queries still accept the request anchor; an old route
  remains only while advancing.
- `setStandingIntent` stores the order/goal only. It does not cancel, pin, or
  mutate navigation and ignores epoch/provenance for route decisions.
- Preserve canonical key order including current `drop`. `target_class` sorts
  after `suppress_fire_freeze` and before `v`. The existing reserved uint32 in
  the 200-byte binary standing-intent record becomes target-class ID 0/1, so
  the fixed stride need not change and JSON/binary standing views agree. This
  closes an omission in the reference PR, which added canonical JSON but did
  not expose the class in the binary standing Intent.
- Keep `ShellAbiVersion = 1`: the field is optional, the binary value consumes
  reserved space, and old modules do not request section 14. The required
  GameVersion cutover happens in Phase 10.

Gate and commit:

- Canonical, raw non-SDK, SDK build-time vocabulary, fallback, arrived-before-
  resolve regression, stable identity, cumulative drift, and epoch/provenance
  no-churn tests pass. Commit wire/typed contract and coordinator together.

### Phase 7 — subtask 07: follower, steering, and death reset

Files:

- Change `src/shell/body_nav.nim`, `src/shell/body.nim`, and
  `src/shell/episode.nim`.
- Change `tests/test_shell_body_nav_rework.nim` from red to green and import it
  in the currently fastest measured shard (expected `tests/shard_2.nim`, but
  verify runtimes first).
- Extend `tests/test_shell_body_seat.nim` and
  `tests/test_shell_episode_ladder.nim`.

Production types/procs:

```nim
type
  BodyRouteCursor* = object
    phase*: uint8
    edgeIndex*, cellOffset*: uint16
  BodyNavState* = enum
    bnsIdle, bnsFollowing, bnsSteering, bnsNoProgress, bnsArrived

proc routeWaypoint*(seat: BodyNavSeat; index: BodyRouteIndex;
  selfPos: BodyPoint): Option[BodyPoint]
proc routeAdvancing*(seat: BodyNavSeat; selfPos: BodyPoint;
  arriveRadius: float): bool
proc steeringMask*(system: BodyNavSystem; seatIndex: int;
  selfPos, target: BodyPoint; profile: CostProfile;
  elapsedTick: int): uint8
proc resetNavigationLife*(system: BodyNavSystem; seatIndex: int)
```

Follower/steering rules and tests:

- The descriptor streams copied start/local and goal legs, immutable middle
  segments/crossings, and the exact endpoint connector. Look ahead at most six
  cells within the current leg and choose the farthest exact-clear point.
- If no route advances, score all eight octants in `NavNeighbors` order.
  Reject non-standable, non-clear, and blocked-penalty candidates. Integer
  score is target-distance reduction minus quantized profile danger minus the
  finite hazard price; first octant wins ties. A progress candidate moves on
  the same tick; otherwise emit zero and `bnsNoProgress`.
- `arrived` is explicit and never called following. Remove `bnsStalePath`; a
  stationary seat cannot be reported as walking.

Death clearing order, before `setSeatActive(false)`:

1. Edge descriptor bytes/count and both copied leg buffers/counts.
2. Route cursor/phase and exact endpoint connector state.
3. Accepted request anchor, semantic target identity, and route revision.
4. `lastXy`, `stuckTicks`, blocked penalty and its TTL.
5. Last-query tick, last-follow-replan tick, follow-replan/stuck counters.
6. Desired profile and moving-goal flag.
7. Last query result/failure and navigation diagnostic state.

The shared index, immutable overlay, safe cache, danger raster and danger
geometry persist. Inactive seats are skipped by danger rebuilds and asserted
never queried. Respawn starts with no route-life state and may steer/query on
its first valid navigate tick.

Gate and commit:

- The three Phase-1 tests now pass without changed assertions and are shard
  wired. Focused body/episode tests prove same-tick movement, deterministic
  steering, no-progress, arrived, failed-query old-route retention only while
  advancing, death-before-inactive ordering, and clean respawn. Commit
  integration/lifecycle as one checkpoint.

### Phase 8 — subtask 08: full regression matrix

Files:

- Expand the new route/index/hazard tests and existing
  `test_shell_body_nav.nim`, `test_shell_body_seat.nim`,
  `test_shell_binary_view.nim`, `test_shell_emit_validator.nim`,
  `test_shell_episode_ladder.nim`, `test_shell_first_light_server.nim`, and
  `test_manifest_schema.nim`.
- Change `src/shell/episode.nim` diagnostics and `src/ctf/server.nim` log use.
- Change `docs/designs/FIRST_LIGHT_DEMO.md` for the new diagnostic shape.

Production type/proc changes:

```nim
type FirstLightNavSummary* = object
  counts*: array[BodyNavState, int]
  steeringSeats*, noProgressSeats*: seq[uint8]

proc formatNavSummary*(tick: uint32; nav: FirstLightNavSummary): string
```

Tests written first:

- Route legality/goal/component and every typed failure; danger+blocked+hazard
  combinations; all ramp/bucket/lifecycle boundaries; literal/class wire
  strictness; canonical JSON and binary reserved-field goldens; SDK dark/light;
  death/respawn/inactive; query transactionality; diagnostics for all five
  states.
- Assert no active tick invokes/schedules legacy full-grid planning and no
  per-seat route-query field scales with map/fine-node count.
- Regression checks explicitly leave cover selection/scoring, combat, fog,
  strategy, `drop`, and handoff unchanged.

Gate and commit:

- All focused shell tests and their owning shards pass in runtime-linked and
  runtime-stub compile shapes. Commit only regression/diagnostic/doc changes.

### Phase 9 — subtask 09: canonical qualification harness and gates

Files:

- Add `tools/bench_body_nav_rework.nim`.
- Add `tools/run_body_nav_gate.sh` only if the exact Docker invocation is too
  error-prone to keep in the report; no dependency is added.
- Change production code only for allocation-free counters/timers required to
  measure the inclusive body slice. Add `bodySliceNanoseconds` to
  `FirstLightTickResult`; it encloses all seat actions, route queries,
  steering, danger rebuild, safe-cache rollover, and nav bookkeeping, while
  excluding guest execution/view encode.

Harness procs:

```nim
type
  NavGateScenario* = enum
    ngsFirstGoals, ngsMovingGoals, ngsBucketDangerRollover,
    ngsStuckReplans, ngsWorstDegree, ngsColdMemo
  NavGateStats* = object
    samplesNs*: seq[int64]
    p95Ns*, maxNs*: int64

proc runRouteCorpusGate*(corpusPath: string): JsonNode
proc runActivationGate*(): JsonNode
proc runBodySliceGate*(rosterSize: int; scenario: NavGateScenario;
  warmups = 5; repetitions = 30): NavGateStats
proc retainedNavBytes*(episode: FirstLightEpisode): int64
```

Benchmark plan:

- Emit machine-readable JSON with commit, dirty state, `NimVersion`, OS/arch,
  compile flags, Docker image ID, CPU limit, pool digest, per-case samples, and
  explicit pass/fail thresholds. Reject a dirty or wrong-arch canonical run.
- Route quality: all 3,072 literal cases. Report p95/max overall and separately
  for every roster/profile/dynamic/distance stratum, with count/missing/illegal
  columns. Required p95 <=3.0% and max <=10.0% in every row; empty is failure.
- Activation: in the same process/image, measure `newBodyMap` alone, then fresh
  map + `newBodyRouteIndex`, for every one of the 64 published specs and the
  colossal fixture. Use one warmup/five samples for pool and one warmup/three
  for colossal, reporting each sample and worst ratio. Require <=2x per pool
  map and <=3x colossal. Report transient build peak separately.
- Retained memory: exact payload/fixed-object accounting plus steady-state RSS
  delta after build/GC. Require shared nav <=16 MiB per published pool map and
  <=32 MiB colossal. Existing per-seat danger+visited rasters are reported
  separately, not mislabeled as route-query state.
- Tick time: 16 and 32 seats, all six hard scenarios, five warmups and 30
  measured repetitions, fresh/cold state reconstructed where the scenario
  requires it. Require inclusive body-slice p95 <=4.0 ms and max <=5.0 ms for
  every roster/scenario row. Worst-degree maps/rooms are discovered by the
  activation census and then named literally in output. Cold memo forces every
  memo stamp stale before all seats query on one tick.
- Canonical Docker command uses the repository Dockerfile's existing generic
  build seam with Nim 2.2.4 and exact flags:

```sh
docker buildx build --load --platform linux/amd64 --target build \
  --build-arg NimMain=tools/bench_body_nav_rework.nim \
  --build-arg 'NimFlags=-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on' \
  --tag coworld-ctf-nav-gate .
docker run --rm --platform linux/amd64 --cpus=1 \
  coworld-ctf-nav-gate ./ctf --all --corpus tests/fixtures/shell/nav_route_corpus.json
```

  The harness verifies `uname -m` is x86_64/amd64. This Mac's Docker server is
  arm64, so amd64 may be emulated; the brief explicitly requires the Dockerfile
  linux/amd64 cell. I will label any emulated absolute latency provisional if
  it cannot represent a production-equivalent CPU and will not claim the body
  gate passed on arm64 numbers.

Gate and commit:

- All quality, activation, memory, and canonical tick rows must pass unchanged.
  On failure I report the exact row and use only the approved structural
  fallbacks (segment sampling, bounded memo-fill degradation, added structural
  alternatives, or earliest-arrival label). I will not raise live caps, remove
  cases, or weaken percentiles. Commit the harness/instrumentation and any
  separately reviewed structural fix.

### Phase 10 — subtask 10: final cutover, deletion, and version

Files:

- Delete `src/shell/body_planner.nim` after moving only the still-needed
  `BodyDangerField`/profile definitions to their truthful owner.
- Reduce `src/shell/body_cache.nim` to the duck cache; remove route-field slots,
  pins, `peekRouteDistance`, minter APIs, and related constants.
- Remove legacy planner/minter jobs, schedulers, cursors, traces,
  `ColdPlanBudgetPerTick`, `runPlanningTick`, `prewarmColdPlans`, plan budget
  events/logging, `bnsStalePath`, and compatibility-only tests.
- Make the shared index/query/overlay path the sole production path in
  `body_nav.nim`, `episode.nim`, and `server.nim`.
- Change `src/ctf/sim_types.nim` GameVersion changelog/constant.
- Update all nine `.bitreplay` fixtures and derived replay/glory goldens via
  `tools/record_all_fixtures.sh`.
- Rebuild `static-replay-viewer/` with
  `tools/build_replay_viewer.sh "$PWD/static-replay-viewer"` in this phase, so
  the cutover commit obeys the sim-sources stamp once the explicit gate allows
  the rebuild.
- Update `docs/designs/strategy-play-calling-shell-2026-08-29.md` and its
  tracked HTML twin, `docs/designs/BR_PLAYS.md`,
  `docs/designs/FIRST_LIGHT_DEMO.md`, and any source comments that still claim
  route fields/resumable planning/stale-path diagnostics.

Tests/gate:

- Before choosing a number: fetch/merge `origin/main`, scan every remote branch
  claim >= main, and take the next number above all claims. Current main is
  GV52, but Phase 0 deliberately does not reserve a number that can race.
- Run `tools/ci/check_gameversion.sh origin/main`; the changelog headline uses
  `GVnn (shared cog navigation): ...` and says what behavior it obsoletes.
- Grep/import checks prove the deleted full-grid live planner/minter APIs have
  no production caller and no active-play scheduling path.
- Record on an idle machine, run all nine recipes through the canonical script,
  verify the capture/event beats and every embedded GameVersion, rebuild
  derived goldens, then rebuild the viewer.
- One commit contains the production cutover/deletion, GameVersion, docs,
  fixtures, derived goldens, and viewer bundle. This intentionally avoids an
  intermediate committed sim-source state with a stale viewer.

### Phase 11 — subtask 11: final verification

Files:

- Add no planned production files. Correct only defects or stale docs exposed
  by verification, with a separate attributable commit and a viewer rebuild if
  any `src/*.nim` correction changes the sim-sources stamp.
- Write `PHASE_11_REPORT.md` with complete commands, outputs, gate artifact
  paths, open risks, final commit, and clean status.

Checks:

```sh
sh tools/runtime_spike/fetch_deps.sh
# with WASMTIME_C_API/C_INCLUDE_PATH/LIBRARY_PATH/DYLD_LIBRARY_PATH exported:
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav_rework.nim
nim c -r -d:release tests/tests.nim
# compile/run the four CI shards with workflow flags, including -d:useMalloc
tools/ci/check_gameversion.sh origin/main
node tools/qa_module_eval.cjs
# Docker viewer build/staleness and full gating replay smokes from build.yml
```

- Re-run the canonical Phase-9 artifact after the final source commit and
  compare corpus route hashes across arm64 and amd64.
- Verify all docs describe the new immutable index, bounded queries, hazard
  surface, hint/target contracts, diagnostics, and deleted scheduler; no stale
  route-field/pending-plan claim remains outside clearly labeled history.
- Verify `git diff --check`, clean worktree, branch/base relation, and no remote
  publication. Final report includes the required codebase-friction rating.

## 3. Retained index layout and byte accounting

The production index uses structure-of-arrays and fixed-width IDs. It does not
retain Dijkstra distances or parents. Exact counts are discovered in Phase 2;
the table below uses the approved probe maxima and deliberately conservative
rounding.

| Retained data | Formula | Giant estimate | Colossal estimate |
|---|---:|---:|---:|
| legal move mask | `navCells * 1` | 0.08 MiB | 0.33 MiB |
| room compaction | `roomOf*2 + localIndex*4 + roomCells*4 + starts*4` | <=0.82 MiB | <=3.28 MiB |
| portal next-hop fields | `portalFieldCells * 1 + (sides+1)*4` | <=1.88 MiB | 9.08 MiB |
| flat segment cells | `segmentCells * 4` | <=0.98 MiB | 2.92 MiB |
| sides/segments/arcs/adjacency/bounds | exact packed arrays | <=0.25 MiB | <=0.75 MiB |
| shared query scratch | side arrays + fixed 4096 local search/descriptor | <=0.30 MiB | <=0.40 MiB |
| immutable overlay | `navCells*2 + segments*4 + rooms*2` | <=0.17 MiB | <=0.66 MiB |
| mutable safe cache | sides `(uint32+uint16)` + rooms | <0.01 MiB | <0.02 MiB |
| **conservative total** | all above | **<=4.5 MiB** | **<=17.5 MiB** |

The shared segment-cost memo is part of query scratch and is accounted as
`directedArcCount * (sizeof(uint32 value) + sizeof(uint16 generation))`.
Unlike the design's shorthand 27,460 intra-room directed arcs, the exact count
also includes both directions of every crossing. At the measured colossal
counts the bound is `(27,460 + 2*1,237) * 6 = 179,604` bytes before any
alignment; Phase 2/4 report the actual packed allocation. Generation wrap
clears the value/stamp arrays outside a route choice before generation 1 is
reused.

`retainedNavBytes` means every retained payload plus fixed owner objects and
sequence headers. Arrays are exact-sized in two passes, so logical capacity is
known. Allocator/RSS delta is reported separately; transient build heap,
distances, parents, and coverage-proof buffers are never counted as retained.
Per-seat danger/visited rasters are also reported separately because they are
unchanged by this task, while per-seat route state is fixed: 4,096 packed
edge refs (8 KiB), two 512-cell int32 legs (4 KiB total), small cursor/anchor
metadata, and no map-sized route-query array.

## 4. Bounded query pseudocode and fixed-point rules

```text
query(start pixel, ValidatedGoal, profile, danger, blocked, overlay, elapsed):
  assert goal belongs to index.map and component(start) == goal.component
  startAnchors = legal exact connectors in rings 0..4, fixed ring order
  goalAnchors  = legal exact connectors in rings 0..4, fixed ring order
  if either empty: typed attach failure; publish nothing

  candidates = []
  for compatible start/goal anchor pair in deterministic order:
    if same room:
      add legal direct-cell-line candidate if present
      add cheapest via-one-portal-side candidate by walking both hop chains
      run weighted room-local A* with exactly 4096 pop/result cap
      add it if it reaches the exact goal; cap hit only drops this candidate

    attach virtual start to every side of start room by scored hop chains
    attach every side of goal room to virtual goal by scored reversed chains
    run A* over side nodes, <=4096 pops:
      intra-room arc = named stored segment and direction
      crossing arc   = named stored crossing and direction
      dynamic edge cost is evaluated in traversal order
      tie tuple is (f, g, physicalLengthQ4, sideIndex, labelKind)
    reconstruct edge refs plus copied start/local and goal legs in shared scratch
    append exact endpoint connectors
    validate every move/connector, descriptor caps, component, and exact goal
    add successful transactional candidate

  choose minimum (fullCost, physicalLengthQ4, descriptorLexicographicOrder)
  if none: typed failure; publish nothing
  atomically copy scratch descriptor/legs into seat and bump revision
```

Arithmetic:

- Length unit is Q4 (1/16 px). Orthogonal 8 px = 128; diagonal = 181.
  The A* heuristic is exactly
  `181*min(abs(dxCell),abs(dyCell)) + 128*(max-min)` using cell-index deltas.
- Danger sample `D = roundTiesEven(clamp(danger,0,...) * 256)`. Profile
  weights are Q8 `W = 256/640/64`. For base step length `L`, danger-adjusted
  cost is `roundTiesEven(L * (65536 + W*D) / 65536)`. If the sampled midpoint
  nav cell is the blocked cell, multiply that result by 8 exactly.
- Physical ETA uses the derated speed `33 Q4 units/tick` (2.0625 px/tick).
  Arrival at each sampled cell is `elapsed + ceil(cumulativeLengthQ4 / 33)`;
  ceiling is chosen for the conservative-late safety property. Other rational
  multiplications round nearest, ties to even.
- Hazard adds a finite per-step price. If arrival is never, add zero. Let
  `slack = paintArrival - eta`: slack >=96 adds zero; slack <=0 adds
  `12*L`; otherwise add
  `roundTiesEven(12*L*(96-slack)/96)`. It is never `Inf`, never a prune.
- All accumulated costs/priorities/physical lengths are checked `int64` (with
  explicit overflow failure even in release); stored static segment lengths
  are `uint32`. No clock, thread, async work, pointer identity, or unordered
  hash traversal participates.
- The lazy danger memo is shared per query generation and keyed by directed arc
  ID. It memoizes only the danger+blocked contribution that is independent of
  entry ETA; directional hazard is added separately because it depends on
  traversal order and elapsed arrival.
- Qualification's denominator remains the independent unquantized 4 px float
  oracle. Search quantization error is visible in the reported inflation.

## 5. Explicit underspecification decisions

1. **Phase-1 red tests vs per-phase green rule:** preserve real red assertions,
   keep the new file out of shards until Phase 7, and report the expected red
   as Phase 1's gate. Never skip or invert it.
2. **Which 64 maps:** use `data/br_s2_map_pool.json`, not the measured legacy
   20-seed `map_pool.nim`; add arena and one supported colossal fixture as
   extra activation/topology checks.
3. **Corpus selection:** literal 3,072-row cross product with frozen points,
   danger sources/hash, blocked cell, oracle cost/hash. Near/far are <=p25 and
   >=p75 geodesic selections before freezing.
4. **Memory meaning:** exact retained logical payload/object bytes are the
   threshold; RSS and transient peak are separate evidence, and unchanged
   per-seat danger rasters are reported separately.
5. **Portal bounds:** 4-cell anchor ring and +/-4-cell, 64-pop crossing search.
   Evidence that these are too small stops Phase 2 for review; no map-derived
   play-time bound is introduced.
6. **Coverage contingency:** 4 px micro-corridor nodes are added only for an
   exhaustive proven gap, never speculatively and never by excluding a map.
7. **Fixed-point rounding:** nearest/ties-even for rational cost products;
   conservative ceiling only for Q4-distance-to-ETA conversion. Hazard ramp is
   96 ticks and finite max multiplier 12 from the reference implementation.
8. **Local search/smoothing:** start at 4,096 pops and K=6. Tune only downward
   or add structural alternatives from gate evidence; never scale the cap with
   room size.
9. **Single-label hazard risk:** the adversarial Phase-4 test decides. Failure
   adds one earliest-arrival alternative label per side; it does not enlarge
   the live-search cap.
10. **Safe-room search:** exactly 512 BFS pops, fixed neighbour order. Failure
    returns unresolved/fallback rather than scanning the room.
11. **Semantic fallback:** literal point remains required and validated.
    Identity is class+resolved source cell; bucket, epoch, and provenance are
    excluded.
12. **Binary standing Intent:** consume the existing reserved uint32 for target
    class ID so the 200-byte stride stays stable; add section 14 for hints.
13. **ABI/GameVersion:** retain ABI v1 for additive optional/reserved fields;
    choose the collision-free GameVersion only immediately before Phase 10.
14. **Diagnostics:** replace stale/no-path claims with counts for idle,
    following, steering, no-progress, arrived and seat lists for the two action
    states operators must chase. Delete plan-budget logging with its scheduler.
15. **Staged commits vs viewer rule:** the task explicitly delays GameVersion,
    fixtures, and viewer until phases 10/11. Intermediate branch commits may
    fail only the sim-source bundle-staleness check; they are not shippable.
    Phase 10 makes the first complete shippable commit with the rebuilt viewer.
16. **Docker on this Mac:** enforce linux/amd64 and one CPU in the image/run;
    label emulated absolute latency provisional if it is not a production-
    equivalent CPU. Arm64 development numbers never satisfy the canonical gate.
17. **Cover hold:** retain one clearly labeled disabled TODO tied to
    `1218165969208626`; do not alter cover selection/scoring or invent its goal.
18. **Documentation truth:** replace the living design's route-field,
    resumable-planner, and stale-path sections rather than stacking caveats;
    keep historical decision-record entries explicitly historical. Update both
    Markdown and tracked HTML twin together when the cutover exists.

