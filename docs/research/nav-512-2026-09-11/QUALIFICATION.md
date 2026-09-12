# Qualification of 512 navigation work units per cog per tick

Status: the 512 research target passed every registered m5a held-out, c6a
and Intel c8i-flex workload/placement gate. Claude independently reproduced
every raw held-out and fleet result and confirmed all verdicts. No publication
or production default change has occurred.

The candidate uses a pool of 512 planning work units per configured seat per
tick, shared by all seats, compared with the current 256 multiplier. Plans
spend first in a persisted round robin; one visit can consume the whole pool,
and route-field minting receives what remains. This is not a per-cog quota.
Work accounting is unchanged: these units include connectors, reconstruction and route-field
minting, as well as A* pops. The target is comparative whole-game speed,
including long frames, rather than a microbenchmark or a guarantee that every
frame meets its deadline.

## Changes and why they help

Source checkpoint: `c651dec9`, on the current shipped planner. The archived
C10/C11 rewrite is not part of this candidate.

1. Heap sifts hold the displaced node and shift one neighbor per level. This
   reduces stores while preserving ordering, ties and the position table.
2. A clearance-distance certificate accepts short clear segments when the
   raster proves them safe. All other cases use the original supercover check.
3. Eleven small helpers are inlined without their own diagnostic stack frames.
   Bounds checks and the global `--stackTrace:on` flag remain. A deliberate
   `setPosition` bounds defect verifies reporting through its framed caller.
   Selected helpers can call each other, so a trace can omit an entire chain
   such as `canStand -> clearanceAt -> inBounds` and show the nearest framed
   caller. This is a lasting diagnostic tradeoff, not a benchmark-only flag.

No memory capacity, allocation layout, route cost, work-unit price or public
schema changed. No memory-cap increase was needed. Source default remains 256;
separate pinned binaries implement the experimental budgets.

## Evidence completed

- All 2,301 current-base local shard checks passed, along with runtime-linked
  and runtime-stub server checks, native focused suites, viewer build and stamp.
- Frozen original heap and segment oracles verify output preservation, including
  exhaustive short-segment cases, boundaries, random operations and ties.
- Same-budget 256 semantic streams match on all six held-out workloads.
  Same-budget 512 streams match on the training screens. Full planner-state
  fingerprints match between original and candidate within each toolchain on
  the diagnostic workload at the default pool.
- Six current-base training games and 36 held-out performance games passed on
  native m5a. All six workload verdicts passed independently; every individual
  pair improved total, median, p95 and maximum frame time.
- All 48 c6a and Intel games passed on two workloads in pinned and unpinned
  execution.
  Each version's behavior repeats exactly and matches its m5a reference.
- Claude independently reproduced the raw metrics and verdicts for every
  held-out m5a, c6a and Intel game, and verified checkpoint/archive restoration.

Detailed numbers and exact inputs are in [the m5a result](current-main/RESULT.md),
[the c6a result](fleet/C6A_RESULT.md), [the Intel result](fleet/C8I_RESULT.md),
and their frozen cards and raw archives.
No warmup, outlier, long frame or slower repetition was removed.

Activation at 32 seats retained equal capacities, object sizes and dominant
array payloads. RSS was about 2.57 GB on the larger map and 9.66 GB on the
colossal geometry, with original/candidate differences below 0.3 MB. This is
activation RSS, not a peak-gameplay memory claim.

## Limits that matter

The stress workloads still miss many frame deadlines on the older pinned m5a
core. Passing means 512 is no slower than 256 under the registered comparisons;
it does not mean arbitrary maps or policies will meet every deadline.

Moving-goal runs have fewer pending and no-path seat-ticks and more movement,
but more stale-route ticks. These aggregates are measured at different points
and cannot prove per-request latency or movement quality. See
[the counter review](STALE_COUNTER_REVIEW.md). The algorithm and cost model are
unchanged; no new cost-optimality or cross-budget trajectory guarantee is made.

Original Mac and Linux internal-state hashes differ on the diagnostic workload,
although final paths match. A bounded investigation found differing `hypot`
inputs but did not locate the complete internal discrepancy. This is separate
from candidate/original exactness within a toolchain. The family campaigns
compare full recorded behavior on native Linux using the same binary bytes.

The fleet cases cover two selected workloads and synthetic presence clients,
not production contention. Unpinned server execution still pins those clients
to CPUs 6/7. The same owned instance and disk are used for each hardware family;
no production node, league or version lock is changed.

## Reproduce and resume

Start with [README.md](README.md), the frozen cards, and
[RAW_ARTIFACTS.md](RAW_ARTIFACTS.md). Exact source patches, guest modules,
compiler/image/binary pins, raw logs and result JSONs are archived. Keep failed
H1/H2 target screens and superseded diagnostics as negative evidence. The
independent restore audit and closure records explain how to rebuild the source
checkpoint without relying on a working tree or a locally rebuilt guest.

## Work accounting and maintenance

The charged operations in `stepPlan` and `stepMint` are one endpoint-scan
candidate, connector candidate, A* heap pop, predecessor link, path-reversal
swap, route-field raster cell cleared, or route-field Dijkstra pop. Constant
state transitions do not consume units. Danger rebuilds, following and cover
queries are outside this pool. A higher pool therefore does not mean exactly
twice as many A* pops.

The eleven selected helpers are `nodeLess`, `setPosition`, `inBounds`,
`clearanceAt`, `canStand`, `cellWalkable`, `cellOf`, `gridWidth`,
`routeDistanceAt`, `setRouteDistance` and `clearRouteCell`. Changing this set
needs its own correctness, diagnostic and performance evidence. H2 depends
on `buildClearance` retaining its current distance-transform semantics; rerun
`test_shell_body_segment_exact` whenever those semantics change.

## Evidence index

- Frozen gates: [six-cell protocol](qualification/PROTOCOL.md),
  [current-base card](current-main/CARD.md), [fleet card](fleet/CARD.md),
  with adjacent SHA256 sidecars.
- Provenance: [asset pins](current-main/assets.json),
  [build provenance](current-main/ASSET_PROVENANCE.md),
  [build records](current-main/builds.tar.gz), [hardware](HARDWARE.md).
- Checks: [shard and build-shape results](checks/at46dd/RESULT.md),
  [checkpoint viewer check](checks/viewer-at-c651.txt).
- Independent results: [H3](H3_PEER_VERDICT.md),
  [m5a held-out](HELD_OUT_PEER_VERDICT.md), [c6a](C6A_PEER_VERDICT.md),
  [Intel](C8I_PEER_VERDICT.md).
- Durability: [restore audit](RESTORE_REVIEW.md),
  [restore closure](RESTORE_CLOSURE.md), [lessons](LESSONS.md),
  [future integration](INTEGRATION.md).

All native jobs are finished. The owned instance is confirmed stopped; see
[fleet/final-instance-state.json](fleet/final-instance-state.json). The source
and evidence are local commits on `james/nav-budget-screen`; no publication,
merge to origin/main or live budget change was performed in this resumed task.

[PEER_HANDOFF.md](PEER_HANDOFF.md) records Claude's completed state and the
non-canonical H1+H2 work left in its separate tree.
