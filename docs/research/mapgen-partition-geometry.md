# Space partitioning, geometry and graph structure for the map-generator rewrite

**Scope.** The math that decides *where rooms, lanes and chokepoints go*. Voronoi/Delaunay,
Poisson-disk, BSP, medial axes, graph-first layout, flow/cut, visibility, tilings, offsets.
Every technique is classified against the properties **we** need, on **our** primitives.

**Companion dimensions** (other researchers): noise/gradient fields, constructive/grammar
methods, biome and art. This document assumes those exist and does not duplicate them.

**Author's one-line answer.** Build a **maximal Poisson-disk seed set in the fundamental
domain, lift it by the symmetry group, take the Voronoi diagram, erode every cell by half a
lane width, and label each cell solid/open.** That single construction hands you rooms
(open cells), lanes (the grout between eroded cells, of *exactly* the width you chose),
chokepoints (short grout segments), a room-adjacency graph you can force to be
k-connected, exact symmetry, and obstacles that are literally `shapePolygon` rings. It costs
about a millisecond. Section 6 works it out; Section 10 says what to build first.

---

## 0. What our engine and rules actually say

Numbers here are read out of the tree, not remembered. They matter because several of the
constraints in the research brief turn out to be *different* constants than assumed, and one
of them (lanes) turns out to **already exist in the rules layer** and simply be unimplemented
by the generator.

### 0.1 Primitives

| Thing | Where | Shape |
| --- | --- | --- |
| `ArenaShape` | `src/ctf/sim_types.nim:736` | tagged union: `shapeRect`, `shapeDisc`, `shapeDiamond`, `shapeDiagonal`, `shapePolygon` |
| `shapePolygon` | `sim_types.nim:752` | `points*: seq[MapPoint]`, `MapPoint = {x,y: int}` — **closed ring of integer vertices**, implicit last→first closure, even-odd point-in-polygon at runtime (`arena.nim:851`) |
| obstacle seed set | `sim_types.nim:855` | `CtfMap.leftObstacles: seq[ArenaShape]` — **half (2-team) or quadrant (4-team) only** |
| symmetry lift | `arena.nim:939` | `buildArenaObstacles(gameMap)` stamps the orbit under `symMirror`/`symRot180`/`symRot90` |
| containment / bbox / raster | `arena.nim:899`, `:1275`, `:1304` | `inShape`, `shapeBounds`, `rasterizeWallMasks` |
| connectivity repair | `src/ctf/burrow.nim:648` | `burrow()` — Dial's algorithm, deterministic, no RNG, honours a `domain` mask (fundamental domain) and a `brushRadius` |
| metrics | `src/ctf/map_metrics.nim:730` | `evaluateMap()` — ~45 metrics; internals listed in §0.3 |
| symmetry algebra | `src/ctf/hex.nim` | D6 cube coords, `apply`, `orbit`, `orbitUnique`, `stabilizer`, `GroupC2/C3/V4/C6/D6` — **built, and not yet used by the shipping generator** |

That integer-vertex ring is the single most important fact in this document. A Voronoi cell,
an inward offset of a convex polygon, a clipped half-plane intersection and a straight-skeleton
face are all *convex or simple polygons with rational vertices*. Rounded to integers they are
`shapePolygon` with no loss of expressiveness and no new engine code. Our dimension is the
one whose output the engine already speaks natively.

### 0.2 Physical and rule constants

| Constant | Where | Value |
| --- | --- | --- |
| board (2-team) | `sim_types.nim:685` | 1235 × 659 px; 4-team square 960 × 960 (`map_rules.nim:87`) |
| hex board (standard) | `hex.nim:~710` | 969 × 1119 |
| `GunRange` | `sim_types.nim:317` | **1050** px (≈ the whole field width) |
| `VisionRangePx` | `map_rules.nim:266` | 1575 (120° cone) |
| `PlayerHalf` | `sim_types.nim:286` | 6 → **13 px solid** |
| `SoldierBodyPx` | `sim_types.nim:261` | **34 px drawn** |
| `MinCorridorWidth` | `arena.nim:1073` | **26** (shipped) |
| `RecommendedCorridorWidthPx` | `map_rules.nim:~338` | **68** = 2 × `SoldierBodyPx` — *not shipped* |
| `MaxExposedRunPx` | `map_rules.nim:~271` | **132** = `TicksToKill` × 2.75 px/tick |
| `NominalLanePx` | `map_rules.nim:733` | **124** = 2·`SoldierBodyPx` + 2·`StrafeWindowPx` |
| `lanePitchPx` | `map_rules.nim:749` | `laneWidthPx + coverSizePx` = **180** at standard size |
| `laneCount` | `map_rules.nim:736` | `max(3, …)` — "below three there is no route CHOICE" |
| `chokepointSpacingPx` | `map_rules.nim:~750` | 1050 |
| `chokepointsPerRoute` | `map_rules.nim:751` | `max(1, (traverse + 525) div 1050)` |
| `maxOpenRunPx` | `map_rules.nim:754` | 1050 (occlusion regime) / 1312 / 1575 |
| mean free sightline band | `map_rules.nim:382` | occlusion **(262, 1050)** |
| cover budget | `arena.nim:1096` | `CoverPermilleMin/Max` = **40 / 170** (4 %–17 %) |
| `StandCoverRadiusPx` | `map_metrics.nim:89` | 200 |
| `routeCountMin` hard band | `map_metrics.nim:1305` | **lo = 2.0** (`bandHard`) |

