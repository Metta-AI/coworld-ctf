# Shell step parallelism

Status: proposed design, not implemented

Date: 2026-09-07

Evidence commit: `f374a18b2cffa6b1106c5ac3d81fd248018f378d`

## Decision summary

Keep the shell serial by default and make the first implementation candidate
per-seat play stepping (candidate B), behind a server-only
`SHELL_STEP_WORKERS` setting whose default is `0`. A non-zero value creates a
small persistent worker pool for episode work; it is set from the game
container's CPU request, not from the machine's visible CPU count. Do not begin
that implementation until the [profiling task](https://app.asana.com/0/0/1218193498086008/f/)
has measured guest steps and shown that they are a material part of the tick.

Before the [navigation rework](https://app.asana.com/0/0/1218165906459726/f/),
candidate A's total available saving is only the provisional 0.883 ms body
baseline. After that rework moves bounded route queries into each body tick,
remeasure and expect candidate A to become the second useful worker stage.
Candidate C comes last, and only if the new profile still finds input building
material: belief is already folded once and guest views are already lazy.

This changes a ratified rule, not an accidental implementation detail. The
Season 2 design currently requires the whole per-seat pipeline to run on the
tick thread in seat order and names compilation as its only asynchronous work
(`docs/designs/strategy-play-calling-shell-2026-08-29.md:2332-2347`). Any
implementation approved from this document must amend that rule explicitly.

The non-negotiable result is **byte-identical mask streams and identical
annotation order versus serial execution**. Parallelism changes only how the
same tick result is calculated. It changes no game rule, replay format, wire
contract, schema, ABI, or entrant-visible behavior, so it must not bump
`GameVersion` or re-record fixtures.

## Current pipeline and shared-state map

`ShellEpisode.step` still has seven useful stages. The current result is a
set of ordered sequences plus timing counters (`src/shell/episode.nim:163-177`).
The table lists every read or write outside the current seat's own `SeatBody`,
`BodyNavSeat`, `LadderSeat`, or `ReflexSeatState`. “Seat-local” means that two
jobs may mutate different indexed elements but never the container or another
seat's element.

| Stage | State outside the seat | Access and ordering consequence | Classification |
|---|---|---|---|
| 1. Compile-plane progress | `runtimeState.lastCompileTick`; compile-plane task/result queues, cache, commit cursors; episode `bindings`; `result.moduleStatuses` | Begins the compile tick, polls two existing workers, commits ready modules under the cap, extends bindings, then appends statuses (`src/shell/episode.nim:739-768`, `src/shell/episode.nim:1167-1178`, `src/shell/compile_plane.nim:625-635`). Commit order is shared state. | Shared write; serial |
| 2. Lifecycle and belief | Frame slots; the episode's seat collection and activation count; `BodyNavSystem.seats`; result annotations, installs, and `runtimeNanoseconds` | Death and activation create/drop bodies, toggle one nav seat, and append lifecycle records. Active bodies then update belief once (`src/shell/episode.nim:1038-1077`, `src/shell/episode.nim:1180-1212`). Activation count and ordered result sequences are shared. | Shared fold plus seat-local writes; serial initially |
| 3. Per-seat ladder inputs | Frame slots and self-position table; immutable map, mode, roster, gun range, and view interval; the temporary `inputs` array | Each live seat computes default/reflex decisions, binary context, and scalar guard facts into its indexed input (`src/shell/episode.nim:1214-1263`). Guard closures capture already-computed scalar values, not a `SeatBody` ref (`src/shell/episode.nim:568-637`). Guest view bytes are not built here. | Read-only episode data plus seat-local writes; candidate C |
| 4. Play-list tick | Ladder `nextInitSeat`; bindings; shared `RuntimeEngine`, epoch ticker, and pooling allocator; result `runtimeNanoseconds` | Initialization/retune grants mutate the persisted global cursor and remain serial (`src/shell/ladder.nim:510-544`). Thereafter each `stepSeat` touches one ladder seat and its Stores, but the current loop is index-ordered (`src/shell/ladder.nim:578-711`). | Shared init, then seat-local writes; candidate B after init |
| 5. Standing-order install | Ladder output; result logs, statuses, retunes, annotations, and installs | The tick thread folds ladder rows in seat order, turns faults into annotations, installs changed orders, and appends the public sequences (`src/shell/episode.nim:1265-1303`). Installing an order mutates only that body's nav seat, but output order is observable. | Shared ordered fold; serial |
| 6. Body action | Immutable map; one indexed nav seat; ladder snapshots and roster-to-team table for pact declarations; result masks, handoffs, pact declarations, nav/combat census, and `bodyNanoseconds` | `actFromBelief` reads the map/range and mutates only the body and its own nav seat (`src/shell/body.nim:1302-1390`). The current loop then appends all results and reads ladder snapshots for pact declarations (`src/shell/episode.nim:1305-1361`). | Seat-local action plus shared ordered fold; candidate A for action only |
| 7. Danger and planning | All bodies' tracks; `BodyNavSystem.minter`, `lastPlanSeat`, `lastMintSeat`, trace rings, and `planBudgetEvents`; result planning/nav fields | Danger inputs read every active body's tracks; one scheduled nav seat is rebuilt. The pooled planner and single minter advance persisted cursors (`src/shell/episode.nim:1099-1105`, `src/shell/episode.nim:1362-1365`, `src/shell/body_nav.nim:132-145`, `src/shell/body_nav.nim:572-628`). | Shared, order-dependent write; serial |

The map itself is immutable after construction (`src/shell/body_map.nim:1-5`).
`ShellRuntimeState` contains per-seat frame, position, reflex, and log-window
slots plus one compile tick marker (`src/shell/episode.nim:199-204`). The
runtime owns one Engine and ticker while every runtime instance owns a separate
Store (`src/shell/runtime.nim:40-61`). These ownership boundaries are the
reason per-seat work is possible; the ordered folds are the reason worker jobs
must not append directly to a tick result.

## Candidate A: body action per seat

### Boundary

Run only `actFromBelief` on workers. Belief folding stays in the serial
lifecycle stage; the current episode already calls `updateBelief` once and then
calls `actFromBelief`, rather than the compatibility `seatTick` wrapper
(`src/shell/episode.nim:1200-1207`, `src/shell/episode.nim:1327-1334`,
`src/shell/body.nim:1392-1396`). This records the already-merged belief-once
change and does not count it as a future gain.

The action method mutates the seat's body and `body.nav.seats[seatIndex]`. Route
requests call `navigationWaypoint` and `replacePlan`, which update only that nav
seat and read the shared map (`src/shell/body.nim:1328-1346`,
`src/shell/body_nav.nim:516-529`, `src/shell/body_nav.nim:719-762`). Live
weapon range is also an indexed nav-seat read (`src/shell/body.nim:1348-1357`).
It does not advance the shared planner or danger scheduler.

### Result fold and invariant

Allocate one stable slot per configured seat when the episode starts. A worker
writes only `{mask, navState, combatOutcome, completed, errorCode,
fixedErrorText}` in its slot.
After the barrier, the tick thread walks the existing episode seat order and:

1. appends the mask;
2. updates the nav/combat census;
3. derives handoff and pact declarations using the standing order, ladder, and
   roster on the tick thread; and
4. appends nothing for absent seats, exactly as today.

Keeping pact lookup out of the worker matters because it reads ladder snapshots
and creates managed sequences (`src/shell/episode.nim:1344-1359`). The fold
must reproduce the serial byte stream, including mask order and every result
sequence. Pre-sized slots are reused; the worker stage introduces no per-tick
queue or result allocation.

The existing body-order proof covers only two seats
(`tests/test_shell_body_seat.nim:634-667`). The 32-seat permutation tests cover
danger and pooled planning, not body action (`tests/test_shell_body_nav.nim:443-463`,
`tests/test_shell_body_nav.nim:825-859`). Implementation therefore requires a
new 32-seat body-action permutation test comparing masks, paths, nav outcomes,
and combat outcomes across serial, reversed, and fixed-permutation orders.

### Cost and expected gain

Effort: **M, 3–5 engineering days**, including the shared worker substrate,
32-seat proof, dual compile-shape checks, and replay differential.

The provisional 32-seat body result is 0.883 ms; even perfect parallelism
cannot save more than that today (`docs/reports/body-lane-gate-report-2026-08-31.md:45-48`).
At one requested CPU it should be neutral or slower. Do not ship A before the
nav rework solely for this saving. Its value changes if bounded route work is
moved into `actFromBelief`; that is addressed below.

## Candidate B: play steps per seat

### Boundary

Keep `scheduleInitializations` and retunes on the tick thread, including their
two-per-tick global quota and `nextInitSeat` cursor. Once that phase completes,
dispatch one job per ladder seat. A worker runs the existing `stepSeat` logic,
including overlays, controller selection, guest calls, and per-seat output.
The barrier completes before the standing-order fold
(`src/shell/ladder.nim:510-544`, `src/shell/ladder.nim:623-709`).

There can be at most three guest steps per seat, hence 96 at 32 seats; each
step gets 50,000 fuel (`src/shell/types.nim:400-413`). View bytes stay lazy and
memoized within one seat tick: the first actual guest step builds them and a
seat with no guest step builds none (`src/shell/ladder.nim:578-588`). That is
the already-merged lazy-view change, not candidate C work.

The current `LadderSeatInput` carries two managed closures, `viewSource` and
`guardContext` (`src/shell/ladder.nim:66-74`). They must not cross the worker
boundary. Evaluate each entry's guard expression to a fixed per-seat bitset on
the tick thread after the serial init pass, then let the worker combine that bit
with the entry's live/faulted state. Replace the production view closure with a
non-capturing `gcsafe` leaf that receives a raw episode pointer, seat, and tick;
it preserves the current build-on-first-step behavior. This is a required part
of B, not optional cleanup. Tests that inject a view builder must use the same
explicit context shape.

### Wasmtime ownership

The shared Engine and epoch ticker remain unchanged. Epoch increments are
already performed by a dedicated thread (`src/shell/runtime.nim:120-126`), and
Wasmtime documents the C epoch increment as safe from any thread in
[engine.h](https://docs.wasmtime.dev/c-api/engine_8h.html). Each `ShellInstance`
owns its Store, context, instance, functions, and host state
(`src/shell/instance.nim:47-74`, `src/shell/instance.nim:356-432`). Wasmtime
48.0.1 documents an Engine as shareable and a Store as movable but exclusively
mutated by one caller at a time ([Engine](https://docs.rs/wasmtime/48.0.1/wasmtime/struct.Engine.html),
[Store](https://docs.rs/wasmtime/48.0.1/wasmtime/struct.Store.html)). One seat
job must own all Stores for that seat until it finishes; no work stealing may
split one seat or overlap two ticks.

Host callbacks mutate only the instance's `InstanceHostState`, its per-instance
`BodySeatCache`, and guest memory; map access is read-only
(`src/shell/instance.nim:47-74`, `src/shell/instance.nim:196-330`,
`src/shell/instance.nim:356-404`). Expected Wasmtime traps remain ordinary
per-call results. A play fault may close that Store on its worker, just as the
current caller closes it, because no other thread can hold that instance
(`src/shell/ladder.nim:578-600`, `src/shell/instance.nim:433-440`). Different
Stores may return slots to the shared pooling allocator concurrently; this
needs the stress/TSan validation below even though Wasmtime owns the allocator's
synchronization.

The worker produces one `LadderSeatTick` slot. Only the tick thread sums step
counts and folds logs, statuses, retunes, play-fault annotations, provenance,
and standing orders by seat index. That preserves both status order and replay
annotation order (`src/shell/episode.nim:1265-1303`).

### Cost and expected gain

Effort: **L, 7–10 engineering days**. The hard parts are exclusive Store
handoff, managed output ownership, fault-path stress, and parity validation,
not dispatching 32 jobs.

Guest-step cost is not measured in the repository. The useful upper bound is
96 calls at 50,000 instructions plus host calls; the earlier gate report put a
worst tick of `nearest_cover` calls near 2.6 ms, but that number and the rest of
the report are provisional (`docs/reports/s2-cog-body-tick-2026-09-03.md`, section 7). B is
the best first candidate because its possible serial work is largest and its
Store ownership is clean, not because a speedup has already been demonstrated.

## Candidate C: per-seat input building

### Boundary

Candidate C covers the default decision, reflex observation, context bytes,
and guard facts currently built into indexed `LadderSeatInput` values
(`src/shell/episode.nim:1236-1263`). It does **not** include belief folding,
which already happens once, or eager guest view construction, which no longer
exists. The older 3.51 ms all-seat view result measured the pre-lazy shape and
is not a current candidate-C estimate (`docs/reports/body-lane-gate-report-2026-08-31.md:37-48`,
`docs/reports/body-lane-gate-report-2026-08-31.md:184-191`).

The data reads are seat belief plus episode-immutable map/mode/roster settings.
Reflex mutation is confined to `runtimeState.reflexStates[seat]`. The current
guard builder scans the body, then returns closures over scalar values such as
`hpFrac` and `nearestEnemy`; it does not retain the body itself
(`src/shell/episode.nim:568-637`). Those closures are later called by
`guardPasses`, including during the still-serial initialization pass
(`src/shell/ladder.nim:401-425`, `src/shell/ladder.nim:510-538`).

Do not pass an `IntentContext` closure between threads. A C implementation
should put plain `GuardFacts` scalars in the worker slot, then build the small
closure bundle on the tick thread before initialization. Context bytes and any
managed default intent data use the same single-owner slot protocol described
under memory safety: the worker writes once, the tick thread moves once after
the barrier, and neither side copies the value. A later combined B+C stage may
instead create and consume the closures on the same worker, but it must still
supply plain facts to the serial initialization phase.

### Cost and expected gain

Effort: **M, 4–5 engineering days** after the worker substrate exists. It needs
a plain guard-facts representation, ownership-safe managed outputs, and
parallel-versus-serial goldens.

The old view number cannot justify C after lazy view construction. The
remaining known provisional number is roughly 2.7 ms for the 32-seat reflex
worst shape (`docs/reports/s2-cog-body-tick-2026-09-03.md`, section 7), while default, context,
and guard costs are not isolated. Implement C only if the profiling task shows
this input stage is at least 20% of shell p95 at 32 seats and scales on 2- and
4-CPU runs.

## What stays serial

**Compile progress and commit.** Compilation already uses two background
workers, while the tick thread polls, commits under a cap, updates the module
cache/bindings, and publishes status in deterministic order
(`src/shell/compile_plane.nim:401-448`, `src/shell/compile_plane.nim:625-635`).
Do not merge this queue with the step pool: compilation is unbounded-latency
background work, while seat jobs are a same-tick barrier.

**Lifecycle.** Activation allocates a body, changes nav active state and the
episode counter, and emits safe-install annotations in seat order
(`src/shell/episode.nim:1038-1077`). It is cheap and infrequent; leave it on
the tick thread. Belief update may be reconsidered only with measured evidence
and a separate ownership audit.

**Initialization and retune scheduling.** The global two-per-tick quota and
persisted round-robin cursor determine which entries become runnable this tick
(`src/shell/ladder.nim:510-544`). Parallelizing it would change behavior, not
just elapsed time.

**Standing-order install.** Installing a changed order cancels an in-flight
plan and pins the seat cache (`src/shell/body.nim:571-596`). The surrounding
fold also constructs public annotations and installs in seat order
(`src/shell/episode.nim:1079-1093`). It is cheap and stays serial.

**Danger rebuild.** Exactly the scheduled nav seat mutates each tick, and its
trace is ordered by stable seat index (`src/shell/body_nav.nim:470-485`). It is
already staggered to one seat per tick, so parallel dispatch has nothing useful
to split. Reconsider only if its cadence is deliberately raised.

**Pooled planning and minting.** Planning owns one persisted cursor and a
shared budget; minting owns another cursor and permits one job in flight
(`src/shell/body_nav.nim:562-628`). Their order is part of fairness and result
timing, so they stay on the tick thread until the nav rework removes them.

**Result fold, mask application, and replay writes.** All workers finish before
the tick thread folds seat slots. The server then applies masks and writes mask
changes and annotations in the returned order (`src/ctf/server.nim:5168-5206`).
No worker writes a replay, log, status list, annotation list, mask sequence, or
shared census directly.

## Dangers and mitigations

| Danger | Required mitigation |
|---|---|
| ORC reference counts are not atomic. A seemingly read-only assignment of a `ref`, string, sequence, or closure can race by changing its count. | Queue only POD descriptors and raw `ptr` values into stable episode-owned storage. Worker entry points use `{.cursor.}` aliases when they must dereference an existing managed object and never copy it. Per-seat result slots have exclusive ownership: worker writes, barrier, tick thread moves/folds. Make this a reviewed invariant, not a runtime guard. Nim's [thread documentation](https://nim-lang.org/docs/typedthreads.html) and [ORC documentation](https://nim-lang.org/2.2.0/mm.html) are the governing references. |
| `gcsafe` can be satisfied with an unsafe cast while a closure still captures unsafe state. The compile plane already has a narrow `{.cast(gcsafe).}` around runtime validation (`src/shell/compile_plane.nim:401-432`). | Keep the worker loop `{.thread, gcsafe.}`. Permit a cast only around a reviewed leaf call whose inputs are raw pointers or worker-owned values. Candidate C returns plain guard facts; it never transports closures. Add a compile-time check that the concrete task and fixed error slot contain no managed fields. |
| An unexpected exception can leave some jobs complete while another aborts. | Every worker catches `CatchableError`, writes a fixed-size POD error record, and still reaches the barrier. The tick thread checks slots in seat order, raises a new exception for the first failing seat before folding any output, and treats the episode as failed; it must never continue with a partial tick. Expected guest traps remain normal ladder fault results. |
| A worker may be descheduled while Wasmtime's wall epoch continues, producing a deadline fault with little CPU consumed. | Keep fuel as the deterministic primary bound and the existing epoch deadline as the wall backstop (`src/shell/runtime.nim:18-25`, `src/shell/instance.nim:468-473`). Do not retry a timed-out call. Compare fault codes and mask streams at 1, 2, and 4 CPUs, and do not enable workers where quota-induced deadline faults rise. |
| `cpuTime()` counts process CPU consumed across workers, while current gates use it to avoid scheduler-preemption failures (`src/shell/containment.nim:93-107`). | Preserve CPU-time gates as total-work regression checks, but add stage wall time around dispatch-to-barrier for critical-path speed. Report both; never compare a sum of worker durations with the old serial wall duration. |
| `getMonoTime` values currently sum serial per-seat durations; sums become misleading under overlap (`src/shell/episode.nim:1190-1212`, `src/shell/episode.nim:1302-1333`). | Measure one wall interval around each parallel stage. If per-seat samples are retained for diagnosis, label their sum “worker work,” not stage latency. The profiling task owns the production line; this design adds no metric itself. |
| Production uses ORC with `-d:useMalloc`, so strings, guest buffers, and Wasmtime teardown can contend in the allocator (`Dockerfile:32-41`). | Reuse job/result storage, move managed outputs exactly once, and benchmark allocation counts plus p95/max at 1/2/4 CPUs. Reject a candidate that reduces stage wall time but increases total tick p95 or allocations. |
| The runtime-stub build has no Wasmtime types but must still compile. | Put the pool's generic POD/barrier code outside the runtime conditional; keep B's Store job behind the existing `ShellRuntimeAvailable` boundary. Run both server compile shapes required by `AGENTS.md:195-218`. |
| Any append from completion order changes logs, statuses, annotations, masks, or replay bytes. | Workers write indexed slots only. The tick thread folds by the existing episode seat order after all jobs finish. Differential tests compare every ordered sequence, not just masks. |
| Existing permutation evidence is incomplete. | Add the missing 32-seat body permutation, retain the 32-seat danger/plan permutations, and run serial-versus-parallel ladder and replay differentials (`tests/test_shell_body_seat.nim:634-667`, `tests/test_shell_body_nav.nim:443-463`, `tests/test_shell_body_nav.nim:825-859`). |

## Execution model comparison and choice

Research was refreshed on 2026-09-07 from each upstream repository, package
file, recent commit history, and CI configuration. None of the three packages
appears in `nimby.lock` at the evidence commit.

| Model | Current state checked | Fit for this tick barrier |
|---|---|---|
| In-repo persistent pool pattern | The compile plane uses `Thread`, `Lock`, `Cond`, task/result deques, explicit shutdown, and a tick-thread fold (`src/shell/compile_plane.nim:401-448`, `src/shell/compile_plane.nim:218-238`). | Best determinism and packaging fit. It already matches the project's Nim/Wasmtime build. A step pool should reuse this pattern, but remain a separate bounded barrier because compile work must not delay a tick. Smallest dependency and code surface; explicit slot ownership is visible in review. |
| [Malebolgia 1.3.2](https://github.com/Araq/malebolgia) | The current package requires Nim 1.9.3+, has no dependencies, and offers structured fork/join with a compile-time pool size ([package](https://github.com/Araq/malebolgia/blob/master/malebolgia.nimble), [recent commit](https://github.com/Araq/malebolgia/commit/239dd8779dbf2e94837efc1e7ce417d14a7f054e)). Its CI exercises Nim devel but does not state an ORC ownership contract. | Attractive and small, but compile-time `ThreadPoolSize` conflicts with a deployment-set worker count/default-off path. Its ergonomic captured tasks make accidental managed-ref copies easier to hide. Not enough benefit over the local pattern. |
| [taskpools 0.2.1](https://github.com/status-im/nim-taskpools) | Stable was updated 2026-08-24, requires Nim 2.0.14+, and explicitly tests refc, ORC, ASan, and TSan ([package](https://github.com/status-im/nim-taskpools/blob/stable/taskpools.nimble), [recent commit](https://github.com/status-im/nim-taskpools/commit/957e665930dffc33e50328015925e5144ae34b8c)). It supports a runtime thread count and pointer/POD task arguments. | Strongest external option and the fallback if the local pool grows beyond a simple barrier. It brings a dependency and a broader task/future API than 32 fixed seat slots need. Determinism still depends on our ordered fold, so the library does not remove the hard part. |
| [Weave 0.4.10](https://github.com/mratsim/weave) | The latest release/commit is from 2023; the package adds `synthesis`, and upstream says GC-managed types are not tested and recommends pointer/channel boundaries ([package](https://github.com/mratsim/weave/blob/master/weave.nimble), [latest release commit](https://github.com/mratsim/weave/commit/b6255afa5816ee431dbf2f59cc6bc605d8d657b8)). | Its work-stealing scheduler is much larger than a fixed barrier, makes seat-to-worker ownership less obvious, and lacks current ORC evidence. Reject. |

**Choice:** use a small episode-owned persistent pool following the compile
plane's synchronization pattern. Do not generalize or refactor the compile
plane in the first implementation: the two queues have different latency and
shutdown requirements, and no reusable helper exists today. Reconsider
`taskpools` only if implementation needs cancellation, nested tasks, or dynamic
task graphs beyond this fixed seat barrier.

`SHELL_STEP_WORKERS=0` means no step threads are created and the existing
serial path runs. For a configured quota of `Q` CPUs, start with
`min(3, max(0, Q - 1))` workers: one CPU remains for the game/server thread and
the existing socket, compile, and epoch work. The value must be explicit in the
deployment, because visible node CPUs are not the pod's promised quota.

## Deployment CPU envelope

The current paintbot game runnable has no `resources` block
(`coworld_manifest_paintbot.json:11-29`); the resource block later in that file
belongs to the baseline player (`coworld_manifest_paintbot.json:1165-1184`). At
Metta commit `00761f6e1415aa61189944385836c4525270703b`, omitted game resources
resolve to a 1-CPU request and no CPU limit, while declared game CPU request and
limit values may go up to 6. The evidence is Metta commit
`00761f6e1415aa61189944385836c4525270703b`, in `config.py` lines 302–328 and
`coworld_resources.py` lines 1–27 under
`app_backend/src/metta/app_backend/job_runner/`.

If B passes the measurement gates, pair the first dark production trial with a
**4-CPU request and 4-CPU limit, and 3 step workers**. The request makes the
parallel capacity schedulable instead of relying on opportunistic node burst;
the equal limit keeps cost and interference bounded. The cost is roughly four
times the reserved game CPU versus today's default and may reduce pods per
node. Do not change the manifest until the 4-CPU result beats serial enough to
justify that capacity. Keep a 1-CPU/0-worker lane as the mandatory regression
floor.

## Interaction with the navigation rework

The pending nav rework is specified to remove the pooled planning scheduler and
move bounded route queries into the per-seat body action, while preserving
deterministic route choice and adding no worker threads itself. This document
does not change those decisions.

**Before it lands:** profile first, then implement B if guest stepping is
material. Leave A serial because its entire provisional budget is 0.883 ms and
leave stage 7 serial because its cursors and minter are shared.

**After it lands:** discard the old A estimate and rerun the matrix. With
route queries inside each seat's action and the shared scheduler gone, A has a
larger parallel fraction and one fewer shared-state obstacle. Implement A next
if body-action p95 is at least 20% of shell p95 and shows useful 2-/4-CPU
scaling. The route algorithm and tie-breaking remain identical; only independent
seat queries overlap.

## Measurement plan

The [profiling task](https://app.asana.com/0/0/1218193498086008/f/) is a hard
implementation gate. Consume its Fluffy stages and `SHELL_TIMING` output
before choosing work. Until then, the gate-report figures are provisional:
10.425 ms shell allowance inside a 41.67 ms tick, 0.883 ms for 32 body actions,
3.51 ms for the old eager 32-seat view shape, about 0.98 ms for one danger
rebuild, and about 2.6 ms for a worst tick of cover calls
(`docs/reports/body-lane-gate-report-2026-08-31.md:31-48`,
`docs/reports/body-lane-gate-report-2026-08-31.md:65-81`; the research
report, section 7). Guest steps remain unmeasured.

Use the existing profiler/probe rather than committing a second benchmark
harness. Run Linux/amd64 production Docker builds with:

- 16 and 32 active play seats;
- `--cpus 1`, `--cpus 2`, and `--cpus 4`;
- worker counts 0, 1, and 3 as permitted by the CPU quota;
- serial, B only, A only after nav, then B+A; add C only if its profile gate is
  met;
- at least five fixed seeds and enough ticks to report p50, p95, and maximum for
  input, init, play-step, standing fold, body action, nav-global, whole shell,
  whole tick, worker CPU, and dispatch-to-barrier wall time.

Track allocator calls/bytes, guest fault codes, late frames, and completed play
steps alongside timing. `cpuTime()` remains a total-work signal; wall time is
the latency signal. Reject results from a CPU-starved host rather than tuning
deadline behavior around them.

### Acceptance gates for any implementation

1. Worker count 0 remains the default and meets the 10.425 ms shell allowance
   on the 1-CPU hosted floor with no statistically meaningful regression.
2. Serial and parallel runs produce byte-identical mask streams and identical
   ordered annotations, statuses, installs, logs, retunes, handoffs, and pact
   declarations for every committed replay fixture and the ladder tests. The
   task was written when it counted eight fixtures; the repository now requires
   all **nine** (`AGENTS.md:384-407`).
3. The 32-seat body-action permutation passes before A can enable.
4. No per-tick worker tasks, queues, closures, or result arrays are allocated;
   persistent slots are allocated with the episode. No new tick-path allocation
   is allowed beyond managed values the existing per-tick fold already creates.
5. Runtime-linked and runtime-stub server shapes compile, shard 2 passes apart
   from its documented pre-existing hostile-containment timing flake, and an
   ORC/`useMalloc` stress run shows no races, leaks, rising Store count, or
   allocator-driven p95 regression.
6. At 4 CPUs, the enabled candidate materially improves whole-shell p95 and
   maximum, not just its isolated stage. Use a 20% stage-share threshold to
   decide whether a candidate deserves implementation; set the final rollout
   speedup threshold from the first profiler baseline rather than inventing it
   here.

## Recommendation and rollout

| Candidate | Effort | Present evidence | Recommendation |
|---|---:|---|---|
| A — body action | M, 3–5 days | Only 0.883 ms provisional total before nav | Wait for nav rework; then remeasure and likely implement second. |
| B — play steps | L, 7–10 days | Up to 96 metered guest calls and host work; cost not yet measured | Profile first; implement first if material. |
| C — input building | M, 4–5 days after pool | Eager-view and duplicate-belief costs already removed; remaining costs not isolated | Last, and only if profile meets the 20% stage-share gate. |

Roll out in this order:

1. Land the profiler and record the serial 1/2/4-CPU matrix at the evidence
   build or a freshly rebased successor.
2. Implement the persistent fixed-slot pool with worker count 0 and prove the
   serial path unchanged. Do not enable any candidate yet.
3. Implement B, keeping init and all folds serial. Pass the full parity,
   compile-shape, fault, allocator, and timing gates.
4. Build and publish the 4-CPU manifest change separately, with 3 workers in a
   limited production trial. Compare it with the 1-CPU/0-worker control, then
   either expand or return to 0.
5. After the nav rework, rebaseline and implement A if it passes the stage-share
   and scaling gates.
6. Consider C only from a new profile; do not combine it with B until each
   boundary has an independent serial differential.

No rollout step may change replay outputs. Because that is the acceptance
criterion, none requires a `GameVersion` bump or fixture recut.

## Open questions for implementation approval

This design resolves one question from the task: the profiling output must land
before implementation approval. The remaining questions are:

1. Does the profiler show B is at least 20% of 32-seat shell p95, and which mix
   of guest execution versus host calls dominates it?
2. Is reserving 4 CPUs per game worth the measured whole-tick improvement and
   reduced pod density, or should the first trial use 2 CPUs and 1 worker?
3. Will the nav rework land before implementation starts? If yes, rebaseline A
   in the same matrix; do not preserve the 0.883 ms estimate.
4. Should an unexpected worker exception remain a fatal episode/server error,
   matching today's propagation, or should a future product decision introduce
   transactional recovery? This design recommends fatal propagation and no
   partial fold.
5. Does the ORC/`useMalloc` stress run validate direct Store destruction on seat
   workers, or should faults enqueue Store teardown for the tick thread? Either
   answer must preserve the same fault status and tick.
