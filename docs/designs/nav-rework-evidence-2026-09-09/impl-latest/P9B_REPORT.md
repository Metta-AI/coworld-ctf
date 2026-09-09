# P9B Optimisation Campaign Report

## Round 1 — Idea 0: bounded synchronous weighted A* on the 8 px grid

### Result

Idea 0 is rejected as a production candidate. It conclusively removes static
room choice and hierarchical-segment choice from the search, but the 8 px
lattice itself cannot meet the 4 px float-oracle quality gate.

The retained production predecessor-cycle fix (`c43b97dd`) remains. The two
Idea 0 commits are measurement-only:

- `0c267361` added the preliminary global search measurement.
- `79c831ba` corrected it to use bounded radius-4 exact endpoint connectors.

The preliminary single-containing-cell result is invalid for decision-making:
48 valid corpus endpoints could not see their containing nav-cell center. All
numbers below are from the corrected ring-attached run.

### Search contract measured

- Full `BodyRouteIndex.legalMoves` graph at 8 px.
- Weighted edge cost sampled from the full dynamic danger raster and blocked
  cell, scored with the corpus float rule. This is a favorable accuracy bound
  for the proposed integer implementation; integer Q4/Q8 quantisation cannot
  recover paths the 8 px graph cannot represent.
- Octile heuristic reduced by the maximum radius-4 goal-connector displacement,
  keeping it admissible for any goal attachment.
- One generation-stamped shared experimental workspace per map, reused across
  all cases; no per-seat map-sized allocation.
- Hierarchical route retained as fallback on cap hit.
- Exact start and goal connected through clear nav cells in the existing
  radius-4 attachment ring.
- Follower smoothing was not applied to this route-level measurement; the
  checked quality route is the cell path plus exact connectors.

### Full 3,072-case native results

| Pop cap | Reached | Fallback | Illegal | Overall p95 | Overall max | Pops p95 / max | Search p50 / p95 | Longest path |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16,384 | 2,924 | 148 | 0 | 7.627% | 86.650% | 16,384 / 16,384 | 4.386 / 11.020 ms | 372 cells |
| 32,768 | 3,072 | 0 | 0 | 7.093% | 84.807% | 18,274 / 32,522 | 4.340 / 12.405 ms | 372 cells |
| 65,536 | 3,072 | 0 | 0 | 7.093% | 84.807% | 18,274 / 32,522 | 4.356 / 12.299 ms | 372 cells |

The 32,768 and 65,536 rows are route-identical: no query uses more than 32,522
pops. The existing 512-cell local-leg capacity is large enough for every
completed corpus path; no descriptor-cap increase is justified by this corpus.

Dedicated seven-sample profiles at 32,768 pops:

| Case | p50 | p95 | Pops | Path cells |
|---|---:|---:|---:|---:|
| Median case, `m09-...-default-blocked-far` | 8.526 ms | 9.226 ms | 11,021 | 214 |
| `br-gen-22010` far danger case | 18.931 ms | 20.901 ms | 27,281 | 281 |

This is already over the full 4 ms body-slice budget for one query. The
experiment was therefore not cut into the live path, and first-goal burst
timings remain the measured post-cycle-fix baseline: 835.556 ms at 16 seats and
1,683.718 ms at 32 seats. A per-tick query budget cannot repair route quality;
Idea 0b is deferred until there is a quality-capable query worth scheduling.

### Where it fails

At 32,768 pops, representative strata are:

| Stratum (r16 and r32 are identical) | p95 | max |
|---|---:|---:|
| default/none/near | 0.328% | 0.937% |
| default/none/far | 0.461% | 22.555% |
| default/danger/near | 9.405% | 29.779% |
| default/danger/far | 4.573% | 14.628% |
| carrier/danger/near | 19.647% | 84.807% |
| carrier/danger/far | 9.974% | 34.949% |
| hunter/danger/near | 2.478% | 4.154% |
| hunter/danger/far | 2.509% | 7.899% |

`blocked` matches `none`; `both` matches `danger` for these selected corpus
cases. The no-danger far maximum proves the graph itself lacks some short 4 px
routes. Danger magnifies the same half-cell placement error: a 4 px path can
run beside a high-gradient danger band that an 8 px-center path must sample or
cross. Because every route completes at 32,768 and the search uses full dynamic
cost, neither static room choice nor cap fallback explains the residual.

### Validation and constraints

Passed:

```sh
nim check -d:release -d:noSignalHandler --threads:on \
  -d:navQueryProfile tools/investigate_body_nav_p9.nim
```

The full native corpus run produced zero missing and zero illegal paths at the
32,768 and 65,536 caps. It used one process and no parallel compile. The
containment gate and corpus were untouched, `tests/tests.nim` was not run, and
Phase 10 was not started.

During the final freshness check, `origin/main` had advanced by seven commits.
It was merged cleanly, leaving the branch 0 behind. The repository-required
viewer rebuild passed and produced checkpoint `b7710621`; its sim-sources stamp
is `f7b39af6964229c6f16cf79002338d2e3180db1e92d6522d0612a6823be7b6a4`.

### Next round

Add the required Fluffy and benchmark stage instrumentation before testing the
next search shape. The strongest accuracy follow-up is a shared 4 px refinement
workspace or a hybrid that creates 4 px freedom only near danger gradients and
geometry boundaries; hierarchical query cost reductions alone cannot close
the now-isolated lattice-resolution gap.

## Round 2 — H1: lattice resolution and legality

H1 is confirmed. Among the 30 worst corrected 8 px routes, 14 oracle routes
use at least one 4 px point whose containing 8 px cell is not walkable at its
centre. There are 756 such points: 4.708% of the oracle points on average
across the 30 routes, with one route at 28.997%. Their point-weighted average
clearance is 8.923 px. The body can legally stand there, but the 8 px
centre-legality graph removes the cell. That is exactly the wall-adjacent band
where LOS-shadow danger detours live.

The full 4 px global weighted A* uses the same float danger and blocked-cell
costs, exact endpoint connectors, and one generation-stamped shared workspace.
It reproduces the existing 4 px oracle exactly across all 3,072 cases: zero
missing, zero illegal, and 0.000% inflation in every stratum. Its overall pop
p50/p95/max is 25,134 / 73,171 / 130,641, its query p50/p95 is 14.677 / 41.849
ms, and its largest pool-map workspace is 3,442,080 bytes. The dedicated median
case is 30.451 / 32.178 ms at 44,236 pops; the far danger case is 59.424 /
60.464 ms at 107,819 pops. This is an accuracy proof, not a production winner.

The first prescribed remedy, one max-clearance standable 4 px anchor per 8 px
cell, also completes all 3,072 routes legally. It improves overall p95/max to
4.021% / 50.265%, and carrier-danger-near p95/max to 11.782% / 50.265%, but
still fails both quality gates. Its overall pop p50/p95/max is 7,896 / 20,182 /
33,448 and query p50/p95 is 4.809 / 12.088 ms. The max shared workspace is
854,660 bytes. The dedicated median and far profiles are 9.042 / 10.138 ms and
15.479 / 17.489 ms respectively.