**Three corrections to the brief, worth stating plainly:**

1. **"Max open run ≤ 125 px" is really `MaxExposedRunPx = 132`** (`map_rules.nim:~271`) — the
   distance a player crosses during `TicksToKill`. It is a bound on *how far you must run with
   no cover*, not a bound on sightline length. The sightline bound is `maxOpenRunPx = 1050`
   and there is a *lower* bound too: mean free sightline must be **≥ 262 px**. A generator that
   chops every sightline to 132 px fails the band from the other side. Rooms need to be
   reasonably big; it is the *traverse* that needs cover every ~130 px.
2. **The shipped hard route band is `routeCountMin ≥ 2`, not 3.** The "3" lives in
   `map_rules.laneCount` (floor 3) as an unenforced design rule. So "≥ 3 vertex-disjoint routes"
   is currently an aspiration in the rules layer that nothing constructs and nothing gates.
3. **The rules layer already has a full lane vocabulary** — `laneCount`, `laneWidthPx`,
   `lanePitchPx`, `chokepointsPerRoute`, `chokepointSpacingPx`, `wallSpanPx` — and the
   generator implements *none* of it. The gap is not "we lack a lane concept"; it is "the lane
   concept exists in `map_rules.nim` and the column lattice in `arena.nim:1693` cannot express it."
   A partition scheme is exactly the missing middle layer. **Every recommendation below is
   aimed at those existing fields**, which means the rewrite is measurable against rules we
   already wrote down.

### 0.3 What the metrics actually compute (so we build to what is measured)

- **Vertex-disjoint routes** — `vertexDisjointRoutes` (`map_metrics.nim:530`): Dinic max-flow on a
  **26 px coarse grid** with node-splitting (unit vertex capacities) → Menger, exactly. Source
  and sink are base *approach sets*. Returns the min cut cell too, which we will exploit.
- **Coarse grid / medial axis** — `buildCoarse` (`:380`): each 26 px cell keeps its widest open
  pixel as its representative, i.e. a **coarse medial-axis sample**.
- **Chokepoints** — `map_metrics.nim:1057`: open cells with `clearPx ≤ 90`, not near a base, lying on
  a base-to-base near-geodesic; then a per-candidate cut test with removal radius `clearPx + PlayerHalf`.
- **Isovists** — `:1160`, range `GunRange = 1050`, `losClear` at 3 px stride.
- **Visibility graph** — `:1196`, adaptive stride from 52 px until ≤ 400 samples, O(n²) pairs.
- **Open runs** — `:776`, per-pixel horizontal + vertical run lengths; `longRunFrac` = share > 600 px.
- **Cost** — `evaluateMap` is **132 ms** on a standard 2-team board (`map_rules.nim:222` comment);
  `MapSelectionK[standard] = 8`, so best-of-K ≈ **1.06 s**. *The metrics are the entire budget.*
  Generation itself must be ≲ 5 ms or it changes the shape of the loop.

### 0.4 The disease we are curing

`generateMapAttempt` (`arena.nim:1485`) places columns at
`colX = xMin + ((2*col + 1) * (xMax - xMin)) div (2*columns)` (`:1693`) — a **uniform lattice** —
and pebbles along each column at a period of 88–120 px (`:1697`) around 56–60 px obstacles. The
tree's own comment (`arena.nim:1080`): *"no adjacent-slot gap exceeds 64 px."* Three consequences:

