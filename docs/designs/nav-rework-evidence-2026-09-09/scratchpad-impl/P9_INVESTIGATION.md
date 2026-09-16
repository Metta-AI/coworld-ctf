# P9 Investigation — Query Cost and Route Quality

## Outcome

The investigation found and fixed one correctness bug, but it did not find a
bounded route-quality design that passes the Phase 9 gate.

- The four `brfDescriptorOverflow` results were not real cap overflows. Mutable
  two-label side-search slots had formed a two-edge predecessor cycle. Commit
  `c43b97dd` records immutable predecessor nodes when labels are popped; all
  four routes now validate with 7 edges, a 65-point start leg, and a 61-point
  goal leg.
- Query cost is dominated by per-query walking and pricing of retained static
  portal paths. The profiled far query read 156,606 cells across segment memo
  fills and endpoint-to-portal chains, relaxed 3,522 arcs, and took a median
  35.766 ms before the fix. Descriptor validation and install copy were only
  0.195 ms and 0.001 ms respectively.
- The 30 worst routes point overwhelmingly to static intra-room path choice:
  26/30 use the same room sequence as the float oracle. Even in the four with
  different room sequences, the measured shared-room excess exceeds 100% and
  the different-room contribution is slightly negative.
- The separate corridor-weighted 8 px A* experiment (`f3f77693`) improves
  overall p95 from 19.910% to 8.322% at 8,192 pops and 7.025% at 16,384 pops,
  but neither passes 3%. Carrier-danger maxima remain 86.650% and 86.197%.
  The far profiled case needs 14,817 pops and adds 11.293 ms at the larger cap.

No containment limit, production pop/descriptor cap, or corpus case changed.
Phase 10 was not started.

## Checkpoints and environment

- Investigation instrumentation: `0b1c495f`
  (`test: instrument phase 9 route investigation`).
- Correctness fix: `c43b97dd`
  (`fix: preserve immutable route predecessors`).
- Revertible experiment: `f3f77693`
  (`experiment: measure corridor weighted route refinement`).
- Native host: macOS/arm64, Nim 2.2.6, release, `--threads:on`, `--opt:speed`,
  `-d:useMalloc`, `-d:navQueryProfile` for stage counters.
- The branch was merged with `origin/main` before investigation and was 37
  commits ahead, 0 behind at that point. The upstream merge affected only the
  replay-viewer presentation lane.

The profiler command was:

```sh
nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on \
  -d:navQueryProfile -o:/tmp/investigate_body_nav_p9 \
  tools/investigate_body_nav_p9.nim
/tmp/investigate_body_nav_p9 \
  tests/fixtures/shell/nav_route_corpus.json \
  /tmp/nav-gate-amd64-final.json \
  >/tmp/p9-investigation-experiment.json \
  2>/tmp/p9-investigation-experiment.log
```

Every single-query number below is the median of seven native runs. Map load,
route-index construction, danger-field construction, and JSON output are
outside each timed query.

## Native single-query stage profile

| Stage/count | `br-gen-22010`, room 14 far route | Median corpus case |
|---|---:|---:|
| Case | `m15-...-default-danger-far` | `m09-...-default-blocked-far` |
| Total query | 35,765,833 ns | 26,832,458 ns |
| Endpoint attach | 177,625 ns | 265,417 ns |
| Same-room candidates and connection chains | 15,771,875 ns | 21,576,292 ns |
| Side-graph A* | 19,544,417 ns | 4,914,583 ns |
| Hazard pricing, nested in the preceding stages | 13,485,672 ns | 7,232,079 ns |
| Descriptor assembly + `validateBodyRoute` | 195,333 ns | 100,500 ns |
| Install copy | 1,167 ns | 834 ns |
| `segmentClear` calls | 402 | 431 |
| Local A* pops | 0 | 0 |
| Side A* pops | 226 | 67 |
| Arcs relaxed | 3,522 | 598 |
| Segment memo fills | 2,144 | 598 |
| Segment cells read | 87,515 | 23,356 |
| Connection-chain cells read | 69,091 | 97,937 |
| Hazard steps priced | 3,522 | 598 |
| Descriptor shape | 13 edges; 15/14 local legs | 7 edges; 60/17 local legs |

`hazard pricing` is deliberately a nested measurement: its time is already
inside same-room connection work and side-graph work, so it must not be added
to the total. The top-level exclusive stages account for essentially the whole
query. There was no local A* in either selected case; the high same-room number
comes from straight-line testing plus building start/goal portal connections
and walking their retained chains.

The pathological work is not an O(map) reset, and the arc memo is not recomputed
for every relaxation inside a query: each directed arc is filled at most once
per query generation. It is nevertheless repeated per seat and per query.
Each fill walks every cell of a retained static segment to apply that seat's
dynamic danger; endpoint connection pricing separately walks portal chains.
The far case therefore reads 156,606 cells while considering only 3,522 arcs.
The shared index already owns static topology, but dynamic danger is generally
seat-specific, so sharing priced memos requires a real danger-field identity or
different representation rather than simply hoisting the existing memo.

