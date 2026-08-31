# Season 2 body P0 measurement

Status: **PROVISIONAL (contended machine)**. These measurements are suitable for
finding obvious budget failures, but they are not the authoritative constant-
setting pass. A quiet-window pass is required after the other lane sessions go
idle.

## Conclusions

- **PROVISIONAL FAIL — lane A quarter-tick runtime.** The conservative direct
  32-seat p95 burst is 188.978 ms, versus the 10.425 ms allowance. The
  eight-source danger rebuild alone is 108.652 ms p95. Lane C is still
  **PENDING**, so the combined lane A + lane C verdict is **PENDING** rather
  than a pass.
- **PASS — validator correctness.** All five giant CTF maps had zero EDT/ring
  and zero EDT/stencil parity failures. Each map contributed 11,669 queries
  spanning standable, blocked, edge, exact-radius, one-past-radius,
  equal-distance-tie, and nearer-other-component cases.
- **PASS — measured validator cap.** Each CTF map had one distinct spawn
  component: 22,001,772 logical bytes, below `MaxValidatorTableBytes`.
- **PASS AS AN UPPER BOUND — BR validator census.** Each generated 16-team
  giant geometry had one component large enough to host a spawn pocket, so
  `1 * 22,001,772 = 22,001,772` bytes is below the 268,435,456-byte cap. This
  is an **upper bound — real BR spawn placement lands with the branch merge;
  spawn-hosting components cannot exceed the census**.
- **Memory is feasible only as a reported cost, not a runtime-budget pass.**
  The largest measured logical steady-state body payload was 333,527,680 bytes
  for 32 seats; allocator occupied-memory delta reached 363,086,848 bytes.
  There is no separate fixed aggregate body-memory constant in this P0 gate,
  but this is substantial and should remain visible during the port.
- No constant was tuned. Any provisional-constant recommendation is deferred
  to the quiet-window authoritative pass. If the PM cross-check differs beyond
  reasonable noise, the affected rows must be retaken in a quiet window, never
  averaged with this pass.

## Measurement conditions

Every number in this report is **PROVISIONAL (contended machine)**.

| Pass | Start load average (1/5/15 min) | End load average (1/5/15 min) | Other load |
|---|---:|---:|---|
| Stencil-free | 2.58 / 2.50 / 3.05 | 2.55 / 2.49 / 3.03 | Lane B and lane C Codex sessions active; other agent TUI sessions live |
| Stencil-backed | 2.50 / 2.48 / 3.02 | 1.90 / 2.03 / 2.49 | Lane B and lane C Codex sessions active; other agent TUI sessions live |

The host was a MacBook Pro (`Mac16,7`) with an Apple M4 Pro (14 cores,
10 performance + 4 efficiency), 48 GB RAM, and macOS 15.5 (24F74). This is
Apple Silicon and is **not the hosted CPU class**. The harness itself ran
serially. The baseline test run had finished, but the other lane sessions made
the box non-idle. The authoritative quiet-window pass is scheduled for after
those sessions go quiet.

The addendum requesting load snapshots arrived after an initial portable pass
and while the first stencil attempt was in progress. That stencil attempt was
interrupted before completion. Both binaries were then retaken with load
snapshots; `/tmp/body-bench-free.json` was overwritten. No number from the
discarded attempts is averaged into this report.

## Method

Both binaries were compiled with Nim's `-d:release` mode. Timings use
`getMonoTime()` in nanoseconds. The complete pass used the committed defaults:
seeds `4242,14005,23011,41017,65003`, five untimed warmups, and 50 measured
samples. No case needed a reduced sample count. Rows that are correctness,
memory, or deliberately cold one-shot observations state their own count.

The stencil-backed pass generated a fresh validated 3211 x 1713 giant map for
each seed, rasterized engine wall masks, and inverted them to walkability. Map
generation and rasterization are input preparation and are excluded from the
episode body barrier. Action scenarios use their actual 640 x 320 map; memory
uses the current giant map. The BR census independently generates the same
giant geometry with `teams = 16`, then uses synthetic markers solely to let the
pinned stencil map builder derive components; components do not depend on team
markers.

For cross-seed timing rows below, “median” and “p95” are the largest observed
per-seed values, not a percentile over already-aggregated percentiles. The seed
that produced each maximum is shown. This is conservative for the budget
composition. Exact per-seed rows, raw nanoseconds, samples, dimensions, and
cardinalities are in the JSON files:

- `/tmp/body-bench-free.json`
- `/tmp/body-bench-stencil.json`