These results rule out both the room hierarchy and a single anchor per coarse
cell as the binding quality fix. The next required H1 measurement is a sparse
mixed graph with 4 px freedom near walls and 8 px anchors elsewhere; H2 remains
queued immediately after that measurement.

The prescribed geometry-only mixed graph also completes all cases legally but
does not meet the gate. It retains every standable 4 px point in cells within
two 8 px cells of centre-dead geometry, one max-clearance anchor elsewhere,
exact 4 px transition edges, and exact coarse anchor edges. Overall p95/max is
3.295% / 15.011%; carrier-danger-near p95/max is 10.415% / 15.011%. Pop
p50/p95/max is 11,749 / 30,037 / 51,587 and query p50/p95 is 7.582 / 19.578
ms. The dedicated median and far profiles are 13.859 / 14.037 ms at 18,391
pops and 27.229 / 28.517 ms at 42,083 pops. Its largest pool map has 56,960
active nodes, a 1,139,200-byte compact stamped-workspace estimate. The simple
measurement harness uses a 3,442,080-byte dense array and reports both numbers.

Therefore H1's result is narrower than “refine near walls”: full 4 px freedom
is sufficient, while one anchor per cell and geometry-only sparse refinement
are not. The queued danger-adaptive Idea D will test whether the missing fine
freedom can be restricted by the dynamic danger footprint instead.

## Round 2 — H2: per-pop cost

H2's proposed hot-loop changes help, but the <=60 ns/pop target is rejected on
this machine. A four-million-iteration component profile on the selected far
danger map measured:

| Component | Before | Replacement |
|---|---:|---:|
| Danger sample + Q8 quantise | 23.532 ns | 4.625 ns precomputed weight read |
| Hazard ETA division | 5.367 ns | 1.005 ns incremental 33-state lookup |
| Dark/precomputed hazard table read | — | 3.884 ns |
| Q4 int64 multiply/round | 8.641 ns | retained |
| Lazy int64 heap pop + push | — | 112.258 ns |
| Legality bitmap read | 5.366 ns | retained |
| Generation-stamp check | 4.155 ns | retained |

The first optimized implementation used a decrease-key heap and reached only
513.2 ns/pop median and 779.7 ns/pop p95 over the corpus; its heap pop/push
microbenchmark alone cost 240.7 ns. Replacing that bookkeeping with a lazy
duplicate-entry int64 binary heap, using constant Q4 grid-edge lengths, and
replacing goal hash lookups with generation-stamped arrays produced the final
result: 291.4 ns/pop median and 345.6 ns/pop p95, versus baseline 665.1 / 786.7
ns/pop. Pop counts remain effectively identical (baseline p50/p95 12,574 /
25,446; optimized 12,576 / 25,444).

The dedicated median case improves from 11.893 / 12.075 ms to 5.103 / 5.288
ms at 16,435 pops. The far danger case improves from 18.623 / 18.948 ms to
8.033 / 9.265 ms at 30,255 pops. All 3,072 baseline and optimized searches
reach their goal, but the 8 px graph's already-measured quality failure remains
unchanged as a decision: faster evaluation cannot restore absent 4 px lanes.

An int32 precomputed weight costs 4 bytes per nav cell per seat: 170,932 bytes
on the largest pool map measured here. The table is refreshed once per danger
generation, outside query timing. The evidence supports retaining table-based
danger and incremental hazard pricing as ingredients for a smaller search, but
not a complete global binary-heap A*.

## Round 2 — Idea D: danger-adaptive resolution

Idea D was measured immediately after H1/H2 in three complete 3,072-case rows.
Cold cells use their standable 8 px centre; hot cells expose their standable
4 px sub-lattice points. Fine/fine, coarse/coarse, and boundary transitions use
exact `segmentClear`. The danger mask is built from danger>0 and dilated before
the query. Dynamic neighbor legality is intentionally computed on demand as
proposed, so its cost is included in query latency; mask construction is timed
separately.

| Row | Hot region | Overall p95 / max | Worst p95 stratum | Pops p50 / p95 | Query p50 / p95 | Hot cells mean / max |
|---|---|---:|---:|---:|---:|---:|
| D1 | danger>0 + 1-cell margin | 0.755% / 83.301% | carrier-danger-far 5.436% | 10,855 / 31,135 | 45.148 / 147.952 ms | 3,588.96 / 11,830 |
| D2 | danger>0 + 2-cell margin | 0.780% / 83.253% | carrier-danger-far 5.427% | 11,025 / 31,920 | 46.235 / 154.742 ms | 3,804.16 / 12,383 |
| D3 | D2, current corridor rooms only | 7.093% / 84.355% | carrier-danger-near 19.647% | 8,017 / 22,066 | 30.548 / 96.574 ms | 527.47 / 7,284 |

All three rows have zero missing and zero illegal routes. D1 is the strongest
quality result short of full 4 px, but it still fails two distinct contracts:
carrier-danger-far p95 is 5.436%, and the maximum is 83.301%. The maximum is
not merely a no-danger artifact: carrier-danger-near itself reaches 83.301%.
Separately, cold no-danger/blocked far routes preserve the 8 px graph's 22.555%
maximum. Expanding the danger margin does not fix either cold-route problem.
D3 proves that limiting hot refinement to the current hierarchical corridor
removes the alternate-room freedom required to respond to danger and nearly
reproduces the Round-1 failure.

D1/D2 hot-mask builds cost 0.083 ms p50 and 1.005 / 2.564 ms p95 respectively.
D3 costs more (0.507 / 5.682 ms) because the room-membership-filtered pass is
measured after obtaining the corridor; the preceding hierarchical route query
is not included. The max pool hot bitset is 5,379 bytes per seat. Compact
active-node workspace estimates are 1,341,140 bytes (D1), 1,365,520 bytes (D2),
and 1,091,600 bytes (D3); the simple measurement harness retains the same
3,442,080-byte dense shared array for all three.

Idea D is therefore rejected in this shape. Danger-adaptive resolution is a
useful quality lever, but danger alone does not identify every fine lane needed
by the 4 px oracle, and on-demand exact legality is much too expensive. No
production path, cap, containment gate, corpus, or per-tick behavior changed.

### Round 2 validation and checkpoints

The round's revertible measurement checkpoints are:

- `fcc58a75` — full 4 px and sub-cell-anchor H1 measurement.
- `8541ac94` — geometry-only mixed-resolution H1 measurement.
- `61590874` — H2 component and before/after search-cost measurement.
- `5935030e` — Idea D danger-adaptive D1/D2/D3 measurement.

The full 3,072-case corpus was run for every H1 graph, both H2 searches, and
all three Idea D rows. H1 and Idea D additionally validate every returned path
with exact pixel legality. The canonical native quality artifact was regenerated
from the unchanged committed corpus; it exits nonzero on the known production
quality gate, as expected. The campaign did not run `tests/tests.nim`.

