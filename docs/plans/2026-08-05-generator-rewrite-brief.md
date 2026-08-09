# The generator rewrite — implementation brief

_2026-08-05. Hand this to the agent that builds the new map generator. It is the
distillation of a 300-seed defect audit, five research surveys (`docs/research/*.md`),
and everything measured while building the tooling you will use._

Read `docs/plans/2026-08-05-mapgen-rebuild-plan.md` for the ranked ordering and the
research docs for depth. This document is the SPEC: what to build, what it must satisfy,
how you will know, and the specific ways this has already gone wrong.

---

## 0. The one-paragraph version

Generate a **skeleton** of rooms and doorways first, in the fundamental domain, using a
Poisson-seeded Voronoi partition whose Delaunay dual starts 3-connected. Lift it by the
symmetry orbit. Then **fill** the cell interiors with cover from a shape vocabulary and a
biome, never touching the skeleton's protected pixels. Because route count only rises when
you open floor and cover only rises when you add walls, keeping those two families on
disjoint pixel sets makes both invariants hold **by construction, with zero search**.

---

## 0.5. Board shape: RECTANGULAR. Hex is a separate epic.

**Maxwell's decision, 2026-08-05: rectangular first, hex after.**

Hex arenas are epic `800a5789`, and 7 of its 9 tasks are still backlog — only the
coordinate kernel (`src/ctf/hex.nim`) and the campaign board's 6-neighbour adjacency are
done. This generator ships against the CURRENT live game, which is rectangular, and must
beat the column lattice on the fitness harness before anything else changes.

So: **do not build hex boards.** `hex.nim` is merged and available, but this work uses it
only where it already earns its place — the 3- and 6-team derivations in `map_rules`
(aspect bounds, base separation). Those are rules ABOUT team counts, not a board shape.

**But keep the symmetry abstraction clean.** The architecture in §3 is naturally
shape-agnostic: generate in a fundamental domain, lift by a symmetry orbit. Rectangular
boards use mirror/rot180/rot90; hex would use D6. Write the partition and lift stages
against a symmetry-group interface rather than hard-coding `x -> width-1-x` at every site,
so the later hex epic is an addition rather than a rewrite. This costs nothing now and is
just good design — it is NOT licence to build hex geometry.

⚠️ Concretely, hard-coding the mirror is how two of this session's three shipped fairness
bugs happened (§7): one site used `width - x` while another used `width - 1 - x`, and a
third anchored on `size div 2` whose mirror differs by one on even-sided boards. A single
symmetry abstraction with ONE definition of the reflection would have made all three
impossible.

---

## 1. Why: look at the output first

Run this before writing any code, and look at the result:

```
nim c -d:release -o:/tmp/map_sheet.out tools/map_sheet.nim
/tmp/map_sheet.out 50 /tmp/before.png        # 2-team
/tmp/map_sheet.out 50 /tmp/before4.png 2>/dev/null 4   # 4-team
```

**Fifty maps, one design.** Every board is a vertical column lattice, mirrored. The four
"column families" (`colStubs`/`colDiamonds`/`colDiscs`/`colChevrons`) are four SKINS ON THE
SAME SLOT — an 18x60 rect, an r28 diamond, an r28 disc, a 28px chevron. Changing family
changes what the pixel looks like, not what the map is. There is no lane, room or
chokepoint concept anywhere in `arena.nim`.

The rubric scores that sheet at **mean 0.939 / 1.000** and is content. Your eye needs two
seconds. **That gap is the single most important fact in this document** — see §6.

Measured defects, 300 seeds, all reproducible with `tools/mapgen_defect_probe.nim`:

| defect | measured | control (hand-authored `arena`) |
|---|---|---|
| useful windows (>=200px clear both sides) | **27.8%** | 71.4% |
| maps with NO useful window | **41.7%** | 0% |
| centre feature dead on giant boards | **100%** | n/a |
| 2-team maps with no centre architecture | **52%** | n/a |
| repair plugs as share of interior wall | 14-16% median, **50% p90 (4-team)** | 0% |
| grenade spawns in stone / unreachable (4-team) | 5.0% / 15.5% | 0% |
| `interiorFrac` (enclosure) | 0.210 with best-of-K | **0.342** |