Repository commit: `20aef2a48c3096622a218f41c97554e0f08a8a0c`.
Pinned stencil commit: `480120c2f5d2a13bc84917b6470b64e67372a752`.

## Scenario and cardinality matrix

| Row family | Actual map / seeds | Samples | Cardinalities and construction |
|---|---|---:|---|
| `episode.*` | 3211 x 1713 px, 401 x 214 cells; all five seeds | 50 | 1 component; 48-99 rooms; 231-398 chokes; 15,157-20,589 atlas posts; 2 home fields |
| `validator.edt_component_*`, parity | same giant CTF maps/seeds | 50 builds; 11,669 queries/seed | 1 deduplicated spawn component; seven query classes; u32 full-pixel EDT |
| `validator.br_*` | 3211 x 1713 px, 401 x 214 cells; generated with 16 engine teams; all five seeds | 50 EDT builds | spawn-pocket threshold 247,105 px; census count 1; eligible component 4,432,979-4,698,657 px; rest count/pixels 0 |
| `planner.*` | giant maps/all five seeds | 50 except one-shot stresses | step-4 lattice 803 x 429; up to 159,196 expansions and 801 path points |
| `follower.*` | giant maps/all five seeds | 50 | direct serial 32-seat batch, prebuilt route |
| `danger.*` | giant maps/all five seeds | 50 | 4/8/16/31 visible sources; per-seat and direct 32-seat batch; cadence 12 ticks |
| `targeting.*` | giant maps/all five seeds | 50 | 4/8/16/31 enemies/candidates; candidate, select, combined, and direct 32-seat batch |
| `action.*` | 640 x 320 px, 80 x 40 cells; deterministic seed 0 | 50, repeated in each outer seed pass | hold, navigate, gun, spray, grenade charge/release, corridor reject; mixed direct 32-seat batch |
| `route_field.*` | giant maps/all five seeds | 50 | 50 fresh goals; 69,215-73,218 reachable cells; 53 cached fields after measurement |
| `duck.*` | giant maps/all five seeds | one cold + 50 warm | atlas sizes 15,157-20,589 |
| `memory.*` | giant map per outer seed, reported seed `-1` | 1 and 32 seats | exactly 4 route fields and 256 duck entries per seat; planner and danger buffers allocated |
| `view.*` | schema-real-max deterministic frame | 50 | 32 tracks/items/kill-feed/shouts; 16 aggressors; 8 grenades/sprays; 4 blast cues; direct 32-seat build+encode |
| `context.*` | schema-real-max deterministic context | 50 | 32-seat roster; direct 32-seat build+encode |
| portable EDT | 720 x 64 synthetic raster | 50 | 10,003 queries across seven classes; zero failures |

## Timing results

All values are **PROVISIONAL (contended machine)**. Milliseconds are followed
by raw nanoseconds in parentheses. For stencil rows, `@ seed` identifies the
per-seed maximum. Zero-millisecond entries retain their raw-nanosecond value.

### Portable view, context, and EDT rows

| Row | N | Median ms (ns) | p95 ms (ns) |
|---|---:|---:|---:|
| `context.batch32` | 50 | 0.847 (847250) | 0.864 (864417) |
| `context.build` | 50 | 0.005 (4917) | 0.005 (5042) |
| `context.cap_stress_encode` | 50 | 0.217 (216500) | 0.230 (229750) |
| `context.encode` | 50 | 0.021 (21000) | 0.022 (21792) |
| `validator.edt_build` | 50 | 0.668 (668083) | 0.685 (684542) |
| `validator.lookup_batch` | 50 | 11.054 (11054208) | 16.707 (16707167) |
| `view.batch32` | 50 | 5.589 (5588542) | 5.772 (5772084) |
| `view.build` | 50 | 0.043 (43333) | 0.049 (49000) |
| `view.cap_stress_encode` | 50 | 0.197 (196917) | 0.216 (215916) |
| `view.encode` | 50 | 0.127 (127458) | 0.136 (135750) |

The real view encoded to 12,202 bytes and the real context to 1,578 bytes.
The synthetic extension-field cap stresses encoded to 32,767/32,768 and
65,535/65,536 bytes respectively; they price the byte caps and are not
representative gameplay frames.

### Stencil-backed rows, conservative cross-seed maxima

