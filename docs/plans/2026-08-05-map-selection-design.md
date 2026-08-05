# Map selection: best-of-K, and the RNG architecture under it

2026-08-05. Ships with `src/ctf/map_seed.nim`, `arena.selectBestMap`,
`map_rules.MapSelectionK`, `tools/gen_validation_baseline.nim` and
`map_eval bestof`.

## 1. The problem

`generateCtfMap` returned the first of up to 100 attempts that passed
`validateGeneratedMap`. Measured first-attempt pass rates:

| team count | first-attempt pass |
|---|---|
| 2 | 92.0% (185/201) |
| 4 | 47.3% (95/201) |

At 92% the validator is not selecting; it is catching crashes. The shipped map
was therefore a uniformly random draw — the 50th percentile of the generator's
own quality range, every time.

Selection is the cheapest quality available to any generator, and it is
generator-independent: it works on the column lattice we have and on whatever
the structure pass builds next.

## 2. What shipped

### 2.1 `selectBestMap` — the ranker, which does not know its generator

```nim
proc selectBestMap*(
  seed: int,
  k: int,
  produce: MapCandidateFn,        # (seed, attempt) -> CtfMap
  accept: MapAcceptFn = nil,      # default: validateGeneratedMap
  score: MapScoreFn = nil,        # default: the installed MapFitness
  maxAttempts = MapGenMaxAttempts,
): MapSelection
```

It draws candidates 0, 1, 2 … of ONE seed, keeps those that pass the gate, and
returns the highest-scoring of the first `k` of them, with the attempt
accounting (`attempts`, `valid`, `score`, `ranked`) a caller needs to report
its own cost honestly.

It knows nothing about columns, scenes, or how `produce` spends randomness.
A replacement generator drives the identical ranker by passing a different
`produce`; a generator with extra invariants passes its own `accept`. The
moment this function names a specific generator, the next generator has to
rewrite it — so it does not.

`generateCtfMap` is now a thin caller: draw attempt 0 (which settles the board
shell, and therefore K), then hand `generateMapAttempt` to `selectBestMap`.

### 2.2 The score comes through a hook, on purpose

`map_metrics` measures maps, so it imports `arena`; `arena` therefore cannot
import it back. `arena.setMapFitness` is installed by `map_metrics`'s module
init, and `sim` imports `map_metrics` **for that side effect**. That is what
makes selection a property of "this binary speaks CTF" rather than of which
modules it happened to pull in. A binary that imports `ctf/arena` alone falls
back to first-valid and generates a *different map for the same seed*;
`tests/test_map_select.nim` asserts the hook is live.

### 2.3 `map_seed` — one sub-stream per named scene

The generator used to run on ONE flat splitmix64 stream. Inserting a draw at
position k shifted every draw after it, so every seed re-dealt, the pool
re-curated, and every pinned baseline moved. The oversize size classes paid
that once. The endzone archetypes dodged it once, with a hand-rolled second
stream keyed `seed xor 0x5A17E9D3C0FFEE11` — which is what let compact
endzones ship with all 29 column maps byte-identical and no GameVersion bump.

`map_seed` makes that structural and open-ended:

```nim
let root = mapSeed(seed, attempt)
var shell   = root.seedStream("layout")    # SAME for every candidate
var terrain = root.stream("terrain")       # re-rolled per candidate
var roomRng = terrain.spawn("room:7")      # child node, one parent draw
var doorRng = roomRng.spawn("door:north")  # nests to any depth
```

* **Names are strings, not an enum.** There is no registry and no closed set;
  two scenes collide only if they pick the same name. A scene that does not
  exist yet must be able to appear without re-dealing the ones that do — that
  is the whole requirement, and an enum cannot meet it.
* **`spawn` costs the parent exactly one draw**, whatever the child does. A
  node that grows from 3 draws to 3000 cannot move its siblings.
* **A name is the whole key.** `stream("terrain")` is the same stream whether
  it is asked for first or last, so scenes need no evaluation order.
* **Any scene is pinnable** (`pinScene`) — hold one still and re-roll the rest.

Discipline borrowed from Cogs-vs-Clips' scene-graph mapgen
(`mettagrid/mapgen`): one root generator, every child spawned, any node
pinnable. Their two-seed split already exists here — `config.mapSeed` is the
layout, `config.seed` is the simulation.

