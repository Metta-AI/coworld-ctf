# Next throughput unit: ranked mechanisms for the m5a configured-tick failure

Documents only. No source change, native job, or implementation is
proposed here; everything below waits for explicit authorization. Sources
read: `C2-m5a/configured.json` (breakdown on), `C3-configured-native-summary.json`,
`C5-m5a-stage-summary.json` and `C5_M5A_REVIEW.md` (Fluffy stages),
`P1-m5a/`, `C6_REVIEW.md` counts, `C10_SIMD_PROPOSAL.md`,
`C10_COUNTS_RESULT.md` and `C10/count-summary.json`, `C10_PROTOTYPE_NOTE.md`
with `nav-deferred-cache/tools/c10_replay.nim` and `check_c10_replay.nim`
(read only), the primary `rebuildDangerFromPoints` and `replayVisibleCells`,
the frozen generated C of the C2 replay, the registry in `PEER_PLAN.md`
section 3, `PEER_CARDS.md`, and `SCOREBOARD.md`.

## 1. What the failure is made of

Worst configured row on m5a (C2 state f9dff753 plus C2, which already
contains D0a and P1; V1, A4 and H1 came later and are small on this row):
map br-gen-5120, 32 seats, stuck replans, p95 6.485 ms against 4.0. The
per-stage p95 of that row and the same fields across all 11 configured
maps:

| map | worst p95 ms | danger p95 | planning p95 | weight refresh p95 | weapon p95 | ns per pop p95 |
|---|---:|---:|---:|---:|---:|---:|
| br-gen-505 | 4.45 | 2.05 | 1.66 | (in nav) | 0.49 | 1,607 |
| br-gen-5001 | 6.09 | 3.65 | 1.66 | | 0.51 | 1,619 |
| br-gen-5040 | 5.15 | 2.78 | 1.58 | | 0.52 | 1,543 |
| br-gen-5120 | 6.48 | 4.19 | 1.59 | 1.01 | 0.49 | 1,553 |
| br-gen-5161 | 5.36 | 3.12 | 1.52 | | 0.50 | 1,472 |
| br-gen-5204 | 5.13 | 2.78 | 1.66 | | 0.49 | 1,621 |
| br-gen-5263 | 4.70 | 2.38 | 1.60 | | 0.50 | 1,557 |
| br-gen-5312 | 5.80 | 3.58 | 1.54 | | 0.50 | 1,500 |
| br-gen-5359 | 5.30 | 2.84 | 1.61 | | 0.50 | 1,569 |
| br-gen-5400 | 5.66 | 3.22 | 1.64 | | 0.49 | 1,602 |
| br-gen-5448 | 5.36 | 3.03 | 1.60 | | 0.50 | 1,551 |

Two facts decide the ranking:

- Planning is flat. Route search is 1.5 to 1.7 ms on every map (B = 1,024
  pops at 1,472 to 1,621 ns per pop; all 11 maps have 85,814 nav cells),
  and it is the same on the 16-seat rows. The per-pop cost is a fixed
  1.6 ms per tick on this host; it does not vary with the map and does
  not track the failure.
- Danger tracks the failure exactly. The danger stage p95 runs 2.05 to
  4.19 ms across the maps and the worst tick equals danger plus the flat
  remainder (about 2.3 ms: planning 1.59, weapon 0.49, follower 0.15,
  steering 0.10) within 0.05 ms on every map. The p95 tick is a fill tick
  (one scheduled seat rebuild; at 32 seats and cadence 32 every tick has
  one), and its cost is the visibility work of 8 sources on that map's
  openness.

Fill-tick composition on m5a at 1300 px from the C5 Fluffy stages (same
tree; the stage sum 4.16 ms matches the 4.19 ms danger p95 above):

| stage | ms per fill tick | share of danger |
|---|---:|---:|
| danger.hit.replay (8 bitmap replays) | 2.35 | 56% |
| danger.packWeights (publish, Q8 refresh; 1.01 on map 5120, 0.42 on the P1 synthetic map) | 1.02 | 24% |
| danger.closeFloor (8 exact-pixel discs) | 0.43 | 10% |
| danger.scaleMax (full-raster max) | 0.28 | 7% |
| danger.clear (full-raster zero) | 0.08 | 2% |

Scale estimate (approximate prioritization, corrected per
`C10_MICRO_DECISION.md`; summed per-stage p95 values and traced stage
means are not a mathematically exact ceiling and prove nothing about what
any single unit can do): to reach p95 4.0 ms on map 5120 with the other
stages as they are, the danger stage would need to fall from about 4.19
to about 1.7 ms. On these figures a stack of exact per-fill reductions
(replay, refresh, floor, passes) looks necessary and a contribution from
the flat remainder, planning included, is not excluded; the projection
must be re-done from Fluffy after each retained unit rather than carried
forward. Whether m5a should define the gate remains James's ruling, and
construction-only gains (A-series) do not enter this estimate.

## 2. Registry check