- It is a **lattice**, and every lattice has straight lattice lines. Uniform column x-positions
  mean the free space between columns is a set of full-height straight streets. This is the same
  failure mode as BSP's spanning cut (§3), arrived at by a different route.
- Every obstacle is an interchangeable pebble of fixed size, so **there is no region**: no cell,
  no room, no wall, nothing with an inside and an outside. Metrics that ask about regions
  (`interiorFrac`, `chokeCount`, `visDegreeCv`) have nothing to bite on.
- Gaps of 51–76 px are **wider than a body (34) and narrower than a lane (124)**, so they read as
  neither cover nor corridor. Glass placed there sees nothing because there is no sightline
  worth interrupting — the geometry has no scale in the 100–400 px band where a 1050 px gun lives.

---

## 1. How to read the (A)/(B)/(C) classification

A guarantee is meaningless without saying *of what* and *over what input range*. Throughout:

- **(A) HARD GUARANTEE.** For **every** seed and every parameter in the stated range, the output
  satisfies the stated property. No rejection sampling needed; a validator checking this property
  can only ever pass. The property is stated exactly, with its preconditions.
- **(B) DISTRIBUTION SHIFT.** The property holds more often, or its distribution is tightened,
  but a specific seed can violate it. Still needs the filter. Value = how much it lifts the pass
  rate and how *cheaply* violations can be repaired rather than rejected.
- **(C) COSMETIC.** Changes how the map looks or is described; does not move any measured property.

Two failure modes to watch for when reading claims in this literature:

- **Guarantee laundering.** "Voronoi cells are convex" (true, (A)) is often quoted in support of
  "Voronoi maps have nice rooms" (false in general, (B) at best). I have tried to keep the
  guaranteed statement adjacent to the design claim.
- **Guarantees that do not survive discretisation.** A 40 px doorway is *exactly* 40 px in
  continuous geometry and may be 1 or 2 cells on our 26 px routing grid depending on where it
  lands. Anything (A) in continuous space is only (A) end-to-end if the *validator's* resolution
  can see it. Flagged where relevant.

---

## 2. Master technique table