All three retained tools pass sequential release `nim check` with threads and
the signal handler disabled. `node tools/qa_module_eval.cjs` passes every viewer
source, GameVersion, and sim-sources-stamp check; the current stamp is
`4e1693c1bdcb8eb12c16188c21aa672317bc519a3332c465b29b7fd7d6ac504e`.

Freshness was checked before every checkpoint. `origin/main` moved twice during
the round. The first merge had the expected generated-WASM conflict; the viewer
was rebuilt from combined source and committed in merge `9271407f`. On the H2
checkpoint, a chained command printed the new one-commit-behind state but did
not stop before creating `61590874`; this sequencing error was corrected
immediately with merge `93ce132b` before Idea D began. Final branch state is
clean and zero commits behind `origin/main`.

## Round 3 — R3.1: precomputed 4 px legality

R3.1 builds one exact 8-way legal-move byte for every 4 px lattice point plus a
packed standable bit. Build timing covers the complete table construction;
after timing, an independent exhaustive pass recomputes `canStand` and exact
`segmentClear` for every bit and asserts equality. All 64 pool maps and the
seed-4242 four-team colossal map pass.

The largest pool lattice has 172,104 points. It retains 172,104 legality bytes
and 21,513 standable-bit bytes, 193,617 bytes total. Across maps, median-map
build p50 is 193.752 ms, p95-map build is 206.662 ms, and the largest observed
sample is 217.098 ms. The colossal lattice is 1,248 x 1,248 = 1,557,504 points,
exactly four nodes per 8 px nav cell. It retains 1,557,504 legality bytes plus
194,688 standable-bit bytes, 1,752,192 bytes total; its three build samples are
1.977, 1.991, and 2.003 seconds.

The exact byte count is modestly above Redirect 3's rough 171 KB / 1.6 MB
estimate because that estimate counted the legality byte but not the required
packed standable bit. This table removes every per-edge `segmentClear` call
from subsequent 4 px measurements and remains shared, immutable episode state.

## Round 3 — R3.2: legacy-grounded 4 px search loop

R3.2 measures the current `BodyPlanner` and the replacement on the exact two
mandated cases, 15 sequential release-build samples each. This corrects a
premise in Redirect 3: the repository contains no evidence for the stated
30-60 ns legacy work-unit cost, and the real planner measures 2,131-2,201
ns/work unit (2,149-2,234 ns/A* expansion) here. Its median case takes
97.829/103.527 ms p50/p95 for 44,449 work units and 43,792 expansions; its far
danger case takes 231.238/235.208 ms for 108,495 work units and 107,625
expansions. The matching float search over R3.1 legality takes 32.640/33.414 ms
and 65.333/67.312 ms, confirming that on-demand geometry was a large part of
the legacy cost.

The dense loop uses stamped `int32` g/parent/state arrays, precomputed integer
Q4 weights, a zero-valued but armed incremental-hazard table, integer octile
heuristics, and a binary heap with one packed `int64` key. There are no float,
`Option`, closure, or `segmentClear` operations in its search loop. It takes
13.015/13.807 ms at 38,813 pops (335.3/355.7 ns/pop p50/p95) on the median case
and 38.510/43.351 ms at 105,773 pops (364.1/409.9 ns/pop) on the far case. That
is about six times cheaper per unit than the actual legacy planner, but it is
not close to the redirect's unsupported 60 ns/pop target and still misses the
2/5 ms query targets. A 21-bit tie field is required, rather than the suggested
20 bits, because the colossal lattice has 1,557,504 nodes.

The largest pool map retains 193,617 bytes of R3.1 legality plus 4,130,496
bytes of shared dense workspace, 4,324,113 bytes total. One integer danger
weight table and the armed hazard-price table are 170,932 bytes each per seat.
The colossal equivalents are 1,752,192 + 37,380,096 = 39,132,288 shared bytes,
with 1,557,504 bytes per per-seat table, so the full replacement exceeds the
32 MiB budget before route-index deletion. The current colossal route index is
26,709,545 bytes; specifically, its portal-next fields plus segment-cell lists
are 19,523,113 bytes. Those structures are deletable only if a replacement no
longer needs hierarchical route construction or following. Removing both would
put the measured shared total at 19,609,175 bytes, but R3.2 does not claim the
rest of the route index can be removed safely.

## Round 3 — R3.3: danger plus wall-band mixed graph

R3.3 unions Idea D's `danger > 0` cells dilated by one nav cell with the static
wall band: a seed cell has an unwalkable 8 px centre but at least one standable
4 px point, and the band includes its one-cell neighbourhood. Every standable
4 px point in that union is searchable; one 8 px-cell anchor remains elsewhere.
Cold anchor edges are contractions of real R3.1 legal 4 px chains found at
index build, not direct shortcuts. The search prices every hidden 4 px segment
and expands the chain back into the returned route. Search graph edges therefore
perform no `segmentClear` call and the measured route remains a strict subset of
the full-4 oracle graph. Exact endpoint checks remain outside the graph-edge hot
loop for non-lattice callers; all corpus endpoints use their exact lattice node.

On all 3,072 corpus cases the combined graph has zero missing and zero illegal
routes. Overall inflation is 0.313% p95 and 0.829% max. The worst stratum is
roster-32 hunter/blocked/near (tied with the corresponding none and carrier
rows) at 0.461% p95 and 0.829% max, so every quality gate passes by a wide
margin. The search uses 10,407/31,248/52,518 pops p50/p95/max and takes
2.294/6.693 ms p50/p95 over the complete corpus.

Across cases, danger dilation covers 3,589 cells on average and 11,830 max;
the danger-plus-band union covers 6,632 average and 14,527 max. Active nodes
(fine nodes in the union plus cold anchors) are 47,601 average and 70,717 max.
The largest pool map's static wall band has 4,306 cells containing 8,414
standable fine nodes. Its maximum measured shared legality, topology, and dense
workspace footprint is 13,440,682 bytes.

The mandated median profile takes 2.949/3.214 ms p50/p95 at 12,643 pops; the
far-danger profile takes 9.902/11.162 ms at 45,150 pops. Thus neither reaches
the rough 2/5 ms targets. Full-4 R3.2 is much worse at 13.015/13.807 ms and
38.510/43.351 ms. If shipping one of these two designs, R3.3 is the clear
choice: it passes quality while using about one quarter of full-4's latency.
That is a comparative recommendation, not yet a production cut; R3.4 still has
to measure whether a deterministic per-tick query budget makes its seat-level
cost acceptable.

## Round 3 — R3.4: deterministic per-tick query budget

R3.4 measures simultaneous far-danger first-goal requests on the same pool-15
case as R3.3. Each tick walks seats in ascending stable index, admits at most K
synchronous route constructions, lets deferred seats run the production local
steering primitive toward the requested goal, and lets routed seats follow
their first returned waypoint. It runs three warm-up waves and 30 measured
waves for both 16 and 32 seats. The timing is a native arm64
**navigation-only lower bound** rather than a cut-in `ShellEpisode` body slice:
it contains every candidate route query plus steering/following work, but omits
the remaining body and episode work. A failure of this lower bound is therefore
conclusive against the inclusive 4/5 ms gate without putting a losing variant
into production.

