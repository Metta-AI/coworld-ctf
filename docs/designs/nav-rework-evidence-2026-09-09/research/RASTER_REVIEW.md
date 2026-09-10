# Raster review: where the LOS danger rebuild spends its time, and one exact remedy

Written 2026-09-09 by Claude (peer). Source and generated-C review only; no source edits,
no remote benchmarks. Generated C is from this Mac's release build of the focused suite at
the S1 working tree (Nim 2.2.6, `-d:release -d:useMalloc --threads:on`); the C compiler
differs from production but Nim's C emission does not, and the call structure is Nim's.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. What one rebuild does (`body_nav.nim:423-455`)
Zero the float32 raster; for each selected source (up to 8): `nextVisitGeneration`, mark the
origin cell, then `castRay` to every perimeter offset of the disc of radius
`dangerRadius = ceil(liveGunRangePx / 8)` cells (`initDangerGeometry`, 232-262); then the
close-floor loop over a 190 px square; then one pass for `DangerLosWeight` (a no-op multiply
at 1.0) and the maximum. `castRay` walks a Bresenham-style line, at each step asking
`sightCellBlocked` (twice on a diagonal step, once otherwise) and adding the kernel value
through `addVisibleCell`, which uses a per-seat `visited` stamp so a cell is added once per
source even though many rays cross it.

Work scales with rays x steps: with the harness's 331 px range the radius is 42 cells, the
perimeter has 236 offsets, and eight sources walk about 80k steps per rebuild; with the
production range (section 4) the radius is 132, the perimeter 748, and eight sources walk
about 790k steps, and at the configured 1,300 px (radius 163) about 1.2M steps. The disc
holds about 55k cells at radius 132 and 84k at 163, so at those ranges the ray walk visits
each cell roughly 14 times while adding it once. These are step counts from the geometry,
not measured costs.

## 2. What each step costs, from the generated C
`castRay` (`@pshell@sbody_nav.nim.c`): `sightCellBlocked` and `addVisibleCell` are emitted
`N_INLINE` in the same translation unit, but inside `sightCellBlocked` every predicate is a
call into `body_map`'s translation unit, which GCC cannot inline without LTO:
- `gridWidth__(map)` and `gridHeight__(map)`: real calls returning a field, each followed by
  an error-flag check (`if (*nimErr_) goto`), on every invocation, although both are loop
  invariants of the ray.
- `cellCenter__(cell)`: a real call, with two overflow-checked multiplies and adds
  (`nimMulInt`, `nimAddInt`, `raiseOverflow`).
- `isWall__(map, point)`: a real call; inside it `inBounds__` (a call within `body_map`'s own
  unit, so GCC may inline that one), then an overflow-checked `y * mapWidth + x`, then a
  bounds-checked read of the pixel `wall: seq[bool]`.
So a blocked-cell query is four cross-unit calls, four overflow checks, one bounds check and
four error-flag checks, to read one byte. `castRay`'s body carries 19 checked-arithmetic or
bounds-check sites in total. `addVisibleCell` is cheap: bounds compares against the field's
own `gridW`/`gridH` fields, a stamp compare, and an inlined float32 add (the `+=` resolved to
an inline helper, not a call). Nim's `-d:release` keeps overflow and bounds checks on; only
`-d:danger` removes them, and production does not build with it.

Per-step cost is therefore dominated by call and check overhead, not by arithmetic. The
measured raster slice (about 1.0 ms on m6i for the 331 px workload, roughly 80k steps) is
about 12 ns per step, consistent with that picture. The share that the four calls and nine
checks represent is not measured; that is what the preregistration below measures.

## 3. Existing precomputed map data (`body_map.nim`)
- `wall: seq[bool]`, per pixel (what `isWall` reads).
- `clearance: seq[uint8]`, per pixel: distance-to-wall transform (`buildClearance`, 932).
- `walkable: seq[bool]`, per nav cell (`deriveWalkableGrid`, 296-303): true when the
  clearance at the cell centre exceeds `PlayerHalf` (6 px). This is a stricter predicate than
  "the centre pixel is a wall": a cell whose centre is 1-6 px from a wall is not walkable but
  is not a wall, and the ray treats it as transparent. So `walkable` cannot replace
  `isWall(cellCenter(cell))` without changing which cells block sight, which would change the
  raster, the danger hashes and routes. No existing table equals the ray's predicate.
- `component`, `roomLabel`, atlas, fields: unrelated.
The route index's wall band is a different predicate again (4 px lattice legality).

## 4. Harness fidelity finding: configured range and pool versus the corpus workload