`validateBodyRoute` does recheck route geometry, but its measured descriptor
assembly plus validation cost is only 0.10–0.20 ms here. `segmentClear` is not
used per local-A* neighbor: local search uses the shared `legalMoves` bitmap.

## What the Phase 9 tick window measures

`ShellTickResult.bodySliceNanoseconds` starts immediately before the loop over
all play seats and stops after scheduled danger rebuilding and the planning
tick. It includes:

- the linear frame lookup for each seat;
- `actFromBelief`, including query/follow/steer and weapon selection;
- per-seat summary bookkeeping, handoff declarations, and pact declarations;
- mask assembly;
- `rebuildScheduledDanger` for all seats; and
- `runPlanningTick`.

It excludes runtime/play execution, standing-order decoding, belief updates,
activation/index construction, corpus loading, and oracle scoring. Thus it is
an intentionally inclusive body-path budget, not a pure route-query timer.
Danger rebuild for all seats is included. The single-query profiler above
isolates route construction from those extra costs.

## Correctness bug and native before/after

The side search retains two mutable labels per portal side. A child label stored
only its parent's `(side, label-slot)`. Later label replacement could rewrite
that parent slot; in the four failing cases, reconstruction entered a cycle
after one prefix edge and repeated two edges until `RouteEdgeCap` was reported.
The diagnostic traversal initially reproduced the cycle exactly:

| Corpus cases | Reported cap before fix | Actual condition before fix | Fixed descriptor |
|---|---|---|---|
| `m32-...-r16-s0-carrier-danger-far` | edge count 4,096 | no finite overflow; prefix 1, cycle 2 | 7 edges; start 65; goal 61 |
| `m32-...-r16-s0-carrier-both-far` | edge count 4,096 | no finite overflow; prefix 1, cycle 2 | 7 edges; start 65; goal 61 |
| `m32-...-r32-s0-carrier-danger-far` | edge count 4,096 | no finite overflow; prefix 1, cycle 2 | 7 edges; start 65; goal 61 |
| `m32-...-r32-s0-carrier-both-far` | edge count 4,096 | no finite overflow; prefix 1, cycle 2 | 7 edges; start 65; goal 61 |

The fix stores the predecessor arc and predecessor node in immutable,
pop-bounded records. It preserves label replacement and the 4,096-pop cap,
while reconstruction now follows stable nodes. A corpus-pinned regression test
proves the former failure validates.

The unchanged native 16-seat `first_goals` row was rerun through the existing
30-sample tick harness:

| Revision | p95 | max |
|---|---:|---:|
| Phase 9 native baseline (`b24d8d8d`) | 854,258,459 ns | 854,543,458 ns |
| Immutable predecessors (`c43b97dd`) | 835,556,417 ns | 838,774,041 ns |

The roughly 2% decrease is ordinary host variance, not a claimed speedup: the
search counts and profiled stage costs are unchanged. The correctness fix adds
bounded retained predecessor storage and removes the cyclic reconstruction.
The tick gate remains far over 4/5 ms.

## Worst-30 quality attribution

Costs are measured on each 4 px-resampled route with the corpus float scoring
rule. `Shared` is the candidate-minus-oracle cost for edges lying wholly inside
rooms present in both routes. `Other` is the remaining total excess, including
different-room and transition edges. Small negative values mean the candidate
was slightly cheaper outside the shared-room portion.