The decisive one is not in the table. **A smarter window selector cannot fix the glass
bug**: adjacent columns sit 51-76px apart, so small and standard boards offer only 2.0-2.4
usable window spots against a draw of 2-4. The lattice spacing IS the occluder. That is why
this is a replacement, not a repair.

---

## 2. What you are replacing, and what you must not touch

**REPLACE** — `generateMapAttempt`'s drawing half in `src/ctf/arena.nim`:
- the column lattice (~:1662-1755)
- the sightline-repair prosthetic (`block sightlineRepair`, ~:1923-1988) — a loop that drops
  r28 diamonds at random column x until no 4px row is unblocked, budget `cols(40)`. Pure
  validator appeasement placed with zero regard for play, and 14-16% of a standard board's
  interior wall. **Delete it. Do not reimplement it.** §4 gives the constructive replacement.
- blind window/trench/pickup placement (~:1990-2009 and after)
- the hard-coded 138px centre offset against a scaled flag ring (~:1892) — this alone kills
  the centre feature on 100% of giant boards

**KEEP — all of it is verified and calibrated:**
- symmetry lifting, `rasterizeWallMasks` (pixel-identical to the shipped collision bake,
  pinned by `tools/mask_parity_probe.nim`), `mapWallAt`, `inShape`, `shapeBounds`,
  `pointInPolygon`, the mapSpec round-trip
- `src/ctf/map_metrics.nim` — ~45 metrics, `evaluateMap`, `staticScore`, `scoreBands`
- `src/ctf/map_rules.nim` — per-regime targets AND the population resolver
- `src/ctf/map_seed.nim` — per-scene RNG substreams
- `src/ctf/burrow.nim` — Dial's-algorithm connectivity repair, zero RNG
- `src/ctf/hex.nim` — cube coords, D6 symmetry, orbits
- `src/ctf/map_lanes.nim` — k-fold disjoint burrow **with a Menger certificate**
- `src/ctf/mapgen_vocab.nim` — 8 shape constructors, sizing derived from `map_rules`
- `src/ctf/mapgen_biomes.nim` — 5 ported terrain algorithms + dither + edge mask
- `src/ctf/mapgen_graph.nim` — scene-graph prototype, `interiorFrac` 0.345
- `arena.selectBestMap` — generator-agnostic best-of-K; it takes a candidate callback, so it
  drives your generator with no changes

---

## 3. The architecture

**Skeleton first, fill second, on DISJOINT PIXEL SETS.**

The invariants split into two families with opposite monotonicity:
- **route count** rises only when you OPEN floor
- **cover / sightline-blocking** rises only when you ADD walls

Today's pipeline oscillates between them: `burrow`'s cheapest-path dig is a straight-corridor
generator (a sightline adversary) and the plug pass narrows corridors (a route adversary),
and nothing re-checks either. Give each family its own region — a **protected skeleton** that
is never walled, a **fill region** that may be freely walled — and both hold at once.

### Stages (each a scene with its own RNG substream from `map_seed`)

1. **Seed** — Poisson-disk sample the fundamental domain at `r = lanePitchPx` (180 from
   `map_rules`). Maximal Poisson-disk gives hard bounds: inradius >= r/2, circumradius <= r,
   every Voronoi edge <= 2r. One scalar controls room scale, pinch length and street length.
   ⚠️ **You MUST seed the mirror axis at spacing < r.** A mirror axis is a Voronoi edge unless
   a seed sits on it — otherwise every point of the axis is equidistant from a seed and its
   image, and you get a perfectly straight full-board corridor down the middle of every
   2-team map. Also seed on the pedestals.
2. **Lift** by the symmetry orbit (`hex.nim`). Everything downstream inherits exact fairness.
3. **Partition** — Voronoi cells from the lifted seeds. Cells are convex, so inward offsetting
   is re-intersecting shifted half-planes: no CGAL, no straight skeleton.
   ⚠️ Symmetric seed sets are saturated with exact cocircularities — the adversarial input for
   Delaunay. Use **int64-exact incircle** (the determinant stays under 2^51 for coords <=2048),
   which `shapePolygon`'s integer vertices want anyway.
