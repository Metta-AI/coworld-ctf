# Phase 10 plan: production cutover to resumable mixed-grid routing

Status: **PLANNING ONLY.** This document does not authorize production-code,
cap, fixture, viewer, or contract changes. Phase 10 must stop after the
measurement checkpoint below and wait for James to rule on the pop budget,
colossal memory policy, and cutover shape.

## Accepted candidate and fixed constraints

The implementation candidate is the measured R3.3/R4.4/R5 line:

- Precompute exact 4 px body legality.
- Mark the fine region from `danger > 0`, dilated by one 4 px cell, unioned
  with the static wall band.
- Use 4 px nodes in that region and 8 px anchors elsewhere. Contract exact
  cold chains; do not approximate or delete wall-hugging lanes.
- Use exact width-1 Dial search over integer Q8 costs.
- Keep one shared, stamped, resumable search workspace per episode.
- Admit work in stable shortest-job-first order and spend at most `B` pops per
  simulation tick across all seats.
- Keep production steering live while a request waits or is in flight.
- Restart work whose snapshotted danger generation is no longer current.

The route-quality gate remains exact: no missing route, no illegal waypoint,
and weighted-cost inflation p95 at most 0.5% and maximum at most 3.0% against
the 4 px exact oracle. Timing gates also remain unchanged. A benchmark result
does not itself authorize the cutover.

## P10.0: measurement-only ruling packet

This is the only work to do before James rules. It may change the measurement
harness and reports, but not `src/`, production tests, memory caps, fixtures,
or the committed viewer.

### Native B experiment

Run the SJF scheduler natively on the same fixed corpus and host protocol as
R5.1. The 18 rows are:

`{12,288 control; 16,384; 20,480} pops/tick x {16, 32 seats} x
{first-light, moving-goal, stuck-recovery}`.

For every row record:

- all 120 slice samples, plus slice p50/p95/max;
- total pops and completed/failed/restarted/cancelled requests;
- per-seat request-to-install route ticks, summarized p50/p95/max;
- oldest request age and maximum consecutive waiting ticks;
- stable seat completion order and a repeated-run equality check;
- steering work separately from search work, as calls and ns/tick;
- route-quality hashes and missing/illegal/inflation results, to prove budget
  and admission changes affect latency only.

Measure each configuration in a fresh process, in the established order and
repeat count, on an otherwise idle machine. Preserve raw TSV/JSON output and
the exact executable/source stamp in the Phase 10 report.

### Budget ruling rule

Recommend the largest of 16,384 and 20,480 whose native worst-row search slice
p95 is at most approximately 3.2 ms, while reporting its maximum rather than
hiding it. The 12,288 row is a control, not a preferred choice.

The current incumbent is 16,384. Existing R5.1 evidence has a worst native
SJF p95/max of 3.149209/3.388250 ms, so 20,480 must beat the stated boundary
before it can replace the incumbent. If 20,480 exceeds it, recommend 16,384.
If both exceed it on the controlled rerun, recommend neither and return to
James with the measurements; do not loosen the gate.

Also publish an inclusive upper-bound estimate by adding the measured nav
slice to Phase 9's worst-degree non-nav body-work p95/max for the matching
roster. Use both host series so the limitation is explicit:

| seats | Phase 9 native non-nav body p95/max | incumbent B=16k nav p95/max | additive p95/max |
|---:|---:|---:|---:|
| 16 | 3.909375 / 4.025084 ms | 3.098416 / 3.292166 ms | 7.007791 / 7.317250 ms |
| 32 | 7.885667 / 7.909458 ms | 3.149209 / 3.388250 ms | 11.034876 / 11.297708 ms |

The Phase 9 canonical series gives 4.787305/5.021593 ms at 16 seats and
6.592622/7.108034 ms at 32 seats after the same addition. These are deliberately
conservative sums from separate runs, not claims about an integrated body
tick. They show that passing the approximately 3.2 ms nav-slice screen is not
enough to claim the 5 ms production gate. The approved candidate must later
pass an integrated whole-body measurement; if it does not, lower `B` or reduce
measured work rather than relabeling the result.

