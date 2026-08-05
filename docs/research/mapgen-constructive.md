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