Corrected after Codex's note; every statement below was verified in the tree at HEAD.
- Gun range. `sim_config.nim:1274` reads an explicit `gunRange` from the variant config;
  `1398-1399` fall back to the selected map's metadata only when the key is absent;
  `server.nim:1674` passes `config.gunRange` into the shell, and `resetShellForSim`
  (`server.nim:4058`) carries it into the episode. The repo manifest
  (`coworld_manifest_paintbot.json`) sets `gunRange: 1300` explicitly on every Season 2
  variant, including the shipped `battle-royale-s2` (variant 0). The pool metadata says 331
  (`data/br_s2_map_pool.json` and `data/br_map_pool.json` both carry `gunRange: 331` per map),
  which is what applies when no explicit key exists, and 331 is what the frozen corpus and
  every harness row use. The `initShellEpisode` default of 1,050 (`GunRange`) is not the live
  value either; my earlier draft's use of it was wrong, and so was any "10x measured" claim:
  no cost at 1,300 has been measured anywhere in this programme. What is arithmetic, not
  measurement: the kernel radius is `ceil(range / 8)` cells, 42 at 331 and 163 at 1,300, the
  perimeter ray count scales with the radius and the steps per ray with the radius again, so
  the ray walk at 1,300 is on the order of 15x the walk at 331 while `attenuation` clips
  contributions beyond `DangerLosRangePx = 1050`, so rays are still cast to 163 cells but add
  nothing past 131. The demo trace in `PROFILE_SERVER` ran at the 1,050 default with an
  unknown threat count on this Mac and is not evidence for 1,300 either.
- Map pool. `battle-royale-s2` has `mapPath: brpool16`, and `pickBrPoolSpecJson`
  (`br_map_pool.nim:199-215`) resolves `brpool16` to `data/br_map_pool.json`: 11 maps of
  3211 x 1713 px (about 86k nav cells). The corpus, the quality gate, the tick rows, the
  latency rows and every memory ledger in this programme use `brpool`, that is
  `data/br_s2_map_pool.json`: 64 maps of 2271 x 1212 px (about 42.7k nav cells). The source
  comment at `br_map_pool.nim:194-198` says `brpool16` is "not referenced by any shipped
  variant yet"; the manifest at HEAD contradicts it. Which manifest is actually deployed is
  outside this tree; Codex or James should confirm the published manifest version before
  the scope statement is treated as final.
- Consequence. If the deployed variant matches the repo manifest, the qualification workload
  differs from live play in two multiplicative ways: the raster and packed table are about
  twice as large per seat (86k versus 42.7k cells; the "172k int16 entries" figure quoted in
  DEVBOX_NUMBERS_2 was for giant maps), and the LOS walk per source is roughly 15x longer.
  None of this changes a threshold, and the 331 px corpus stays the frozen route-quality
  reference exactly as it is. It does mean the tick rows need a paired diagnostic at the
  configured range and on the configured pool before any m5a or c6a floor is called
  production-representative, and that every per-step saving in section 5 is worth
  proportionally more than the 331 px rows will show.

## 5. Remedies, exact only (no change to which cells block sight, no cross-seat reuse)

### R1 (recommended): a per-cell sight-blocked table built at map activation
Add to `BodyMap` (or the nav system, next to the danger geometry) a `seq[bool]` of
`navWidth * navHeight` entries, `sightBlocked[cell] = isWall(cellCenter(cell))`, computed
once in `newBodyMap` after `wall` exists, with the out-of-grid case handled by the existing
bounds compare in `sightCellBlocked`. `castRay` then reads `map.sightBlocked[y * navWidth +
x]` (with `navWidth` hoisted into a local once per ray). Exactness is by construction: the
table is the same predicate over the same immutable inputs, evaluated at activation instead
of per step, so every ray decision is identical and the raster, the danger hashes, the packed
tables and the routes are byte-identical. Memory: one byte per nav cell, 42,733 bytes on the
largest pool map (the packed table's 85,466 bytes / 2), about 86 KB on the giant `brpool16` maps and about 389 KB on colossal; it is shared
retained nav data and must be ledgered under the pool 16 MiB and total 256 MiB gates (pool
margin after L1: 16,777,216 - 16,023,601 = 753,615 bytes, so it fits). Cost removed per
step: four cross-unit calls, four overflow checks, one bounds check, four error-flag checks;
kept: one bounds compare and one byte load. A bitset would save 7/8 of the bytes at the cost
of a shift and mask per read; not worth it at 43 KB.

### R2: inline the accessors and hoist loop invariants (no memory, partial)
Mark `gridWidth`, `gridHeight`, `cellCenter`, `isWall`, `inBounds` `{.inline.}` so Nim emits
them into the calling unit, and read `gridWidth`/`gridHeight` once per ray. Exact; removes
the calls but not the checked arithmetic or the pixel-index computation. Worth doing anyway
for every other caller of `isWall`; on its own it is the smaller part of R1's saving.

### R3: disable overflow and bounds checks inside the three ray procs (no memory)
`{.push overflowChecks: off, boundChecks: off.}` around `sightCellBlocked`, `castRay` and
`addVisibleCell`, justified by a range proof: `x` and `y` are inside the nav grid after the
explicit compare, so `cellCenter` is inside the pixel map and the index is inside `wall`;
`gx`, `gy` are inside the field after the explicit compare. Exact for in-range inputs, which
the explicit compares guarantee; removes the 19 check sites. Combine with R1 for the smallest
loop. This is the only remedy that changes failure behaviour on an out-of-range bug (silent
instead of a `Defect`), so it should carry the proof in a comment and a test that feeds edge
rays at the grid border.

### R4 (not exact, listed so it is not rediscovered): visit each cell once
The sim already has `computeFovShadowcast*` (in the profile trace) and the disc holds ~14x
fewer cells than the ray walk has steps at production range. A shadowcasting or recursive
visibility pass would make the rebuild O(cells) instead of O(rays x radius). But it computes a
different visible set at the margins (a different line-of-sight definition), so the raster,
the corpus danger hashes and routes change: a behaviour and GameVersion change needing a
decision, and a corpus re-baseline. Order-of-magnitude prize at production range; excluded
from this unit by the brief's exactness requirement.

### Ranking
R1 first (largest exact saving per step, trivially provable, 43 KB ledgered); R3 second
(free of memory, needs the range proof); R2 folded into R1's implementation (hoisting is
natural once the table exists). Cross-seat raster reuse is excluded per the brief: it wins
only when seats share an ordered source list, which the identical-start harness makes
universal and real play does not.

