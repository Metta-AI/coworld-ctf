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

<!-- SECTION-MARKER -->
