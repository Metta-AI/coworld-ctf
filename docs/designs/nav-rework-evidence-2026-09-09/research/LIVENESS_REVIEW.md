# Liveness review: far-route starvation under the danger-generation restart rule

Written 2026-09-09 by Claude (peer) for `LIVENESS_REVIEW_BRIEF.md`. Review only: no source
edits, no benchmarks, no commits. Line numbers are at 20234cc7 (Codex's uncommitted M0 edits
to `body_route_query.nim` do not touch the lines cited). Evidence for the symptom:
`LATENCY_REPORT.md` sections 5 and 7.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Every dynamic input the resumable search consumes, and what invalidates a job

| Input | Where read | Snapshot or live? | What changes it | What it invalidates |
|---|---|---|---|---|
| start, goal | `BodyRouteSearchRequest` (`body_route_query.nim:60-64`), set in `submitMixedRoute` (`body_nav.nim:738-744`) | snapshot at request | a new request (`shouldQueryRoute`, 591-615: anchor kind or safe-ground cell changed, goal moved more than `ReplanGoalCells = 2` cells, profile changed, no installed route or cursor at end, `stuckTicks >= 8`, or moving target and 12 ticks since last plan) | the whole job: `cancelStaleRouteJob` (771-784) drops a job whose `requestGeneration` differs from the pending one; `seat.revision` is bumped per request (989) |
| profile | request | snapshot | profile change forces a new request | as above |
| blockedCell | request, from `seat.blockedPenalty` (731-736) | snapshot | set on a forced (stuck) replan with a 96-tick TTL; cleared by TTL at 966-968 | a stuck replan is itself a new request; TTL expiry alone does not invalidate a job |
| elapsedZoneTick | request (`episode.elapsedZoneTick`, set per `step`, `episode.nim:1268`) | snapshot at request; the hazard price is computed against this frozen ETA (`hazardStepCostQ4`, `body_hazard.nim:144-159`, ramp `HazardRiskRampTicks = 96`) | advances every tick | nothing: a long-lived job prices hazard against a stale ETA and nobody cancels it for that |
| hazard overlay | `spendBodyRoutePops` via `integratedMixedCost` (399-401, 646-648) | live reference, but the overlay is immutable after construction (`newBodyHazardOverlay` sets `bhsReady` once, `body_hazard.nim:89-102`; no mutating proc) | nothing during play | nothing |
| graph, legality, anchors, bridges | live | immutable per map | nothing | nothing |
| packed weights (`seat.packedWeights`) | live, every pop and every attachment (`beginBodyRouteSearch` 570-571; spend 646, 678) | live | `publishDangerGeneration` (457-474) after each scheduled rebuild: `rebuildPackedWeights` rewrites the seat's table, then `inc seat.dangerGeneration` unconditionally | `cancelStaleRouteJob`: a job whose `request.dangerGeneration != seat.dangerGeneration` is discarded and the seat returns to `brlPending` with the new generation (780-784); the search restarts from scratch at the next admission. Also (472-474) an installed route whose generation is stale is cleared, which makes `shouldQueryRoute` true at 610 and produces a new request |
| workspace stamps | `job.workspaceGeneration` vs `workspace.generation` | one job at a time; `beginWorkspace` on every begin | a new begin | there is never a second job to interleave, so this only guards against misuse |
| seat life | `resetNavigationLife` (330-356) | n/a | death and harness resets | clears pending, installed, and the shared job if it belongs to that seat |

So the only live-read cost input is the per-seat packed weight table, and the danger generation
exists precisely to guarantee that every pop of one search reads one table. That guarantee is
what makes the resumable search equal to an uninterrupted search, which is what the corpus
gate certifies (the gate runs single uninterrupted queries with a fixed generation,
`tests/test_shell_body_nav_rework.nim:105,137`).

The cadence (`DangerCadenceK = 32`, `dangerSeatDue` 545-546) rebuilds each seat's raster from
scratch every 32 ticks regardless of whether its inputs changed (`rebuildDangerFromPoints`
423-455 zeroes and recomputes). The generation therefore advances every 32 ticks even when the
threat picture is identical, and the in-flight job of that seat is thrown away. The
`--latency` counters match this exactly: 62-63 restarts per 2,000-tick far wave, 0 completions.