### Mandatory stop and ruling packet

Write the B=16k/20k tables, raw artifact paths, proposed `B`, inclusive
estimate, and colossal recommendation below into `PHASE_10_REPORT.md`. Commit
only the harness/report checkpoint if the governing brief authorizes that
checkpoint. Then stop. James must explicitly rule on:

1. the production `B` (or a request for another budget);
2. the colossal memory option and cap;
3. whether the implementation below may begin.

## P10.1: production architecture after approval

### Module ownership

`src/shell/body_route_query.nim`

- Own the compact mixed graph, exact packed cost decoding, width-1 Dial
  workspace, resumable job state, bounded reconstruction scratch, and query
  outcome.
- Split the current synchronous query into `begin`, `spendPops`, and `finish`.
  One call to `spendPops` consumes no more than the passed budget and returns
  the exact number of settled pops.
- Never allocate or clear map-sized storage on a request or tick path. Stamps
  distinguish searches; wraparound performs one explicit reset outside the
  timed steady state and has a test.

`src/shell/body_nav.nim`

- Own bounded per-seat request, pending, installed-route, progress, and
  recovery state plus the stable SJF scheduler.
- `navigationWaypoint` submits or refreshes a request and immediately returns
  either the next point on a still-valid installed route or the existing
  production steering answer. It never runs an unbounded route query.
- Route completion installs atomically: reconstruction succeeds into shared
  scratch, the result fits the fixed seat buffer, and only then do descriptor,
  cursor, revision, and danger generation change together.

`src/shell/episode.nim`

- Call the shared scheduler exactly once per simulation tick, after body
  actions have submitted requests and after that tick's staggered danger
  rebuild has published its new generation.
- Give it the single episode-wide `B`; unused budget may serve later seats in
  the same tick but may not carry into a later tick.
- If danger changed, invalidate affected installed routes and cancel/requeue
  stale in-flight work before spending a pop. Bodies already steered during
  the action pass, so waiting remains covered that tick; completed work becomes
  visible on the next action pass.

`src/shell/body.nim`

- Keep behavior priority and actuator semantics unchanged.
- Replace direct dependence on legacy planning state with the bounded nav API:
  submit/refresh goal, ask for current route waypoint, and fall back to
  steering while pending.
- Preserve same-tick response to a living valid goal through steering; the
  pop-budgeted route is an optimization and obstacle-quality upgrade, not a
  reason to freeze.

### Exact bounded state

No seat owns a heap, map-sized score array, or dynamically growing route.
Define named fixed-capacity objects and pin their layout with `sizeof` tests:

- `BodyRouteRequestSnapshot`: start/goal body points, resolved start/goal fine
  nodes, movement profile id, goal revision, request tick, danger generation,
  blocked-cell snapshot, and admissible lower-bound estimate.
- `BodyPendingRoute`: one newest request, request generation, an explicit
  `idle`/`pending`/`inFlight` lifecycle value, first-wait tick, and replacement
  count. A new goal replaces the one pending slot; there is no unbounded queue
  per seat. The episode-wide job's seat id and this lifecycle must agree by
  assertion.
- `BodyRouteJob`: one episode-wide in-flight seat id plus request snapshot,
  Dial current distance/bucket cursor, open count, goal state, pop count, and
  cancellation generation. All map-sized arrays remain in the shared
  workspace.
- `BodyRouteSpan`: a fixed-width descriptor for either a shared contracted
  cold chain or a short explicit 4 px direction run. Use fixed integer ids,
  lengths, and offsets; do not store `seq[BodyPoint]` per seat.
