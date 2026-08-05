# Correct-by-construction and constraint-based map generation

Research for the Coworld CTF map-generator rewrite. Dimension: **which techniques can
*guarantee* a good map rather than merely make one likely.**

Written 2026-08-05. Sources are linked inline; primary sources preferred, folklore
flagged as folklore.

---

## 0. The one-paragraph answer

Five of our six invariants can be made **true by construction**, and the sixth is
constructible in the axis-aligned form we actually measure. The mechanism is not a
solver — it is **monotonicity plus spatial separation**. Our invariants split into two
families with *opposite* monotonicity: route count only ever goes **up** when you open
floor, and cover/sightline blocking only ever goes **up** when you add walls. A pipeline
that mixes them oscillates forever (which is what our current generate → validate →
repair → re-validate loop does). A pipeline that gives each family its own disjoint set
of pixels — a **protected skeleton** that is never walled, and a **fill region** that is
freely walled — makes both families monotone in their own territory and therefore
achieves both simultaneously, by construction, with no search. Constraint solvers (ASP,
SAT, SMT) *can* express every invariant exactly and do give hard guarantees, but their
cost is 3–5 orders of magnitude over our 10–30 ms runtime budget on a board of our size;
their correct role is **offline**: to build and certify a catalogue of skeletons that the
runtime then decorates. WFC gives us essentially nothing we need — its guarantee is local
pattern similarity, and it is widely and wrongly sold as a playability method.

---

## 1. Classification key

Every technique below is tagged:

- **(A) HARD GUARANTEE** — by the structure of the algorithm, the output *cannot* violate
  the stated property. No filter needed. The property must be stated precisely; "cannot
  produce a disconnected map" and "cannot produce a map with fewer than 3 vertex-disjoint
  base-to-base routes" are wildly different guarantees and only one of them makes a CTF
  map playable.
- **(B) DISTRIBUTION SHIFT** — makes good output more likely, sometimes dramatically, but
  the bad output is still in the support. Still needs a filter. Best-of-K lives here.
- **(C) COSMETIC** — changes how the map *looks*; no bearing on the invariants.

A recurring trap in this literature: a technique with an (A) guarantee about something
*local* gets marketed as an (A) guarantee about something *global*. WFC is the canonical
case (§4.1). Watch for it everywhere.

---

## 2. The invariant set, stated precisely enough to construct

Let `F ⊂ R²` be the open (walkable) free space, `W` the wall set, `B = {b₁ … b_n}` the
base/pedestal anchors, and `G` the coarse routing graph our metrics already use: cells of
`RouteCellPx = 26` px, one vertex per fully-open cell, 4- or 8-adjacency
(`src/ctf/map_metrics.nim:91`).

| # | Name | Formal statement | Today's enforcement |
|---|---|---|---|
| **I1** | Route redundancy | for every ordered pair `(bᵢ, bⱼ)`, the max number of internally **vertex-disjoint** paths in `G` from `src(bᵢ)` to `dst(bⱼ)` is `≥ 3` | *measured* — `vertexDisjointRoutes` (unit-capacity Dinic, `map_metrics.nim:530`), banded at `routeCountMin ≥ 2` |
| **I2** | Stand-side cover | for each base `k`: `area(W ∩ disc(bₖ, 200)) / area(disc(bₖ,200)) ∈ [0.10, 0.25]` | *measured* — `standCover` (`map_metrics.nim:173`) |
| **I3** | No cross-field sightline | there is no `y` with `minWall[y][x] = false` for all `x ∈ [sightlineLoX, sightlineHiX]` | *repaired then validated* — `arena.nim:1921` repair (budget `cols(40)` plugs), `arena.nim:2219` validator, both on a **stride-4 row sample** |
| **I4** | Bounded open run | `openRunMaxPx ≤ ~125` where runs are **axis-aligned** maximal open segments | *measured only* |
| **I5** | Spawn/capture disjointness | `spawnPocket(k) ∩ captureZone(j) = ∅` for all `k, j` | *carved and validated* |
| **I6** | Exact fairness | the full obstacle mask is invariant under the team symmetry group `Γ` (Klein V4 / D6 subgroup, `src/ctf/hex.nim:390`) | *constructed* — fundamental-domain generation + orbit lift, integer vertices |