## 2. Is "preserve the generation when the rebuilt packed weights are equal" sufficient and correct?

### 2.1 Correctness argument
The search's state after n pops is a function of (graph, request, the weight values it has
read). If the table after a rebuild is bitwise equal to the table before, every future read
returns what an uninterrupted search would have read, so continuing the job yields exactly the
uninterrupted result. The generation is a proxy for "the table differs"; making it advance only
when the table differs keeps the invariant the rule protects, with no approximation. Equality
of the packed int16 table is the right thing to compare, not the float raster: the search
never reads the float raster (`rebuildPackedWeights` 321-343 is the only consumer), and two
different float rasters that pack to the same Q8 values are indistinguishable to the search.

### 2.2 Sufficiency for the stationary-threat case
In the harness every seat sees the same 8 static tracks and `MaxDangerSources = 8`, so
`selectNearestSources` (485-507) always selects all 8 as a set. Correction (Codex): it orders
them by distance from the seat's own position, so the ordered list can change as the seat
moves, and the float accumulation is order-dependent, so the packed table is not guaranteed
identical at every cadence; it is identical whenever the order is unchanged and very likely
identical otherwise (a last-bit float difference has to cross a Q8 rounding boundary to show
in the table). So equality-preservation removes most, not provably all, restarts in this
workload; whether the remaining restarts still starve a far route is an empirical question
for the `--latency` rerun. When it holds, a far route needing 31k-52k pops completes in
31-52 ticks of its own admissions at B = 1,024 (plus waiting for earlier seats under SJF). The far waves would then publish, and the near waves would stop
paying the 32-tick re-request (`route_completions` of 27-31 per 16-seat near wave in
`LATENCY_REPORT.md` are those re-requests).

In real play the same condition holds for every seat with no confirmed visible threat
(`dangerInputFromTracks`, `body.nim:1468-1478`: candidates are only tracks fresh this tick),
which is the common state for most seats most of the time. It does not hold for a seat whose
selected sources move by a cell or change membership; those seats keep the current behaviour.

### 2.3 What the candidate changes beyond the in-flight job
`publishDangerGeneration` also clears an installed route whose generation is stale (472-474).
With equality-preservation that clearing stops for unchanged seats, so an installed route is
followed until the goal, a stuck event, a goal change, or the 12-tick moving-target cadence,
instead of being re-requested every 32 ticks. Two consequences:
- Fewer pops spent on re-requests (throughput gain, not measured here).
- Hazard freshness: routes and long jobs price the zone against the `elapsedZoneTick` of
  their request. Today the 32-tick wipe bounds that staleness at 32 ticks for a static goal;
  with the candidate a static-goal route could persist for hundreds of ticks while the zone
  closes, against a 96-tick risk ramp. This is a real play-behaviour difference in the zone
  phase and is the one part of the candidate that is not "preserving identical inputs".

### 2.4 Determinism and replay
The equality check is a pure function of state already on the deterministic path; masks
change (seats follow instead of steer), so this is a movement-mask change: GameVersion bump,
nine fixtures, viewer rebuild, docs, once, per the standing rule. Cross-architecture route
hashes on the corpus are unaffected (single queries, fixed generation) and should be verified
byte-identical.

## 3. What the existing contract allows versus what needs a new decision