| Row | N | Median ms (ns) @ seed | p95 ms (ns) @ seed |
|---|---:|---:|---:|
| `episode.clearance_walkability` | 50 | 37.706 (37705833) @ 4242 | 43.731 (43731292) @ 4242 |
| `episode.components` | 50 | 33.729 (33729292) @ 4242 | 36.737 (36737209) @ 14005 |
| `episode.topology` | 50 | 147.573 (147572917) @ 23011 | 157.908 (157907917) @ 23011 |
| `episode.cover_dirs` | 50 | 49.713 (49713083) @ 4242 | 53.152 (53151916) @ 4242 |
| `episode.post_atlas` | 50 | 68.956 (68955500) @ 23011 | 72.315 (72314583) @ 14005 |
| `episode.home_dijkstra_sum` | 50 | 15.166 (15166082) @ 65003 | 15.506 (15505708) @ 4242 |
| `episode.complete_barrier` | 50 | 351.009 (351009375) @ 14005 | 362.447 (362447291) @ 14005 |
| `validator.edt_component_1` | 50 | 74.457 (74457000) @ 41017 | 80.206 (80205583) @ 41017 |
| `validator.edt_lookup` | 11669 | 0.000 (375) @ 14005 | 0.015 (14875) @ 4242 |
| `validator.stencil_ring_oracle` | 11669 | 0.020 (19833) @ 14005 | 5.180 (5179583) @ 4242 |
| `validator.br_edt_1` | 50 | 72.509 (72509334) @ 4242 | 80.011 (80010500) @ 4242 |
| `planner.typical_spawn_to_center` | 50 | 14.229 (14228958) @ 4242 | 15.014 (15014125) @ 4242 |
| `planner.typical_goal_quartile_25` | 50 | 6.920 (6920041) @ 65003 | 7.184 (7183709) @ 65003 |
| `planner.typical_goal_quartile_50` | 50 | 15.129 (15129250) @ 65003 | 16.124 (16124125) @ 65003 |
| `planner.typical_goal_quartile_75` | 50 | 27.954 (27954041) @ 65003 | 30.184 (30184042) @ 65003 |
| `planner.worst_cold` | 50 | 58.673 (58672583) @ 4242 | 65.046 (65045750) @ 4242 |
| `planner.oracle_miss` | 1 | 0.000 (292) @ 23011 | 0.000 (292) @ 23011 |
| `planner.fallback_step_2` | 1 | 0.016 (16375) @ 23011 | 0.016 (16375) @ 23011 |
| `planner.fallback_step_1` | 1 | 0.074 (73583) @ 41017 | 0.074 (73583) @ 41017 |
| `follower.batch32` | 50 | 0.000 (375) @ 65003 | 0.000 (459) @ 65003 |
| `danger.sources_4` | 50 | 1.704 (1704333) @ 4242 | 1.916 (1916292) @ 4242 |
| `danger.sources_8` | 50 | 3.109 (3108917) @ 4242 | 3.342 (3342208) @ 4242 |
| `danger.sources_16` | 50 | 5.804 (5804167) @ 4242 | 5.900 (5900083) @ 65003 |
| `danger.sources_31` | 50 | 11.233 (11232500) @ 65003 | 13.089 (13089125) @ 65003 |
| `danger.batch32_sources_4` | 50 | 56.420 (56419708) @ 4242 | 57.746 (57746458) @ 4242 |
| `danger.batch32_sources_8` | 50 | 103.290 (103290125) @ 4242 | 108.652 (108652166) @ 4242 |
| `danger.batch32_sources_16` | 50 | 190.282 (190281833) @ 4242 | 196.925 (196925166) @ 4242 |
| `danger.batch32_sources_31` | 50 | 363.603 (363603417) @ 65003 | 368.062 (368062125) @ 65003 |
| `targeting.candidates_4` | 50 | 0.001 (500) @ 65003 | 0.001 (542) @ 65003 |
| `targeting.select_4` | 50 | 0.000 (333) @ 4242 | 0.000 (334) @ 65003 |
| `targeting.combined_4` | 50 | 0.001 (834) @ 41017 | 0.001 (1042) @ 41017 |
| `targeting.batch32_4` | 50 | 0.026 (26000) @ 4242 | 0.030 (29583) @ 14005 |
| `targeting.candidates_8` | 50 | 0.001 (1166) @ 14005 | 0.001 (1167) @ 14005 |
| `targeting.select_8` | 50 | 0.001 (666) @ 65003 | 0.001 (833) @ 65003 |
| `targeting.combined_8` | 50 | 0.002 (1792) @ 4242 | 0.002 (2000) @ 65003 |
| `targeting.batch32_8` | 50 | 0.057 (57125) @ 14005 | 0.072 (72250) @ 4242 |
| `targeting.candidates_16` | 50 | 0.003 (2958) @ 14005 | 0.003 (2959) @ 65003 |
| `targeting.select_16` | 50 | 0.001 (1416) @ 65003 | 0.001 (1458) @ 65003 |
| `targeting.combined_16` | 50 | 0.004 (4458) @ 14005 | 0.006 (5792) @ 14005 |
| `targeting.batch32_16` | 50 | 0.134 (134250) @ 65003 | 0.149 (148500) @ 65003 |
| `targeting.candidates_31` | 50 | 0.008 (8292) @ 14005 | 0.011 (10625) @ 65003 |
| `targeting.select_31` | 50 | 0.003 (2916) @ 41017 | 0.003 (3000) @ 14005 |
| `targeting.combined_31` | 50 | 0.011 (11167) @ 4242 | 0.013 (12750) @ 4242 |
| `targeting.batch32_31` | 50 | 0.347 (347083) @ 14005 | 0.372 (371792) @ 14005 |
| `action.hold` | 50 | 0.000 (83) @ 0 | 0.000 (84) @ 0 |
| `action.navigate` | 50 | 0.034 (34417) @ 0 | 0.038 (38375) @ 0 |
| `action.gun_fire` | 50 | 0.034 (33958) @ 0 | 0.040 (39750) @ 0 |
| `action.spray_fire` | 50 | 0.034 (33959) @ 0 | 0.038 (38333) @ 0 |
| `action.grenade_charge` | 50 | 0.036 (35667) @ 0 | 0.041 (41250) @ 0 |
| `action.grenade_release` | 50 | 0.035 (34750) @ 0 | 0.040 (39583) @ 0 |
| `action.corridor_reject` | 50 | 0.001 (667) @ 0 | 0.001 (709) @ 0 |
| `action.mixed_batch32` | 50 | 0.791 (791042) @ 0 | 0.914 (913917) @ 0 |
| `route_field.cold_mint` | 50 | 7.262 (7261541) @ 4242 | 8.594 (8593709) @ 14005 |
| `route_field.warm_lookup` | 50 | 0.000 (42) @ 14005 | 0.000 (42) @ 65003 |
| `duck.cold` | 1 | 0.097 (97250) @ 4242 | 0.097 (97250) @ 4242 |
| `duck.warm` | 50 | 0.000 (41) @ 65003 | 0.000 (42) @ 65003 |