No prior unit vectorized the replay or grouped its additions: C3 (row
cursor, rejected), C6 (scalar full-word runs only, 16 to 30 percent of
set bits, rejected at the micro gate), C7/C9 (list representations,
rejected on changing-source regimes), C8 (zero-weight omission, rejected)
are the replay units; SIMD appears in the registry only as a citation in
`C7_RESEARCH_REVIEW.md` and a compiler note. The close floor has never
been a unit (it appears only in cache design notes as part of the
rebuild). The max pass and clear pass have never been units. Weight
refresh has D0a, D1 (rejected), P1 (retained), S1 (retained, 2.3 percent)
and H11 (card). Pop-loop hypotheses H2/H3/H8/H9 are registered and
untried, and section 1 shows they cannot decide this gate.

## 3. Ranked mechanisms (at most three)

### Rank 1: C10, aligned four-cell group replay (root's proposal, counts done)

Mechanism: keep the C2 bitmap and miss recording; on a hit, process each
nonempty aligned nibble of a word as one four-cell group, one coordinate
computation per group, one vector add for full nibbles, a bitwise blend
for mixed nibbles, scalar fallback only for groups that leave the kernel
row or the map row.

Evidence it has: root's counts on the corrected C6 origin sample (64
even-spread origins, three maps, 331 and 1300 px): 98.8 to 99.7 percent
of replay additions lie in safe groups, 3.70 to 3.74 set lanes per
nonempty group, 92.0 to 92.9 percent of set bits in full nibbles; every
set-bit index checked against the scalar formula. This is the count that
C6 lacked: C6 covered only all-ones 64-bit words (16 to 30 percent of set
bits), while nearly all bits sit in full or near-full four-cell groups.
Expected size, if the per-cell overhead is what dominates: the C2 loop
executes per visible cell nine overflow-checked integer operations, one
checked 64-bit division, a non-intrinsic `countTrailingZeroBits` call,
two bounds checks and pointer reloads forced by `-fno-strict-aliasing`
(all visible in `C9/full/local-mac/generated-c/parent_replayVisibleCells.c`
and the nim.cfg in force), about 26 ns per visible cell on m5a (2.35 ms
over 8 times about 11,200 cells). Grouping divides most of that by 3.7.
That is an argument, not a measurement.

Evidence it lacks: any timing; the split between "grouping" and "SIMD";
changing-source behaviour on m5a, where C9 showed a 1.2 to 1.6 percent
excess with a Nim-identical miss path that the disassembly could not
explain and three pairs could not separate from parent noise of 0.8 to
2.0 percent; portability of the vector path to every production compile
shape.

Pre-implementation diagnostics and stopping rules (tools-only micro,
no production change), amending root's preregistration:

- Three arms, not two: C2 replay; grouped scalar (same nibble grouping,
  same one-division-per-group, plain scalar adds per set lane, raster and
  kernel pointers and lengths hoisted identically in both grouped arms,
  no Nim sequence copies); grouped SIMD (the prototype). Selection
  between them follows root's corrected rule in the decision paragraph
  below, not a "scalar first" rule.