Ratified text on this rule (all quoted from the evidence dir):
- PLAN_P10.md line 22: "Restart work whose snapshotted danger generation is no longer current."
- PLAN_P10.md line 341: "danger-generation restart before further pops".
- PROCEED_P10.md item 6 (James's approval): "danger-generation restart rule, determinism by
  stable seat order".
- P9B_REPORT.md line 485: "a changed danger generation discards and restarts suspended
  workspace state".
- body_nav.nim 458-460 (source comment): "A search can therefore compare one monotonic
  generation before it spends another pop."
- test 193: "danger generation cancels stale in-flight work before another pop" (uses a
  genuinely changed source; it passes unchanged under the candidate).

None of these says the generation must advance on every rebuild. They say a job must not
continue across a generation change, and "generation" is described everywhere as the
identity of the danger state the search reads. Advancing it only when that state differs is
inside the approved rule, not a change to it. The brief's instruction stands: no human
approval gate is needed for preserving identical inputs. Two things are outside that:
1. The installed-route lifetime (2.3): the 32-tick wipe is an emergent effect of the
   generation, not a ratified clause, but changing it changes zone-phase play. If Codex wants
   the narrowest change, keep the wipe on the cadence (decouple the two uses of the generation)
   and preserve only the in-flight job; that leaves play behaviour outside the search identical
   and still fixes starvation. If the wipe is removed too, add a bounded refresh request
   without wiping (a pending re-request keeps the installed route until the new one installs,
   finish path 836-849) and register it as a decision for James because it alters when routes
   are re-priced against the zone.
2. Anything that lets a job continue across a changed table (section 5) is a new policy and
   needs a decision.

## 4. Practice elsewhere (primary sources)

- Koenig and Likhachev, "D* Lite", AAAI 2002, pp. 476-483 (https://aaai.org/papers/00476-aaai02-072-d-lite/;
  abstract read). Koenig, Likhachev, Furcy, "Lifelong Planning A*", Artificial Intelligence
  155(1-2):93-146, 2004 (https://idm-lab.org/bib/abstracts/Koen04a.html; abstract read). The
  family reuses the previous search and re-expands only vertices made locally inconsistent by
  edge-cost changes; when no cost changes, the previous result stands with no work. That is
  the principled version of "do not restart when nothing changed"; our candidate is the
  degenerate case (all-or-nothing on table equality).
- Sun, Yeoh, Koenig, "Moving Target D* Lite", AAMAS 2010, pp. 67-74
  (https://idm-lab.org/bib/abstracts/papers/aamas10a.pdf; abstract read): reuse when start and
  goal both move, the case our `ReplanGoalCells` hysteresis and moving-target cadence handle by
  re-requesting instead.
- The repository's own ratified rejection (`.nav-rework-brief.md` line 151): "D* Lite (targets
  changing edge costs; here topology is static and goals churn)". That rejection was about
  adopting an incremental planner as the primary algorithm; it does not bear on skipping a
  restart when costs are unchanged.
- Recast/Detour sliced pathfinding (`initSlicedFindPath` / `updateSlicedFindPath` /
  `finalizeSlicedFindPath`, https://github.com/recastnavigation/recastnavigation, header read):
  a bounded-iteration resumable query over an immutable navmesh; the header I fetched does not
  document behaviour when the mesh changes mid-query, so I make no claim about it. Unity's
  agents recompute paths when a bake invalidates them, which is the "restart on change" policy
  we have (forum discussions only; not a primary source, listed for orientation).
- Koenig, Likhachev, Liu, Furcy, "Incremental heuristic search in AI", AI Magazine 25(2), 2004:
  PDF fetched but not text-extractable here; not relied on.

Reading: production incremental planners only redo work that a change touches; the two
extremes are "always restart" (ours today) and "repair locally" (LPA*). Equality-preservation
moves us from the first extreme to "restart only when something changed", which every source
treats as the obvious floor.

## 5. Narrow candidate (for Codex to implement; I am not editing src)

Change confined to `publishDangerGeneration` (`body_nav.nim:457-474`):
1. Before `rebuildPackedWeights`, keep a comparison of the old table. Correction (Codex):
   compare-as-you-write is not straightforward, because `rebuildPackedWeights` (321-343) has two
   passes: the first writes the Q8 values, the second scatters the 0x8000 hot bit onto the
   neighbours of every danger > 0 cell. A compare in the first pass would see old values that
   still carry hot bits, and the second pass only sets bits, never clears them, so an
   old-versus-new decision needs the complete old table. Options: (a) one shared 85 KB scratch (85,466 bytes on the largest pool map, 778,752 on colossal)
   buffer (seats rebuild sequentially, so one buffer serves all; counted in the shared retained
   total), copy the old table in, rebuild, compare; (b) compare in pass one with the hot bit
   masked off on both sides and additionally detect any hot bit that would be cleared (an old
   hot cell whose 3 x 3 neighbourhood has no new danger > 0 cell), which is fiddly. (a) is the
   safe choice and its cost is one copy plus one compare per cadence.
2. If nothing changed: do not increment `dangerGeneration`, do not clear the installed route,
   keep the in-flight job. If anything changed: existing behaviour exactly.
3. Keep `weightRefreshes` counting rebuilds so the harness split stays comparable; add a
   counter for "unchanged" rebuilds.
Decoupling option (narrowest play-behaviour change, see 3.1): keep the installed-route clear
on the cadence regardless of equality, and skip only the generation bump. Recommend Codex pick
this unless the zone-freshness decision is taken to James now.

Tests required:
- Unit: stationary source, two rebuilds: generation unchanged, in-flight job survives
  `runRouteScheduler`, route installs, `installedRoute.dangerGeneration` equals the seat's.
- Unit: changed source: the existing test 193 unchanged and green.
- Unit: two float rasters that pack to equal Q8 tables: generation unchanged.
- Unit: sources that leave, then return: generation advances twice (equality is against the
  previous table, not any earlier one).
- Harness `--latency` on the Mac for determinism and on the Xeon/c6a for the far tail: far
  waves publish every seat within the cap; near p50/p95/max recorded; `deterministic: true` in
  two fresh processes; `scheduler_restarts` near zero in far waves.
- Corpus quality: route hash byte-identical (5a1340213fe3...), zero missing/illegal, all strata.
- Focused suites, both compile shapes, the Phase 1 liveness laws, `tests/tests.nim` once,
  containment pair, then GameVersion, nine fixtures, viewer, docs.
- A moving-threat `--latency` variant (informational) to document the remaining limitation.

## 6. Limitations of the candidate

- Seats whose selected sources move or change membership keep the restart behaviour; at
  B = 1,024 a far route for such a seat still starves whenever it needs more than roughly 32 x B
  pops. That is the general problem and it is not fixed by equality-preservation. Options for
  a later decision, in increasing scope: (a) restart only if a changed cell was read by the
  search so far (a changed cell adjacent to a settled node), which needs a per-cell touched
  stamp or a neighbourhood check of `workspace.state`; (b) finish the job on a snapshot of the
  table taken at admission and refresh afterwards (85 KB copy per admission, a route priced on
  danger up to one job-lifetime old); (c) LPA*-style local repair, which the design rejected as
  the primary planner. Each is a new policy.
- Hazard ETA staleness grows with job lifetime and, if the installed-route wipe is removed,
  with route lifetime (2.3).
- The equality check costs one copy and one compare of the table per cadence rebuild, well
  under the ~455 us refresh it sits next to; it is deterministic, but it is not allocation-free
  without a shared scratch buffer, and compare-as-you-write is not available until the two-pass
  hot-bit issue in section 5 item 1 is solved.
- Selection membership depends on the seat's own position (`selectNearestSources` anchored at
  `selfXy`), so with more than 8 confirmed threats a moving seat can flip membership and force
  a restart even with stationary enemies.
- Not measured: how many seats in real episodes have unchanged tables between cadences. A
  cheap follow-up is the "unchanged rebuild" counter in a first-light log line.

## 7. Codex's added candidate: identical-source reuse before the rebuild

Proposal (Codex, mid-review): before `selectDangerSources`, copy the seat's current
`selectedDangerCount` and ordered `selectedDangerPoints` to locals; after selection, if count
and ordered points are unchanged, refresh `dangerTick`, report "unchanged", and skip the raster
rebuild, the packed-weight rebuild and the generation bump. Motivation: on m5a at B = 1,024
the tick fails headroom at 6.06 ms with danger at 3.4 ms including 1.1 ms of weights (Codex's
numbers, not verified by me).

### 7.1 Verification of the premise
- The raster is a pure function of the ordered source points and immutable geometry.
  `rebuildDangerFromPoints` (423-455) reads only `sources`, `map`, `dangerKernel`,
  `dangerPerimeter`, `dangerRadius`, `dangerRangePx`, and the constants `DangerClosePx`,
  `DangerCloseFloor`, `DangerLosWeight`. The four seat fields are assigned once in the
  constructor (291-294) and never reassigned anywhere in `body_nav.nim`; `map` is the
  immutable `BodyMap`. It zeroes the raster first, so no state carries over between rebuilds.
- Order matters and Codex's "ordered" comparison is the right one: the LOS accumulation adds
  float32 contributions per source in source order (`+=` in `addVisibleCell`/`castRay` and at
  447-449), so the same set in a different order can differ in the last bit and pack
  differently. Comparing ordered points is exact; comparing sets would need a proof of
  order-independence that does not hold for float accumulation.
- The order itself depends on the seat's own position (`selectNearestSources` sorts by
  squared distance from `selfXy`, ties by seat, 485-507). A moving seat with stationary
  threats can therefore reorder the same 8 points and miss the reuse; correctness is
  unaffected, only the hit rate. In the `--latency` harness all 8 tracks sit in a 3 x 3 cluster
  at the far goal, so reordering as the seat approaches is likely; the hit rate there is an
  empirical question, not a given.
- Direct callers: `initializeDanger` (542, activation and the harness's corpus setup) and
  `rebuildScheduledDanger` (561, the cadence, called once per tick from `episode.nim:1498`);
  tests call `rebuildScheduledDanger` and `rebuildDanger` directly
  (`test_shell_body_seat.nim:225,237,265`, `nav_route_corpus_support.nim:204`). Correction
  (Codex): no "never built" sentinel is needed. `newBodyNavSystem` (283-299) constructs every
  seat with a zero raster from `initDanger` and, for route-enabled seats, sets
  `dangerGeneration = 1` and calls `rebuildPackedWeights` on that zero raster (296-299), so a
  fresh seat already holds the table for the empty selection, and an initial empty selection
  is a legitimate "unchanged" case.
- `dangerTick` is only consumed by `dangerFingerprint` (571-575), which has no consumer in
  `src` or `tests`; refreshing it on a skipped rebuild keeps that diagnostic identical to
  today. `recordDanger` (the trace ring) should still record the cadence event with a flag or
  the existing shape, so trace-based goldens stay stable; check `test_shell_body_seat` 225-270.
- No retained state or hash is added: the comparison uses stack locals; `selectedDangerPoints`
  and `selectedDangerCount` already exist on the seat.

### 7.2 Comparison with section 5's weight-equality candidate

| | Weight equality (section 5) | Identical-source reuse (Codex) |
|---|---|---|
| Skips the generation bump | yes | yes |
| Skips the packed-weight rebuild (~0.46 ms m6i, ~1.1 ms m5a) | no | yes |
| Skips the raster rebuild (~0.9-1.0 ms m6i, ~2.3 ms m5a) | no | yes |
| Catches changed sources with an unchanged table | yes | no |
| Cost of the check | one pass over the table | 8 point compares |
| Determinism | pure | pure |
| Retained state | a shared scratch copy of the table (or per-seat copy) until the two-pass issue is solved | none |

Identical-source reuse strictly dominates on cost when it hits, and it addresses both the
liveness symptom and the m5a headroom failure Codex reports. Weight equality catches a
different, rarer case. They could compose (sources-equal check first, table compare second),
but the table compare is not free of state or allocation as things stand (section 5 item 1),
so weight equality is not part of L0 and is parked until the hot-bit two-pass issue has a
clean solution.

### 7.3 Decision recorded (Codex, 2026-09-09)
Codex registers L0 as a prerequisite qualification fix: preserve the in-flight generation only
for exactly unchanged ordered source points, and keep the installed-route expiry on every
scheduled refresh so the existing zone-price refresh behaviour is not weakened. No claim of
general moving-threat liveness. Note for the implementation: the current wipe (472-474) is
keyed on a generation mismatch, so with the bump skipped the expiry has to be applied on the
cadence explicitly; and an expired route triggers a new request through `shouldQueryRoute`
(610), which is a new job, so a seat that just completed a far route will request again on the
next cadence while its table is unchanged; that keeps today's re-request cost and is the
trade Codex chose.

### 7.4 Contract position
Same as section 3: skipping work whose inputs are provably identical is inside the approved
rule, since the generation still advances whenever the danger state the search reads differs.
The installed-route wipe question (2.3, 3.1) applies to this candidate identically: skipping
the bump also skips the wipe, so either decouple the wipe or take the zone-freshness decision
to James. The m5a headroom claim is a qualification benefit and should be measured with the
prereg protocol on that host (interleaved parent and candidate, three fresh processes), not
asserted from the danger split.

### 7.5 Additional tests for this candidate
- Unit: same ordered sources on two consecutive cadence ticks: raster and table bitwise
  identical to a forced rebuild (compare against a fresh `rebuildDangerFromPoints` on a scratch
  seat), generation unchanged, `dangerTick` advanced, trace entry recorded.
- Unit: same set, different order: full rebuild taken (documents the conservative miss).
- Unit: empty selection on a fresh seat: table built once; empty again: skipped.
- Unit: source leaves and returns: rebuilt both times.
- Harness: `--tick` rows with the split, on m6i and m5a, interleaved parent/candidate; expect
  `weight_refresh_p95` and `danger_p95` to fall on rows whose sources are stationary and
  `pops_per_tick` unchanged; `--latency` far waves publish.
- Everything in section 5's list (corpus hash, suites, shapes, liveness laws, fixtures, GV,
  viewer, docs).

## 8. Review of the narrow L0 shape (Codex, final)

Shape as stated by Codex: public `rebuildDanger` and `initializeDanger` stay forced (always
rebuild); ordered-source reuse is applied only inside `rebuildScheduledDanger`; the existing
"rebuild from selected points" block is factored so its two callers share it; installed-route
expiry stays on every scheduled refresh; the in-flight generation is preserved only when the
ordered selected points are unchanged.

Assessment: this is the right narrowing.
- Scope: reuse lives on the one production cadence path (`episode.nim:1498`), so activation,
  the corpus support, the harness's `initializeDanger` and every direct test caller keep
  today's forced semantics; the corpus gate and its route hash cannot be affected by
  construction.
- Correctness: `selectDangerSources` still runs every cadence (it must, to produce the points
  to compare), and the compare is against the seat's own `selectedDangerPoints[0 ..< count]`
  copied to locals before selection. Ordered compare, count compare, then the factored rebuild
  block on a miss; on a hit refresh `dangerTick`, record the trace event, and skip
  `rebuildDangerFromPoints`, `rebuildPackedWeights` and the generation increment.
- Installed-route expiry: because the wipe at 472-474 is keyed on generation mismatch, the
  cadence path must clear the installed route explicitly on a hit as well as a miss, so the
  expiry cadence is unchanged in both cases. That keeps zone-price refresh exactly as today.
- Interaction to test: after a hit, the expired route causes a new request (610) while the
  seat's generation is unchanged; if that seat is the in-flight seat, the new request has a
  new `requestGeneration`, so `cancelStaleRouteJob` drops the job on the request-generation
  branch (776-779), not the danger branch. That is correct and today's behaviour, but it means
  a seat that is following a route and also has an in-flight job (possible only via the moving
  target or stuck paths) loses that job at expiry as before. Worth one explicit test so nobody
  reads the drop as a regression of L0.
- Determinism: pure; no clocks, no allocation on the hit path, no new retained state.
- Two things to keep out of L0: the weight-equality compare (parked, section 7.2) and any
  change to the expiry cadence.
- Tests: section 7.5 as written, minus the sentinel case, plus the expiry-with-in-flight case
  above and one that proves `initializeDanger` and direct `rebuildDanger` still rebuild on
  identical points.

Stopping here; no source edits.