- `BodyInstalledRoute`: fixed `BodyRouteSpanCap` array, length/cursor,
  start/goal legs, route revision, danger generation, and failure/progress
  fields. Reuse the current fixed 4,096-edge and 512-point leg bounds unless
  corpus and colossal proofs demonstrate that a different fixed bound is
  required. Overflow is a visible bounded failure followed by steering, never
  allocation.

Before production edits, the measurement harness must report the maximum span
count and start/goal leg length over every corpus query and a generated
worst-case colossal traversal. The implementation then adds compile-time
`sizeof` assertions and reports exact bytes for every type, per seat, for 16
and 32 seats. The allocation gate includes these buffers.

### Stable SJF and request lifecycle

At the scheduler point, build a bounded seat-id candidate array. Its ordering
key is:

1. estimated remaining pops from the static component/room and endpoint
   geometry;
2. original request tick;
3. seat id.

The key is snapshotted when admitted. Do not use wall time, hash iteration, or
mutable progress as a tie-break. A request already in flight remains active
until it completes, becomes stale, or reaches a separately specified bounded
failure condition; SJF chooses the next request, not a mid-search preemption
policy. Replaced goals collapse to the newest per-seat request.

The danger overlay has a monotonic generation. Requests and installed routes
carry it. A rebuild increments the generation only after all new per-seat
weights are ready. A mismatch cancels the in-flight job without installing a
partial result and queues a fresh snapshot. The shared stamp generation also
advances, so stale scores and parents cannot be observed.

### Retained hierarchy: hints, steering, and coverage

The hierarchy stops being the primary follower, but is not deleted wholesale.
Retain, until a separately measured replacement exists:

- room ids and room-to-side lists used to summarize safe ground;
- portal-side anchors, side graph arcs, and compact segment metadata needed by
  `BodySafeCache` and safety-distance hints;
- cell/component ids needed for cheap rejection, SJF estimates, and component
  coverage checks;
- pocket/fine-anchor endpoint attachment data not superseded by the mixed
  graph's own attachment tables;
- enough static legal-neighbor data for steering and route-leg validation.

Safety hints may choose a source/side using the retained side graph, but the
actual movement toward that target goes through the new installed route or
production steering. Coverage is proved once when the graph activates and in
the corpus gate; proof-only build scratch is released before steady state.

The first cut deletes exactly these two runtime-retained payloads once the
mixed graph owns reconstruction:

- `portalNext`: 14,159,361 bytes on the measured colossal row;
- flat segment `cells`: 1,340,938 `int32` entries = 5,363,752 bytes.

That is 19,523,113 bytes removed on colossal. Do not also delete
`localIndex`, `roomCells`, `segments`, side topology, pocket connectors, or
fine anchors in this cut: current safety hints and activation proofs still use
them. A later deletion requires a caller audit, an explicit replacement, and a
fresh byte/quality measurement. On smaller maps report the same two fields
from the runtime allocation counter rather than extrapolating.

### Shared graph and pool accounting

Precompute and retain:

- packed exact fine legality;
- static 8 px legal moves, room/component ids, and static wall-band bits;
- fine nodes only for the danger-plus-wall-band region;
- 8 px anchors for cold cells;
- compact cold-edge descriptors and their exact reconstructable chain data;
- per-seat packed `int16` Q8 danger weights when James selects that option;
- one shared dense stamped Dial workspace and bounded bucket storage;
- one shared bounded reconstruction buffer.

Activation must publish a byte ledger by field and fail before gameplay if the
approved cap is exceeded. Pool-map evidence from R5.3 is a useful floor, not a
substitute for measuring the final retained representation: fine legality
193,617 bytes, compact backbone 219,007, packed weights 85,466 bytes per seat
and 2,734,912 for 32 seats, and the measured dense workspace 4,130,496 bytes.
Those known fields total 7,278,032 before final cold-chain, Dial-bucket,
hierarchy-hint, and per-seat descriptor accounting. The corresponding `int32`
pool weight table is 170,932 bytes per seat and 5,469,824 for 32 seats.

## Colossal decision