K=2 is 18.926/20.082/23.378 ms p50/p95/max at 16 seats and
19.297/20.969/25.059 ms at 32. Deterministic admission gives seats 0-1 a route
on tick 1 and the last pair on tick 8 or 16. K=4 rises to
38.801/42.953/46.843 ms and 37.731/39.606/46.034 ms, with 4/8-tick last-seat
latency. K=8 reaches 74.931/77.816/79.792 ms and 75.483/78.327/84.073 ms,
with 2/4-tick last-seat latency. The exact first-wave admission arrays in the
R3.4 artifact confirm stable seat order for every K and roster.

K=2 wins only relative to K=4/8: it minimizes the already excessive slice at
the cost of a 16-tick 32-seat tail. It still exceeds the p95 limit by 5.2x and
the max limit by 5.0x at 32 seats. Consequently no R3.1-R3.4 experiment should
be cut into production. R3.3 solves quality and is the best algorithmic result,
but synchronous completion remains the binding constraint; the next viable
design would have to suspend and resume the R3.3 search itself under a work or
time budget rather than merely limit how many complete searches start per tick.

## Round 3 final qualification and disposition

The final clean-tree qualification ran `tools/run_body_nav_gate.sh` at
`bf77c71094f186276ff44c59c553d045e7cf64c7` in the required linux/amd64 Docker
image, limited to one CPU, with Nim 2.2.4 and the canonical release flags. It
completed every stage and returned the expected non-zero verdict because the
unchanged production navigator still fails quality and burst timing:

- Production quality: 3,072/3,072 scored, zero missing, zero illegal, 19.910%
  overall p95 and 86.650% max. The worst row is roster-32 carrier/both/near at
  36.825% p95 / 86.650% max.
- Activation/memory: pass. Maximum activation ratio is 1.982 against the 2.0
  pool limit. The colossal row is 1.881 against 3.0 and retains 28,499,284
  bytes against 33,554,432.
- Production first-goal body slice: 661.160/669.928 ms p95/max at 16 seats and
  1,289.705/1,320.415 ms at 32. Moving-goal, stuck-replan, and cold-memo rows
  also fail. Bucket danger rollover and worst-degree steady-state rows pass for
  both rosters (all p95/max values below 3.52 ms).

All four Round 3 tools pass sequential release `nim check` with threads and the
signal handler disabled. `node tools/qa_module_eval.cjs` passes module loading,
served-source equality, WASM GameVersion, and sim-source-stamp checks; the stamp
is `4e1693c1bdcb8eb12c16188c21aa672317bc519a3332c465b29b7fd7d6ac504e`.
The documentation audit found no authoritative product documentation to update:
Round 3 added measurement tools only, and this report plus scoreboard are the
authorized experiment record. The branch is clean, 55 commits ahead and zero
behind `origin/main` after the required refreshes.

Disposition: keep the four measurement checkpoints and do not ship any Round 3
candidate. R3.3 is the first candidate in the campaign to solve the full quality
gate, but neither it nor K=2 meets the timing gate. The evidence now points to a
resumable, bounded R3.3 search as the next experiment; starting fewer synchronous
whole searches cannot bound the tick that admits even one far query.

## Round 4 — R4.1: ALT landmarks and corridor margin

R4.1 measured deterministic farthest-point landmarks over the route index's
walkable 8 px cells. Because R3.3 contains 4 px nodes, an 8 px cell potential can
change by a full cell across a 4 px graph edge. The direct 128-Q4-per-cell ALT
potential was therefore inconsistent and reopening made it pathologically slow.
The retained experiment uses the strongest closed-once-safe projection: 64 Q4
per cell step, combined with the existing octile bound by `max`.

The R3.3 baseline in the same run was 10,407/31,248/52,518 pops p50/p95/max and
2.184/6.463 ms query p50/p95. L=4 produced 10,430/31,010/52,417 pops and
2.263/6.684 ms; L=8 produced 10,382/30,975/52,417 and 2.350/7.011 ms; L=16
produced 10,382/30,935/52,417 and 2.538/7.603 ms. Thus the best p95 pop reduction
was only 1.0%, and every landmark count made latency worse. The integer-Q4 graph
also has equal-cost paths with different float-oracle costs: changing expansion
order moved overall/max inflation to 0.319%/3.766% at L=4 and 0.324%/3.640% at
L=8/16. All still pass the campaign quality gate, but they do not satisfy the
stronger R4.4 requirement that the combined winner preserve R3.3's inflation.

Pool landmark retention maxima are 341,864 / 683,728 / 1,367,456 bytes for
L=4/8/16. Median pool build times are 2.696 / 6.343 / 13.236 ms. On colossal the
same tables retain 3,115,008 / 6,230,016 / 12,460,032 bytes and build in
10.742 / 37.439 / 107.461 ms cumulatively.

The independent corridor restriction used every room touched by the real
hierarchical route descriptor plus every room adjacent across a legal nav edge.
It reduced p95 pops by only 1.6% (30,758) and query p95 to 6.262 ms, while quality
regressed to 1.594% p95 / 79.659% max; the worst stratum reached 5.119% p95.
That rejects the one-room margin just as conclusively as D3's zero-margin row.
No R4.1 lever advances.

## Round 4 — R4.2: exact monotone bucket queue

R4.2 replaced R3.3's decrease-key binary heap with a circular monotone Dial
queue. Entries carry their insertion sequence, and width-16 buckets select the
lowest exact integer `f` before insertion order, so neither width approximates
priority order. Stale decreases are discarded by matching the queued `g` to the
stamped workspace. The circular array spans eight times the maximum graph-edge
cost. The per-seat `int32` cell table retains the exact Q16 combined factor; the
corpus's armed incremental-hazard overlay is zero, so orthogonal and diagonal
costs remain bit-exact while the neighbour loop performs one cell-table read.

On the mandated median case, width 1 takes 2.303/2.804 ms p50/p95 for 12,643
pops, or 182/221 ns per pop. On the far-danger case it takes 8.224/11.154 ms for
45,150 pops, or 182/247 ns per pop. This beats the R3.3 binary-heap profiles
(2.949/3.214 ms and 9.902/11.162 ms in Round 3), though the noisy far p95 is
effectively tied. Width 16 takes 3.271/3.424 ms and 11.906/12.199 ms, or
258/270 and 263/270 ns per pop; scanning colliding exact priorities costs more
than its smaller bucket array saves.

The width-1 arrays contain 4,368 bucket headers (69,888 bytes) for the median
profile and 43,680 (698,880 bytes) for the higher-cost danger profile; width 16
uses 273 (4,368 bytes) and 2,730 (43,680 bytes). Both widths return identical
route checksums across all 15 repeats and retain the same pop counts. Width 1
advances to R4.3; width 16 is rejected.

## Round 4 — R4.3: resumable pop-budgeted scheduling