## 6. Preregistration proposal (Codex owns the runs)

Parent: the S1 working tree (or its checkpoint), B = 1,024, breakdown on.
Candidates: K1 = R1 alone; K2 = R1 + R3 (+ R2 hoisting inside R1). Fresh nimcache each.

Exactness gate before any timing is read:
- Unit test: for all 64 pool maps and colossal, `sightBlocked[cell] == isWall(cellCenter(cell))`
  for every cell (exhaustive; a few hundred thousand compares).
- Unit test: one seat, eight sources at the harness cluster, rebuild with parent and
  candidate code paths (or parent binary snapshot) and compare the float raster and packed
  table byte for byte; plus border rays (origin within `radius` of every edge) for R3.
- Full corpus `--quality`: all 3,072 per-case `danger_hash` asserts pass (this is the exact
  raster identity check the harness already performs), route hash 5a1340213fe3..., zero
  missing/illegal.
- `--tick` pop arrays identical to the parent in all six rows; `--latency` non-timing identical.
- Ledger: activation row shared bound rises by exactly `navWidth * navHeight` bytes plus one
  sequence overhead on every map; pool and colossal gates still pass.

Timing, two axes:
- Axis A (comparability): the existing rows at 331 px, m5a first, then c6a, then m6i; three
  interleaved parent/candidate fresh processes per host on CPU 5; report
  `danger_p95_ns` minus `weight_refresh_p95_ns` (the raster slice), `danger_p95_ns`,
  whole-tick p95 and max, every repeat, worst-of-repeats, against that host's A/A spread.
- Axis B (fidelity, diagnostic): the same rows with `liveGunRangePx = 1300` (the configured
  value, not the 1,050 default) on the corpus pool, and separately one giant map from
  `data/br_map_pool.json` at 1,300 with a start and near/far pair chosen by the same seeded
  rule as the 331 rows; both need a harness option (`--gun-range`, `--pool-file`) that Codex
  owns. Parent and candidate both, same protocol. The 331 px corpus remains the frozen
  quality reference and is not touched. Report the parent's configured-range floor on m5a and
  c6a as its own finding regardless of the candidate; do not extrapolate it from 331 rows.

Prediction, stated before the run: the raster slice falls by the per-step overhead removed
(unknown fraction, expected substantial because the step is call-and-check dominated); the
weight slice, `ns/pop` and everything outside `shell.danger` are unchanged; at the configured range the absolute saving scales with the ray work, which axis B measures rather than assumes. Decision rule: carry K1 or K2 to
qualification only if every exactness check passes and the raster slice improves beyond the
A/A spread on m5a; whole-tick headroom on m5a is reported, not assumed. Cost: 2 candidate
builds x 3 hosts x 2 axes x 6 processes, plus one harness change.

## 7. What this does not establish
No timing was run. The per-step overhead fraction is inferred from the generated C, not
measured. Whether production seats commonly see eight sources at once is unknown; the demo
trace's p50/p95 spread (328 vs 1,350 us) suggests most cadence ticks are cheap and the tail
is the loaded case. R4 is the only path to a different complexity class and it is not exact. Nothing has been measured at 1,300 px or on the
`brpool16` maps; section 4's scope finding is the first thing the paired diagnostic must settle.
