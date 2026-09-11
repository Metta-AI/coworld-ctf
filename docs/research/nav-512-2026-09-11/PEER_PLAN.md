# Peer Phase 1 plan: 512 pooled units without slowing the game

Peer tree `nav-512-peer` at `6b6b3408`. Read-only phase; no source changed.
Inputs: BRIEF.md, AGENTS.md, the budget screen report and its raw archive,
the runtime-benefits report, the archived loop under
`docs/designs/nav-rework-evidence-2026-09-09`, the four planner sources, the
root's P0 Fluffy traces (`P0/RESULT.md`, both `.json.gz`), `H1_PROPOSAL.md`,
`LITERATURE.md`, `LOOP.md`, `PEER_STEER.md`. All numbers below come from
those files or from scripts run over the raw archive; nothing is estimated
unless labelled so.

## 1. Where the time goes (evidence, not opinion)

### 1.1 Whole-game accounting from the saved screen (32 seats, repeat 1)

Sums over the 1,200 measured frames of each raw `server.log`
(`BUDGET_FRAME`, `BUDGET_SHELL`, and the 24-tick `SHELL_TIMING` windows).
Repeat 2 matches to within 0.5 % on every column.

| Budget | Frame sum (s) | Shell sum (s) | planning_us sum (s) | ladder (s) | reflex (s) | danger (s) | frames > 41.667 ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 31.13 | 22.58 | 7.99 | 2.25 | 10.16 | 0.85 | 103 |
| 512 | 34.68 | 25.27 | 10.75 | 2.29 | 10.12 | 0.80 | 186 |
| 1024 | 33.63 | 25.11 | 11.29 | 2.20 | 9.57 | 0.77 | 194 |

16 seats: 15.54 s (256) vs 16.26 s (512); planning 3.44 s vs 4.07 s.

So at 32 seats the 512 delta is +3.55 s of frame time, of which +2.76 s is
the planning stage and about +0.8 s is everything else (more cogs moving
means more sim, output and ladder work). The objective "512 costs no more
than 256" therefore means: planning at 512 must come in about 0.8 s *below*
today's 7.99 s, i.e. ~7.2 s, unless the non-planning delta is also
addressed.

### 1.2 The root's P0 Fluffy split, re-derived from the traces

`nav.fieldMint` and `nav.astarPlan` are nested inside `shell.planning`.

| Scope | 256 total (s) | 512 total (s) | Delta (s) | calls 256 / 512 |
|---|---:|---:|---:|---:|
| nav.astarPlan (stepPlan) | 4.29 | 5.04 | +0.75 | 357 / 290 |
| nav.fieldMint (stepMint) | 3.63 | 5.62 | +1.99 | 1,118 / 886 |
| shell.planning | 7.95 | 10.73 | +2.78 | |
| shell.reflex | 10.38 | 10.27 | -0.11 | 28,926 |
| shell.ladder | 2.39 | 2.42 | +0.02 | max call 244 / 255 ms |

Per-frame attribution from the same traces: frames containing mint work
number 1,118 (256) and 886 (512); mint time per such frame p50/p95/max =
0.16 / 8.14 / 8.58 ms at 256 and 0.30 / 16.2 / 17.0 ms at 512. A* frames
number 234 / 180; A* per frame p95/max = 40.5 / 42.3 ms at 256 and
79.8 / 84.7 ms at 512.

**The minter is elastic.** `runPlanningWork` hands the minter whatever the
plan pass leaves (`src/shell/body_nav.nim:625-644`), and a mint of one field
on the 3211x1713 practice map costs 85,814 clear units (one per raster cell,
`src/shell/body_planner.nim:519-522`, `src/shell/body_cache.nim:156-165`)
plus up to 85,814 Dijkstra pops. On the ~80 % of ticks with no pending plan
the minter therefore spends the *entire* pool: 8,192 units at 256, 16,384 at
512. Doubling the pool doubles mint spend per quiet tick (8.1 -> 16.2 ms
p95 above) until the mint queue drains. That is why the mint arm carries
most of the 512 regression even though a mint unit is cheap.