- Stop before any whole-body candidate unless each 1300 px map gains at
  least 20 percent median replay on both hosts and no 331 px median
  regresses over 1 percent (root's limits, unchanged).
- Then the nine actual-source traces and the changing/repeated regimes
  unchanged, with the preregistered per-trace and changing-regime limits
  unchanged; for the changing regime on m5a preregister five interleaved
  pairs instead of three, decided now because of the C9 noise finding,
  which is a sample-size choice for a new unit and not a limit change.
- Portability gate before production: the vector path must have an exact
  scalar counterpart selected at compile time for every production
  compile shape, proven by the full-raster bit comparison on both
  architectures and the unchanged full quality hash.

Prototype review (`tools/c10_replay.nim`, `check_c10_replay.nim`, read only):

- Group selection is correct: `shift = ctz(word) and not 3` gives the
  aligned nibble containing the lowest set bit; lane i maps to kernel
  index k + i and to map cell gx + i, which is the row-major contiguity
  the bitmap encodes. The safe test (`kx + 3 < diameter`, `gx >= 0`,
  `gx + 3 < width`, `gy` in range, `k + 3 < kernel.len`) keeps every load
  and store inside the kernel row and the map row; padding bits are zero
  by the recording invariant, so no group starts beyond the box.
- Exactness holds: each cell still receives exactly one addition per
  source, in ascending group order; lane order inside a group is
  irrelevant because cells are independent. Full nibbles store the four
  sums; mixed nibbles store `(mask and updated) or (not mask and before)`
  (SSE2) or `vbslq_f32` (NEON), which returns the inactive lanes'
  original bits, negative zero included. The check initializes alternate
  cells to negative zero, so that path is tested. Word clearing
  `word and not (15 shl shift)` is right.
- Scalar fallback recomputes the row per lane, which is required because
  a boundary group can straddle a kernel row; it uses checked indexing.
- Gaps root already lists, and I agree they are required before timing:
  border origins (the check asserts the box fits the grid, so the
  fallback for `gx < 0`, `gx + 3 >= width` and `gy` out of range is never
  exercised), and a systematic sweep of all 16 nibble patterns in both
  safe and boundary positions. Add one case whose origin sits at each
  grid corner and edge at 1300 px so every fallback branch runs, and one
  crafted word per nibble pattern.
- Two design notes for the timed arm, not correctness: the group loop
  still carries the checked division and overflow-checked arithmetic per
  group and reloads `seat.danger.values` and `seat.dangerGeometry.kernel`
  through the seat on each group under `-fno-strict-aliasing`; hoisting
  those into locals is part of the grouped-scalar arm's definition above
  so the comparison is fair. The 16-entry mask table is a runtime `let`;
  fine for tools, a `const` in production.
- The check tool compares the prototype against a reference within one
  call on crafted bitmaps; the C6-style real-map comparison (all cells,
  float bits, real origins) should be added before the micro so real
  occupancy is covered, not only crafted geometries.

Decision: accept C10 for a tools-only micro under the amended
preregistration, after the two pending correctness additions. No
production implementation is authorized by this plan. Selection rule as
corrected by root in `C10_MICRO_DECISION.md`, fixed before timings:
prefer grouped scalar if it clears the 20 percent / 1 percent control
screen and SIMD improves it by under 5 percent; retain SIMD for the next
screen only if it clears the same control screen and improves scalar by
at least 5 percent on each 1300 px map on both hosts; if neither
qualifies, close the unit. My earlier wording ("reject SIMD if scalar
exceeds 20 percent") is withdrawn; it would have discarded a larger gain.

### Rank 2: close-floor row spans (exact, from code reading)

Mechanism: `rebuildDangerFromPoints` adds the 0.5 close floor with a per-cell
squared-distance test over a (2 times closeCells plus 1) squared box, 49 by
49 = 2,401 cells per source at 190 px, 8 sources per fill. For each row the
cells inside the disc form one contiguous interval (the distance is
monotone in `gx` on either side of the source), so the same cells can be
found by computing the interval endpoints per row and adding 0.5 over the
span. Per-cell sequence is unchanged: each cell gets source i's kernel add
(if visible) then source i's floor add (if inside), before source i plus 1,
so the float results are bit-identical.

Evidence it has: Fluffy `danger.closeFloor` 430 to 436 µs per fill tick on
m5a (8 sources), about 22 ns per box cell, against about 1,772 disc cells
per source (pi times 23.75 squared) actually added; the cost is the
per-cell test and address arithmetic, not the 14,000 adds.

Evidence it lacks: an exhaustive equivalence check (interval form versus
the per-cell test for every source sub-cell offset and every row; 64
offsets times 49 rows, trivially enumerable), and any timing.

Stopping rule: the equivalence enumeration must show zero cell
differences for every offset and range in use; and the unit is worth
running only if it can plausibly save at least 0.3 ms per fill tick,
which the 0.43 ms stage supports; if a re-read of the stage on the
configured worst row shows under 0.2 ms, drop it. Expected whole-body
effect on map 5120 is about 5 percent of the worst tick, so this is a
stack member, never a gate closer. It has no regime dependence: it runs
on hits and misses alike, so the C9-style changing-source risk does not
apply.

### Rank 3: the two remaining full-raster passes (max scan, clear) and the map-size-dependent refresh

Mechanism: `scaleMax` walks every raster cell for a max with a dead
`DangerLosWeight` branch (the constant is 1.0), 0.28 ms per fill; the clear
is a full memset, 0.08 ms; the weight refresh is 1.01 ms on map 5120
against 0.42 ms on the P1 synthetic map, so it scales with the mixed-graph
size. A four-lane max (SSE2 `maxps`, NEON `vmaxq`) is exact for finite
non-NaN values, which the raster is; the max is order-independent. The
refresh needs its own code reading (`rebuildPackedWeights` in
`body_route_query.nim`) before anything is claimed; P1 already streams
the dilation, and S1 gained only 2.3 percent, so the remaining cost per
packed cell must be counted first.

Evidence it lacks: a per-element cost figure for the refresh on map 5120
(elements per pass and ns per element against a streaming floor), and
timing for all three.

Stopping rule: read `rebuildPackedWeights`, count elements per pass on map
5120 from the index stats, and compute ns per element from the 1.01 ms
figure; compare it against a measured streaming pass over the same
element count on the same host (a tools-only measurement, not an assumed
hardware floor). If the refresh is within a small factor of that
measured pass, it is memory-bound and only the max pass and clear
remain, worth at most about 0.3 ms together on these figures; then rank
this below the close floor and do not open a unit for the refresh.
Otherwise a refresh unit is worth a counts-first proposal.

## 4. What this plan does not do

- It does not resample C9, C7, C6, C3, C8 or A8, and it does not propose
  a lazier or smaller list representation.
- It does not count A-series construction gains toward this gate.
- It does not propose changing cadence, source count, raster resolution,
  kernel support or the close-floor radius; those are semantics and
  rulings, not exact units.
- It does not open a pop-loop unit now: planning is flat at about 1.6 ms
  across maps, so it does not explain the map-to-map failure pattern,
  which is a prioritization reason and not proof that optimizing it
  cannot contribute to acceptance; H2/H3/H8/H9 stay registered.

NEXT THROUGHPUT PLAN READY