R4.3 suspends the width-1 Dial search itself. One shared workspace owns the
head request; pending requests are FIFO in stable ascending seat order. Each
tick spends at most B queue pops, including stale lazy-decrease entries. A route
is reconstructed, independently checked for pixel legality, and installed only
after the search completes. Until then, every pending or in-flight seat calls
the production `steeringMask` primitive toward its current goal. A changed goal
restarts the head request in place; a changed danger generation discards and
restarts suspended workspace state. K=2 was not retained because one workspace
already meets the slice gate, the total budget is unchanged, and a second dense
workspace worsens the known colossal-memory problem.

The 18 rows cover 16/32 seats, B=4,096/8,192/12,288, and first-goal burst,
moving goals at 12-tick cadence, and forced stuck replans. Every row passes the
4 ms p95 / 5 ms max gate. Worst p95/max slice is 1.101/1.244 ms at B=4,096,
2.031/2.108 ms at B=8,192, and 3.093/3.168 ms at B=12,288. The corresponding
worst time-to-route p95/max is 501/517, 251/259, and 167/173 ticks, all from the
32-seat first-goal burst. B=12,288 therefore advances: it uses the available
slice headroom to halve the tail at each step up in budget.

At B=12,288, 16-seat first goals take 44/87/87 ticks p50/p95/max and 32-seat
first goals take 87/167/173. Moving-goal rows take 3/6/11 and 6/10/11 ticks;
stuck rows take 8/27/29 and 18/53/57. Steering covers 51.0-70.3% of seat-ticks
across those six rows. The scheduled danger changes cause two restarts in each
moving-goal row and one in each stuck row (2.27-5.71 restarts per 100 completed
routes); no change is ignored. Every row produces an identical logical
fingerprint on an immediate repeat and when request arrival is reversed, because
stable seat order—not caller order—defines FIFO admission.

## Round 4 — R4.4: combined winner

The combined experiment keeps R3.3's danger-plus-wall-band graph and existing
octile heuristic, replaces its binary heap with exact width-1 Dial, and schedules
one resumable workspace at B=12,288 with production steering during the wait.
No R4.1 reducer is included. The full 3,072-case corpus returns zero missing and
zero illegal routes, 0.313115% overall p95 / 0.829058% max inflation, and
0.460583% worst-stratum p95. Those values exactly match R3.3. Pops are
10,409/31,251/52,523 p50/p95/max; deterministic insertion-order ties account for
the tiny pop-count difference without moving the quality distribution. Corpus
query time is 2.161/5.825 ms p50/p95. The scheduler qualification is the same 18
rows recorded in R4.3; every row passes, with 3.093/3.168 ms worst p95/max.

Colossal cannot fit this representation under 32 MiB. Its 1,557,504 fine nodes
make the dense stamped `g`/parent/state workspace 37,380,096 bytes by itself.
One 8 px-resolution `int32` weight table is 1,557,504 bytes per seat, or
49,840,128 bytes for 32 seats. The smallest concrete retained set identified by
this experiment is 1,752,192 bytes of fine legality plus 24,920,064 bytes for
32 int16 8 px weight tables, leaving 6,882,176 bytes for compact active-node
topology and workspace. Reaching that bound requires dropping the dense
full-board workspace and the hierarchical portal next-hop/segment-cell fields
once hierarchical following is no longer primary. This is measurement and a
design bound, not authorization: no production cap was changed.

## Round 4 final qualification and disposition

The final checkpoint is `8491b14b54104179e1333d9179f70adb297cc162`.
R4.1-R4.4 all pass sequential release `nim check` with threads and the signal
handler disabled. Viewer module evaluation, served-source equality, WASM
GameVersion, and sim-source-stamp checks pass. The R4.4 native artifact reruns
all 3,072 quality cases; the R4.3 artifact reruns all 18 scheduling rows and
their repeat/permutation determinism checks. The campaign did not run
`tests/tests.nim`.

The clean-tree canonical production gate ran in linux/amd64 Docker with one CPU,
Nim 2.2.4, and image
`sha256:8bc218cb8a4aba668c7e41ef286b7ee80d55c8720c818509c511f62966fa9994`.
It returns the expected nonzero verdict because Round 4 remains measurement
code and the production navigator is unchanged. Production quality is
19.910% p95 / 86.650% max with zero missing/illegal; the worst row is
roster-32 carrier/both/near at 36.825% p95 / 86.650% max. Activation passes:
the maximum pool ratio is 1.941, and colossal is 1.918 with 28,499,284 retained
bytes. Production first-goal p95/max is 677.508/697.238 ms at 16 seats and
1,294.583/1,306.523 ms at 32. The 32-seat danger-rollover row is also just over
the gate in this host-sensitive run at 4.057/5.479 ms; worst-degree remains
green at 3.336/3.451 ms.

Disposition: retain all four Round 4 checkpoints. R4.1 rejects ALT and the
adjacent-room corridor. R4.2 selects width-1 exact Dial. R4.3 selects one shared
workspace and B=12,288. R4.4 proves that combination preserves R3.3 quality and
bounds all measured navigation slices, but it is not production code and the
colossal representation exceeds the cap. Do not change caps or start Phase 10;
the next decision belongs to James.

After qualification, `origin/main` advanced to `ff55e9e2` with ladder-only
tools/docs. It was merged without conflict as `bb461344`; viewer/source-stamp QA
still passes, the worktree is clean, and the branch is zero commits behind.


## Round 5 — R5.1a/b: admission order and arrival probes

The admission harness uses the R4.4 mixed graph, exact width-1 Dial queue, one
persisted workspace, production steering for every waiting seat, and a deliberately
heterogeneous burst: even seats use the near corpus query and odd seats the far
query. This makes shortest-job-first measurable without changing the total work.
Every row repeated with the same fingerprint and with reversed caller order;
stable seat index breaks equal-estimate ties.

R5.1a shortest-job-first results follow. Route ticks are p50/p95/max and slice
milliseconds are p95/max.

| B | seats | scenario | route ticks | slice ms | routes installed in issue tick |
|---:|---:|---|---:|---:|---:|
| 4096 | 16 | first_goal_burst | 8/137/137 | 0.773/0.867 | 1 |
| 4096 | 16 | moving_goal_12_tick_cadence | 5/104/137 | 0.645/0.695 | 4 |
| 4096 | 16 | stuck_replans | 37/85/85 | 1.094/1.15 | 0 |
| 4096 | 32 | first_goal_burst | 15/257/273 | 0.658/0.706 | 1 |
| 4096 | 32 | moving_goal_12_tick_cadence | 18/241/273 | 0.664/0.697 | 2 |
| 4096 | 32 | stuck_replans | 80/164/169 | 1.073/1.116 | 0 |
| 8192 | 16 | first_goal_burst | 4/69/69 | 1.224/1.316 | 2 |
| 8192 | 16 | moving_goal_12_tick_cadence | 3/52/69 | 1.207/1.298 | 8 |
| 8192 | 16 | stuck_replans | 11/40/43 | 2.085/2.164 | 0 |
| 8192 | 32 | first_goal_burst | 8/129/137 | 1.266/1.357 | 2 |
| 8192 | 32 | moving_goal_12_tick_cadence | 5/104/137 | 1.425/1.566 | 8 |
| 8192 | 32 | stuck_replans | 32/80/85 | 2.05/2.139 | 0 |
| 12288 | 16 | first_goal_burst | 3/46/46 | 1.825/1.872 | 3 |
| 12288 | 16 | moving_goal_12_tick_cadence | 2/35/46 | 1.76/1.854 | 12 |
| 12288 | 16 | stuck_replans | 8/27/29 | 2.546/2.641 | 0 |
| 12288 | 32 | first_goal_burst | 5/86/91 | 1.844/1.9 | 3 |
| 12288 | 32 | moving_goal_12_tick_cadence | 4/70/91 | 1.796/1.887 | 12 |
| 12288 | 32 | stuck_replans | 18/53/57 | 2.603/2.838 | 0 |