| # | Case | Same rooms | Candidate rooms | Oracle rooms | Shared excess | Other excess |
|---:|---|:---:|---|---|---:|---:|
| 1 | `m31-...-r16-s15-carrier-both-near` | no | `11-24-21-11-1` | `11-24-21-6-1` | 2583.559 (103.95%) | -98.059 (-3.95%) |
| 2 | `m31-...-r16-s15-carrier-danger-near` | no | `11-24-21-11-1` | `11-24-21-6-1` | 2583.559 (103.95%) | -98.059 (-3.95%) |
| 3 | `m31-...-r32-s31-carrier-both-near` | no | `11-24-21-11-1` | `11-24-21-6-1` | 2583.559 (103.95%) | -98.059 (-3.95%) |
| 4 | `m31-...-r32-s31-carrier-danger-near` | no | `11-24-21-11-1` | `11-24-21-6-1` | 2583.559 (103.95%) | -98.059 (-3.95%) |
| 5 | `m45-...-r16-s13-carrier-both-far` | yes | `7-5` | `7-5` | 1407.353 (100.12%) | -1.657 (-0.12%) |
| 6 | `m45-...-r16-s13-carrier-danger-far` | yes | `7-5` | `7-5` | 1407.353 (100.12%) | -1.657 (-0.12%) |
| 7 | `m45-...-r32-s13-carrier-both-far` | yes | `7-5` | `7-5` | 1407.353 (100.12%) | -1.657 (-0.12%) |
| 8 | `m45-...-r32-s13-carrier-danger-far` | yes | `7-5` | `7-5` | 1407.353 (100.12%) | -1.657 (-0.12%) |
| 9 | `m44-...-r16-s12-carrier-both-near` | yes | `5-4-12-5` | `5-4-12-5` | 1432.955 (98.74%) | 18.343 (1.26%) |
| 10 | `m44-...-r16-s12-carrier-danger-near` | yes | `5-4-12-5` | `5-4-12-5` | 1432.955 (98.74%) | 18.343 (1.26%) |
| 11 | `m44-...-r32-s12-carrier-both-near` | yes | `5-4-12-5` | `5-4-12-5` | 1432.955 (98.74%) | 18.343 (1.26%) |
| 12 | `m44-...-r32-s12-carrier-danger-near` | yes | `5-4-12-5` | `5-4-12-5` | 1432.955 (98.74%) | 18.343 (1.26%) |
| 13 | `m44-...-r16-s12-default-both-near` | yes | `5-4-12-5` | `5-4-12-5` | 972.954 (99.35%) | 6.343 (0.65%) |
| 14 | `m44-...-r16-s12-default-danger-near` | yes | `5-4-12-5` | `5-4-12-5` | 972.954 (99.35%) | 6.343 (0.65%) |
| 15 | `m44-...-r32-s12-default-both-near` | yes | `5-4-12-5` | `5-4-12-5` | 972.954 (99.35%) | 6.343 (0.65%) |
| 16 | `m44-...-r32-s12-default-danger-near` | yes | `5-4-12-5` | `5-4-12-5` | 972.954 (99.35%) | 6.343 (0.65%) |
| 17 | `m24-...-r16-s8-hunter-both-near` | yes | `4-12` | `4-12` | 641.008 (100.26%) | -1.657 (-0.26%) |
| 18 | `m24-...-r16-s8-hunter-danger-near` | yes | `4-12` | `4-12` | 641.008 (100.26%) | -1.657 (-0.26%) |
| 19 | `m24-...-r32-s24-hunter-both-near` | yes | `4-12` | `4-12` | 641.008 (100.26%) | -1.657 (-0.26%) |
| 20 | `m24-...-r32-s24-hunter-danger-near` | yes | `4-12` | `4-12` | 641.008 (100.26%) | -1.657 (-0.26%) |
| 21 | `m23-...-r16-s7-default-both-near` | yes | `5-14` | `5-14` | 1519.859 (98.44%) | 24.083 (1.56%) |
| 22 | `m23-...-r16-s7-default-danger-near` | yes | `5-14` | `5-14` | 1519.859 (98.44%) | 24.083 (1.56%) |
| 23 | `m23-...-r32-s23-default-both-near` | yes | `5-14` | `5-14` | 1519.859 (98.44%) | 24.083 (1.56%) |
| 24 | `m23-...-r32-s23-default-danger-near` | yes | `5-14` | `5-14` | 1519.859 (98.44%) | 24.083 (1.56%) |
| 25 | `m29-...-r16-s13-carrier-both-near` | yes | `6-3-7-6` | `6-3-7-6` | 2200.139 (100.80%) | -17.368 (-0.80%) |
| 26 | `m29-...-r16-s13-carrier-danger-near` | yes | `6-3-7-6` | `6-3-7-6` | 2200.139 (100.80%) | -17.368 (-0.80%) |
| 27 | `m29-...-r32-s29-carrier-both-near` | yes | `6-3-7-6` | `6-3-7-6` | 2200.139 (100.80%) | -17.368 (-0.80%) |
| 28 | `m29-...-r32-s29-carrier-danger-near` | yes | `6-3-7-6` | `6-3-7-6` | 2200.139 (100.80%) | -17.368 (-0.80%) |
| 29 | `m17-...-r16-s1-carrier-both-far` | no | `3-24-20-5` | `3-10-24-20-5` | 1330.426 (100.68%) | -8.971 (-0.68%) |
| 30 | `m17-...-r16-s1-carrier-danger-far` | no | `3-24-20-5` | `3-10-24-20-5` | 1330.426 (100.68%) | -8.971 (-0.68%) |

## Corridor-restricted weighted 8 px A* experiment

The experiment first obtains the production hierarchical route, takes the set
of rooms on that route plus both endpoint rooms, then runs weighted A* only on
`BodyRouteIndex.legalMoves` cells in that corridor. If it reaches the exact
goal through clear endpoint connectors, that path replaces all static
intra-room segments for scoring; otherwise the production route is retained.
This is measurement code only and does not install the potentially long path in
a production descriptor.