### 2.4 The re-roll defect this also fixes

The old retry was `seed + attempt`. The first draw off the flat stream was the
SIZE CLASS, so a rejected seed re-rolled into a **different board size**:
`mapSeed 1002` did not give you "map 1002 fixed up", it gave you map 1003,
possibly at another size. Two consequences, both now gone:

* `tools/gen_map_pool.nim` had to insist on first-attempt validity, because a
  pool entry that needed one re-roll was a map the pool could not name.
* K could not be chosen per size class, because the size was not known until
  after the attempt that used it.

The shell now draws from `seedStream`, identical for every candidate. K tries
are K tries at ONE board.

## 3. Choosing K

Cost is exactly linear in K; quality is `E[max of K] = K/(K+1)` of the
generator's own range. Measured over 40 seeds (2-team, flat K):

| K | mean staticScore | worst | median |
|---|---|---|---|
| 1 (first valid) | 0.834 | 0.636 | 0.830 |
| 2 | 0.864 | 0.712 | 0.878 |
| 4 | 0.885 | 0.759 | 0.885 |
| 8 | 0.898 | 0.804 | 0.898 |
| 16 | 0.908 | 0.813 | 0.909 |

The valuable half is the **floor**, not the ceiling: 1 → 8 lifts the worst map
0.636 → 0.804. 8 → 16 buys another 0.010 for double the time.

Per-candidate cost (generate + validate + `evaluateMap`, release build):

| class | board | gen+validate | score | total |
|---|---|---|---|---|
| small | 1050x560 | 10 ms | 39 ms | 50 ms |
| standard | 1235x659 | 62 ms | 70 ms | 132 ms |
| large | 1606x857 | 49 ms | 102 ms | 151 ms |
| huge | 2223x1186 | 81 ms | 220 ms | 301 ms |
| giant | 3211x1713 | 194 ms | 453 ms | 648 ms |

So `MapSelectionK` is per class, chosen to hold ONE generated map near a
second at every size rather than to hold K constant and let a giant board cost
forty times a small one:

| class | K | ~cost per map |
|---|---|---|
| small | 12 | 0.6 s |
| standard | 8 | 1.1 s |
| large | 6 | 0.9 s |
| huge | 4 | 1.2 s |
| giant | 2 | 1.3 s |
| colossal | 1 | one candidate |

`colossal` is 1: override-only, 22 M pixels, and one `evaluateMap` there costs
more than a whole standard-board selection.

**What the live paths pay.** The map editor's `POST /api/map` goes from 49 ms
to ~1.1 s on a standard board and from 226 ms to ~1.3 s on a giant one. That is
the price of the editor showing the map the server would actually generate; a
`k` parameter exists on `generateCtfMap` for a caller that knowingly wants a
cheaper draw, but the editor must not use it — an editor that previews a
different map than the sim ships is worse than a slow editor. Server boot pays
one selection, once.

## 3b. The measured shift

`map_eval bestof --seeds 2001-2150` — 150 seeds held OUT of the curated pool
and out of the validation baseline, each generated BOTH ways, with the
hand-authored `arena` as control. Reproduce with that one command.

```
staticScore
  K=1  (first valid)  min 0.637  p25 0.786  med 0.840  p75 0.882  max 0.959  mean 0.829
  best-of-K           min 0.721  p25 0.842  med 0.901  p75 0.944  max 1.000  mean 0.889
  seeds improved 123, unchanged 27, regressed 0
```

Zero regressions is structural, not luck: the K=1 candidate is a prefix of the
K>1 candidate list, so the shipped map can never score below it. One seed
(2138) reaches 1.000 — the control's own score.

The scalar moving is not evidence on its own; a weighted rubric can be moved by
one metric. So the report prints the whole band set, and **every non-degenerate
metric moved TOWARD the control, none away:**

| metric | control (arena) | K=1 median | best-of-K median | direction |
|---|---|---|---|---|
| interiorFrac | 0.342 | 0.117 | **0.161** | toward |
| exposedFrac | 0.038 | 0.232 | **0.200** | toward |
| longRunFrac | 0.110 | 0.172 | **0.141** | toward |
| routeCapacityFrac | 0.320 | 0.438 | **0.381** | toward |
| collisionCoverRatio | 1.456 | 0.752 | **0.922** | toward |
| midOpenFrac | 0.412 | 0.607 | **0.562** | toward |
| detourMax | 1.295 | 1.111 | **1.170** | toward |
| visDegreeCv | 0.524 | 0.290 | **0.328** | toward |
| coverPermille | 167 | 90 | **110** | toward |