4. **Rooms and doorways** — thin wall quads along cell edges, with doorways cut at width `d`.
   Start with ALL doorways open: the Delaunay dual of a plane triangulation with >=4 vertices
   is **3-connected**, so by Menger there are 3 vertex-disjoint routes between every pair.
   Close doorways only while the check still passes. Planarity caps k <= 5.
5. **Protected skeleton** — mark the route pixels. Nothing after this may wall them.
6. **Fill** — cover inside cell interiors from `mapgen_vocab` and `mapgen_biomes`, budgeted
   against `CoverPermille`. Size the LAST piece rather than drawing it (bisect wall thickness;
   it is continuous and monotone in cover).
7. **Features with reasons** — glass only where a sightline genuinely exists to see through;
   trenches only on exposed crossings; pickups half-safe/half-contested. Each carries a stated
   purpose and a post-condition that is checked.

**The intentionality rule, which is the whole point:** every feature placement must take a
region, a purpose, and a post-condition, and must FAIL if the post-condition does not hold.
"Walls in front of glass" happened because two passes had opposed goals and no shared notion
of purpose. Make placed-but-pointless structurally impossible rather than caught later.

---

## 3.5. ARCHETYPES — the requirement that outranks the score

**Maxwell, 2026-08-05, on a 30-map 4-team sheet: _"they should be very unique from one
another, different styles... this is all the same pinwheel shape dividing the 4 corners."_**

This is the primary acceptance criterion. A generator that satisfies every invariant in §4
and produces thirty variations of one map has failed.

### The diagnosis: the route GRAPH never changes
The pinwheel is not a decoration problem. Every 4-team map today routes the same way —
**four corners connected through a centre hub** — and every 2-team map routes as parallel
columns. That is ONE graph per team count. Swapping diamonds for discs changes the pixels;
it cannot change the graph, which is why the four "column families" are indistinguishable.

⚠️ **Symmetry AMPLIFIES this.** Generating in a fundamental domain and lifting means the
design space is one domain — so a templated domain makes the template *more* visible after
the lift, not less. Variety must live inside the domain, in the topology.

### What an archetype is
An **archetype** picks the route topology and the spatial character; the biome and the shape
vocabulary then only skin it. Different archetype = different GRAPH, not different pebbles.

Suggested starting set — invent better ones, but they must differ in topology, not decor:

| archetype | route topology | character |
|---|---|---|
| **three-lane** | 3 parallel routes, distinct lengths | the MW2 grammar: one tight flank, one contested mid, one exposed fast lane |
| **ring** | a perimeter loop; the centre is contested but optional | rotations matter, centre is a risk not a requirement |
| **hub** | one dominant central space everything funnels through | high contact rate, short fights |
| **warren** | many small rooms, high route count | short sightlines, high `interiorFrac`, low open runs |
| **field** | few LARGE masses, sparse | long sightlines, cover is rare and valuable |
| **blocks** | a grid of streets | regular, readable, many equivalent routes |

For 4 teams the topology must ALSO stop being radial-only: a ring road with four bases on
it, a grid of blocks, a central keep with four approaches, or four warrens joined at the
edges are all rot90-legal and none is a pinwheel. **Radial arms from a centre are one option
among several, not the only shape a 4-fold symmetric map can take.**

### Make it measurable, or it will not happen
Archetype must be a real stage with its own RNG substream, chosen per map, and it must show
up in the numbers. Two maps of different archetypes should differ in **room count**, **route
count** and their metric fingerprint — which is exactly a MAP-Elites behaviour space over
`interiorFrac` x `routeCapacityFrac` (see `docs/research/mapgen-search-based.md`, which also
explains that our 15 bands are really ~6 constraints + ~8 style axes + ~1 quality term, and
that scoring style axes as quality is what makes the rubric saturate).

**Acceptance tests for this section specifically:**
- On a 50-map sheet, an observer can point at a tile and say which archetype it is.
- Room count and route count both vary materially across seeds — report the distributions,
  not the means.
- **The self-check: could you identify a specific seed from its picture alone?** If every
  tile is interchangeable, you have rebuilt the problem with better geometry.