| # | Technique | What is *exactly* guaranteed | Class | Fit for us |
| --- | --- | --- | --- | --- |
| 1 | **Poisson-disk sampling** (Bridson) | No two samples closer than `r`. O(n) time. | **(A)** | ★★★ minimum spacing of cover / seeds, by construction |
| 2 | **Maximal** Poisson-disk (add coverage) | Additionally every domain point within `r` of a sample ⇒ every Voronoi cell has **inradius ≥ r/2 and circumradius ≤ r** | **(A)** | ★★★ *bounded room size*, both directions |
| 3 | **Voronoi diagram** (Fortune, O(n log n)) | Cells are convex, non-overlapping, cover the domain; the dual (Delaunay) is planar | **(A)** | ★★★ regions + region graph in one object |
| 4 | **Lloyd relaxation / CVT** | Converges to a critical point of the quantisation energy; each step is non-increasing. *No* bound on cell regularity after k steps | **(B)** | ★★ 1–2 steps is a cheap regulariser; not needed if you use #2 |
| 5 | **Power / Laguerre diagram** | Cells still convex; and weights exist realising **any prescribed set of cell areas** (Aurenhammer–Hoffmann–Aronov) | **(A)** | ★★★ "this room is exactly 18 % of the field" |
| 6 | **Voronoi of a G-invariant seed set** | The diagram is exactly G-invariant. **Corollary/trap: every mirror axis is covered by cell *boundaries* unless seeds lie on it** (§8) | **(A)** | ★★★ exact fairness free; one sharp trap |
| 7 | **Inward offset of a *convex* polygon** | = intersection of the inward-shifted edge half-planes; every point of the result is ≥ d from the original boundary | **(A)** | ★★★ 15 lines of Nim, no CGAL |
| 8 | **Minkowski erosion by a disc** (C-space) | Planning a radius-ρ disc in F ≡ planning a point in F ⊖ B(ρ). Exact | **(A)** | ★★★ turns "corridor width" into "free C-space non-empty" |
| 9 | **Straight skeleton / mitered offset** | Wavefront at time d; for **non-convex** input the mitered offset ≠ the erosion at reflex vertices (it is *less* conservative) | (A) for the wavefront, **(B)** for clearance | ★ only needed for non-convex regions; we can avoid those |
| 10 | **BSP / k-d partition** | Leaves are disjoint axis-aligned rectangles covering the domain; the BSP tree induces a **tree** on the leaves | **(A)** for disjointness, **(A)** for "connectivity is a tree" | ✗ a tree is 1-connected; and cuts span the domain (§3) |
| 11 | Offset / staggered / non-axis-aligned BSP cuts | Nothing new; reduces axis-aligned run frequency | **(B)** | ✗ still a tree |
| 12 | **Medial axis / grassfire** | The medial axis is a **deformation retract** of the region ⇒ same components and same holes; the radius function gives **exact** clearance | **(A)** as an *analysis* | ★★★ this is how "chokepoint" gets a definition (§5) |
| 13 | Medial-axis **pruning** (λ-MA, DSE, scale axis) | λ-medial axis is Hausdorff-stable w.r.t. the shape; plain MA is not | **(B)** | ★★ fixes our current spurious-branch problem |
| 14 | **Menger / unit-capacity max-flow** | # vertex-disjoint s–t paths = min vertex cut. Exact | **(A)** as measurement; **(A)** as construction via #15–17 | ★★★ already implemented; underused |
| 15 | **Every plane triangulation with n ≥ 4 vertices is 3-connected** | ⇒ 3 vertex-disjoint paths between *every* pair, by Menger | **(A)** | ★★★ the k-route answer (§7) |
| 16 | **Tutte's wheel theorem** (generate 3-connected graphs by Tutte moves from a wheel) | Every 3-connected graph is reachable; every move preserves 3-connectivity | **(A)** | ★★ complete but more machinery than we need |
| 17 | **Harary graphs `H(k,n)`** | k-connected with the minimum ⌈nk/2⌉ edges | **(A)** | ★ non-planar for k ≥ 5; useful as a *template* |
| 18 | **Tutte / barycentric embedding** | A 3-connected planar graph with the outer face pinned to a convex polygon embeds with **straight edges, no crossings, all faces convex** | **(A)** | ★★ turns an abstract graph into geometry |
| 19 | **Schnyder / de Fraysseix–Pach–Pollack** | Planar straight-line drawing on an **(n−2)×(n−2) integer grid** | **(A)** | ★★ integer vertices = `shapePolygon` natively |
| 20 | **Rectangular dualization** | If the adjacency graph is *rectangularly dualizable*, it is realised **exactly** as a rectangle packing | (A) *conditionally*, **(B)** overall (not all graphs qualify) | ★ good for base pockets, bad for organic maps |
| 21 | **Delaunay → MST → re-add ~15 % edges** (TinyKeep folklore) | MST ⇒ connected. Nothing else | **(B)** | ✗ gives 1-connectivity + luck; we can do strictly better |
| 22 | **Graph grammars / cyclic generation** (Dormans) | Whatever the rule set is proven to preserve; in practice, a cycle exists by construction | **(B)** (rule-dependent) | ★★ good for *mission* structure; see the constructive researcher |
| 23 | **Art gallery ⌊n/3⌋** (Chvátal; Fisk's constructive proof) | ⌊n/3⌋ vertex guards always suffice for a simple n-gon | **(A)** | ★★ inverted: "no single position sees a whole room" (§9) |
| 24 | **Kernel of a polygon** (Lee–Preparata, O(n)) | Exact set of points seeing the whole region; empty kernel ⇔ not star-shaped | **(A)** | ★★★ one interior pillar ⇒ empty kernel ⇒ no god spot |
| 25 | **Isovist / visibility polygon** (Joe–Simpson O(n)) | Exact visible region from a point | **(A)** as measurement | ★★ already have a sampled version |
| 26 | **Visibility graph analysis / axial map** (space syntax) | Nothing; a measurement framework | **(A)** measurement | ★★★ *the* formalisation of "lane" (§9.3) |
| 27 | **Periodic lattices** (square/tri/hex) | Exact symmetry, uniform spacing — **and infinitely many straight lattice lines** | **(A)** both good and bad | ✗ the straight lines are the disease we have |
| 28 | **Aperiodic tilings** (Penrose; hat/spectre monotile) | Admits only non-periodic tilings; repetitivity ⇒ every local patch recurs at bounded density | **(A)** for aperiodicity | ✗ Penrose has **Ammann bars**: perfectly straight lines across the whole tiling. And global point symmetry fights aperiodicity |
| 29 | **Substitution / hierarchical tilings** | Exact self-similar hierarchy (district → room → cover) | **(A)** for the hierarchy | ★ the hierarchy idea is worth stealing without the tiling |

---

## 3. Voronoi, Delaunay, and the seed distribution that makes them behave

### 3.1 Why relaxed / blue-noise Voronoi cells are so well-behaved

The Voronoi diagram of a point set S partitions the plane into cells
`V(s) = {x : |x−s| ≤ |x−t| ∀t ∈ S}`. Each cell is an intersection of half-planes, therefore
**convex** — that is unconditional, (A). What is *not* unconditional is cell size and shape:
Voronoi of uniform-random points produces cells whose areas vary by an order of magnitude,
with thin slivers wherever two seeds are close.

Two ways to fix that, and they are not equally strong.

**Lloyd relaxation / CVT (class B).** Iterate: compute the diagram, move each seed to its cell's
centroid, repeat. Each step is a gradient-descent step on the quantisation energy, and the
distribution visibly evens out ([Lloyd's algorithm, Wikipedia](https://en.wikipedia.org/wiki/Lloyd%27s_algorithm);
[Du–Emelianenko–Ju, *Convergence of the Lloyd algorithm for computing CVTs*, SIAM J. Numer. Anal. 2006](https://math.gmu.edu/~memelian/pubs/pdfs/DEJ_SIAM_lloyd.pdf)).
But convergence is *linear at best*, is only fully proven in 1-D, and — crucially for us —
**there is no bound on the worst cell after k iterations**. Amit Patel's polygon-map pipeline,
the canonical game reference, just says "running it twice typically gives good results"
([Polygonal Map Generation for Games](http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/)).
That is textbook (B): a distribution shift, still needing a filter.

**Maximal Poisson-disk seeding (class A).** A *maximal* Poisson-disk sample with radius `r`
satisfies two conditions:
1. **empty-disk / inhibition**: `|s − t| ≥ r` for all distinct samples;
2. **maximality / coverage**: every point of the domain is within `r` of some sample.

([Ebeida et al., *A Simple Algorithm for Maximal Poisson-Disk Sampling in High Dimensions*;
definition restated in [Quan et al., *Maximal Poisson-disk Sampling via Sampling Radius Optimization*](https://weizequan.github.io/mps2016/MPS.pdf).)
Bridson's O(n) dart-throwing with a background grid of cell size `r/√2` gives condition 1
directly and condition 2 in practice by exhausting the active list
([Bridson, *Fast Poisson Disk Sampling in Arbitrary Dimensions*, SIGGRAPH sketches 2007](https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph07-poissondisk.pdf)).

**Then the cell bounds are theorems, not hopes.** For a maximal sample with radius `r`:

> **Cell size lemma.** For every seed `s`, `V(s)` contains the disc of radius `r/2` about `s`,
> and is contained in the disc of radius `r` about `s`.
>
> *Proof.* Inradius: any neighbour `t` has `|s−t| ≥ r`, so the bisector of `s,t` is at distance
> `≥ r/2` from `s`; `V(s)` is the intersection of the half-planes bounded by those bisectors,
> all of which contain `B(s, r/2)`. Circumradius: for `x ∈ V(s)`, maximality gives some sample
> `u` with `|x−u| ≤ r`, and `s` is the nearest sample to `x`, so `|x−s| ≤ |x−u| ≤ r`. ∎

So: **room inradius ≥ r/2, room diameter ≤ 2r, and every Voronoi edge has length ≤ 2r**
(an edge lies in the closure of both its cells). That is (A), it is cheap, and it is the single
most useful hard property in this whole document, because it converts a global geometric
constraint (no long straight pinches, bounded room scale) into *one scalar parameter*.

**Choosing `r` from our own rules.** `lanePitchPx = laneWidthPx + coverSizePx = 124 + 56 = 180`
at standard size (`map_rules.nim:749`, `:733`). Set

```
r = lanePitchPx = 180 px
```

and you get: cell diameter ≤ 360 px (comfortably inside `maxOpenRunPx = 1050` and *above* the
262 px mean-free-sightline floor), grout segments ≤ 360 px, cell inradius ≥ 90 px so an eroded
room of lane width 124 is always non-empty. On 1235 × 659 (A ≈ 814 k px²) a maximal
disk sample at r = 180 lands around **20–25 seeds**; on the 969 × 1119 hex board, ~28. Those
are small numbers: everything downstream is trivially fast.

### 3.2 The Delaunay dual is the region graph you have been missing

The Delaunay triangulation is the dual of the Voronoi diagram: two cells are adjacent iff their
seeds are joined by a Delaunay edge. So *the room-adjacency graph comes for free with the
partition* — you do not build it, you read it off. This is the structural thing the column
lattice can never give: `arena.nim` has obstacles but no adjacency, so no question of the form
"how many ways from A to B" can be asked before rasterising and running max-flow.

Delaunay properties we can lean on:

- **Planar** (A) — so route disjointness in the graph maps to spatial disjointness (§7.2).
- **Contains the Euclidean MST** and the Gabriel/relative-neighbourhood graphs (A) — so any
  spanning subgraph you want is available as a *subgraph selection* problem, not a search.
- **Degree** averages < 6 for interior seeds (Euler), so the graph is sparse and the k-connected
  subgraph problem is tiny.

The *game-dev* canonical use of this is TinyKeep's "Delaunay → MST → put back ~15 % of the
discarded edges" recipe
([Adonaac, *Procedural Dungeon Generation Algorithm*, Gamasutra 2015](https://www.gamedeveloper.com/programming/procedural-dungeon-generation-algorithm)).
Judged honestly that is **(B)**: MST gives connectivity (1-connected) and the 15 % re-add gives
*some* loops with no guarantee at all about how many are vertex-disjoint or where. We can do
strictly better — see §7, where the correct move is to keep the graph 3-connected by
construction rather than to prune to a tree and sprinkle edges back.

### 3.3 Power (Laguerre) diagrams: prescribing area exactly

Replace `|x−s|` with the *power distance* `|x−s|² − w_s`. Cells are still intersections of
half-planes, hence still convex — the classification-preserving generalisation
([Aurenhammer, *Power Diagrams: Properties, Algorithms and Applications*, SIAM J. Comput. 16(1), 1987](https://www.cs.jhu.edu/~misha/Spring16/Aurenhammer87.pdf)).
The reason to care: **for any prescribed positive areas summing to the domain area, there exist
weights whose power diagram realises those areas exactly**, and they are the solution of a
convex problem (semi-discrete optimal transport; Aurenhammer–Hoffmann–Aronov,
*Minkowski-type theorems and least-squares clustering*, Algorithmica 20 (1998) 61–76; modern
treatment in [de Goes et al. / Bourne–Roper, *Centroidal power diagrams, Lloyd's algorithm and applications to optimal location problems*](https://arxiv.org/pdf/1409.2786)).

Classification: **(A) on cell area**, given a convergent solve. For us it buys:

- "Each of the four team quadrants owns exactly 25 % of the field" — but symmetry already gives
  that for free, so the real use is intra-quadrant: "the base pocket is 12 % of the quadrant,
  the midfield room is 20 %."
- Direct control of the **cover permille band (40–170)** by prescribing the total area of the
  solid cells before you even build them.

Cost: an L-BFGS on ~20 weights, each evaluation a diagram rebuild. At n = 25 this is well under
a millisecond, but it is the most complex piece of machinery here. **Recommendation: skip in v1.**
The erosion knob (§6.4) already gives continuous, monotone control of cover fraction and is a
five-line bisection. Keep power diagrams in the back pocket for the day someone asks for
per-region area targets.

### 3.4 Voronoi under a symmetry group

Because the Voronoi construction is defined purely by distances, it commutes with isometries:
if `S` is invariant under a group `G` of isometries, then `V(gs) = g·V(s)` and the whole diagram
is `G`-invariant. **(A), exactly, with no numerical tolerance.** This is why our dimension is
unusually well matched to the fairness requirement: seed the fundamental domain, lift the seeds
by `hex.orbit`, and the *entire partition* — cells, edges, adjacency graph, chokepoints,
route counts — is exactly symmetric. There is nothing to re-verify.

The trap this creates is important enough to have its own section: **§8**.

### 3.5 Torus / periodic Voronoi

For a lattice `Λ`, the periodic Voronoi/Delaunay of `S + Λ` on the flat torus `R²/Λ` is standard
and implemented in CGAL ([Osang et al., *Generalizing CGAL Periodic Delaunay Triangulations*, ESA 2020](https://drops.dagstuhl.de/opus/volltexte/2020/12941/pdf/LIPIcs-ESA-2020-75.pdf);
[Yan et al., *Computing 2D Periodic Centroidal Voronoi Tessellation*, ISVD 2011](https://www.gipsa-lab.grenoble-inp.fr/~kai.wang/papers/ISVD11.pdf)).
**Not applicable to us**: our board has a hard wall border (`ArenaBorder = 10`) and a
non-wrapping topology. The technique that *is* applicable — and is the same idea — is the
"compute in the fundamental domain plus a collar, then lift the combinatorics" trick those papers
use to keep predicates exact. See §8.4.

---

## 4. BSP, k-d, and why an axis-aligned cut is a rifle

### 4.1 What BSP actually guarantees

Recursively split a rectangle by a line; recurse; place a room inside each leaf; connect siblings
bottom-up ([RogueBasin, *Basic BSP Dungeon generation*](https://www.roguebasin.com/index.php/Basic_BSP_Dungeon_generation);
[Liapis, *Constructive Generation Methods for Dungeons and Levels*, PCG Book ch. 3](https://antoniosliapis.com/articles/pcgbook_dungeons.php)).
Guarantees, precisely:

- **(A)** Leaves are pairwise-disjoint and tile the domain. Rooms inset in leaves never overlap.
  This is genuinely valuable and is why BSP is everywhere.
- **(A)** The sibling-connection scheme induces a **tree** on the leaves.
- **(B)** Room aspect ratio, if you constrain the split ratio (0.45–0.55 → homogeneous,
  0.1–0.9 → heterogeneous, per the RogueBasin write-up).

### 4.2 The two reasons it is wrong for us

**Reason 1 — a tree is 1-connected.** Menger's theorem is unforgiving: a tree has a vertex cut of
size 1 between almost every pair, i.e. **exactly one** vertex-disjoint route. Our target is ≥ 3.
Retrofitting extra edges onto a BSP tree is possible but it is exactly the TinyKeep patch: no
guarantee about *how many* of the resulting routes are vertex-disjoint, and none about where they
run. If the k-route property is the point (and it is — `laneCount` floors at 3 for a reason), then
starting from a structure whose defining feature is acyclicity is starting in the wrong place.

**Reason 2 — cuts span the domain.** The root split of a BSP is a single line across the whole
board. Even if the *rooms* are inset, the cut line is where corridors get routed and where room
walls align, so open space accumulates along it. With `GunRange = 1050` on a 1235-wide board, a
single unbroken straight run of free space along a root cut is a full-field firing lane. Our own
generator has this disease already via a different mechanism (the uniform column lattice of
`arena.nim:1693` — a degenerate 1-D BSP), and the measured symptom is exactly what you would
predict: `longRunFrac` pressure and glass that never occludes anything.

### 4.3 The variants, honestly classified

| Variant | Effect | Class |
| --- | --- | --- |
| Jittered split position (0.1–0.9 instead of 0.45–0.55) | Room sizes vary; cut lines still span | **(B)** |
| **Offset / staggered cuts** (each child shifts its sub-cut) | Breaks *alignment* of walls across the tree; the top cut still spans | **(B)** |
| **Non-axis-aligned BSP** (arbitrary split hyperplanes) | Kills the axis-aligned open *row* specifically (which is what `map_metrics`' horizontal/vertical run scan at `:776` measures!) but the run is still straight, just diagonal — and our metric would stop seeing it | **(B)**, and a *metric-gaming* hazard |
| **k-d tree** (alternating axis, split at a data point) | Same as BSP with axis alternation forced | **(B)** |
| BSP on a **non-convex or curved** domain | Cuts no longer span; but you have lost the disjoint-rectangle guarantee | (B) |

The honest summary: **every BSP variant that removes the spanning cut removes it statistically,
not structurally.** The Voronoi family removes it structurally, because a Voronoi edge is a
bisector segment of length ≤ 2r (§3.1) and consecutive edges are collinear only on a measure-zero
set of seed configurations. That is the crisp reason to prefer the Voronoi family here, and it is
worth stating in exactly that form: *BSP's boundaries are global by construction; Voronoi's are
local by construction.*

**Where BSP is still right for us:** the **base pocket**. A base needs an axis-aligned, predictable,
symmetric little compound with spawn clearance (`spawnClearW/H`) and endzone gates. That is a
rectangle-packing problem and BSP or rectangular dualization (§7.5) is the right tool for a region
of ~4 rooms. Use it *inside* one cell, not for the field.

---

## 5. Medial axis, distance transforms, and what a chokepoint actually *is*

### 5.1 The guarantee

The grassfire / medial-axis transform of an open region `F` is the set of centres of maximal
inscribed discs, with the radius function `ρ(x)` = the distance transform. Two exact facts:

- **The medial axis is a deformation retract of `F`** (for bounded open sets with reasonable
  boundary), so it has the same number of connected components and the same first homology.
  Route counting and loop counting on the skeleton are therefore *exact*, not approximate. **(A)**
- **`ρ` is the exact clearance.** A disc agent of radius ρ₀ can traverse a skeleton branch iff
  `ρ ≥ ρ₀` everywhere on it. **(A)** (this is the C-space statement of §6.6.)

Our `buildCoarse` (`map_metrics.nim:380`) already computes a 26 px-resolution version of this:
each cell stores its widest open pixel and its `clearPx`. So we own the machinery; what we lack
is a *definition* that uses it.

### 5.2 The definition to adopt: chokepoints are sublevel intervals, and they have a length

The brief asks for length-aware clearance ("a short pinch is a doorway, a long one is a kill box").
The medial axis gives this exactly and with no fudge:

> Parameterise a skeleton branch by arclength `s` and consider the **sublevel set**
> `{ s : ρ(s) < ρ_choke }`. Its connected components are the pinches. Each component `I` has
> - **width** `w(I) = 2·min_{s∈I} ρ(s)` — the narrowest clearance;
> - **length** `L(I) = |I|` — how far you must travel while that narrow.
>
> Classify: **doorway** if `L ≤ L_door`, **corridor** if `L_door < L ≤ L_kill`, **kill box** if `L > L_kill`.

With our numbers: `ρ_choke` ≈ 45 px (so `w < 90`, matching `ChokeMaxClearPx = 90`);
`L_door` ≈ `SoldierBodyPx` × 2 ≈ 68 px (you are through it in ~25 ticks);
`L_kill` ≈ `MaxExposedRunPx = 132` (past this, a defender kills you before you clear it).

This is worth building because it is the first definition in our stack that distinguishes
"tight and interesting" from "tight and lethal", and it is computable from data
`map_metrics.nim` already produces. Today, `map_metrics.nim:1057` finds chokepoint *candidates*
(cells with `clearPx ≤ 90`) and then does a cut test — it has no notion of the pinch's **length**
at all, which means a 40 px doorway and a 40 px × 400 px shooting gallery score identically.
**That is a concrete, small, high-value fix to an existing file.**

### 5.3 Pruning — the classic hard part

Plain medial axes are wildly unstable: a one-pixel boundary bump spawns a branch. The literature's
answer is a *regularised* skeleton with a stability theorem:

- **λ-medial axis** (Chazal & Lieutier): keep points whose set of nearest boundary points has
  circumradius ≥ λ. Hausdorff-stable under perturbation of the shape, unlike the raw MA
  ([Chazal & Lieutier, *The λ-medial axis*, Graphical Models 67(4), 2005]; discrete version:
  [Robust skeletonization using the discrete λ-medial axis](https://www.researchgate.net/publication/220644771_Robust_skeletonization_using_the_discrete_l-medial_axis)).
- **Discrete Skeleton Evolution / contour-approximation pruning**: iteratively delete end branches
  that contribute least to shape reconstruction
  ([Bai–Latecki; Montero & Lang, *Skeleton pruning by contour approximation and the integer medial axis transform*, Computers & Graphics 36(5), 2012](https://dl.acm.org/doi/10.1016/j.cag.2012.03.029)).
- **Scale axis / cosine-pruned MA** ([Patiño et al., CPMA, 2020](https://arxiv.org/pdf/2012.02910)).

Classification: pruning is **(B)** — it improves the skeleton but the parameter is a taste knob and
no method gives "the right branches" unconditionally.

**Our shortcut, which is better than any of them:** if you *generate* the free space as a
partition, you already know the skeleton — it is the Voronoi edge network, by construction, with
no pruning needed. The generalized Voronoi diagram of a set of obstacles **is** the medial axis of
the free space, which is precisely why GVDs are the standard maximum-clearance roadmap in robot
motion planning ([Roadmap-based path planning using the Voronoi diagram for a clearance-based
shortest path, IEEE RAM 2008](https://ieeexplore.ieee.org/document/4539723/)). Extracting a
skeleton from pixels is only hard when you did not build the pixels from a skeleton.

> **Design rule:** never *extract* the corridor network from a rasterised map if you can *emit*
> it. Extraction costs a pruning heuristic (B); emission is (A).

Keep the extraction path alive for one purpose only: validating hand-authored maps and legacy
pool maps, where there is no generator to ask.

<!-- SECTION-MARKER -->
