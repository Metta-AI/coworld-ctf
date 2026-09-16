# Navigation rework decision ledger

This is the running implementation ledger for the phase-gated navigation
rework. Later phases may add entries but must not silently rewrite earlier
decisions.

## Binding decisions

| ID | Phase | Decision | Consequence |
|---|---:|---|---|
| D001 | 0 | The implementation base is `origin/main` commit `52103b107832e12f30a719dd299bc7636c3dd12f`. | Corpus provenance names this exact source commit. |
| D002 | 1 | Refresh and merge `origin/main` once at each phase boundary before the first commit, not before every commit. | Phase 1 was already ahead 0/behind 0, so its merge was a no-op. It touched neither `src/shell/body*.nim` nor `src/shell/episode.nim`. |
| D003 | 1 | Freeze 3,072 literal route cases: 64 maps x 2 rosters x 3 profiles x 4 dynamic states x 2 distance strata. | Ordinary tests read the manifest; only `tools/build_nav_route_corpus.nim` rewrites it. |
| D004 | 1 | The oracle stays an independent 4 px A* scored with unquantized `float32` danger and float64 accumulation. | New integer danger quantization cannot silently move the denominator. |
| D005 | 1 | Cover-hold cold transition is not fabricated. | The manifest carries task `1218165969208626` with `enabled: false`. |
| D006 | 1 | The three post-change navigation laws are committed red and standalone until Phase 7. | They are not shard-imported, skipped, inverted, or weakened. The corpus/oracle portion is green. |
| D007 | plan verdict | `RouteEdgeRef` uses one `uint16` direction bit, leaving IDs `0..32767`. | Phase 2 activation must assert `segments + crossings <= 32767` and include the map name in the failure. |
| D008 | plan verdict | Phases 3-9 retain the legacy planner beside the new path. | Every pre-existing shard must remain green; a focused-only phase report is incomplete. |
| D009 | plan verdict | Every phase report records exact commands, exit codes, pasted output excerpts, and `git log --oneline origin/main..HEAD`. | Phase reports are evidence, not summaries without reproducible commands. |
| D010 | 1 | No authoritative repo documentation changes in Phase 1. | Both commits are test-only and self-documented; the approved plan reserves the final public navigation/design rewrite for Phase 10. |
| D011 | 2 | The frozen route corpus is encoded as one compact JSON case per line, and its source commit is a frozen literal rather than the current checkout commit. | The writer reproduces the committed file byte-for-byte while later test-only commits cannot silently change its provenance. |
| D012 | 2 | `body_map.nim` owns the exported eight-neighbor order, exact `segmentClear`, and `legalNavMove`; the legacy planner consumes those definitions. | The route index and legacy planner share one legality predicate without changing existing planner behavior. |
| D013 | 2 | Phase 2 stopped at the first published-map crossing qualification failure: `br-gen-20049`, choke 47. | The `+-4`-cell box and 64-pop bound were not raised, the unfinished index was not committed, and exhaustive qualification/integration did not proceed. |
| D014 | 2 | The proposed resolution is the plan's sparse 4 px micro-corridor contingency, confined to the failing crossing connector while rooms and fields stay on the 8 px grid. | This changes route-segment point encoding and requires review before implementation; the recommended minimal representation reserves negative `int32` segment-cell values for `-1 - fineGridIndex`. |
| D015 | 2 resolution | `RESOLVE_P2.md` authorized negative-`int32` sparse 4 px points in crossing segments and, when required by the unchanged coverage proof, pocket connectors. | Crossing search remains direct 8 px, then 64-pop boxed 8 px, then 256-pop boxed 4 px; caps remain fixed. |
| D016 | 2 resolution | Fine-grid indices encode one of 16 deterministic 4 px lattice phases so a narrow pixel pocket can use the phase that passes through it; crossing anchors remain on phase `(0,0)`. | A negative reference remains self-decoding. Fine points stay confined to crossings/pocket connectors and sample dynamic state from their containing 8 px cell. |
| D017 | 2 resolution | Every pixel component absent from the portal-side graph receives a separate row-major coarse seed component; sparse pocket corridors attach otherwise uncovered coarse/pixel pockets without joining distinct pixel components. | The first published map reaches zero uncovered pixels with 1 fine crossing, 2 pocket connectors, 10 fine points, and 40 fine-point bytes. |
| D018 | 2 | Phase 2 stopped again at the fixed side-anchor ring gate. An exhaustive anchor-only census found 68 misses across 26 of 66 supported maps, with required rings up to 29. | Ring 4 was not widened. A simple ring-5 exception would fix arena choke 81 but not the published corpus, and distant anchors cannot use the existing +/-4-cell crossing box. The contingency/proof WIP remains uncommitted pending review. |
| D019 | 2 resolution | `RESOLVE2_P2.md` makes the route index's legal 8 px cross-room edges the portal truth. Pass A clusters them by unordered room pair at one 64 px constant; Pass B consults uncovered BodyMap chokes only as local fine-gap hints and derives both rooms from `roomOf`. | The arena side-label failure disappears without widening `PortalAnchorRingCells`. The derivation is isolated in commit `ebb0c525`; qualifier rows now report chokes, portals, sides, dropped chokes, max room degree, and arcs. |
| D020 | 2 | Full qualification now stops on published map 1, `br-gen-20184`: 562 standable pocket pixels remain unresolved. The first failing pixel component has 72 pixels and zero walkable 8 px cells; another has 7 pixels, zero coarse cells, and no phase-0 4 px point. | This is not a 32 px or 256-pop cap failure. `BodyPocketConnector` requires a non-negative coarse `targetCell`, so a component with no coarse cell is unrepresentable. Proposed resolution: explicit fine-only component anchors using the existing 16-phase negative encoding and a retained graph-component ID; keep both caps unchanged. |
| D021 | 2 resolution | `RESOLVE3_P2.md` limits exhaustive coverage to spawn-backed validator components. Non-validator islands are counted as `unreachable_components` / `unreachable_px`, receive no fine-only representation, and are not activation failures. | `BodyMap` must expose validator component and spawn provenance so activation can assert every validator component has an anchored coarse cell and every spawn cell is anchored. Phase 3 must later guard goal attachment with typed `brfGoalAttach`. |
| D022 | 2 | The RESOLVE3 scope removes the 79 non-validator pixels on `br-gen-20184`, but 483 pixels in validator component 1 remain unresolved, first `(1884,648)`. | This is a hard stop under ruling 5. There are 24 anchored coarse goals in the fixed box and the nearest are ring 2, but the source's complete fixed-phase 4 px region has only 9 nodes and reaches none; no <=32 px exact two-segment bridge exists. The scoping WIP remains uncommitted pending a fine-corridor representation ruling. |
| D023 | 2 resolution | `RESOLVE4_P2.md` replaces fixed-phase pocket search with deterministic 8-connected pixel BFS in a fixed `+-32` px box, followed by exact farthest-first string-pulling into self-decoding 16-phase fine points. | Pocket connectors chain in row-major seed order, Pass B receives the same pixel search as its third attempt, and the retained per-coarse-cell fine-anchor index is available to Phase 3. Rooms, portal fields, ordinary segments, and the fixed caps remain unchanged. |
| D024 | 2 | Coarse route graphs inside one physical pixel component collapse only after an exact pixel connector proves the bridge. Safe cell interiors use the clearance-field radius proof; boundary cells receive the exhaustive pixel census. | Commit `71e2d2d1` qualifies all 66 maps with zero uncovered validator pixels. Pool maxima are 1.9298x activation and 1,399,698 retained bytes; colossal is 2.1146x and 26,709,081 bytes. The 64 px portal clustering constant remains below the RESOLVE2 topology escalation threshold. |
| D025 | 3 gate | Phase 2 was independently accepted with route-index 7/7, body-map 15/15, body-nav 20/20, body-seat 23/23, and both server compile shapes green. | Phase 3 must prove every retained fine point is endpoint-attachable. Phase 9 owns the first structural response to thin activation headroom: component-wide multi-source pocket BFS with reused visit stamps, never a relaxed cap. Phase 10 must claim a GameVersion above main's then-current value (59 at this gate). |
| D026 | 3 | Route queries use one activation-sized, generation-stamped scratch workspace: fixed 4,096-pop local and side searches, exact Q4 octile side heuristic, bounded copied endpoint legs, and immutable route-edge references. | No seat owns map-sized query arrays. A result is usable only while its scratch generation is current, and installation copies a fully assembled and validated descriptor into fixed per-seat storage. |
| D027 | 3 | Endpoint attachment searches retained coarse and per-cell fine anchors in the same fixed four-cell ring and rejects a goal without validator-component provenance as typed `brfGoalAttach`. | Every retained Phase 2 fine point on the published narrow-pocket map is individually queried and validated in the focused suite. Non-validator islands stay unrepresented and cannot enter the route graph. |
| D028 | 3 | A local-search cap hit discards only that candidate; it is observable in `BodyRouteQueryStats` and does not invalidate another bounded candidate. | The synthetic cap-fallback test records a local cap hit, asserts both pop counts stay at or below 4,096, and still validates the exact returned route. Phase 4 may add hazard cost without changing this transaction boundary. |
| D029 | 3 fixup | Hierarchical route-index and scratch construction is activation-only and opt-in: `initFirstLightEpisode` prepares it exactly when the roster contains a play seat; all-input and legacy-only body systems leave it absent. | Ticks that do not call the new path pay no route-index work. Phase 9 must account this as a named, once-per-play-episode activation component without moving the containment timing window. |
| D030 | 4 | Zone hazard enters the shell only through an activation-time copy of `ZoneArrivalField.damage`; render `arrival` never crosses the seam. The exact ready gate is `season2Shell && zoneDamageByPaint && zonePhases.len > 0`, otherwise the episode owns a typed dark overlay. | Route queries cannot build or scan the source field. The server passes live elapsed zone time into each episode step instead of retaining an activation-time tick snapshot. |
| D031 | 4 | Directional hazard advances cell by cell at 33 Q4 units/tick with ceiling ETA conversion and a finite ties-to-even 96-tick ramp capped at 12x physical length. | Painted cells remain legal. Segment extrema may skip only provably zero or fully saturated traversals, with cell-by-cell equivalence pinned by tests. |
| D032 | 4 | The shared query-local memo uses one 4-byte cost and one 2-byte generation stamp per directed arc and stores only danger plus blockage. Entry-ETA hazard is evaluated separately. | No per-seat map-sized memo exists, reverse arcs cannot alias, and query generations cannot serve stale costs. |
| D033 | 4 | The adversarial two-prefix test requires one bounded earliest-physical-arrival alternative label per side beside the cheapest label. | The fixed side-pop cap remains 4,096; the demonstrated route uses the safer alternative without widening any search bound. |
| D034 | 4 fixup | `ZoneDamageSnapshot` is owned by the CTF zone-field layer; `body_hazard` imports that lower-layer type and `zone_field.nim` may not import the shell. | The dependency direction is pinned by a source-architecture test and an Emscripten replay-viewer compile. |
| D035 | 4 fixup | No tick-path optimization is justified for the reported containment delta: a 36-sample probe and source trace show the memo, elapsed overlay, and safe-cache paths are absent from clean ticks, while three adjacent pairs have mixed per-wave signs. | Phase 9 retains the canonical performance gate; the P4 fixup does not add speculative benchmark-only code. |
| D036 | 5 | Safety hints use only integer public values: `-1` means absent/never, dry self is zero distance and time with no direction, distance is ceil Q4/16, time is ceil Q4/33, and retreat is one of eight integer octants. | Plays never reconstruct zone geometry or depend on floating-point route answers. `zoneSafeTarget` exposes the resolved source point, but the `zone_safe_ground` Intent contract remains Phase 6. |
| D037 | 5 | A room with dry ground uses a legal 512-pop fixed-cap weighted cell search, ordered by `(Q4 distance, row-major cell)`; a room without dry ground compares its walked portal chains plus the shared safe-distance field. | Every selected source is rechecked against the same dry predicate. A cap hit or unresolved source returns all `-1` safety metrics instead of scanning farther. |
| D038 | 5 | The safety search reuses the activation-only `BodyRouteQueryScratch`; hazard/cache context is installed only when route scratch exists. | The all-input and legacy constructor/type remain source-identical to accepted Phase 4 and allocate no Phase-5 scratch. The route and safety queries are serial on the game thread. |
| D039 | 5 | JSON adds optional `nav` before the existing `schema` key; PV1 appends section 14 with one 32-byte row; SDK decoding exposes `SdkNav.present`. | Dark frames omit the JSON key and binary section byte-for-byte, existing JSON order and PV1 sections stay fixed, and the final four reserved i32 values are zero. |
| D040 | 6 | `target_class` is optional and neutral-empty; `zone_safe_ground` is its only value, only on `navigate_to`, and a validated literal point remains mandatory fallback. | Neutral JSON stays byte-identical, canonical order is after `suppress_fire_freeze` and before `v`, binary ID 0/1 occupies the reserved uint32 at offset 12 of the unchanged 200-byte record, and `ShellAbiVersion` stays 1. |
| D041 | 6 | A navigation request's identity is `(class, resolved source cell)`, while literal drift is measured cumulatively from the last accepted goal anchor. | Bucket, epoch, and provenance cannot churn routes; class/source/profile changes can replace pending work, and cadence/no-route/stuck retries remain suppressed while pending. |
| D042 | 6 | `setStandingIntent` validates and stores only. Query acceptance owns the route anchor, including after failure or cancellation, and an old route survives only while advancing. | Standing-intent replacement no longer cancels or pins navigation. The pin and slot fields remain physically present until the Phase-10 deletion boundary. |
| D043 | 6 gate | The production-linked aggregate passes 2,171 checks, both server shapes pass, every focused suite passes, and all four shards have a final green result. | The exact parallel shard run exposed a pre-existing fixed-temp-path collision in shard 3; its isolated rerun passes 647/647 and the collision is carried as an explicit follow-up risk. |
| D044 | 6 containment | No timing-driven reshuffle follows the accepted Phase-5 layout commit. Three final adjacent baseline/HEAD samples have mixed outcomes, including two pairs where both pass; the last is 4,633 us baseline and 4,638 us HEAD against 5,000 us. | Earlier misses on both sides remain recorded. The arm64 gate is treated as load-sensitive, and canonical linux/amd64 qualification stays in Phase 9. |
| D045 | 7 freshness | Phase 7 merged advancing `origin/main` at `a3ca2fba`, `c68c5d9c`, and `c3f7781b` before its checkpoints rather than building on accepted Phase 6's stale base. | The final Phase-7 HEAD is based on current `origin/main` `c3f7781b`; unrelated upstream scoring, profiling, and replay changes are preserved in merge commits. |
| D046 | 7 | A play episode constructs the immutable route index and shared query scratch once, omits the per-seat legacy planner, and uses synchronous bounded queries plus the descriptor follower for every play-seat movement mask. | Copied start/local and goal legs, immutable indexed middle segments, crossings, and the exact endpoint are streamed by `BodyRouteCursor`; K=6 smoothing uses `segmentClear` from the cog's real position. Legacy constructors and tests still build the old planner through Phase 10. |
| D047 | 7 | When no descriptor waypoint advances, steering scores all eight `NavNeighbors` in fixed order with integer Q4 progress, quantized danger, and finite hazard cost; only a physically progressing legal candidate may move. | First octant wins equal scores, no candidate records `bnsNoProgress`, and arrival records `bnsArrived` rather than following. A failed replacement retains the old descriptor only while it advances. |
| D048 | 7 lifecycle | `resetAfterDeath` clears the route buffers, cursor, endpoint, accepted identity, revisions, progress/block state, query result, and legacy per-life state before setting the seat inactive. | Inactive seats are skipped by scheduled danger work and assert on both query and steering entry; respawn begins with no route-life state and can move on its first navigate tick. |
| D049 | 7 gate | The Phase-1 red file is green 11/11 and wired into measured-fastest shard 4. The aggregate and parallel shards have no functional failures, but current `origin/main` and HEAD both consistently miss the unchanged arm64 containment max under isolated adjacent runs (closest pair 6,365 us baseline / 6,361 us HEAD). | The failure is reported, not hidden or threshold-weakened. Phase 9 remains the canonical linux/amd64 performance gate. The FIRST LIGHT probe passes and shows 32/32 moving on the first navigate tick. |
| D050 | 8 fixup | The server passes the guarded `gameTicksElapsed()` value into the shell episode, so lobby zone time is zero and does not jump backward at `startGame`. | A server-seam regression warms the safe cache across the lobby/start boundary and pins elapsed tick, bucket, and revision; no raw `tickCount - gameStartTick` remains in shell-facing source. |
| D051 | 8 | `ShellNavSummary` is a complete census of `idle`, `following`, `steering`, `no_progress`, and `arrived`, with seat lists for steering and no-progress. | `SHELL_NAV` prints once per second and on plan-budget events. The retired planner-era `pending_plans`, `stale_path`, and `no_path` fields are removed from current source and `SHELL_DEMO.md`. |
| D052 | 8 gate | The expanded functional matrix passes in focused linked/stub runs, the four shards, and the one-shot aggregate. Shard 2 and the aggregate fail only the unchanged arm64 containment body-time assertion; one isolated pair under load `4.60 8.90 12.05` fails on both current main (6,055 us) and HEAD (6,227 us). | The local timing gate remains explicitly red and was not retried or weakened. Phase 9 must run the canonical Linux/amd64 gate. Phase 10 still owns legacy-planner deletion and GameVersion/fixture work. |
| D053 | 9 | The canonical harness runs only on a clean linux/amd64 Docker build with Nim 2.2.4, the exact approved flags, one CPU, and the full 3,072-case corpus; native modes remain non-canonical and the `--all` spelling refuses them. | Commit `b24d8d8d` records exact retained-byte counters, the inclusive `bodySliceNanoseconds` seam, per-case/stratum JSON, activation/RSS evidence, six literal tick scenarios, and a portable native RSS probe. |
| D054 | 9 gate | Architecture determinism and every activation/memory row pass, but quality fails overall and in 30/48 strata (19.910469% p95, 86.650066% max, four descriptor overflows), while 8/12 emulated canonical tick rows and 11/12 native tick rows fail. | The unchanged Phase-9 acceptance gate is red. Approved structural experiments did not close the quality gap and were reverted; Phase 10 must not begin without a new approved design or an explicit gate/architecture decision. |