The final activation artifact must measure the complete shape. The following
numbers are conservative known lower bounds, using the measured colossal
fine-node count, retaining the 7,186,432-byte hierarchy remainder after the
two deletions above, and excluding new Dial-bucket, contracted-chain,
reconstruction, and per-seat descriptor bytes:

| option | known components | lower bound | speed/quality consequence |
|---|---|---:|---|
| A. Raise cap, dense + `int32` weights | hierarchy remainder 7,186,432 + legality 1,752,192 + dense workspace 37,380,096 + weights 49,840,128 | 96,158,848 B (91.70 MiB) | Preserves dense exact search; largest memory shape. |
| B. Raise cap, dense + exact packed `int16` weights | hierarchy remainder 7,186,432 + legality 1,752,192 + dense workspace 37,380,096 + weights 24,920,064 | 71,238,784 B (67.94 MiB) | Preserves exact route costs after widened reconstruction arithmetic and dense throughput; saves 24,920,064 B. |
| C. Hierarchical-only above a lattice threshold | current hierarchy, without fine workspace/weights | within current cap | The production hierarchy's corpus proxy measured 19.910% p95 and 86.650% maximum cost inflation. It misses the 0.5%/3.0% gate despite zero missing/illegal routes. |

The compact fixed workspace tested in R5.3 fits colossal at 32,469,128 bytes,
but measured 779--1,129 ns/pop and 11.328--35.623 ms query latency; the R3.2
dense workspace measured 335--410 ns/pop, and the accepted dense Dial line was
faster again. Therefore compact hashing is not the production recommendation.

**Recommendation: option B.** It keeps the accepted exact quality and dense
throughput while halving the dominant per-seat weight pool. `int16` stores the
exact 15-bit Q8 danger value plus hot-region flag; addition and comparison widen
before arithmetic, so this is a representation change, not cost quantization.
Do not set a cap from the 71,238,784-byte lower bound. First measure the final
contracted chains, Dial buckets, descriptor pool, and allocator overhead, then
propose a cap rounded above that full observed total (80 MiB is only a planning
estimate, not an authorized value). If James will not raise the cap, option C
must be described as an explicit quality exception; it cannot be called a pass.

## P10.2: legacy deletion and cutover, only after approval

Make the production switch in one reviewable cutover commit after red tests and
the new path are ready. There must be no runtime feature flag or two planners
left in parallel.

- Move still-needed danger/profile definitions, then delete
  `src/shell/body_planner.nim`.
- Reduce `src/shell/body_cache.nim` to the duck cache. Delete route cache
  fields, route pins, route-distance peeks/minters, and route-cache constants.
- Delete legacy planner/mint jobs, schedulers, cursors, retry state, traces,
  events, `ColdPlanBudgetPerTick`, `runPlanningTick`, `prewarmColdPlans`, plan
  budget logging, `bnsStalePath`, and compatibility-only seams.
- Delete Phase 3--8 hierarchical FOLLOWING and its installed edge/start-leg/
  goal-leg follower state. The retained hierarchy is hints/coverage data only.
- Remove synchronous production calls to `queryBodyRoute`; only the episode's
  pop-budgeted scheduler may advance exact search.
- Delete tests that assert legacy cache/minter/scheduler mechanics. Retarget
  behavioral tests to request replacement, stable admission, budget exhaustion,
  resumability, danger restart, atomic install, steering during wait, fixed
  overflow, and progress/recovery behavior.
- Turn the Phase 9 corpus test into a production-path gate: instantiate the
  production graph and scheduler, drive it across ticks at the approved `B`,
  collect the installed production route, and compare with the same exact
  oracle and route hashes. Direct measurement-only solvers may remain only in
  scratch tooling, not `src/`.

Suggested local commit boundaries after approval:

1. red production scheduler/state tests;
2. compact graph + exact packed weights + resumable Dial implementation;
3. body/episode integration and steering coverage;
4. one legacy-deletion/cutover commit;
5. GameVersion, fixtures, viewer, contract docs, and final Phase 10 report.