| Pop cap | Reached | Fallback | Illegal | Overall p95 | Overall max | Query p50 | Query p95 | Query max |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8,192 | 2,484 | 588 | 0 | 8.322% | 86.650% | 3.314 ms | 6.426 ms | 7.830 ms |
| 16,384 | 2,920 | 152 | 0 | 7.025% | 86.197% | 3.304 ms | 9.185 ms | 307.667 ms |

The 307.667 ms maximum is a host-scheduling outlier; the p95 and the dedicated
seven-sample profiles are the useful comparison. Both variants remain far from
the 3%/10% acceptance limits.

The r16 and r32 corpus cases have identical geometry and dynamic rasters, so
their measured rows are identical. Each row below therefore represents both
roster-size strata separately.

| Profile/dynamic/distance | 8,192 p95 / max | 16,384 p95 / max |
|---|---:|---:|
| default/none/near | 1.660 / 3.032% | 1.660 / 3.032% |
| default/none/far | 1.022 / 7.671% | 0.953 / 7.671% |
| default/danger/near | 10.014 / 41.392% | 9.457 / 31.033% |
| default/danger/far | 15.613 / 16.711% | 4.872 / 14.898% |
| default/blocked/near | 1.660 / 3.032% | 1.660 / 3.032% |
| default/blocked/far | 1.235 / 7.671% | 1.022 / 7.671% |
| default/both/near | 10.014 / 41.392% | 9.457 / 31.033% |
| default/both/far | 15.613 / 16.711% | 4.872 / 14.898% |
| carrier/none/near | 1.660 / 3.032% | 1.660 / 3.032% |
| carrier/none/far | 1.022 / 7.671% | 0.953 / 7.671% |
| carrier/danger/near | 28.135 / 86.650% | 19.765 / 86.197% |
| carrier/danger/far | 32.495 / 36.942% | 10.685 / 35.209% |
| carrier/blocked/near | 1.660 / 3.032% | 1.660 / 3.032% |
| carrier/blocked/far | 1.235 / 7.671% | 1.022 / 7.671% |
| carrier/both/near | 28.135 / 86.650% | 19.765 / 86.197% |
| carrier/both/far | 32.495 / 36.942% | 10.685 / 35.209% |
| hunter/none/near | 1.660 / 3.032% | 1.660 / 3.032% |
| hunter/none/far | 1.022 / 7.671% | 0.953 / 7.671% |
| hunter/danger/near | 3.549 / 11.278% | 3.319 / 6.440% |
| hunter/danger/far | 6.222 / 14.090% | 4.058 / 6.327% |
| hunter/blocked/near | 1.660 / 3.032% | 1.660 / 3.032% |
| hunter/blocked/far | 1.235 / 7.671% | 1.022 / 7.671% |
| hunter/both/near | 3.549 / 15.065% | 3.319 / 6.440% |
| hunter/both/far | 6.222 / 14.090% | 4.058 / 6.327% |

Dedicated per-query profiles retain the same production stage counters and add
the corridor search as a separate stage:

| Case/cap | Base query | Corridor | Combined | Pops | Reached |
|---|---:|---:|---:|---:|:---:|
| room-14 far / 8,192 | 35.673 ms | 6.389 ms | 42.056 ms | 8,192 | no |
| median / 8,192 | 26.349 ms | 5.453 ms | 31.802 ms | 6,751 | yes |
| room-14 far / 16,384 | 35.487 ms | 11.293 ms | 46.969 ms | 14,817 | yes |
| median / 16,384 | 27.270 ms | 5.608 ms | 32.827 ms | 6,751 | yes |

The production endpoint/same-room/side-graph/hazard/descriptor breakdown stays
within ordinary run-to-run variance of the baseline table because the
experiment runs afterward. Install-copy timing is unchanged and applies to the
base descriptor; the experimental full cell path is deliberately not installed
into production state.

## Validation

Passed:

```sh
nim check -d:release -d:noSignalHandler --threads:on \
  src/shell/body_route_query.nim
nim check -d:release -d:noSignalHandler --threads:on \
  -d:navQueryProfile tools/investigate_body_nav_p9.nim
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_route_query.nim
```

The route-query suite passed 14/14 including the new cyclic-predecessor
regression. The existing native tick harness was run unchanged for the required
before/after row. `tests/tests.nim` was not run.

## Decision

The immediate correctness fix should remain. The corridor experiment should
not be promoted as-is: it is too slow, still fails the quality gate, and its
remaining carrier-danger failures show that restricting refinement to the
static side-graph room choice is not enough. The next investigation should
make room-level choice danger-sensitive and measure the actual follower path,
without changing Phase 9 gates or beginning Phase 10.