## Open risks carried into Phase 6

- The new route index must preserve the literal corpus's map/danger/oracle
  hashes without adopting the later fixed-point cost model as its denominator.
- The deliberate red file remains outside CI until Phase 7; Phase 7 must make
  all three laws green before importing it into the fastest measured shard.
- Phase 6 must add the `zone_safe_ground` Intent and stable request identity;
  Phase 5 deliberately exposes only the resolver and hints.
- The directional hazard alternative is proven by the fixed adversarial case;
  Phase 9 remains responsible for canonical all-map route quality and inflation.
- The local arm64 activation numbers pass the Phase 2 thresholds, but the
  canonical linux/amd64 Docker performance gate remains Phase 9 work.
- Phase 9 must measure route-index and query-scratch preparation separately
  inside play-episode activation. The fixup's small-map diagnostic was about
  0.95--1.08 ms for the index and 0.02--0.05 ms for scratch; pool and colossal
  ratios remain the canonical evidence.
- Non-validator islands remain deliberately unrepresented. Query code must
  reject goals without validator provenance instead of treating those islands
  as ordinary disconnected route graphs.
- The arm64 shard-level containment timing is load-sensitive: the direct
  adjacent baseline/HEAD pair is the attributable Phase-5 signal, while Phase
  9 remains responsible for the canonical linux/amd64 performance gate.