At B=12,288, SJF changes first-goal p50 from FIFO 23 to 3 ticks at 16 seats
and 46 to 5 at 32 seats. It does not change p95/max (46/46 and 86/91),
because the same far searches still consume the same total work. Moving-goal
p95 improves from 41 to 35 and 86 to 70. Stuck rows are homogeneous and
unchanged. SJF is therefore a useful fairness/median policy, not a tail fix.

R5.1b spends the same total budget on 1,024-pop probes in the arrival tick,
discarding incomplete probes before ordinary FIFO admission:

| B | seats | scenario | route ticks | slice ms | installed in issue tick | discarded probe pops |
|---:|---:|---|---:|---:|---:|---:|
| 4096 | 16 | first_goal_burst | 70/138/138 | 0.636/0.707 | 0 | 4096 |
| 4096 | 16 | moving_goal_12_tick_cadence | 53/137/137 | 0.645/0.747 | 0 | 7168 |
| 4096 | 16 | stuck_replans | 38/85/85 | 1.086/1.241 | 0 | 7168 |
| 4096 | 32 | first_goal_burst | 138/258/274 | 0.624/0.696 | 0 | 4096 |
| 4096 | 32 | moving_goal_12_tick_cadence | 121/257/273 | 0.653/0.758 | 0 | 7168 |
| 4096 | 32 | stuck_replans | 80/164/169 | 1.082/1.256 | 0 | 7168 |
| 8192 | 16 | first_goal_burst | 36/70/70 | 1.209/1.287 | 0 | 8192 |
| 8192 | 16 | moving_goal_12_tick_cadence | 18/61/69 | 1.142/1.194 | 3 | 15360 |
| 8192 | 16 | stuck_replans | 14/40/43 | 2.215/2.465 | 0 | 14336 |
| 8192 | 32 | first_goal_burst | 70/130/138 | 1.285/1.392 | 0 | 8192 |
| 8192 | 32 | moving_goal_12_tick_cadence | 52/129/137 | 1.206/1.526 | 3 | 15360 |
| 8192 | 32 | stuck_replans | 35/82/85 | 2.259/2.54 | 0 | 14336 |
| 12288 | 16 | first_goal_burst | 24/47/47 | 1.823/1.872 | 0 | 12288 |
| 12288 | 16 | moving_goal_12_tick_cadence | 12/41/46 | 1.708/1.789 | 3 | 21504 |
| 12288 | 16 | stuck_replans | 8/27/29 | 3.224/3.681 | 0 | 22528 |
| 12288 | 32 | first_goal_burst | 47/87/92 | 1.782/1.838 | 0 | 12288 |
| 12288 | 32 | moving_goal_12_tick_cadence | 35/86/92 | 1.708/1.764 | 3 | 21504 |
| 12288 | 32 | stuck_replans | 20/53/57 | 2.644/3.634 | 0 | 22528 |

No near first-goal query completes inside 1,024 pops. At B=12,288 the twelve
failed probes consume the whole arrival-tick budget, so first-goal p50/p95/max
regresses by one tick to 24/47/47 and 47/87/92. The few in-tick moving-goal
completions do not repay the repeated discarded work. Reject two-phase
admission.

The extra combination row uses SJF at B=16,384. First-goal p50/p95/max becomes
2/35/35 ticks at 16 seats and 4/65/69 at 32, versus FIFO 18/35/35 and
35/65/69. Moving-goal p95 falls from 31 to 26 and 64 to 52. First-goal slice
p95/max is 2.530/2.583 ms and 2.442/2.684 ms. This is the best native tail row,
but the larger budget—not admission order—causes the tail reduction, so it is
not promoted over accepted R4.4 without an integrated canonical gate.

## Round 5 — R5.1c/d: loop cost and warm starts

The accepted Dial workspace was already structure-of-arrays. The staged loop
walks only set bits in the legality byte, stages neighbour nodes and stamps,
uses direct midpoint arithmetic, and checks queued g before the generation
stamp on stale entries. Its required 18-row matrix is:

| B | seats | scenario | route ticks | slice ms |
|---:|---:|---|---:|---:|
| 4096 | 16 | first_goal_burst | 130/259/259 | 0.654/0.908 |
| 4096 | 16 | moving_goal_12_tick_cadence | 8/14/15 | 0.634/0.721 |
| 4096 | 16 | stuck_replans | 37/85/85 | 1.115/1.138 |
| 4096 | 32 | first_goal_burst | 259/501/517 | 0.654/0.77 |
| 4096 | 32 | moving_goal_12_tick_cadence | 11/27/29 | 0.637/0.754 |
| 4096 | 32 | stuck_replans | 80/164/169 | 1.118/1.173 |
| 8192 | 16 | first_goal_burst | 65/130/130 | 1.25/1.33 |
| 8192 | 16 | moving_goal_12_tick_cadence | 4/9/9 | 1.264/1.367 |
| 8192 | 16 | stuck_replans | 11/40/43 | 2.08/2.161 |
| 8192 | 32 | first_goal_burst | 130/251/259 | 1.235/1.371 |
| 8192 | 32 | moving_goal_12_tick_cadence | 8/13/15 | 1.258/1.331 |
| 8192 | 32 | stuck_replans | 32/80/85 | 2.083/2.316 |
| 12288 | 16 | first_goal_burst | 44/87/87 | 1.806/1.951 |
| 12288 | 16 | moving_goal_12_tick_cadence | 3/6/11 | 1.77/1.876 |
| 12288 | 16 | stuck_replans | 8/27/29 | 2.658/2.741 |
| 12288 | 32 | first_goal_burst | 87/167/173 | 1.745/1.973 |
| 12288 | 32 | moving_goal_12_tick_cadence | 6/10/11 | 1.906/2.103 |
| 12288 | 32 | stuck_replans | 18/53/57 | 2.701/3.227 |

On the median profile, accepted/staged query p50/p95 is 2.334/2.903 ms versus
2.417/2.683 ms, or 184/229 versus 191/212 ns per settled pop. On the far
danger profile it is 8.554/10.913 versus 8.365/10.271 ms, or 189/241 versus
185/227 ns. The result is noisy and not a consistent median improvement;
neither path approaches 100 ns/pop.