### 1.3 Cost per unit, calibrated on the real server

- **A\* units ~5 us each.** Ticks 32-39 of the 256/32 run have exactly one
  seat consuming the full 8,192-unit pool each tick (`SHELL_PLAN_BUDGET
  ... units=8192`), and `BUDGET_SHELL` for those ticks is 42-46 ms against
  4-5 ms on the surrounding quiet ticks. The tick-48 `SHELL_TIMING` window
  (406 ms planning over ~73.7k units) gives 5.5 us/unit. The P0 trace agrees:
  stepPlan max call 42.3 ms at 8,192 units.
- **Mint units ~0.35-0.45 us each (mixed clear + pop).** In 256/32 windows
  with zero plan events, `planning_us` is 2.8-4.9 ms per tick for 8,192
  mint units. P0: full-pool stepMint calls of 8.0-8.6 ms at 8,192 units
  are the pop-heavy phase (~1 us per pop); clear-phase calls are ~0.16 ms.
- So A* units are 10-15x more expensive than mint units, and the archived
  figures of 30-60 ns and 394 ns per expansion (`docs/reports/body-lane-gate-report-2026-08-31.md:62`,
  archive `CAMPAIGN_P9B_REDIRECT3.md:4`) were measured on small or cached
  workloads. On this map the per-pop cost is dominated by memory traffic
  (see 2.1). The module comment at `src/shell/body_nav.nim:20-21` ("~8k
  units, a few milliseconds") is off by an order of magnitude and should be
  corrected when the planner is next touched.

### 1.4 Ticks 362 and 1082

Both are synchronized `edge_ride` replans: at tick 362 twenty-five seats
receive a new `navigate_to` standing order in the same tick (`SHELL_INSTALL`
lines), pending plans jump from 0 to 23, and stale/no-path seats to 14/10.
Composition of the 256/32 tick-362 shell step (285 ms):

- ladder stage (the play invocation burst): ~245 ms, budget-independent
  (`SHELL_TIMING` window 384: ladder 328 ms vs 49 ms in the previous window;
  P0 ladder max call 244 ms at both budgets).
- planning: the pool, 8,192 A* units, ~40 ms. At 512 this becomes ~80 ms
  and at 1024 ~130 ms, which is exactly the observed 293 -> 341 -> 393 ms.

Tick 1082 has the same shape (12-14 seats replan, ladder ~100 ms). Ticks
2-3 are play `init` (ladder 285 ms in the first window). **No planner change
can move the frame maximum below ~250 ms at 32 seats; the maxima gate must
be stated on the planning contribution or on frames excluding the ladder
burst, or it will fail for reasons outside this brief.**

### 1.5 Work thrown away at 256

Grouping `SHELL_PLAN_BUDGET` events by (seat, revision): at 256/32 seats,
17 of the 35 plans that were ever suspended never resolved (cancelled by a
newer order), and their visits account for 249k of 595k event units (42 %);
at 256/16 it is 52 %. At 512/32 it is 3 %. Suspended-plan completion latency
p50/max is 5/9 ticks at 256 and 3/7 at 512. This is why total A* time rises
only 17 % when the pool doubles: much of 256's A* work is wasted, and 512
finishes plans before they are cancelled. (First-visit completions emit no
event, so these are lower bounds.)

### 1.6 Out of scope but larger than planning

`shell.reflex` is 10.3 s per 32-seat game at either budget, 30 % more than
all planning. It is not part of this brief; it is the biggest single lever
on whole-game time and the root should know that before any whole-game
gate is set.

## 2. Ranked bottlenecks inside the planner (code-level)

### 2.1 A\* pop (`advanceAstar`, `src/shell/body_planner.nim:584-636`)

Per pop, eight neighbours each do: bounds + `canStand` (`body_map.nim:217`),
`segmentClear` (a 4-px Bresenham with up to 8 more `canStand` calls,
`body_planner.nim:298-329`), `ensureRecord` (`:235-250`), `closed`/`gScore`
reads, `danger.sample` (`:134`), `heuristic` (`:546-552`, which calls
`peekRouteDistance`, `body_cache.nim:193-207`: a 4-slot scan,
`nearestWalkable`, a float classify and an LRU clock write), then
`pushOrDecrease` (`:183-199`).

Ranked by likely share of the ~5 us, with the reasoning stated:

1. **Sparse hash record lookup.** `hashKeys`/`hashRecords`/`hashGeneration`
   are three separate `int64` arrays of `nextPowerOfTwo(2 x 344,487)` =
   1,048,576 slots (`:260-266`): 25 MB per seat, probed at a multiplicative
   hash of the lattice index, i.e. three unrelated cache lines per neighbour.
   The host has 512 KiB L2 per core and 16 MiB L3 per die (raw archive
   `machine.txt`). Eight neighbours x three misses is the single largest
   plausible term. Inference, not yet measured.
2. **Fixed heap traffic.** `HeapNode` is 40 bytes (`:33-36`); every sift
   level swaps two nodes and writes two `positions` and two
   `positionGeneration` entries at random `item` indices (`:150-181`). With
   frontiers of tens of thousands of nodes, each push/pop walks ~15 levels.
   This is the mechanism the root's H1 targets; it is shared with the
   minter.
3. **Segment legality recomputation.** For the primary step (4 px) the eight
   `segmentClear` results per lattice node depend only on the immutable map,
   yet are recomputed on every expansion. ~50-70 `canStand` calls per pop.
4. **Heuristic side work.** `peekRouteDistance` per neighbour: `routeKey`
   (two divisions), 4-slot scan, `nearestWalkable`, classify, clock bump.
5. **Call overhead.** Production builds use `-d:release --opt:speed
   --stackTrace:on` (`docs/reports/nav-budget-screen-2026-09-11/build_native.sh:14`).
   With stack traces on, every non-inlined helper (`canStand`,
   `clearanceAt`, `inBounds`, `cellWalkable`, `routeDistanceAt`,
   `nodeLess`...) pushes and pops a frame. At 50-80 helper calls per pop this
   is plausibly 0.3-0.6 us. Unmeasured.

### 2.2 Mint pop (`advanceMintSearch`, `:454-486`)

Cheap per unit but numerous: eight `cellWalkable` triples, one
`routeDistanceAt`, one `setRouteDistance`, one `pushOrDecrease` on the
shared 85,814-slot `FixedHeap`. The heap is the only non-trivial term, so
items 2 and 5 above are the only exact levers here; item 1, 3, 4 do not
apply. The clear phase (one store per unit) cannot be made meaningfully
faster per unit; its cost is purely that it consumes budget.

### 2.3 Connector and endpoint scans

Normally a handful of units. Pathological case: `initConnector` sets
`maxRing = max(latticeW, latticeH)` (`:390`), so a start or goal with no
straight-line-reachable lattice node can charge up to the whole lattice
(344k units at 1 unit per ring cell) before falling back to a finer step.
Not seen in the logs (53 of 67 suspended visits spent exactly the full
pool, consistent with long A*), but a qualification corpus should include
a pocketed start to confirm it stays bounded.

### 2.4 Memory per seat on the practice map (computed from constructors)

Capacity = max(85,814 cells, 803x429 = 344,487 lattice nodes) = 344,487.
Heap: nodes 13.8 MB + positions 2.8 + positionGeneration 2.8 = 19.3 MB.
Search: hash 25.2 MB + keys 2.8 + closed 0.3 + gScore 2.8 + cameFrom 2.8 =
33.8 MB. Result path 5.5 MB; follower path buffer 5.5 MB
(`body_nav.nim:242`); route slots 4 x 85,814 x 9 B = 3.1 MB; danger 0.4 MB.
About 68 MB per seat, 2.2 GB at 32 seats; the archive's "~68 MB per seat"
(`DRAFT_DESIGN.md:105`) agrees. The exact optimizations below *reduce* this
(E1 -22 MB, E2 -10 MB per seat); no cap growth is needed for them. There is
no gate today that asserts planner memory; only the validator tables
(256 MiB, `types.nim:465`) and the viewer are capped.

## 3. Candidate optimizations

All "exact" candidates below must leave unchanged: every emitted path,
every per-visit `workUnits`/`astarExpansions`/`expansions` count, the heap
contents and order, `jobFingerprint`/`mintFingerprint`/`routeStateFingerprint`
at every suspension boundary, and the fixed allocation sizes' semantics.

### 3.1 Exact-preserving, shared by A\* and minter

- **H1 (root's proposal): hole-based sifting.** Hold the displaced node, move
  one child/parent per level, write once at the final position. Halves node
  stores and position writes per level. Same comparator, arity, tie
  decisions. Assessment: correct and safe; the largest exact lever for the
  minter, because the minter pop is heap-dominated. For A* the heap is one
  of three big terms, so H1 alone will not reach the A* target. Expected
  gain on mint pops: material but unmeasured; the archive measured a
  decrease-key heap at 240 ns vs lazy at 112 ns per op
  (`P9B_REPORT.md:167-183`), which bounds what heap work can cost per pop.
- **E2: slim the heap and position maps.** `tie1`, `tie2`, `item` fit
  `int32`; `positions` fit `int32`; `positionGeneration` can be `uint32`
  (generation is per search, it will not wrap in a game). Node 40 -> 32 B
  (or 24 B if `cost` is stored as-is and ties packed), position maps halve.
  Comparator and values unchanged, so exact. Reduces the bytes every sift
  level touches; complements H1. Memory -10 MB per seat.
- **S0: `{.push stackTrace: off.}` (and `{.inline.}`) on the hot helpers in
  `body_map`, `body_cache`, `body_planner`.** Zero semantic change, keeps
  bound checks. Cheapest experiment available; should be run as its own
  card because it may be a large fraction of both arms.

### 3.2 Exact-preserving, A\* only

- **E1: direct-indexed record map instead of the open-addressed hash.**
  Keys are lattice indices < latticeW x latticeH. A `seq[int32]` record
  index plus a `seq[uint32]` generation stamp sized to the primary lattice
  (2.8 MB, L2/L3-resident for a typical frontier) replaces 25 MB of hash.
  Record numbers are assigned in the same call order so `keys[]`, `closed[]`,
  `gScore[]`, `cameFrom[]` and the fingerprints are identical. Fallback
  steps (2 px, 1 px) have larger lattices; keep the hash for those or size
  the direct map for step 2 and hash only step 1. Expected: the largest
  single A* win if the cache-miss inference in 2.1 holds.
- **E4: precomputed 8-bit segment-legality mask per primary lattice node.**
  Depends only on the immutable map, so compute at activation (344 KB,
  shared across seats, ~2.7 M `segmentClear` calls once). Replaces the
  neighbour `canStand` + `segmentClear` pair at step 4; fallback steps keep
  the live check. This is the "static legality caching" the root named.
- **E3: hoist heuristic side work per visit.** Resolve the goal's route-slot
  index once per `stepPlan` call (mints cannot run inside a visit), keep the
  per-call LRU clock bump so `routeStateFingerprint` stays identical, hoist
  `planCostProfile(job.profile)` and `latticePoint(targetIndex)`.

### 3.3 Not exact, listed so they are not rediscovered

- **Mint budget cap.** Give the minter `min(leftover, 256 x seats)` while
  plans get 512 x seats. Keeps today's mint spend per quiet tick, gives A*
  the doubling. Changes when fields become ready (heuristic strength, hence
  pop counts and equal-cost tie-breaks), so it is a design decision for
  James, not an optimization. It is the only proposal that removes the
  +2.0 s mint term structurally; see section 5.
- **Shared route fields across seats.** Fields depend only on map and goal
  cell; duo partners request identical goals (tick 362 shows paired
  identical `navigate_to` points). A server-wide slot table would halve mint
  work. Same caveat: readiness timing changes.
- **Mint clear re-pricing** (e.g. 64 cells per unit), goal-changed mint
  cancellation avoidance, lattice step 8, weighted JPS
  (`LITERATURE.md`), heuristic changes (archive H1). All change routes,
  counts or both.

## 4. Recommendation for the first experiment

Take the root's **H1 as experiment 1**, on the grounds in 1.2: the mint arm
is the larger part of the 512 regression, its pop is heap-dominated, and H1
is shared. Two amendments:

1. Pre-register **E2 as experiment 2 on the same heap** rather than folding
   it into H1, so the trace tells us whether write count (H1) or bytes per
   level (E2) is the binding term. If the root prefers one card, H1 first,
   E2 immediately after, both against the same oracle.
2. Run **S0 as experiment 3** before E1/E4. It is a one-line pragma change,
   exact by construction, and if it is worth 10 % or more it changes the
   baseline every later card is measured against. It must be its own card
   because it affects everything.

Then E1, then E4, then E3, in that order, each as one card. E1 before E4
because the cache-miss term is the larger inferred cost and E1 also frees
22 MB per seat.

Arithmetic the loop has to close (32 seats, from 1.1 and 1.2): plain 512
needs planning to fall from 10.73 s to about 7.2 s, i.e. a combined 1.5x
per-unit speedup on the mixed workload, with the mint arm needing ~1.55x on
its own if the pool stays a single elastic budget. I do not expect
H1+E2+S0 to deliver 1.55x on mint pops alone, because clear units are
already ~free and the pop's non-heap work is small; so the honest
expectation is that exact optimizations get A* comfortably under target and
leave a mint residual. That residual is where the mint-cap decision (3.3)
belongs, and the loop should surface it to James with numbers rather than
try to optimize past it.

## 5. Challenges to the objective and to root assumptions

- **"512 pooled units costs no more than 256" is under-specified while the
  minter is elastic.** Plain 512 doubles mint spend by construction. Either
  the gate accepts that the minter is capped separately (a behaviour change
  to be ratified), or the exact program must make mint pops ~1.55x faster,
  which is an unusually high bar for heap micro-optimizations. Decide this
  before candidate timings, not after.
- **The frame maximum is a ladder number.** ~245 ms of the worst frame is
  play invocation at both budgets (1.4). A maxima gate on whole frames will
  fail every candidate for reasons outside the planner. Gate maxima on
  `shell.planning` per tick and on whole frames with the ladder burst ticks
  reported separately.
- **The baseline wastes 42-52 % of its suspended A* units on cancelled
  plans** (1.5). "No more time than 256" therefore rewards a baseline that
  throws work away. Report units wasted alongside time so a faster
  candidate that finishes more plans is not penalized for the sim work its
  moving cogs then cause.
- **Reflex is bigger than planning** (1.6). Any whole-game promise should say
  so.
- **`tools/bench_body_port.nim --case planning` is broken** (asserts
  `spent != ColdPlanBudgetPerTick` against the per-seat pool at `:634`,
  `:660`), so there is no working real-budget planning bench today. The
  offline replay bench in 6.2 replaces it for this campaign.

## 6. Paired criterion, corpus, and separating profiling from qualification

### 6.1 Acceptance comparison (candidate512 vs baseline256), per configuration

Paired by (map, seed, seat count, gun range, play, run order); two process
repeats each; native m5a, all server threads on one pinned core as in the
screen; production Nim 2.2.4 and flags; unprofiled binaries only. Report,
per pair, with the raw records retained:

| Measure | Rule |
|---|---|
| Whole-game frame time sum (ticks 1-1200) | candidate512 <= baseline256, no margin credit |
| Frame p50, p95 | candidate <= baseline |
| Frame maximum | reported; gated on `shell.planning` max per tick (candidate <= baseline) and on whole-frame max excluding ticks whose ladder stage exceeds 50 ms, with those ticks listed |
| Deadline misses (frames > 41.667 ms) | candidate <= baseline; descriptive, as in the screen |
| Navigation wait | pending seat-ticks, no-path seat-ticks, stale seat-ticks: candidate <= 512-screen values (87 / 42 at 32 seats) |
| Route latency | ticks from `replacePlan` to `installCompletedPath`, p50/p95/max, from a new always-on per-plan record (first-visit completions included) |
| Legality | every installed path segment passes `canStand` + `segmentClear`, asserted offline over every path the game installed |
| Determinism | two repeats produce identical nav counters and identical `gameHash`; at equal budget, candidate and baseline produce identical paths and unit counts |
| Memory | per-seat planner allocation bytes computed from constructors, candidate <= baseline |

Never call a median win a success while p95, max, or wait regress.

### 6.2 Exactness harness (before any timing)

Copy the current `body_planner.nim` heap and search code into
`tests/body_planner_reference.nim` exactly as `tests/body_danger_reference.nim`
does for danger, and add `tests/test_shell_body_planner_exact.nim` that runs
reference and candidate side by side and compares, after every `stepPlan`
and `stepMint` visit: `jobFingerprint` / `mintFingerprint` /
`routeStateFingerprint`, the full heap node array and positions, and the
final `pathSnapshot`. Inputs: the BR golden map and at least two generated
maps of different sizes; random start/goal pairs including snapped starts,
pocketed starts (connector fallback), avoid points, all three cost
profiles, seeded danger fields; budgets 1, 7, 256, 8,192 and 16,384 so
every charged arm suspends at least once. Also an offline **replay bench**:
record the sequence of `replacePlan` requests and danger fingerprints from a
baseline game, replay them through the planner alone at a fixed budget, and
report ns per A* unit and per mint unit. This isolates per-unit cost (what
an optimization changes) from workload (what the budget changes).

### 6.3 Corpus breadth

At least: practice map br-gen-4242 (3211x1713) and the golden 4248 map;
two further brpool seeds including the largest non-colossal generator
output; 16 and 32 seats; gun ranges 331, 497 and 1050 (danger cost, not
planner cost, but it changes routes); `edge_ride` plus one play that moves
its goal every 12 ticks (`PlanMovingReplanTicks`) to exercise cancellation,
and one carrier/hunter profile play. One colossal map for memory only.

### 6.4 Keeping profiling out of qualification

Fluffy builds (`-d:ProfileTracePath`) are attribution only, as `LOOP.md`
already states: same-budget profiled vs unprofiled counters must match, but
no timing from a profiled binary enters a gate. Qualification uses the
two-timer measurement patch from the screen (`server.patch`) plus one new
per-tick line with plan units, mint units and A* pops (exact counters, no
clocks) so "measure both" is satisfied without markers. Compile outside the
timed interval; keep source hashes and compiler versions beside results.

## 7. Documentation and code mismatches found

- `src/shell/body_nav.nim:20-21`: "~8k units, a few milliseconds" vs ~40 ms
  measured. Fix when the planner is next edited.
- `tools/bench_body_port.nim:634,660`: stale single-seat budget asserts.
- Archive `HANDOFF_NAV_POPS_RESEARCH.md:51` still carries the retracted
  "~1 ms per request" figure (corrected in `PHASE_10_REPORT.md:35-40`).
- The park report lives at `docs/designs/nav-research-park-2026-09-10.md`,
  not under `docs/reports/`.

## 8. Unresolved

- The split of A* pop time between hash misses, heap traffic, legality and
  call overhead is inferred (2.1), not measured. Experiments 1-3 will
  resolve the heap and call-overhead terms; a `perf stat` cache-miss count
  on the replay bench would settle E1 before it is built.
- How much mint work is wasted by `enqueueMint` cancellation and by
  duplicate per-seat fields for shared goals is not observable in any
  existing log (mint traces have capacity 0 in production). The new counter
  line in 6.4 should include mint cancellations and duplicate-goal mints.
- Whether production hosts match the m5a single-core screen remains open,
  as the root's ledger records.

PHASE 1 READY
