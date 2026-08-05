# A scene-graph map generator for CTF — founding design

**Status:** DESIGN + working prototype (`src/ctf/mapgen_graph.nim`,
`tools/mapgraph_eval.nim`, `tests/test_mapgen_graph.nim`). Nothing ships yet.
`src/ctf/arena.nim` is untouched; the current generator still owns every map
the league plays.

**Stage 4 of the map-generator rebuild.** Stage 1 was the hex kernel
(`hex.nim`) and the burrow tool (`burrow.nim`); stage 2 the size-class rule
sets (`map_rules.nim`); stage 3 the fitness harness (`map_metrics.nim`). This
stage is the generator those three were built to feed.

**Headline measurement**, standard 2-team, 40 seeds, scored by
`map_metrics.staticScore` with the hand-authored `arena` as control:

| | staticScore (min / med / max) | interiorFrac median |
|---|---|---|
| `arena` control | 1.000 | **0.342** |
| current generator (curated pool) | 0.871 / 0.878 / 0.908 | **0.128** |
| scene-graph prototype | 1.000 / **1.000** / 1.000 | **0.345** |

39 of 40 seeds valid, 0 invalid, 1 refused by the plan. It matches the
hand-authored control on architecture and beats the current generator 2.7x.

**Read §8 before believing that.** Three things the headline hides: the
prototype strands floor the sim validator does not check (2 of 8 seeds, ~2.5%
of the board, against the arena's 0.00%); every seed looks nearly like every
other seed; and a `staticScore` of exactly 1.000 on all 39 maps means the
harness can no longer rank them at all.

---

## 0. What is actually wrong today

Maxwell's words: *"there seem to be so many things that are not intentional
enough in the map generation."* The concrete form of that:

`generateMapAttempt` lays a **uniform column lattice**. It draws 4–6 x-slots
across the half-field, walks each one in y at a drawn period with a
stratified phase, and drops one of four interchangeable pebble skins
(`ColumnFamily`) at each slot, clearing about a quarter of them at random. It
then runs a **sightline-repair pass** that scans for uncovered rows and drops
28 px diamonds into random columns, up to 40 of them, until the scan stops
complaining.

Three things follow, and they are the reason a rewrite is worth several
agent-weeks rather than a tuning pass:

**Nothing is placed for a reason.** A slot exists because the loop reached it.
No obstacle knows what it is for, so no obstacle can be checked against what
it is for. The reported "walls in front of glass" defect is the archetype:
the window pass glazes a column, and the repair pass afterwards parks a
diamond in front of it. Neither pass is wrong on its own terms, because
neither has terms.

**The validator selects nothing.** Roughly 96% of 2-team seeds pass on the
first attempt. A gate that admits everything is a crash guard, not a filter,
so what ships is the 50th percentile of the generator's own range.

**The measurement says "scatter".** `interiorFrac` — open floor with at least
6 of 8 directions blocked within 120 px — is 0.342 on the hand-authored arena
and has a **median of 0.118** across the curated pool. The arena is honest
scatter *by design* and still triples the generator, because its scatter is
dense enough to enclose. The pool's is not enclosing anything.

---

## 1. What Cogs-vs-Clips actually is

Read: `metta/packages/mettagrid/python/src/mettagrid/mapgen/{scene,area,mapgen}.py`
and `mapgen/scenes/*`. It is a **scene graph over rectangular sub-grids**.

### 1.1 The core, precisely

An **`Area`** (`area.py`) is a view into the outer grid: `outer_grid`, absolute
`x, y`, `width, height`, and a list of string `tags`. `area.grid` is the numpy
slice. `make_subarea` clamps into the parent and raises if it would not fit.
That is the whole type — 90 lines.

A **`Scene`** (`scene.py`) is bound to exactly one `Area` plus a
`GridTransform` (the 8-element dihedral group: identity, three rotations, two
flips, two transposes). The two operations available to `render()` are:

* mutate `self.grid`;
* call `self.make_area(x, y, w, h, tags=[...])`.

`self.grid` is the area's slice with the **inverse** of the accumulated
transform already applied, so a scene author writes in a local upright frame
and the result lands rotated/mirrored in the root grid. `make_area` maps the
corners back through the inverse transform. **Transforms are therefore free to
every scene author** — nothing in `maze.py` or `bsp.py` mentions rotation.

**`render_with_children()`** is the driver: render self, then
`get_children()` (dynamic, from code) followed by `config.children` (static,
from config); for each `ChildrenAction`, select areas and recurse.

A **`ChildrenAction`** is an `AreaQuery` plus a scene config. The query is:

* `where`: `"full"` (the scene's own area) or `AreaWhere(tags=[...])`
  (every listed tag must be present);
* `limit`, `offset`, `order_by` (`"random" | "first" | "last"`);
* `lock`: a named set — selected areas are added to it and are invisible to
  any later query using the same lock. This is how two layers stop fighting
  over the same zone.

**RNG descent** is `create_as_child`: `rng = parent_scene.rng.spawn(1)[0]`
(numpy `SeedSequence` spawning). Each scene gets an independent stream derived
from its parent. `SceneConfig.seed` overrides it, which is how a single scene
is pinned.

### 1.2 What makes its output feel intentional

Three mechanisms, and we have taken none of them.

**Partition scenes that render nothing.** `BSPLayout` (`bsp.py`) is fifteen
lines: build a BSP tree, and for every leaf call `make_area(..., tags=["zone"])`.
It draws no pixels at all. `BoundedLayout` is similar — it makes one *centred*
sub-area clamped to `max_width/max_height` and tags it. Separating *what the
sub-regions are* from *what goes in them* is the single most important idea
here, and it is exactly the one our generator lacks: our loop decides position
and content in the same statement.

**Content is always given a bounded region, never the map.** A biome or a
dungeon in `biome_arena.py` never draws "somewhere". It is handed a BSP zone,
then a `BoundedLayout` shrinks that zone to at most `max_biome_zone_fraction`
(0.27) of the map, and only then does a `RandomScene` pick caves/forest/
desert/city/plains and fill it. Districts, not noise.

**Correct by construction, not validated afterwards.** `compound.py` never
runs a flood fill to check its interior is reachable, because it only ever
draws walls as **thin borders** — never as fill — and carves its gates from
the same shared constants that positioned the walls. There is no code path
that can produce a sealed compound.

### 1.3 The composite: `biome_arena.py`

`BiomeArena.render()` is `return` — it draws nothing. All of it is
`get_children()`, and the ORDER is the design:

1. **base biome**, `where="full"` — the substrate.
2. **biome layer** — a `BSPLayout(area_count=biome_count)` over the full area;
   a random 60% of its `zone` areas get a `BoundedLayout(tag="biome.zone")`
   containing a weighted `RandomScene` over the five biomes.
3. **dungeon layer** — the same shape again, independently: its own
   `BSPLayout(area_count=dungeon_count)`, 50% fill, capped at
   `max_dungeon_zone_fraction` (0.2), `RandomScene` over
   {BSP rooms, maze-dfs 0.6, maze-kruskal 0.4, radial maze}.
4. **asteroid mask** — the boundary silhouette.
5. **buildings** — `UniformExtractorParams(target_coverage=building_coverage)`,
   a *budget* rather than a count.
6. **hub compound**.
7. **`MakeConnected`** — connectivity repair, LAST.
8. perimeter / corner placements, then `EnsureHubReachableJunction(max_distance=15)`.

Counts autoscale from area (`biomes = clamp(area // 1600, 3, 48)` at
`density_scale` 0.9) and are floored so no zone can exceed its fraction cap.

Two properties worth stealing outright: **layers are independent partitions of
the same ground** (the biome BSP and the dungeon BSP are unrelated trees, so
districts overlap in interesting ways instead of tiling), and **repair is a
named final layer with a principled algorithm**, not a loop that patches until
a scan goes quiet.

### 1.4 The rest, briefly

* `make_connected.py` — Dial's algorithm over a cost grid, wall cost 10,
  object cost 50; joins components by cheapest tunnel. Already ported as
  `src/ctf/burrow.nim`, cost model intact.
* `mirror.py` — renders a child on one half and copies it across; a *scene*,
  so symmetry composes with everything else.
* `dither.py` — stochastically flips cells near a boundary with probability
  decaying by distance. The archetypal **symmetry-destroying** pass: for us it
  must run inside the fundamental domain, before the lift, or it breaks team
  fairness silently.
* `maze.py` (dfs/kruskal), `radial_maze.py`, `room_grid.py`, `convchain.py`,
  `wfc.py`, `asteroid_mask.py`, `mean_distance.py` — content and analysis
  scenes, all region-scoped.

---

## 2. What does NOT transfer

Stated plainly, because three of these are load-bearing and one of them
invalidated my first partition design outright.

**Continuous space, not a tile grid.** Our maps are pixel-space `ArenaShape`s
(rect / disc / diamond / diagonal / polygon) rasterised to wall masks. A
width-1 corridor is meaningless; the agent is 13 px solid, 34 px drawn, and
`mapRules.minCorridorWidthPx` is 68 for standard. Every scene must think in
px and in *shapes*, not in cells. Concretely: their mazes, `convchain`, `wfc`
and `dither` are all cell-flippers and none of them port directly. What ports
is the *scene graph*, not the scene library.

**Competitive symmetry is mandatory.** Their maps have no fairness
requirement. Ours must generate in a fundamental domain and lift by the
symmetry orbit — `symMirror`/`symRot180` for 2 teams, `symRot90` for 4, and
`hex.nim`'s D6 kernel for the hex family. Two consequences: (a) any
symmetry-destroying scene must run *inside* the domain, before the lift;
(b) **no rule may bake in handedness**, because 4 teams on hex use the Klein
four-group and two of the four teams therefore see a *mirror* world.

**The protected-floor carve deletes walls.** The engine keeps the capture
columns, spawn pockets and flag ring clear. On a standard board that is 38% of
the half-field. A wall drawn there is silently erased — so a scene that
*counts on* a wall it drew on protected floor is making a promise the engine
will take away. This has to be a **precondition** (is this footprint on
buildable ground?) checked before the structure is chosen, not a validator
afterwards.

**The horizontal-sightline invariant is unlike anything in their generator,
and it constrains the PARTITION, not the content.** This is the one that cost
me a design. The validator rejects any unbroken horizontal ray between the
capture columns. My first partition was a plain BSP over the half-field, with
each leaf inset to leave a street around its structure — the `compound.py`
discipline. It refused **all twelve** seeds, and it was right to: *a
horizontal cut that spans the domain leaves a street running clear across the
half-field, and a street is a horizontal sightline.* Their BSP is free to cut
anywhere because nobody shoots down their corridors.

**Replays pin `mapSpec`.** We may freely break seed→map identity; we may not
break spec→map identity. That is what makes the whole rewrite shippable
without breaking playback (§7).

---

## 3. The architecture

### 3.1 The scene abstraction, in Nim

```nim
Region = object          # a rect of the fundamental domain + why it exists
  rect: MapRect
  tags: seq[string]

Placement = object       # one obstacle + the audit trail that justifies it
  shape: ArenaShape
  scene: string          # the scene path that drew it
  serves: string         # the affordance it exists to provide

Board = ref object       # everything scenes share
  placements: seq[Placement]
  posts: seq[Postcondition]
  budgetPx, spentPx: int
  protectedAt: proc(x, y: int): bool
  ...

Ctx = object             # what one scene sees
  path: string
  rng: Rand
  region: Region
  rules: MapRules
  board: Board
  areas: seq[Region]     # the regions THIS scene made
  locks: Table[string, HashSet[int]]

Scene = ref object
  name: string
  render: proc(ctx: var Ctx)
  children: seq[ChildAction]

ChildAction = object     # the port of their ChildrenAction
  full: bool; tags: seq[string]; limit: int; order: Order; lock: string
  scene: Scene
```

A scene may do exactly two things: `ctx.place(shape, serves)` and
`ctx.make(rect, tags)`. `make` **clamps into the parent region**, so a scene
physically cannot hand a child ground it was not given. `place` requires a
non-empty `serves` string — a feature nobody can name a purpose for cannot be
written — and debits the shared cover budget.

Regions are pixel rects, not grid views. We do not need their transform
machinery (`self.grid` as an inverse-transformed numpy view) because our
scenes emit shapes rather than writing cells, and shapes are cheap to
transform. If we later want per-scene rotation, the right port is a
`transform` field on `Ctx` applied inside `place`.

### 3.2 RNG descent, and how a scene is pinned

**Deliberately different from theirs, and better for us.** They spawn from the
parent stream in child order, so inserting a sibling renumbers every later
sibling's stream. Ours is keyed by the scene's **path**:

```nim
proc streamSeed(root: int, path: string): int =
  root xor cast[int](hash(path)) xor 0x5EED_10A7
```

with the child path built from the child scene's *name* and its occurrence
index, never from the parent's child index. Two properties fall out, both of
which the sub-stream work (`mapk`) is after:

* **adding a scene anywhere leaves every other scene's stream bit-identical**;
* **any single scene is pinnable** by overriding its path key alone, without
  touching the root seed.

This is the integration point: the sub-stream architecture should own
`streamSeed` and the path convention; `mapgen_graph` should call it.

### 3.3 Where symmetry happens

Nowhere in the scene tree. Every scene runs inside the **fundamental domain**
and `buildArenaObstacles` lifts the result downstream, exactly as it does for
the current generator. Team fairness is structural, not checked.

A symmetry-destroying scene (a `dither`-style edge roughener, an erosion pass)
is therefore just another child of the domain, and is exactly fair for free.
For the hex family the domain is a `hex.teamGroup(teamCount)` fundamental
sector and the lift is `hex.orbit`; nothing in the scene abstraction changes.

### 3.4 The three intentionality mechanisms

**(a) A tag is a decision, and it is the parent that makes it.** Any decision
that needs to see the whole half-field at once — which districts must break a
sightline, how the cover budget is split — is made in the partition scene and
published as a tag. A child selecting `["district", "rayblock"]` may *assume*
its parent already proved this leaf must host a sightline-breaking structure.
Intent flows down as data.

**(b) Preconditions, not validators.** `rectUnprotected` is checked *before* a
district is given a role, so a structure is never asked to keep a promise the
carve will erase. The same shape applies to every affordance: measure it,
then place against it.

**(c) Post-conditions outlive the pass that made them.** A scene may register
a `Postcondition` — a claim plus a closure — that the driver re-checks after
the **whole tree** has rendered. This is the structural answer to "walls in
front of glass". The glazier registers *"this pane still has something to see
through it"*; if any later scene blocks it, `checkPostconditions` fails the
map **by scene name** instead of shipping a pointless window.

That guard is negative-controlled. `tests/test_mapgen_graph.nim` turns on a
`vandalScene` that deliberately parks a slab in front of every pane, and
asserts the failure fires. A guard nobody has seen fire is indistinguishable
from a guard that cannot fire.

---

## 4. The CTF map as a composition

Read top to bottom, this IS the map's design intent — the thing 590 lines of
imperative draw code cannot show you at any length.

```
ctf2                          names the three regions of a half-field
  districtPlan   (field)      partitions; decides which districts must
    structure    (rayblock)     break a sightline / may hold cover
    plaza        (open)
  centralBastion (seam)       cover where the two teams actually meet
  standApron     (apron)      cover on the approach to the pedestal
  glazier        (field)      glass, LAST, only where sight exists
  [connect]                   burrow, only if a plan ever fails to be
                              connected by construction — see §4.4
```

### 4.1 The partition (`colonnadeLeaves`) — the load-bearing decision

Not a BSP. **Columns first, and each column's horizontal cuts staggered half a
row against its neighbour's.** Every row is then either inside some column's
structure (blocked by it) or in one column's street — where the neighbouring
column is mid-structure.

This is the same stratified ladder the hand-authored arena uses for its
pickets (0/+48/+24/+72). The difference is that here it is **load-bearing
rather than decorative**, and the plan proves it worked before shipping.

It also buys the route shape a CTF map wants, for free: to cross the field you
must jog in y at every column boundary, which is exactly the detour the
metrics reward (`detourMax` arena 1.30, pool median 1.14, prototype 1.17–1.42)
and the straight sprint they punish.

Column 0 is deliberately **unjittered** — its first district must sit flush
against the top of the domain, because the validator's first scan row is two
pixels below it. Jittering it cost twelve of twelve seeds.

### 4.2 The y-cover — how the repair prosthetic is DELETED

Under mirror symmetry the left half alone must break every horizontal ray. So
the plan runs a **greedy interval cover** over the districts that are
*capable* of hosting a blocker (footprint big enough, and entirely off
protected floor), selecting a set whose y-extents cover the validator's scan
band. Each selected district is built *because it covers rows nothing else
covers*. That reason is recorded as the `rayblock` tag.

If the cover cannot be completed, **the candidate is refused**. No diamonds
are dropped. Best-of-K draws another seed. The prosthetic is not
reimplemented, it is unnecessary: the invariant is a property of the street
plan.

Both structure archetypes block their full y-extent by construction:

* **courtyard** — four walls; the west and east doors have **disjoint y-bands**,
  so the union of the two side walls covers every row of the footprint while
  the two doors still make a real through-route. One constraint, two purposes.
* **bunker** — three walls (a U). Whichever way it opens, at least one
  full-height side wall survives.

Reachability is by construction for the `compound.py` reason: walls are only
ever thin borders, never fill, and `StreetInset` guarantees a street ring
around every footprint.

### 4.3 Where invariants are ENFORCED vs merely measured

| invariant | mechanism | where |
|---|---|---|
| no open horizontal ray | **enforced by construction** (staggered columns + y-cover) | partition |
| ≥3 vertex-disjoint base-to-base routes | **emergent**, measured by `routeCountMin` | metrics; prototype 4–7, hard floor 2 |
| cover budget 42–168 permille | **enforced**, shared board resource | `place` debits, scenes ask `canAfford` |
| walls off protected floor | **enforced as a precondition** | `rectUnprotected` before role assignment |
| interior reachable | **by construction** (thin borders + street ring) | structure scenes |
| glass has something to see | **measured then enforced**, plus a post-condition | glazier |
| stand-approach cover | **targeted**, measured by `standCover` | standApron + districts |
| collision-point cover | **targeted**, measured by `collisionCoverRatio` | centralBastion |

The honest line in that table is row 2: route count is still emergent. §8.

### 4.4 Where burrow runs

**Nowhere, in the prototype** — and that is a claim, not an omission. Because
the street network is the complement of the partition's cut lines, and every
footprint is inset from its leaf, the field is connected by construction; 39
of 40 seeds passed the sim's own corridor-flood without any repair. Burrow
belongs in the tree as a final named layer (their `MakeConnected` position)
for the cases the prototype does not cover: organic/cave district types,
the asymmetric hex domains, and any scene that draws fill rather than borders.
It should be a **named layer that reports when it fires**, so "the plan needed
rescuing" is a measured number rather than an invisible habit.

### 4.5 Four teams

Same tree, three substitutions:

* domain = quadrant (`symRot90`), or `hex.teamGroup(4)` = Klein V4;
* the sightline scan is full-width (`rowBlockedFull`), so the y-cover becomes
  a cover of the *quadrant's* rows against the folded image — the same greedy,
  a different feasibility test;
* `centralBastion` becomes four-fold and `standApron` runs once per team
  anchor via a `ChildAction` with `tags: ["apron"]` and `limit: 0`.

No rule in the tree is handed, which is what keeps the V4 mirror-world teams
fair.

---

## 5. What was built, and what it measures

`src/ctf/mapgen_graph.nim` (≈830 lines incl. commentary), driven by
`tools/mapgraph_eval.nim`, tested by `tests/test_mapgen_graph.nim` (shard 3).

The prototype **borrows the shell** (board size, clearances, endzone,
pedestals) from `generateMapAttempt` with size/symmetry/endzone locked, then
replaces terrain wholesale. That is deliberate: the only thing differing
between the two rows below is the terrain.

Standard 2-team, 40 seeds, `map_metrics` with `arena` as control:

```
  arena control        1.000    interior 34.2%
  current gen (n= 5)   min 0.871 med 0.878 max 0.908   interior med 12.8%
  scene graph (n=39)   min 1.000 med 1.000 max 1.000   interior med 34.5%
  graph: 39 valid, 0 invalid, 1 refused by the plan
```

**The cover ceiling is the binding constraint on architecture, and the arena
already sits on it.** The control measures 167 permille against the
validator's 170 maximum — the hand-authored map spends essentially its whole
budget. Sweeping the prototype's nominal target 120 -> 135 -> 150 -> 160 ->
168 -> 175 -> 185 moved `interiorFrac` 26.4% -> 26.9% -> 29.3% -> 30.4% ->
34.6% -> 37.0% -> 38.9% with no loss of validity, and 195 was the first value
to breach the ceiling. Enclosure is bought almost linearly with cover, so a
generator that under-spends the budget cannot produce architecture no matter
how good its plan is. The shipped default is 180 nominal.

(The constant is a NOMINAL budget, not the measured permille: `areaOf` sums
shape areas, so it double-counts overlapping walls and ignores the carve. The
validator's measured permille is always lower. A real build should debit the
budget with measured incremental coverage, or calibrate the estimator.)

Per-metric, prototype against control and pool:

| metric | arena | pool median | prototype |
|---|---|---|---|
| `interiorFrac` | 0.342 | 0.128 | **0.345** |
| `exposedFrac` | 0.038 | 0.201 | **0.025–0.047** |
| `standCoverMin` | 0.072 | 0.044 | **0.078–0.116** |
| `standRingOpenMin` | 0.892 | 1.000 | **0.831–0.911** |
| `collisionCoverRatio` | 1.456 | 0.830 | 0.85–1.10 |
| `detourMax` | 1.295 | 1.14 | 1.17–1.42 |
| `longRunFrac` | 0.110 | 0.173 | **0.086–0.102** |
| `routeCountMin` | 8 | 9 | 4–7 |
| stranded floor | 0.00% | 0.00–0.01% | **0.00–2.56%** |

The two metrics the current generator is worst on — architecture and naked
pedestals — are the two the prototype fixes outright. `collisionCoverRatio`
and `routeCountMin` it does not.

**The cover budget bug is worth recording** because it was architectural, not
a wrong constant. Two of forty seeds shipped at 172 and 180 permille against
the validator's 170 ceiling. The district plan budgeted its own wall rings and
stayed inside them, while the bastion, the plazas and the apron each spent on
top without being able to see the total. A budget only one of five spenders
can read is not a budget. Moving it onto the `Board` and debiting it in
`place` took the run from 37 valid / 2 invalid to 39 / 0.

---

## 6. Renders — what I actually saw

Looked at directly, at 820 px, at three points in the build.

**Good, and unmistakable next to the pool.** Real enclosed rooms, real
doorways, streets you can trace. Glass sits in wall segments with open ground
on both sides. Mirror symmetry is clean. Nothing reads as confetti and there
is not one repair diamond anywhere.

**Bad, and I would not ship it as it stands.**

* **Diversity is a regression.** Seeds 4001 and 4008 are near-identical: the
  same two staggered columns, the same rectangular idiom, the same rhythm. I
  replaced a uniform lattice of pebbles with a uniform lattice of boxes. The
  current generator is scatter, but it is *varied* scatter.
* **The last fix made it look worse while the metric improved.** Adding
  north/south doors to courtyards (to attack the stranded floor) turned solid
  building outlines into dashed, chopped-up ones — at 820 px seed 4004 reads
  as dotted rectangles rather than architecture. `interiorFrac` did not care.
  This is worth recording as its own lesson: the harness cannot see "reads as
  a building", and a change that improves every number can still degrade the
  map. Renders stay in the loop.
* **Everything is an axis-aligned rectangle.** No discs, diamonds, diagonals
  or `shapePolygon` blobs — the vector-obstacle work is entirely unused.
* **The outer thirds are empty beige.** Mostly the shell's protected columns
  (38% of the half-field), but my domain gives away another 54 px by starting
  clear of the spawn pocket instead of working around it.
* **The stand apron is nearly inert** — 11 pieces across 40 maps. The good
  `standCover` number comes from the districts, not from the scene written to
  produce it. That is "placed but pointless" in reverse: a scene whose stated
  purpose is being served by something else, which the intent ledger makes
  visible precisely because every placement is attributed.

**The defect my eye caught and the validator did not.** Seed 4007's outer
column looked like sealed boxes. Measuring instead of squinting
(`tools/dead_probe.nim`, flood from the red flag over the eroded corridor
mask) confirmed it: **3 of 8 seeds stranded floor, up to 7.74% of the board —
40,248 px — against the arena's 0.00% and the pool's 0.00–0.01%.**

The cause was mine, and it is exactly the failure this design exists to
prevent. `bunker` chose `dir = rand(3)` but omitted a wall only for `dir` 0
and 1; for 2 and 3 it drew all four and sealed the room. The sim validator
accepts that happily, because it only demands the flags and the centre
connect.

Fixing the aperture logic and adding an explicit per-structure post-condition
took it to **2 of 8 seeds at ~2.5%**, and the cross-axis doors did not move it
further — so the residue is not inside courtyards, and is still open. The
lesson generalises past the bug: **"thin borders, never fill" is necessary for
reachability but not sufficient.** `compound.py` gets away with it because its
gates are carved from the same constants that positioned its walls; ours are
chosen independently, so the aperture has to be an explicit promise.

---

## 7. Migration

The generator is swapped only once it beats the current one on the harness,
and `mapSpec` playback never breaks, because:

1. **`mapSpec` pins expanded geometry, not the generator.** `mapSpecJson`
   writes `leftObstacles` as shapes; `mapFromSpecJson` reads them back. A
   replay recorded today replays byte-identically against any future
   generator. Seed→map identity is what changes, and that is explicitly
   allowed.
2. **Ship behind a `MapGenOverrides` field** (`generator: "columns" | "graph"`,
   default `columns`). Both live in the tree; the league keeps drawing the old
   one.
3. **Prove it on the harness.** `tools/map_eval rank` over ≥40 seeds per size
   class, arena prepended as control, plus `map_playtest` on the top-k for the
   dynamic metrics `staticScore` cannot see.
4. **Re-curate the pool.** `MapPoolSeeds` is a list of seeds; a new generator
   means a new curated 20 chosen by the ranker. The old pool stays reproducible
   because the old generator stays in the tree.
5. **Flip the default**, and only then delete `generateMapAttempt`'s column
   loop and the sightline-repair block.

Best-of-K (`mapk`) is what makes step 3 work at all: with the plan refusing
seeds honestly, K must be large enough that refusals are cheap. Measured
refusal rate is 1/40 today.

---

## 8. Honest assessment, and scope

**What is proven.** The architecture is real, it is small (~900 lines including
a lot of commentary, against 590 imperative), and it moves the single metric
Maxwell's complaint reduces to — `interiorFrac`, 0.128 → **0.345**, matching
the hand-authored control's 0.342 and beating the current generator 2.7x, on
39 of 40 seeds with zero invalid maps. The repair prosthetic is genuinely gone
rather than relocated: the sightline invariant is a property of the street
plan. The intent ledger and the post-condition guard both work, the latter is
negative-controlled, and the guard caught a real sealed-room defect that the
sim validator does not check for.

**What is not proven, and matters.**

* **Diversity.** One partition idiom and two structure archetypes is not a
  generator, it is a template. This is the biggest open risk and it is the
  next thing to build: more archetypes (organic districts from `genCaves`'
  blob polygons, ridges, trench-lined crossings), and more partition idioms
  (radial for hex, room-grid, irregular column counts).
* **Stranded floor, still open.** 2 of 8 seeds lose ~2.5% of the board to
  pockets nothing can reach, against 0.00% for both the arena and the current
  pool. The sim validator does not test for it (it checks only that the flags
  and the centre connect), so this would ship silently. It must be closed
  before the generator is a candidate — see the note below on why burrow
  cannot close it as things stand.
* **`staticScore` saturates — all 39 maps score exactly 1.000.** The scalar can
  no longer rank them, so best-of-K would be sorting on noise. **This is a
  finding for the metrics and ranker work, not just for me:** once the
  generator is good, either the bands must be re-tightened against a new
  control, or the ranker must sort on the raw metric vector rather than the
  collapsed scalar. Do not let a saturated scalar pick the pool. The corollary
  is sharper: a harness calibrated against a bad generator stops discriminating
  the moment the generator improves past it.
* **The additive shape model cannot host a subtractive repair.** `burrow`
  carves cells out of a mask; our generator emits a list of shapes and has no
  way to express "remove part of that wall" except by editing the placement
  that drew it (which the glazier does, by splitting a rect). So connectivity
  must be either fully by-construction, or repaired by a door-punching scene
  that finds a stranded pocket and splits the wall bounding it. Rasterising
  and re-vectorising is the alternative and is worse. **This is a real
  constraint on the shape of the ported `MakeConnected` layer** and should be
  settled before that layer is written.
* **`routeCountMin` 4–7 against the arena's 8**, and `collisionCoverRatio`
  below the control. Route count should be *enforced* by the partition (a
  column count derived from `mapRules.laneCount`) rather than left emergent.
* **Only 2-team, only `symMirror`, only `standard`.** rot180, rot90, hex and
  the five other size classes are all untested. Small boards in particular may
  not fit a 200 px district row at all.
* **Only rectangles**, and no trenches, no pickup placement scene, no biome
  layering.

**"Refuses everything" versus "accepts everything."** The first partition
refused 12 of 12 seeds; the current one refuses 1 of 40. That contrast is
worth stating on its own, because the existing generator has the mirror-image
pathology: it *accepts* 96% of seeds on the first attempt, which means its
validator selects nothing at all. A generator whose gate admits everything
ships its own median; a generator whose gate refuses most things is doing real
selection but needs cheap candidates. **Ours should sit deliberately at the
refusing end** — refusal is nearly free (the plan fails before any shape is
drawn) and best-of-K turns a high refusal rate directly into quality. The
number to watch is not the refusal rate itself but *why*: a refusal naming an
unreachable y-cover is the architecture working; a refusal from the sim
validator afterwards is the architecture having missed something.

**Scope.** Roughly:

* *2–3 agent-days* — archetype and partition library (the diversity fix), plus
  route count derived from `mapRules` rather than emergent.
* *2 days* — rot180 / rot90 / hex domains and the other five size classes.
* *1–2 days* — pickups, trenches and biome as scenes; burrow wired as the
  named final layer with firing telemetry.
* *2 days* — harness proving, pool re-curation, the `generator:` flag and the
  migration.
* *1 day* — deleting the column loop and the repair pass once the default flips.

**Is it worth it against molding the existing generator?** Yes, and the reason
is narrow enough to check: the defects Maxwell named are not parameter
defects. "Walls in front of glass" is two passes with no shared notion of
purpose; "not intentional enough" is a loop that decides position and content
in one statement. Neither is reachable by tuning `columns`, `period` or
`prob`, because there is no place in that code to put a reason. The scene
graph's whole contribution is that there is: a region, a tag, a `serves`
string, and a post-condition that outlives the pass. The measured 2.3x on
`interiorFrac` is evidence the mechanism works; the diversity regression is
evidence it is a third of the way built.