An explicit CPU-prefetch follow-up loads the state and g rows for all legal
neighbours before processing them. Its profile is 2.454/2.945 ms and 194/232
ns/pop on the median case, and 8.469/9.413 ms and 187/208 ns/pop on the far
case. It improves the far p95 only while making the median case worse. At
B=16,384:

| seats | scenario | route ticks | slice ms |
|---:|---|---:|---:|
| 16 | first_goal_burst | 33/65/65 | 2.473/2.607 |
| 16 | moving_goal_12_tick_cadence | 2/9/9 | 2.363/2.594 |
| 16 | stuck_replans | 7/20/22 | 3.222/3.482 |
| 32 | first_goal_burst | 65/126/130 | 2.424/2.611 |
| 32 | moving_goal_12_tick_cadence | 4/8/9 | 2.47/2.637 |
| 32 | stuck_replans | 11/40/43 | 3.239/3.49 |

The accepted loop at B=16,384 independently reduces first-goal tail from
87/87 to 65/65 ticks at 16 seats and from 167/173 to 126/130 at 32. Its worst
slice is the 32-seat stuck row at 3.125/3.720 ms. The staged and prefetched
loops preserve route ticks and also remain under the native slice gate, but
their per-pop results do not justify replacing the simpler accepted loop.

R5.1d seeds at most 128 previous-route cells, repriced under the new table with
a concrete parent chain:

| B | seats | scenario | route ticks | slice ms | warm seeds | queue pops |
|---:|---:|---|---:|---:|---:|---:|
| 4096 | 16 | first_goal_burst | 130/259/259 | 0.754/1.002 | 0 | 1057856 |
| 4096 | 16 | moving_goal_12_tick_cadence | 8/14/15 | 0.648/0.743 | 26 | 205696 |
| 4096 | 16 | stuck_replans | 37/85/85 | 1.132/1.16 | 6 | 443520 |
| 4096 | 32 | first_goal_burst | 259/501/517 | 0.656/0.801 | 0 | 2115712 |
| 4096 | 32 | moving_goal_12_tick_cadence | 11/27/29 | 0.653/0.764 | 26 | 263936 |
| 4096 | 32 | stuck_replans | 80/164/169 | 1.293/1.44 | 6 | 788736 |
| 8192 | 16 | first_goal_burst | 65/130/130 | 1.251/1.355 | 0 | 1057856 |
| 8192 | 16 | moving_goal_12_tick_cadence | 4/9/9 | 1.255/1.358 | 40 | 313096 |
| 8192 | 16 | stuck_replans | 11/40/43 | 2.093/2.157 | 16 | 541824 |
| 8192 | 32 | first_goal_burst | 130/251/259 | 1.235/1.534 | 0 | 2115712 |
| 8192 | 32 | moving_goal_12_tick_cadence | 8/13/15 | 1.299/1.426 | 58 | 411392 |
| 8192 | 32 | stuck_replans | 32/80/85 | 2.087/2.204 | 16 | 887040 |
| 12288 | 16 | first_goal_burst | 44/87/87 | 1.875/2.084 | 0 | 1057856 |
| 12288 | 16 | moving_goal_12_tick_cadence | 3/6/11 | 1.889/2.055 | 42 | 413224 |
| 12288 | 16 | stuck_replans | 8/27/29 | 3.272/3.325 | 24 | 640128 |
| 12288 | 32 | first_goal_burst | 87/167/173 | 1.834/1.985 | 0 | 2115712 |
| 12288 | 32 | moving_goal_12_tick_cadence | 6/10/11 | 1.891/2.004 | 74 | 529704 |
| 12288 | 32 | stuck_replans | 18/53/57 | 2.694/2.932 | 24 | 985344 |

Warm cells are accepted on moving and stuck rows, but queue pops, settled pops,
and route ticks are identical to the unseeded staged loop in every row. The
added entries do not improve the frontier because the goal-side search and
existing heuristic settle the useful region first. Reject warm starts.

## Round 5 — R5.2: gameplay cost while a route is pending

The steering replay uses the game's integer acceleration, friction, maximum
speed, motion scale, and collision check. Remaining distance is measured on
the exact static 4 px legality graph with 64/91 Q4 edge costs. After route
installation both arms use the same ideal static-geodesic descent, so this
isolates the wait. It is an idealized kinematic replay, not a full server
episode.

For 16 seats (route tail 87 ticks), scheduled/ideal remaining-distance ratio
p50/p95/max is 1.0000/1.0000/1.0000 at tick 24,
1.0037/1.0044/1.0044 at 48, 1.0000/1.0064/1.0064 at 96, and
1.0000/1.0000/1.0000 at 172. For 32 seats (tail 167), it is
1.0000/1.0000/1.0000, 1.0044/1.0044/1.0044,
1.0064/1.0089/1.0089, and 1.0000/1.0109/1.0193 at the same ticks.
No seat meets the eight-tick dead-end threshold. There are 48 and 102 aggregate
no-progress seat-ticks before installation. In this scenario, production
steering covers the route wait with at most a 1.93% sampled distance penalty.

## Round 5 — R5.3: concrete colossal fit

The compact measurement retains exact 4 px legality; one signed int16 per
seat/cell packing exact 15-bit danger Q8 plus the hot-dilation flag; and a
backbone containing uint8 legal moves, uint16 room IDs, uint16 component IDs,
and the wall-band bitset. Cold 8 px transitions and refined anchors are derived
rather than retained. One fixed sparse open-address workspace uses 131,072 hash
slots, 65,536 queue entries, and 65,536 width-1 Dial buckets.

On the largest pool map the exact retained total is 6,948,856 bytes:
193,617 legality, 2,734,912 packed weights for 32 seats, 219,007 backbone,
and 3,801,320 workspace. That leaves 9,828,360 bytes under 16 MiB.
On colossal it is 32,469,128 bytes: 1,752,192 legality, 24,920,064 weights,
1,995,552 backbone, and 3,801,320 workspace. It fits under 32 MiB with
1,085,304 bytes spare.

The full corpus has zero missing and illegal routes, 0.382739% overall p95,
0.829058% max, and 0.460583% worst-stratum p95. The slight p95 difference from
R4.4 is equal-Q4 tie selection. Memory is feasible, but throughput is not:
median query p50/p95 is 11.328/12.333 ms at 1,037/1,129 ns per settled pop;
far query is 34.371/35.623 ms at 779/807 ns. Keep the retained-set design as
proof of fit, not as a production implementation.

## Round 5 — R5.4: K=2 and K=4 workspaces

Each workspace owns one suspended request. A single thread visits active
workspaces in stable round-robin order with a 1,024-pop quantum and the same
total B; production steering covers every pending seat. Repeats and reversed
caller order produce identical fingerprints.