## Open risks carried into Phase 7

- Phase 7 must connect bounded route following and deterministic local steering
  while preserving Phase 6's accepted-anchor query policy.
- Death/life transitions must clear the accepted anchor and every other
  per-life navigation field; the three Phase-1 red laws then become green and
  shard-wired.
- Standing-intent pin and slot storage remains present by explicit instruction;
  Phase 10 owns deletion together with the legacy live planner.
- The arm64 containment threshold remains load-sensitive. Two of the final
  three adjacent baseline/HEAD pairs passed on both sides and the third missed
  only on baseline; canonical linux/amd64 qualification remains Phase 9.
- The paintball replay test uses one fixed process-global temp path, so exact
  parallel local shard execution can race. Its isolated shard passes 647/647.
- GameVersion, all nine replays, the viewer bundle, and final documentation
  reconciliation remain deferred to Phases 10 and 11.

## Open risks carried into Phase 8

- The public `SHELL_NAV` summary still uses its pre-cutover field names while
  the internal diagnostic enum is now idle/following/steering/no-progress/
  arrived. Phase 8 owns the schema, formatting, server log, and documentation
  cutover.
- The legacy planner remains compiled and its standalone suites remain green,
  but it does not produce production play-seat masks. Phase 10 owns physical
  removal after the regression and performance phases.