`validator.edt_total`, `validator.parity`, `validator.br_census`, and memory
rows are inventory/verdict rows rather than timed operations; their raw timing
fields are intentionally zero and their substantive values appear below.

### Episode barrier, per seed

The component sum includes clearance, components, topology, cover, atlas, and
the two immutable home fields. It is compared with the separately measured
complete barrier to expose uninstrumented/measurement overhead.

| Seed | Complete median ms | Complete p95 ms | Component median sum ms | Component p95 sum ms |
|---:|---:|---:|---:|---:|
| 4242 | 344.769 | 357.836 | 339.228 | 362.314 |
| 14005 | 351.009 | 362.447 | 345.673 | 367.669 |
| 23011 | 348.183 | 357.108 | 342.356 | 365.856 |
| 41017 | 336.365 | 348.603 | 332.061 | 352.258 |
| 65003 | 344.047 | 354.636 | 338.279 | 359.291 |

Percentile sums are diagnostic rather than a measured joint percentile; the
complete-barrier p95 is the barrier headline. The barrier is episode-only and
is not charged to each seat or tick.

## Validator memory and cap verdicts

### CTF spawn components

| Seeds | Distinct spawn components | Logical bytes/component | Total logical bytes | Allocator occupied delta | Cap | Verdict |
|---|---:|---:|---:|---:|---:|---|
| all five | 1 each | 22,001,772 | 22,001,772 | 55,051,552 | 268,435,456 | **PASS** |

The cap governs logical validator tables, so allocator overhead is reported but
not substituted into the contract comparison.

### BR census upper bound

| Seed | Standable census components >= 247,105 px | Component pixels | Rest count / pixels | Upper-bound bytes | Cap verdict |
|---:|---:|---:|---:|---:|---|
| 4242 | 1 | 4,675,215 | 0 / 0 | 22,001,772 | PASS |
| 14005 | 1 | 4,618,847 | 0 / 0 | 22,001,772 | PASS |
| 23011 | 1 | 4,469,277 | 0 / 0 | 22,001,772 | PASS |
| 41017 | 1 | 4,432,979 | 0 / 0 | 22,001,772 | PASS |
| 65003 | 1 | 4,698,657 | 0 / 0 | 22,001,772 | PASS |