- The centre of the map is not a fixture. Today essentially every 4-team board has the same
  ring at dead centre; some archetypes should have nothing there at all.

---

## 4. The invariants, and how each is guaranteed

| invariant | mechanism | class |
|---|---|---|
| k vertex-disjoint routes | Delaunay dual starts 3-connected; close doorways only while it holds. Or `map_lanes`' k-fold disjoint burrow (Menger certificate, proved 3/3 seeds) | **guaranteed** |
| stand-side cover band | budgeted region fill; size the last piece | **guaranteed** |
| no cross-field sightline | **1-D interval cover** — compute the cover, do not guess-and-retry. This REPLACES the prosthetic | **guaranteed** |
| max open run, axis-aligned | derived from spacing | **guaranteed** |
| max open run, ALL directions | only checkable — say so | checked |
| spawn zone clear of capture circle | clamp the parameter, do not validate it | **guaranteed** |
| exact fairness | generate in fundamental domain, lift by orbit | **guaranteed** |

⚠️ **Cell-size trap.** `burrow` works at 8px; the route metric measures disjointness at
`RouteCellPx = 26`. **Two corridors disjoint in burrow's grid can share a metric cell** — a
disjointness proof on the wrong grid is a proof about a different graph. Prove it on the
metric's grid.

---

## 5. Numbers that are NOT what you would assume

- **`GunRange = 1050` is a REACH, not an engagement range.** Aim is 32 discrete slots, there
  is no aim assist, and the gun samples the **13px SOLID body**, not the 34px drawn one. Jitter
  sigma is 9.4x smaller than the half-slot, so the lattice dominates:
  `R_slot = 14/tan(5.625deg) = 142px`. P(hit) is 0.47 at 300px and **0.14 at "gun range"**.
  Three constants converge on ~260px. **Any density or encounter law on gun or vision range is
  overstated 12-16x.** `ChokepointSpacingPx = GunRange` is ~4x too large; the chokepoint isovist
  should be re-cut at ~260px.
- **`MaxExposedRunPx = 132`** bounds unprotected TRAVERSE, not sightline — and the sightline
  band has a **LOWER bound of 262px**, so chopping every sightline short fails from the other
  side.
- **The enforced route band is `routeCountMin >= 2`**, not the >= 3 the design intends. Build
  for 3; know which one gates.
- **There is no absolute stand-side cover rule** — only a fairness SPREAD. Two equally naked
  stands score 0 and pass. The one causally-established property in the suite is the one the
  validator does not enforce. Adding the absolute floor is in scope.
- **Movement is L-infinity, not Euclidean** (`velX`/`velY` clamp independently): 41% heading
  anisotropy, isometry group **D4**. 3- and 6-team maps carry an irreducible 15.5% travel-speed
  penalty for one team in three. No board shape fixes it; do not try.
- **Size class now derives from the ROSTER** (`map_rules` population resolver):
  `A = max(smallest class, 101733 * opponents)`, hinged at 5.78 opponents. Do not re-add a
  uniform size draw.

---

## 6. How you will be judged, and the trap in judging

**Acceptance, measured with the hand-authored `arena` as CONTROL in every batch:**

1. `interiorFrac` median **>= 0.30** across 50 seeds (control 0.342; today 0.210).
2. `staticScore` no worse than today's mean 0.939 — necessary, not sufficient.
3. Every invariant in §4 GUARANTEED, with a test that fails if the guarantee is removed.
4. First-attempt validation pass rate reported per size class and per team count.
5. **A 50-map contact sheet that does not look like one map.** `tools/map_sheet.nim`.
6. Windows: useful fraction **>= 60%** (today 27.8%, control 71.4%).
7. Repair-plug share of interior wall: **0%** — the prosthetic is gone.

**⚠️ THE TRAP — read this twice.** The rubric and the eye disagree, and right now the eye is
right. Measured this session, twice, independently:
- The shape item scoring BEST per unit cover renders as a **barcode** of parallel stripes.
- The second-best renders as **confetti** — ~130 rice grains.
- A crude random MIXED composition scored mid-table and was the best-looking map produced.
- A fix that "improved every metric" made maps look worse (cross-axis doors turned buildings
  into dashed outlines).