| K | B | seats | scenario | route ticks | slice ms | dense workspace bytes |
|---:|---:|---:|---|---:|---:|---:|
| 2 | 4096 | 16 | first_goal_burst | 130/259/259 | 0.696/0.812 | 8260992 |
| 2 | 4096 | 16 | moving_goal_12_tick_cadence | 8/15/15 | 0.742/0.824 | 8260992 |
| 2 | 4096 | 16 | stuck_replans | 43/85/85 | 1.201/1.236 | 8260992 |
| 2 | 4096 | 32 | first_goal_burst | 259/517/517 | 0.713/0.847 | 8260992 |
| 2 | 4096 | 32 | moving_goal_12_tick_cadence | 11/27/29 | 0.683/0.813 | 8260992 |
| 2 | 4096 | 32 | stuck_replans | 85/169/169 | 1.137/1.288 | 8260992 |
| 2 | 8192 | 16 | first_goal_burst | 65/130/130 | 1.334/1.434 | 8260992 |
| 2 | 8192 | 16 | moving_goal_12_tick_cadence | 4/8/8 | 1.313/1.407 | 8260992 |
| 2 | 8192 | 16 | stuck_replans | 16/43/43 | 2.192/2.379 | 8260992 |
| 2 | 8192 | 32 | first_goal_burst | 130/259/259 | 1.335/1.499 | 8260992 |
| 2 | 8192 | 32 | moving_goal_12_tick_cadence | 7/14/15 | 1.319/1.426 | 8260992 |
| 2 | 8192 | 32 | stuck_replans | 37/85/85 | 2.2/2.444 | 8260992 |
| 2 | 12288 | 16 | first_goal_burst | 44/87/87 | 1.994/2.217 | 8260992 |
| 2 | 12288 | 16 | moving_goal_12_tick_cadence | 3/11/11 | 2.167/2.449 | 8260992 |
| 2 | 12288 | 16 | stuck_replans | 8/29/29 | 3.317/3.406 | 8260992 |
| 2 | 12288 | 32 | first_goal_burst | 87/172/173 | 1.858/2.067 | 8260992 |
| 2 | 12288 | 32 | moving_goal_12_tick_cadence | 6/10/11 | 1.89/2.081 | 8260992 |
| 2 | 12288 | 32 | stuck_replans | 22/53/57 | 3.222/3.241 | 8260992 |
| 4 | 4096 | 16 | first_goal_burst | 130/259/259 | 0.661/0.896 | 16521984 |
| 4 | 4096 | 16 | moving_goal_12_tick_cadence | 8/14/15 | 0.724/0.876 | 16521984 |
| 4 | 4096 | 16 | stuck_replans | 43/85/85 | 1.233/1.417 | 16521984 |
| 4 | 4096 | 32 | first_goal_burst | 260/516/517 | 0.655/0.914 | 16521984 |
| 4 | 4096 | 32 | moving_goal_12_tick_cadence | 11/28/29 | 0.724/0.882 | 16521984 |
| 4 | 4096 | 32 | stuck_replans | 85/169/169 | 1.218/1.321 | 16521984 |
| 4 | 8192 | 16 | first_goal_burst | 65/130/130 | 1.39/1.594 | 16521984 |
| 4 | 8192 | 16 | moving_goal_12_tick_cadence | 4/8/8 | 1.479/1.581 | 16521984 |
| 4 | 8192 | 16 | stuck_replans | 22/43/43 | 2.388/2.544 | 16521984 |
| 4 | 8192 | 32 | first_goal_burst | 130/259/259 | 1.303/1.601 | 16521984 |
| 4 | 8192 | 32 | moving_goal_12_tick_cadence | 8/14/15 | 1.509/1.648 | 16521984 |
| 4 | 8192 | 32 | stuck_replans | 43/85/85 | 2.369/2.463 | 16521984 |
| 4 | 12288 | 16 | first_goal_burst | 44/87/87 | 2.003/2.155 | 16521984 |
| 4 | 12288 | 16 | moving_goal_12_tick_cadence | 3/6/6 | 1.995/2.069 | 16521984 |
| 4 | 12288 | 16 | stuck_replans | 8/29/29 | 3.416/3.449 | 16521984 |
| 4 | 12288 | 32 | first_goal_burst | 87/173/173 | 2.051/2.237 | 16521984 |
| 4 | 12288 | 32 | moving_goal_12_tick_cadence | 6/10/10 | 2.033/2.145 | 16521984 |
| 4 | 12288 | 32 | stuck_replans | 22/57/57 | 3.417/4.188 | 16521984 |

At B=12,288, K=1 first-goal p95/max is 87/87 and 167/173 ticks. K=2 produces
87/87 and 172/173; K=4 produces 87/87 and 173/173. Extra interleaving cannot
reduce total work and slightly delays the critical request. Dense workspace
retention doubles from 4,130,496 bytes to 8,260,992 at K=2 and quadruples to
16,521,984 at K=4. The K=4 32-seat stuck slice also reaches 3.417/4.188 ms.
Reject both.

## Round 5 final qualification and disposition

Measurement checkpoints are 2db4f21a (SJF/two-phase), 6ebff3a6
(loop/warm-start), e82d40f9 (steering gameplay), 824d876d (compact colossal),
4b477e27 (K workspaces), bf4bae4c (SJF plus B=16,384), and f35319ce
(explicit prefetch). Commit 6ebff3a6 was accidentally made after origin/main
advanced by one commit during a combined freshness/commit command; that
upstream tools-only change was immediately merged as 825b3c3a before further
work. A final fetch found two newer origin/main commits, including the GV61
combat change. They were merged as e7cda62b; the sole binary conflict was
resolved by rebuilding the replay viewer from the combined sources. The final
tree is zero commits behind.

All five Round 5 tools pass sequential nim check with threads and the signal
handler disabled. Viewer module evaluation, served-source equality, WASM
GameVersion, and sim-source-stamp checks pass. The campaign did not run
tests/tests.nim.

The final clean-tree canonical gate ran at
e7cda62bbfd5739a7d1dbe4f961ec8688a1ee404 in linux/amd64 Docker, one CPU,
Nim 2.2.4, image
sha256:940e3bcf32ffce02a48d452913fd45efa74a6d6e6aa5f27bb9adbec3b5fd369f.
It returns the expected nonzero verdict because production navigation remains
unchanged. Production quality is 19.910% p95 / 86.650% max with zero
missing/illegal; the worst stratum is r32/carrier/both/near at 36.825% p95.
Activation/memory passes: maximum pool activation ratio is 1.975 with at most
1,976,805 retained bytes; colossal is 1.948 and 28,499,284 bytes. Production
first-goal p95/max is 667.826/687.650 ms at 16 seats and
1,294.298/1,303.405 ms at 32. Danger rollover and worst-degree rows pass for
both rosters; the synchronous first-goal, moving-goal, stuck-replan, and
cold-memo rows fail as expected.

Disposition: R4.4 remains the accepted candidate production shape. Stable SJF
is the only no-extra-budget Round 5 option worth considering, for median and
moving-goal fairness; it does not shorten the far tail. B=16,384 is the only
measured tail reducer and remains a separate decision requiring an integrated
canonical candidate gate. Two-phase admission, staged/prefetched loops, warm
starts, and K=2/K=4 are rejected. The compact representation makes colossal fit
concrete but must be redesigned for per-pop speed before it can replace the
dense workspace. No production code, cap, or Phase 10 work was started.