This is an **upper bound — real BR spawn placement lands with the branch
merge; spawn-hosting components cannot exceed the census**. Main currently
returns no explicit spawn points for this generated 16-team path, so the report
does not present synthetic markers as real BR spawn placement.

## Steady-state body memory

All numbers are **PROVISIONAL (contended machine)**; logical byte counts are
deterministic, while allocator deltas are process-state-sensitive.

| Item | Per seat | 32 seats |
|---|---:|---:|
| Four route fields | 3,089,304 bytes | 98,857,728 bytes |
| 256 duck entries | 6,144 bytes | 196,608 bytes |
| Planner arrays/heap | 6,968,484-6,984,036 bytes | 222,991,488-223,489,152 bytes |
| Danger buffer | 343,256 bytes | 10,984,192 bytes |
| **Total logical** | **10,407,188-10,422,740 bytes** | **333,030,016-333,527,680 bytes** |
| Allocator occupied delta | 11,248,064-11,346,368 bytes | 359,941,120-363,086,848 bytes |
| Allocator total delta | 0 bytes in four runs; 304,902,144 in one | same observation point |

The allocator total metric reflects arena reservation and therefore varied
between zero and 304,902,144 bytes; occupied-memory delta is the more stable
observed figure. The logical table is the portable capacity result.

## Quarter-tick composition

All p95 contributions are **PROVISIONAL (contended machine)**. The table uses
direct serial 32-seat batches. `resolveAction` already performs navigation
follower work and calls `targetCandidates`/`selectTarget`; those diagnostic
rows are therefore not added again. The action batch used warm route/danger
state, so a due danger rebuild and a cold route/planner event are separate
incremental burst costs. View is the direct 32-seat build+encode row.

| Burst contribution | p95 ms | Counted in total? | Reason |
|---|---:|---|---|
| Mixed 32-seat `resolveAction` normal executor | 0.914 | yes | Includes follower and target acquisition paths |
| Follower 32-seat diagnostic | 0.000459 | no | Already inside resolver navigation cases |
| Eight-enemy targeting 32-seat diagnostic | 0.072 | no | Already inside resolver gun/spray cases |
| Due-tick danger rebuild, 8 sources x 32 seats | 108.652 | yes | Direct simultaneous burst; cadence amortization is not used for worst tick |
| Cold route-field mint | 8.594 | yes | Standing-goal-change cold miss |
| Cold worst-observed planner | 65.046 | yes | Same standing-goal-change burst; route field is resident for the search |
| View tick, 32 real-max build+encode | 5.772 | yes | Direct batch, not per-seat multiplication |
| **Lane A p95 burst** | **188.978** | **yes** | Sum of non-overlapping counted rows |
| Lane C reviewed p95 share | **PENDING** | n/a | No reviewed lane C number supplied |
| Lane A + lane C | **PENDING** | n/a | Cannot infer a combined pass |
| Quarter-tick allowance | 10.425 | n/a | 41.7 ms / 4 |
| Lane A headroom | **-178.553** | n/a | 10.425 - 188.978 |

The episode complete barrier p95 is 362.447 ms and is excluded from the tick
sum because it runs once before activation. The eight-source danger cadence-
amortized worst per-seat p95 is 0.279 ms/tick, but acceptance is against p95
burst, not amortized cost.

**Verdict: numbers are provisional pending a quiet-window authoritative pass;
any provisional-constant recommendation is deferred to that pass.** Lane A is
already a provisional runtime FAIL; the combined verdict remains PENDING until
lane C publishes a reviewed p95 and the quiet-window body pass is accepted.

## Exact rerun commands

Raw outputs remain outside the repository. From the repository root:

```bash
nimby --global sync nimby.lock
nim c -d:release -o:/tmp/bench_body tools/bench_body.nim
/tmp/bench_body --seeds 4242,14005,23011,41017,65003 \
  --warmups 5 --samples 50 --output /tmp/body-bench-free.json

export STENCIL_LAB_DIR=/Users/jamesboggs/coding/personal_labs/personal_paintbot/paintbot_lab/paintbot/stencil_nim
nim c -d:release --path:"$STENCIL_LAB_DIR" \
  -o:/tmp/bench_body_stencil tools/bench_body_stencil.nim
/tmp/bench_body_stencil --case all \
  --seeds 4242,14005,23011,41017,65003 \
  --warmups 5 --samples 50 \
  --stencil-pin 480120c2f5d2a13bc84917b6470b64e67372a752 \
  --output /tmp/body-bench-stencil.json
```

Run `uptime` immediately before and after each binary and record both snapshots.
The stencil binary refuses a lab checkout whose HEAD differs from the pin. No
stencil source is vendored into this repository.