`chokeCount`, `standRingSpread` and `standCoverSpread` read 0 on both sides:
the column lattice produces no genuine chokepoints at all, and it is exactly
symmetric. Selection has nothing to choose between there. That is a fact about
the GENERATOR, not about selection, and it is what the structure pass exists to
change — selection cannot invent architecture, it can only ship the best board
the generator is capable of drawing.

Attempt cost per shipped map, same run (machine under load ~19, so these are
upper bounds against the per-candidate table above):

| class | maps | K | attempts drawn | ms/map |
|---|---|---|---|---|
| small | 23 | 12 | 18.3 | 988 |
| standard | 36 | 8 | 8.9 | 827 |
| large | 30 | 6 | 6.1 | 1208 |
| huge | 29 | 4 | 4.0 | 1554 |
| giant | 32 | 2 | 2.0 | 1553 |

Small boards are the outlier: 12 valid candidates cost 18.3 attempts, a ~65%
pass rate, against ~90% on standard and ~100% on large and up. The generator is
worst on its smallest board.

### 4 teams

`map_eval bestof --seeds 2001-2060 --teams 4`, 60 seeds:

```
staticScore
  K=1  (first valid)  min 0.625  p25 0.727  med 0.786  p75 0.830  max 0.889  mean 0.777
  best-of-K           min 0.658  p25 0.765  med 0.841  p75 0.890  max 0.929  mean 0.822
  seeds improved 51, unchanged 9, regressed 0
```

Same direction, smaller magnitude (+0.045 mean vs +0.060), and again 0
regressions. Every metric that moves moves toward the control; `detourMax` is
the one that does not move at all, and it sits on the WRONG side of the control
(1.412 vs 1.295) across the whole 4-team population — selection cannot fix a
bias the generator applies to every candidate.

The real 4-team finding is the ATTEMPT COST, and it is a warning for the
structure pass:

| class | K | attempts per shipped map | implied pass rate |
|---|---|---|---|
| small | 12 | 54.8 | 22% |
| standard | 8 | 35.0 | 23% |
| large | 6 | 10.4 | 58% |
| huge | 4 | 5.1 | 78% |
| giant | 2 | 2.7 | 74% |

Small and standard 4-team boards spend a third to half of the 100-attempt
budget to find K candidates; individual seeds hit 81 attempts. `selectBestMap`
degrades correctly (it ships the best of however many it found), but the
headroom is thin, and it is thin because the generator is bad at small rot90
boards — not because K is high. If the structure pass raises `MinCorridorWidth`
toward `RecommendedCorridorWidthPx`, re-measure this table before trusting the
budget.

## 4. Blast radius

Seed → map identity is **not** preserved, and that is allowed: replays pin
`mapSpec` and `resolveCtfMapMetadata` prefers it over everything, so playback
never re-runs the generator. Spec → map identity is untouched.

* `tests/fixtures/map-validation-baseline.tsv` regenerated — 307 of 402 rows
  change verdict. It now has a regenerator
  (`tools/gen_validation_baseline.nim`); it never did before.
* The curated pool re-curated. `tools/gen_map_pool.nim` now curates on the
  SHIPPED map (`generateCtfMap`) rather than on attempt 0, so the pool entry
  IS `poolCtfMap(index)` by construction, and the first-attempt-validity
  requirement is retired. 0 of 60 scanned seeds were rejected (best-of-K
  always finds a valid map); mean pool `staticScore` 0.894.
* `PoolRenderHashes` and `docs/pool-review.html` regenerated.

## 5. For the structure pass

Call `mapSeed(seed, attempt)` once, then:

* `seedStream("layout")` for anything that defines the BOARD. Whatever you put
  there is held fixed across the K candidates, which is what makes selection a
  search rather than a lottery, and what lets K be read from the size class
  before any work starts.
* `stream("<your scene>")` for anything selection should search over. Pick any
  name; you do not need to register it.
* `rng.spawn("<node>")` per room / lane / chokepoint, so tuning one node cannot
  shift the next.
* Drive selection by passing your generator as `produce` to `selectBestMap`.
  Do not write a second selection loop.