`interiorFrac` per unit cover rewards fine-grained and parallel layouts, both of which look
like nothing. **Read the ranking next to the render, always.** `tools/map_sheet.nim` prints
the score beside the picture for exactly this reason. If your generator scores well and the
sheet looks like wallpaper, you have optimised the metric and lost the game.

The precedent is not hypothetical: a combat change once took moving-while-firing from 63% to
0.1% (mechanism perfect) and moved hit rate 36.0 -> 36.1 (nothing) while kills fell 34%.

**Diversity is a first-class requirement, not a nice-to-have.** The scene-graph prototype hit
the control on architecture and its own author reported it "replaced a uniform lattice of
pebbles with a uniform lattice of boxes." Scoring 1.000 on 39 of 40 seeds is not success if
the 39 are the same map — and note it also SATURATES the ranker, since `subScore` is flat 1.0
inside a band, so best-of-K silently degenerates to best-of-1 (`MapSelection.tiedAtBest`
reports this now).

---

## 7. Known blind spots in the measuring stick — do not exploit them

- **Open-run scan is axis-only** in the hard validator (horizontal rows). `map_metrics` now
  also reports `diagRunP95Px` / `diagRunMaxPx` / `diagLongRunFrac` SEPARATELY. The longest open
  line on our own control turned out to be **diagonal** (arena 790px vs 663px axis;
  arena-large 1185px, longer than a gun range). A non-axis-aligned generator can build a
  diagonal sniping lane that scores perfectly. **Check your diagonals.**
- **Chokepoint detection has no pinch LENGTH** — a 40px doorway and a 40px x 400px shooting
  gallery score identically. `map_lanes` has the length-aware predicate; the derived max pinch
  length is 66px at a 30px pinch, grading to 132px at 62px+.
- **Fairness tests have shipped green while broken** — one sampled every 9th pixel and missed
  a 19%-asymmetric wall. Sweep every pixel, every size class, both symmetries.

---

## 8. Do not build

- **WFC as the generator.** Its guarantee is local exemplar similarity, not playability; the
  decision problem is NP-hard by its author's own statement; the best path-constraint
  implementation tops out at 2 independent routes and we need 3. Fine for skinning.
- **Aperiodic tilings.** Penrose has Ammann bars — perfectly straight lines across the whole
  tiling. Aperiodic != no sightlines, and it fights mandatory point symmetry.
- **BSP for anything but base pockets.** A BSP tree is 1-connected, and an axis-aligned cut
  spanning the domain leaves a straight street — which is a weapon here.
- **Solvers at the pixel layer.** clingo on 7,192 cells grounds to ~50M+ atoms; on a 60-node
  skeleton graph it solves in single-digit ms. Topology layer only.
- **Thresholded noise as a ROOM generator.** The Euler-characteristic density of a Gaussian
  excursion set is strictly positive (blob regime, no enclosed holes) at every threshold our
  cover cap permits — you would need >50% wall to reach the hole regime. Topological, so no
  octave count or domain warp touches it (a warp is a diffeomorphism; diffeomorphisms preserve
  topology). Noise is a **texture layer**, downstream of structure. It is still worth having
  there — via marching squares into `shapePolygon` — just not load-bearing.

---

## 9. Working rules

- `nim c -d:release -r tests/tests.nim` from the worktree root. ALWAYS `-d:release` — debug is
  10-50x slower through per-pixel map code. Pipe long output to a file and grep it.
- **Commit every green increment.** The machine sleeps without warning and usage limits hit
  mid-task; several agents lost hours today by holding work uncommitted.
- Replays pin `mapSpec` and `resolveCtfMapMetadata` prefers it, so you may freely break
  seed->map identity. You may **not** break spec->map identity.
- Regenerate `tests/fixtures/map-validation-baseline.tsv` (there is a regenerator now:
  `tools/gen_validation_baseline.nim`) and `docs/pool-review.html` with any generator change —
  AGENTS.md requires the pool page to ship with it.
- Never report a count without its fraction. Merge >= 3 seeds before judging. A capture ENDS
  the episode, so episode length is itself an outcome.