Two notes that matter enormously for what follows.

**I1 is a graph property, not a pixel property.** Menger's theorem
([Wikipedia, Menger's theorem](https://en.wikipedia.org/wiki/Menger%27s_theorem)) says the
maximum number of internally vertex-disjoint `s`–`t` paths equals the minimum size of an
`s`–`t` vertex cut. So "≥ 3 disjoint routes" is exactly "no 2 cells whose removal
separates the bases." That is a *global* property of the free space and no local rule can
see it — which is precisely why the local-adjacency methods (§4.1) cannot deliver it.

**I4 as written is much weaker than what the player experiences.** `openRunMaxPx` is
computed over axis runs. A 45° open lane 900 px long passes I4. I say plainly below which
version of I4 is constructible (the axis one: yes; the all-directions one: no clean
construction exists, only sufficient conditions — §5.3).

---

## 3. THE SPINE — constructible / repairable / checkable, invariant by invariant

This is the table the rewrite hangs off.

| Invariant | Verdict | Mechanism | Class |
|---|---|---|---|
| **I1** ≥3 vertex-disjoint routes | **CONSTRUCTIBLE** | Build a **skeleton** of `k ≥ 3` pairwise vertex-disjoint fat corridors between every base pair *first*; forbid any later obstacle from intersecting the skeleton. Max-flow is monotone non-decreasing under adding open cells, so nothing downstream can reduce it. (Lemma 1, §3.1) | **(A)** |
| **I1** (retrofit path) | **REPAIRABLE, hard** | `k`-fold Dial's dig: run the burrow we already ship, mark the dug cells forbidden, run again, run again. 3 successful digs ⇒ 3 disjoint corridors ⇒ min-cut ≥ 3 by Menger. Uses `src/ctf/burrow.nim` unchanged except for a forbidden-cell mask. | **(A)** given a width/area feasibility budget |
| **I2** stand cover 10–25 % | **CONSTRUCTIBLE** | Treat `disc(bₖ, 200)` as its own placement cell with an **area budget**. Wall fraction is monotone increasing and additive in disjoint pieces, and the last piece can be shrunk continuously, so any target in `[0.10, 0.25]` is exactly attainable. Rasterising one 200 px disc is ~126 k px — sub-millisecond. | **(A)** |
| **I3** no horizontal cross-field ray | **CONSTRUCTIBLE** | 1-D interval cover: project every obstacle onto the `y` axis; the union of projections must cover `[ArenaBorder, H−ArenaBorder]`. Gaps get a picket. The projection union is **monotone** — once a row is covered no later obstacle can uncover it. Constructing *into* the gap set is strictly better than our current guess-a-column-and-retry repair with its `cols(40)` budget. | **(A)** |
| **I4** max open run ≤ 125 px, **axis-aligned** | **CONSTRUCTIBLE** | Per-row (and per-column) 1-D covering with spacing ≤ 125 px rather than "at least once". Same monotone bookkeeping as I3, one dimension richer. Note the *feasibility side condition* in §3.2. | **(A)** |
| **I4′** max open run ≤ 125 px, **all directions** | **ONLY CHECKABLE** — say so plainly | No construction gives it in general. Sufficient conditions exist from the visibility-obstruction literature (Pólya's orchard problem, dense forests — §5.3) but they are far denser than 10–25 % cover permits. Constructing for a finite direction set (0°, 45°, 90°, 135°) is the honest engineering compromise and covers most of the felt problem. | **(B)** at best |
| **I5** spawn ∩ capture = ∅ | **CONSTRUCTIBLE** | It is an arithmetic predicate over ~6 scalars (`homeDepth`, `spawnClearW/H`, `endzoneRadius`, board dims). Derive the safe interval for `homeDepth` once, clamp the parameter into it. Cannot fail. | **(A)** |
| **I6** exact fairness | **CONSTRUCTIBLE** | Generate strictly inside a fundamental domain of `Γ`, lift by the orbit, integer vertices so the lift is bit-exact (`sim_types.nim:752` already says this). Two caveats in §6: the **seam** and **chirality**. | **(A)** with stated caveats |

### 3.1 Lemma 1 — the monotonicity that makes I1 constructible

*Claim.* Let `F₀ ⊆ F₁` be free-space sets (i.e. `F₁` is `F₀` with more floor opened).
Then `maxflow_{F₁}(s,t) ≥ maxflow_{F₀}(s,t)` in the unit-vertex-capacity routing graph.

*Proof sketch.* The routing graph of `F₁` contains every vertex and every edge of the
routing graph of `F₀` (opening a cell only adds a vertex; it never deletes one, and it
only adds incident edges). Any feasible flow in `G(F₀)` is therefore feasible in `G(F₁)`.
∎

*Corollary (the design rule).* If we first place `k` pairwise vertex-disjoint fat
corridors and then only ever place obstacles **outside** their dilated footprint, the
final map has min-cut `≥ k` for every base pair. Obstacle placement never reduces the
free space *of the skeleton*, so the corollary is about a set difference, not about
monotone growth of the whole map — it is the same argument restricted to the protected
set.

*The place this dies: embedding.* Two corridors that are disjoint **in the graph** merge
**in the pixels** if they pass within one routing cell of each other, or if they cross.
The min-cut then drops silently. So the topology-first idea (Dormans, §4.3) only carries
its guarantee across the embedding step if the embedding carries a **separation
certificate**: `dist(corridor_i, corridor_j) ≥ 2 · RouteCellPx` for `i ≠ j`, and no
crossings (or crossings turned into shared junction vertices and re-counted). This is the
single most under-stated hazard in the whole graph-grammar literature, and §7 gives a
construction that discharges it for free.

### 3.2 The feasibility side condition on I3 / I4

I3 and I4 need a blocker on every row. The skeleton corridors are *unblockable* by
construction (that is the point of I1). So the construction is only feasible if **no
single row is entirely covered by skeleton corridors**. That is a design-time condition
on the skeleton graph's embedding, and it is discharged by the same 1-D projection
bookkeeping: while routing the skeleton, maintain the per-row "protected span" total and
refuse a corridor placement that would push any row's protected span to the full width.
Cheap (`O(H)` running array), and it converts a subtle global failure into a local
placement rejection.

### 3.3 The oscillation problem, and why separation solves it

Our current pipeline is: generate obstacles → repair connectivity (burrow *opens* floor)
→ repair sightlines (*adds* walls) → validate → retry. These two repairs are adversaries:

- **Burrow's dig is an I3/I4 adversary.** Dial's algorithm takes the *cheapest* path,
  which is the shortest path — i.e. it prefers straight lines, and a straight dug corridor
  is exactly the thing I3 forbids. It also prefers to run through existing near-open
  ground, which is disproportionately the stand-side cover I2 needs.
- **Sightline plugs are an I1 adversary.** A plug dropped into a corridor narrows or
  seals it, reducing the min-cut.

Nothing in the current pipeline re-checks I1 after the sightline repair or I3 after the
burrow, other than the global validator + retry — which is why the pass rate is a *retry*
statistic rather than a construction statistic (~92 % of 2-team, ~47 % of 4-team first
attempts pass, `arena.nim:2460`). Once the skeleton is protected and the fill region is
freely wallable, the two repairs act on **disjoint pixel sets** and cannot interfere.
That is the rewrite's central structural change and it costs nothing at runtime.

### 3.4 One more class we need: (A*) conditional guarantees

The (A)/(B)/(C) key needs a fourth box, because "ALWAYS good" is a *two-part* promise:
the map must be good **and there must be a map**. Solver methods split these:

- **(A) unconditional** — always terminates, always correct. Constructive methods.
- **(A\*) conditional** — *if* it returns, the output is provably correct; it may return
  nothing, and there is no useful bound on when. Every solver (SAT, SMT, ASP, WFC with
  backtracking) is (A\*), not (A).

For a game that must produce a map every episode inside a frame budget, an (A\*) method
**with no constructive fallback is a crash**, not a generator. This is the single most
important practical distinction in the survey and it is almost never drawn in the PCG
literature.

---

## 4. Technique survey

### 4.1 Wave Function Collapse and model synthesis — **(B)**, and widely oversold

**What it is.** Merrell's *model synthesis* (2007 i3D; SIGGRAPH 2008; 2009 thesis) is the
original formulation: given an example model, generate larger models in which every local
neighbourhood is one that appeared in the example. It uses a global search to find
vertex labellings that would make the model inconsistent and removes them from
consideration before committing, and it decomposes the generation into overlapping
subproblems solved in sequence
([Merrell, model synthesis](https://paulmerrell.org/model-synthesis/),
[PDF](https://paulmerrell.org/wp-content/uploads/2022/03/model_synthesis.pdf)).
Gumin's **WaveFunctionCollapse** (2016) is a re-derivation of the same algorithm with an
overlapping-`N×N`-pattern input mode and an entropy-ordered collapse heuristic; Gumin
credits Merrell explicitly and describes his contribution as generalising "his approach to
work with NxN overlapping patterns of tiles instead of individual tiles"
([mxgmn/WaveFunctionCollapse README](https://github.com/mxgmn/WaveFunctionCollapse/blob/master/README.md)).
Karth & Smith's analysis positions both as constraint solving — WFC is a
propagate-and-guess CSP solver whose propagation is arc consistency
([*WaveFunctionCollapse is Constraint Solving in the Wild*, FDG 2017](https://dl.acm.org/doi/10.1145/3102071.3110566)).

**What it actually guarantees.** Gumin states the property himself, and it is *local*:

> **C1.** "The output should contain only those NxN patterns of pixels that are present in
> the input."

C2 (that the output's pattern *distribution* resembles the input's) is explicitly the weak
one. There is nothing about connectivity, path count, sightlines, or cover. Boris Newgas
puts the limitation bluntly: "Because WFC only constrains nearby tiles, it rarely
generates large scale structures"
([*Wave Function Collapse Explained*](https://www.boristhebrave.com/2020/04/13/wave-function-collapse-explained/)).

Nor is success guaranteed. Gumin again: "The problem of determining whether a certain
bitmap allows other nontrivial bitmaps satisfying condition (C1) is NP-hard, so it's
impossible to create a fast solution that always finishes." When propagation empties a
cell's domain, base WFC simply gives up. Karth & Smith find that *shallow* backtracking
does little to resolve conflicts — the folklore that "just add backtracking and it's
fine" is folklore.

**WFC with global constraints.** Newgas's DeBroglie adds non-local constraints, including
`ConnectedConstraint` (a path exists between designated tiles), `LoopConstraint` (**at
least two independent paths**) and `AcyclicConstraint`
([DeBroglie path constraints](https://boristhebrave.github.io/DeBroglie/articles/path_constraints.html);
[*Tessera: A Practical System for Extended WaveFunctionCollapse*](https://www.boristhebrave.com/permanent/21/08/Tessera_A_Practical_System_for_WFC.pdf)).
These are real and useful, but the docs are candid: path constraints "are generally more
performance heavy than other constraints, and usually require backtracking to get good
results." That puts constrained WFC in class **(A\*)**: correct if it returns, no bound on
returning. And `LoopConstraint` tops out at 2 independent paths — our I1 wants 3.

**Verdict for us.**

| Variant | Guarantee | Class |
|---|---|---|
| Simple tiled WFC | tile-adjacency legality | **(A)** for adjacency — which is a *local* property and not one of our invariants |
| Overlapping WFC | C1 local pattern containment | **(B)** for anything we care about |
| Model synthesis | same + a contradiction-avoidance search that materially reduces failures | **(B)**, with better failure behaviour than WFC |
| WFC + DeBroglie path constraints | connectivity / 2 independent paths | **(A\*)**, and short of I1's `k=3` |

**And the grid mismatch is fatal on its own.** Our obstacles are continuous `ArenaShape`s
(`sim_types.nim:731`) on a ~3000×1600 px board; agents are 13 px solid; `MinCorridorWidth`
is 26 px today and the plan argues for 68 (`map_rules.nim:338`). To run WFC you must pick
a tile pitch. Pick it small (26 px) and you get a 115×61 grid where every tile is a
featureless blob and the "patterns" carry no architecture; pick it large (128 px) and the
tile *is* the design — you're really authoring a hand-made tile set and WFC is just
shuffling your own pieces, which is a legitimate authoring tool but not a generator with
guarantees. Merrell's own answer to the continuity problem is *Continuous Model Synthesis*
(Merrell & Manocha, [PDF](https://paulmerrell.org/continuous.pdf)), which works on plane
arrangements rather than a voxel grid — closer to our world model, and worth knowing
about, but it is a *modelling* technique for architectural geometry, not a playability
technique. **Recommendation: do not build the CTF generator on WFC.** It is the right tool
for skinning and for art-tile variety (class C for our invariants), and the wrong tool for
"always good."

### 4.2 Constraint solving: ASP, SAT, SMT, CSP — **(A\*)**, and the cost is the whole story

**Answer Set Programming.** Smith & Mateas, *Answer Set Programming for Procedural Content
Generation: A Design Space Approach* (IEEE TCIAIG, 2011,
[PDF](https://adamsmith.as/papers/tciaig-asp4pcg.pdf);
[researchr record](https://researchr.org/publication/SmithM11-3)) is the canonical
reference. The idea is the *generate / define / test* idiom: choice rules non-
deterministically lay down candidate content, definitions derive properties, and integrity
constraints forbid anything that violates them. The solver then enumerates **all and only**
the artifacts satisfying the specification. This is genuinely the family that can state
our I1 directly — a reachability-with-forbidden-vertices predicate plus
`:- not routes(B1,B2,3).` — and get either a map or `UNSAT`. Nothing else in this survey
can do that.

Follow-on work applies it to mazes and dungeons specifically
([Smith, *A Logical Approach to Building Dungeons*, AISB 2014](https://doc.gold.ac.uk/aisb50/AISB50-S02/AISB50-S2-Smith-paper.pdf);
[*ASP with Applications to Mazes and Levels*](https://link.springer.com/chapter/10.1007/978-3-319-42716-4_8);
[Graph-based action-adventure dungeon levels via ASP](https://www.researchgate.net/publication/327635798)).

**SAT / SMT.** Same power, different packaging. Nelson & Smith's constraint-based
generators produce a level *and a reference solution* simultaneously, so completability is
witnessed rather than asserted; Cooper's **Sturgeon** family generalises this — a mid-level
API over Boolean variables lowered into SAT, SMT, or ASP backends, generating a level
together with an example playthrough
([Sturgeon-MKIII](https://www.researchgate.net/publication/369968681)). For *continuous*
placement — which is our situation — the important pointer is
[*Spatial Layout of Procedural Dungeons Using Linear Constraints and SMT Solvers* (FDG
2020)](https://dl.acm.org/doi/10.1145/3402942.3409603): rooms as real-valued rectangles,
non-overlap and adjacency as linear arithmetic, solved by Z3. That is the one paper in
this survey whose problem shape most nearly matches ours.

**What they guarantee.** (A\*) — every returned model satisfies every stated constraint,
exactly. `UNSAT` means no map in the declared space satisfies them, which is itself
valuable information (it tells you your invariant band is empty for that board size, which
is exactly the failure mode behind our 3/6-team aspect-ratio problem).

**Cost, realistically.** This is where the family fails as a *runtime* generator:

- **Grounding, not solving, is the wall.** clingo grounds rules into propositional form
  before solving. A transitive-closure `reach/2` over a 115×61 = 7 015-cell board grounds
  to ~`n²` = 49 M instances *per source*, and I1 needs it per base pair under vertex
  deletion. The literature says exactly this: clingo "does not scale well, reaching memory
  limits while grounding at higher scaling factors," and "grounding time can be
  unacceptably large as problem size increases despite negligible solving time"
  ([Pushing the Limits of Clingo's Incremental Grounding](https://www.mdpi.com/1999-4893/16/3/169);
  [*Diminution: On Reducing the Size of Grounding ASP Programs*](https://arxiv.org/pdf/2508.08633)).
- The optimistic in-game numbers in the literature — "the time required for PCG is
  negligible and usually below a second"
  ([An Application of ASP for PCG in Video Games, CEUR](https://ceur-ws.org/Vol-3204/paper_14.pdf))
  — are for *small* levels (tens to low hundreds of cells), not 7 000 cells with a
  vertex-connectivity constraint.
- SMT over continuous coordinates is better behaved on *our* variable count (dozens of
  shapes, not thousands of cells) but pairwise non-overlap is `O(n²)` disjunctions and Z3
  on ~50–100 rectangles with adjacency is comfortably in the 0.1–10 s range, not 10–30 ms.

**Therefore: solvers are an OFFLINE tool for us.** Two roles where they pay for
themselves immediately, at zero runtime cost:

1. **Catalogue construction.** Use clingo/Z3 to enumerate a few hundred *skeletons*
   (topology + corridor routing on a coarse lattice, §7) that provably satisfy I1, I3,
   I5 and I6. Ship the catalogue as data. The runtime picks one and decorates the fill
   region constructively. This converts an (A\*) with unbounded cost into an (A) with
   zero cost, and it is the standard move.
2. **Verification oracle.** Encode the invariants once in ASP and use it in CI as an
   independent check on the constructive generator. Two implementations that must agree
   is the cheapest real assurance available; it catches "the constructor and the metric
   disagree about what 3 routes means," which is exactly the class of bug that ships.

One more genuinely useful pointer from this family:
[*You-Only-Randomize-Once: Shaping Statistical Properties in Constraint-based
PCG*](https://arxiv.org/pdf/2409.00837) — solver-based generation naturally produces
*some* answer, not a *representative* one, and this is a real technique for getting
distributional control back. Relevant because our best-of-K ranker assumes candidates of
one seed are comparable samples.

### 4.3 Graph and shape grammars — **(A) for topology, (B) for geometry**

**Dormans's mission/space split.** The core idea — generate the *mission* (the abstract
task/connectivity structure) as a graph via graph rewriting, then generate the *space*
that realises it — is the right idea for us, and Dormans's **cyclic dungeon generation**
is its sharpest form: instead of searching for a path from start to goal, the generator
*rewrites in a cycle*, so the level provably contains a loop rather than a tree
([Dormans/Ludomotion, *Unexplored's Secret: Cyclic Dungeon Generation*, Game
Developer](https://www.gamedeveloper.com/design/unexplored-s-secret-cyclic-dungeon-generation-);
[Newgas, *Dungeon Generation in Unexplored*](https://www.boristhebrave.com/2021/04/10/dungeon-generation-in-unexplored/);
[Newgas, *Graph Rewriting for Procedural Level Generation*](https://www.boristhebrave.com/2021/04/02/graph-rewriting/)).

**What a grammar guarantees:** exactly the invariants preserved by its production rules,
and no more. That is a real and precise (A) — if every rule preserves 3-connectivity of
the mission graph (start from a 3-connected seed graph and only apply rules that are
connectivity-monotone, e.g. vertex splitting, edge subdivision *paired with* a
compensating edge), then every derivation is 3-connected. **This is the mechanism our I1
should use at the topology layer.** Concretely: 3-connected planar graphs are exactly the
graphs of convex polytopes (Steinitz), and there is a clean generation route — start from
a wheel `W_n` (3-connected by inspection) and apply Δ-Y / edge-addition operations known
to preserve 3-connectivity (Tutte's wheel theorem gives the converse: every 3-connected
graph reduces to a wheel). Harary's `H_{k,n}` gives minimal `k`-connected graphs with
`⌈kn/2⌉` edges if you want the sparsest 3-connected skeleton
([Menger's theorem](https://en.wikipedia.org/wiki/Menger's_theorem);
[edge connectivity notes](https://en.wikipedia.org/wiki/Edge_connectivity)).

**What a grammar does NOT guarantee:** anything geometric. The guarantee evaporates at
embedding (Lemma 1's corollary, §3.1). Dormans's own pipeline embeds with a second
"space grammar" and the space grammar can and does fail to realise the mission graph
faithfully; production systems handle this by retrying. So: **(A)** for the graph,
**(B)** for the map, unless the embedding step is itself constructive (§4.4, §7).

**Shape grammars and split grammars.** Stiny & Gips's shape grammars (1972; set grammars
1982) and Wonka et al.'s **split grammars** (*Instant Architecture*, SIGGRAPH 2003) give a
different and genuinely useful (A): a split rule **partitions** a shape into sub-shapes,
so a derivation is a partition of space and sub-shapes **cannot overlap, by construction**
([Procedural Modeling of Buildings / CGA Shape lineage](https://peterwonka.net/Publications/pdfs/2008.CGA.Watson.ProceduralModelingTutorial.pdf);
[Recompose Grammars for Procedural Architecture, SIGGRAPH 2024](https://dl.acm.org/doi/10.1145/3641519.3657400)).
Non-overlap and exhaustive coverage are exactly the properties BSP-style room layout
wants, and our `styleBsp` already gets them implicitly. But split grammars say nothing
about connectivity or sightlines. **(A) for the partition, (C) for playability.**

**L-systems.** Parallel rewriting for branching structures. No invariant we need is
preserved by an L-system, and their characteristic output (trees/branches) is topologically
*acyclic*, which is the opposite of I1. **(C)** for us — useful for decorative
vegetation and crack/erosion detail only.

### 4.4 Graph embedding and floor-plan synthesis — **the missing constructive step**

If §4.3 gives us a topology with the right guarantee, this section is how to lay it into
geometry **without losing the guarantee**. Four families:

**Rectangular dualization.** Given a planar adjacency graph, produce a partition of a
rectangle into rectangles whose adjacency graph is exactly the input. This is a hard,
exact realisation theorem: a plane graph has a rectangular dual iff it is *rectangularly
dualizable* (essentially: internally triangulated, no separating triangles, four corner
vertices on the outer face), and there are **linear-time** algorithms to build it
([*A Theory of Rectangularly Dualizable Graphs*, arXiv:2102.05304](https://arxiv.org/pdf/2102.05304);
[*Rectangular Dualization of biconnected plane graphs in linear time*](https://cab.unime.it/journals/index.php/congress/article/download/125/125);
[Kozminski & Kinnen, *Rectangular duals of planar graphs*](https://www.researchgate.net/publication/229650900);
[He, *Sliceable Floorplanning by Graph Dualization*, SIAM J. Discrete Math.](https://doi.org/10.1137/S0895480191266700)).
**Class (A) conditional on dualizability** — and dualizability is *checkable in linear
time and constructible by design*: if you generate the topology graph in the dualizable
family to begin with, you never fail. Linear-time realisation is comfortably inside our
budget. This is the strongest off-the-shelf constructive embedding in the literature.

Caveat: rectangular duals give **rooms sharing walls**, which encodes adjacency as *shared
boundary*, not as *a corridor of width ≥ 68 px*. Converting shared boundary to a doorway
of controlled width is an extra step, and it is where the disjointness certificate has to
be re-established (two doorways on the same wall segment can be one routing cell apart).
Doable — punch doorways at the wall midpoint with the lattice pitch as the separation
guarantee — but it is not free.

**Orthogonal graph drawing.** Draws a graph with edges as rectilinear polylines, and the
literature gives exact bounds on bends, edge separation and area. Class **(A)** for
planarity and separation — which is precisely the certificate Lemma 1 needs. If corridors
are drawn as orthogonal polylines with a guaranteed minimum separation, corridor
disjointness in pixels follows from disjointness in the drawing. This is the most direct
route from "3-connected graph" to "3 vertex-disjoint pixel corridors."

**Treemaps / squarified layouts.** Partition a rectangle into sub-rectangles with
prescribed *areas*. Class **(A) for area targets** (each cell gets exactly its share) and
**(C) for topology** (adjacency is whatever falls out). Directly useful for **I2**: give
the stand-side 200 px disc an area budget and squarify the cover pieces into it. Not
useful for I1.

**Optimisation-based level layout.** Ma, Vining, Lefebvre & Sheffer, *Game Level Layout
from Design Specification* (CGF 2014,
[preprint PDF](http://www.chongyangma.com/publications/gl/2014_gl_preprint.pdf);
[HAL record](https://inria.hal.science/hal-00927311)) takes a user connectivity graph plus
building blocks and lays them out, "in seconds," producing diverse layouts for the same
connectivity. Excellent prior art and the closest published thing to what we want — but it
is a **deformation/optimisation** method: it *tries* to satisfy the specification and
measures how well it did. **Class (B).** Worth reading for its block-deformation
machinery; do not rely on it for a guarantee.