Before every commit, update from `origin/main` as required by the repository,
preserve unrelated work, and run the documentation audit. Do not push or open a
PR without separate permission.

## Contract and documentation rewrite

Replace the old “no full-board search on a play tick” rule. The authoritative
contract must say:

> Body routes are pop-budgeted resumable searches over a precomputed legal
> mixed-resolution graph. Production steering supplies a legal moving command
> while a request waits, is restarted, or fails boundedly.

Document these invariants in the Season 2 shell design and its HTML twin:

- exact 4 px legality and exact Q8 cost semantics;
- 4 px hot/wall-band nodes plus reconstructable contracted 8 px cold chains;
- one shared stamped workspace and one episode-wide pop budget;
- stable SJF admission and its complete tie-break key;
- one pending request per seat and atomic bounded route installation;
- no map-sized allocation or clearing on query/tick paths;
- danger-generation restart before further pops;
- steering covers every wait/failure tick and live goals still affect motion
  immediately;
- hierarchy is retained only for safety hints, estimates, endpoint coverage,
  and activation proof, not primary following;
- overflow/cap failures are visible and bounded, never silent approximation;
- corpus quality and whole-body timing gates remain unchanged.

Prepare the equivalent Asana wording, but do not post or mutate Asana in this
task. The existing plan names `docs/designs/FIRST_LIGHT_DEMO.md`, but that file
is absent at the inspected HEAD; locate the current authoritative diagnostic
section before editing rather than creating a guessed replacement. Update the
actual design Markdown and generated HTML together.

## Version, fixture, viewer, and final qualification

The cutover changes gameplay and replay behavior. After approval and only when
the production path is complete:

1. Fetch `origin`, merge/rebase safely, scan all remote GameVersion claims,
   choose the next unused value, add a prepend-only `GVnn (...)` headline, and
   run `tools/ci/check_gameversion.sh origin/main`.
2. Re-record all nine fixtures from their documented recipes on an idle
   machine: capture, wipe, draw, seats-16, main CTF replay, gen-small-pits,
   gen-colossal-4team, BR golden, and BR zone-paint smoke. Verify semantic beats
   and update only assertions whose new result is real.
3. Rebuild the committed replay viewer because `src/*.nim` changed, and run its
   source-stamp and replay smokes.
4. Update the Season 2 design Markdown/HTML, navigation diagnostics/reference,
   test documentation, and any config documentation actually affected. This
   change does not alter a `GameConfig`, mapgen override, or envelope constant,
   so `docs/ENV_VARIATION.md` should remain unchanged unless the implementation
   proves otherwise.
5. Rerun the Phase 9 canonical corpus through the production scheduler and
   compare route hashes, missing/illegal counts, p95/max inflation, activation
   bytes, and body timing to the frozen baseline.

Phase 11 qualification remains the final gate: runtime-linked and runtime-stub
`src/ctf.nim` checks with the sanctioned toolchain, focused body-nav and rework
tests, full native suite/shards, GameVersion check, module QA, Docker viewer
build/staleness checks, and every committed replay smoke. Record commands,
environment, commit, CLI/tool versions when relevant, timings, and raw artifact
paths. A partial green run is not a clean qualification.

## Acceptance and stop conditions

Phase 10 is ready for Phase 11 only when all of the following are true:

- James has ruled on `B`, colossal policy/cap, and implementation authority;
- production spends no more than `B` exact pops per episode tick;
- stable SJF, fixed state, danger restart, and wait steering are directly
  tested;
- no legacy cache/minter/planner or hierarchical primary follower remains;
- the production-path corpus passes every unchanged quality gate;
- integrated whole-body timing passes rather than relying on additive estimates;
- approved memory caps include the measured complete allocation ledger;
- GameVersion, all nine fixtures, viewer, design contract, and reports agree.

Until James gives the ruling requested by P10.0, make no production change.