- Current `origin/main` and Phase-7 HEAD both miss the host-sensitive local
  arm64 containment max in ten adjacent pairs. The closest pair is effectively
  equal (6,365 us baseline / 6,361 us HEAD); Phase 9 must run the canonical
  linux/amd64 Docker gate and must not weaken the threshold.
- `GameVersion`, all nine replay fixtures, the committed viewer bundle, and
  the final sim-source stamp remain deliberately deferred to Phases 10 and 11.

## Open risks carried into Phase 9

- The unchanged local arm64 containment body-time gate remains host-sensitive.
  Phase 8's sole isolated pair failed on both `origin/main` and HEAD under the
  same load; Phase 9 must use the approved pinned Linux/amd64 environment and
  must optimize only an attributable HEAD regression.
- Phase 9 must measure route quality, activation time, retained memory, shared
  query workspace, and 16/32-seat body time without weakening the fixed caps or
  reintroducing per-seat map-sized state.
- The legacy planner remains compiled for standalone regression coverage, but
  production play-seat masks are already owned by bounded route queries,
  following, and steering. Physical removal remains Phase 10, not Phase 9.
- `GameVersion`, all nine replay fixtures, the committed viewer bundle, and the
  final sim-source stamp remain deliberately deferred to Phases 10 and 11.

## Open risks after Phase 9

- The room/portal hierarchy does not represent the float oracle's weighted
  route choices closely enough: canonical quality is 19.910469% p95 and
  86.650066% max against 3%/10%, with four `brfDescriptorOverflow` misses.
- First-goal, moving-goal, stuck-replan, and cold-memo body slices exceed the
  4/5 ms limits by two to three orders of magnitude. The steady worst-degree
  and canonical bucket-rollover rows pass, isolating the dominant cost to
  route creation and replacement rather than constant per-tick bookkeeping.
- Phase 10's legacy-planner deletion, GameVersion bump, nine replay recordings,
  documentation cutover, and viewer rebuild remain untouched and blocked on a
  Phase-9 resolution.
