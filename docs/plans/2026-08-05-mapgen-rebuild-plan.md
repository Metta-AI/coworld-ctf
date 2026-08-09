# Map generator rebuild — the ranked build plan

_2026-08-05. Synthesis of five research surveys (`docs/research/*.md`, ~6,800 lines), a
300-seed defect audit, and what shipped during the session that produced them._

This is the decision document. The research says what is possible; this says what we build,
in what order, and what we deliberately do not build.

---

## 1. The verdict

**Replace the drawing pass. Keep everything under it.**

The geometry kernel is sound and was independently re-verified: symmetry lifting is exact,
`validateGeneratedMap` catches real failures, `rasterizeWallMasks` is pixel-identical to the
shipped collision bake, and the measuring stick (`map_metrics`, `map_rules`, `burrow`, `hex`)
is built and calibrated against a hand-authored control.

What must go is the column lattice, the sightline-repair prosthetic, and the blind feature
placement on top of them. Measured, on 300 seeds:

| defect | measured |
|---|---|
| useful windows (>=200px clear both sides) | **27.8%** vs the arena's **71.4%** |
| maps with no useful window at all | **41.7%** |
| centre feature dead on giant boards | **100%** (hard-coded 138px offset vs a scaled 182px flag ring) |
| 2-team maps with no centre architecture | **52%** |
| repair plugs as a share of interior wall | **14-16% median** standard, **50% at p90** on 4-team |
| grenade spawns in stone / unreachable (4-team) | **5.0% / 15.5%** |
| `interiorFrac` (enclosure) | pool median **0.118** vs arena **0.342** |

The decisive test was not the defect count. It was the counterfactual: **could a smarter
window selector fix it?** No — adjacent columns sit 51-76px apart, so small and standard
boards offer 2.0-2.4 usable window spots against a draw of 2-4. The lattice spacing *is* the
occluder. That is what makes this a replacement rather than a repair.

---

## 2. The organising principle

Classify every technique as **(A)** a hard guarantee (cannot emit a violating map),
**(B)** a distribution shift (still needs filtering), or **(C)** cosmetic. "Always good" only
ever comes from (A).

**Search cannot get us there, and we can prove it on our own data.** Best-of-K returns the
K/(K+1) quantile of the generator's *own* distribution — it changes the measure, never the
support. After 12x selection `interiorFrac` still sat at the pool median 0.118, because none
of the twelve candidates had architecture to select.

**The mechanism for (A) is monotonicity plus spatial separation, not a solver.** Our
invariants split into two families with opposite monotonicity:

- route count rises only when you **open** floor
- cover and sightline-blocking rise only when you **add** walls

Give each family a disjoint pixel set — a **protected skeleton** never walled, a **fill
region** freely walled — and both hold simultaneously with zero search. This also explains
why the current pipeline oscillates: `burrow`'s cheapest-path dig is a straight-corridor
generator (a sightline adversary), the plug pass narrows corridors (a route adversary), and
nothing re-checks either.

### Invariant constructibility

| invariant | verdict |
|---|---|
| k vertex-disjoint routes | **constructible** — skeleton-first, obstacle exclusion |
| stand-side cover band | **constructible** — budgeted fill; size the last piece |
| no cross-field sightline | **constructible** — 1-D interval cover |
| max open run, axis-aligned | **constructible** |
| max open run, **all directions** | **only checkable** — stated plainly |
| spawn zone clear of capture circle | **constructible** — clamp the parameter |
| exact fairness | **constructible** — already done, modulo the two bugs in §5 |

Two theorems make the first one concrete:

- **Every plane triangulation with >=4 vertices is 3-connected**, so by Menger there are 3
  vertex-disjoint paths between every pair. Delaunay-with-all-doorways-open *is* such a
  triangulation: start 3-connected and close doorways only while the check still passes.
  Planarity caps k <= 5 — no 2-D board does better without an overpass.
- **A mirror axis is a Voronoi edge unless a seed sits on it.** Symmetric seeds with an
  unseeded axis produce a perfectly straight full-board corridor down the middle of every
  2-team map. Seed the axis at spacing < r and the on-axis cells provably cover it. This
  would have shipped as the worst possible defect in this game.

---

## 3. What the engine actually is — two corrections that move many numbers

**`GunRange = 1050` is a REACH, not an engagement range.** Aim is 32 discrete slots, there is
no aim assist, and the gun samples the **13px solid body**, not the 34px drawn one. Aim jitter
(sigma 0.596 deg) is 9.4x smaller than the 5.625 deg half-slot, so the lattice dominates.

    R_slot = (PlayerHalf + BulletHalfWidth) / tan(5.625 deg) = 14 / 0.09849 = 142 px

P(hit) ~= arctan(14/t) / 5.625deg: **0.47 at 300px, 0.14 at "gun range"** (TTK 10.5s there).
Three independent constants converge on ~260px: `FieldAccuracyPct = 55` is achieved at 259px;
`GrenadeMaxRange = GunRange/4 = 262px` (agrees to 1.2%); the observed 1.0-1.9s TTK band implies
142-225px.

Consequences: **any density or encounter law computed on gun or vision range is overstated
12-16x**; `ChokepointSpacingPx = GunRange` is ~4x too large; the chokepoint isovist cut at
1050px measures *watching*, not *covering*, and should be re-cut at ~260px. The
`coneCoverage` regimes survive as **awareness** regimes; on the **lethality** axis every board
is range-limited. `MaxExposedRunPx = 132` survives, because `TicksToKill = 48` corresponds to
a ~237px engagement.

**Movement is L-infinity, not Euclidean** (`velX`/`velY` clamp independently, no diagonal
normalisation): 41% heading anisotropy, and the isometry group is **D4**. So 3- and 6-team
maps carry an irreducible **15.5% travel-speed penalty for one team in three** — no board
shape fixes it. That is a game-design decision, not a map-generation one.

---

## 4. Stated rules vs enforced rules

These diverged silently and every one was found by reading the code against the brief:

| property | design intent | actually enforced |
|---|---|---|
| vertex-disjoint routes | >= 3 | **`routeCountMin >= 2`** |
| stand-side cover | 10-25% within 200px | **no absolute rule** — only a fairness *spread* |
| cover budget | 18-30% (brief) | **`CoverPermille 40-170` = 4-17%** |
| open-run scan | all directions | **horizontal + vertical only** |
| hard sightline gate | all axes | **horizontal rows only** |

The sharpest one: **a fairness spread cannot express an absolute floor.** Two *equally naked*
stands score 0 on `standCoverSpread` and pass — so the one causally-established property in
the whole suite (stand-side cover, the conversion invariant: maps outside the band converted
0-of-21, 0-of-17, 0-of-10) is the one the validator does not enforce.

---

## 5. Shipped fairness bugs — fix these first, they are one line each

Both are off-by-one errors in a symmetry convention, both silent until something lands on the
boundary, both found by measurement and hidden by a green test.

1. **`pointInPolygon` strict straddle** (task `ed59c142`). A vertex whose neighbours straddle
   its scan row has *both* edges skipped; parity inverts for the rest of that row, and under
   the mirror the inversion lands on the other side — **the two teams get different walls.**
   Measured: 8,770 asymmetric wall px (19%) on the shipped `caves` style; 234 on a plain convex
   quad. Live since GV37. The existing test passes only because it samples every 9th pixel.
   Fix: the half-open rule `(yi > y) != (yj > y)`.
2. **Anchor seam off-by-one** (task `a3fca5b0`). Anchors are placed at `width - x` while shapes
   mirror at `width - 1 - x`, so `mapProtectedFloorAt` disagrees with itself over two 1px
   columns, 522px per standard board, on every size class. Any obstacle overlapping a spawn
   pocket edge is **stone for one team and floor for the other**. The stock generator misses
   those columns by luck, not correctness. Fix: `width - 1 - first`.

**These two also unblock visual quality.** The shape vocabulary currently ships a deliberate
regression — massifs render as *visible beads on a string* on 4-team boards — because its
polygon mitigations exist only to work around bug 1. Fixing both lets `symmetryIsReflection`
and `mirrorIsVertical` be deleted and restores the organic silhouette.

---

## 6. Build order

Already landed this session: `map_metrics` (fitness), `map_rules` (per-regime targets),
`map_seed` (per-scene RNG substreams), generator-agnostic best-of-K, `burrow` + `hex` merged,
`map_lanes` (k-fold disjoint burrow with a **Menger certificate, proved 3/3 seeds**),
`mapgen_vocab` (8 constructors), `mapgen_biomes` (5 ported terrains), `mapgen_graph`
(scene-graph prototype at `interiorFrac` **0.345** vs the arena's 0.342), GV38, and the
defect-probe tooling.

**Rank 1 — the two fairness fixes (§5).** One line each, unblock visual quality, and no
generator work should be measured on an unfair substrate.

**Rank 2 — fix the measuring stick before building against it.**
- Diagonal open runs: *measured this session and separated from the axis bands*. The longest
  open line on our own control is **diagonal** (arena 790px vs 663px axis; arena-large 1185px,
  longer than a full gun range) and was invisible. Decide whether it joins the gate.
- Re-cut the chokepoint isovist at ~260px, not 1050px (§3).
- Give chokepoint detection a **pinch length**; today a 40px doorway and a 40px x 400px
  shooting gallery score identically.
- Add an **absolute** stand-side cover floor, not only a fairness spread (§4).
- Fix `selectBestMap`'s silent degeneration (task `bdd2987e`): `subScore` is flat 1.0 inside a
  band, so the maximum is a plateau and ties keep candidate 0. Make it visible.

**Rank 3 — validate the surrogate. Time-sensitive.** `staticScore` is a hand-written,
never-validated surrogate for play quality. A ~3.2h experiment (40 maps x 3 episodes, Spearman
rho per band vs `MapPlay`) decides what the whole objective should be — and **it needs the old
generator's 0.717-0.932 spread to compute a correlation at all.** A saturating generator
destroys the measuring instrument. Run it before the scene graph replaces the old one.

**Rank 4 — the scene graph as the generator.** Skeleton-first, fill-second, per-scene RNG
substreams, every scene carrying a stated purpose and a post-condition. Consume `mapgen_vocab`
and `mapgen_biomes` as content scenes; `map_lanes` for the skeleton; `burrow` for repair.
Delete the sightline prosthetic in favour of the interval-cover constructor (blocked on task
`76332cf1` — one open row survives on 2 of 3 carved seeds).

**Rank 5 — population-driven sizing** (task `b0b9d6cf`). Size class is currently drawn
**uniformly at random, independent of team count**, so a 1v1 can land on a giant board at 54x
the tuned player density. Derive area from `P = teams x unitsPerTeam` on the **~260px lethal
envelope**, not gun range. Resolve the conflict where base separation forces 6 teams onto giant
while density says otherwise.

**Rank 6 — diversity as a first-class objective.** Our honest weakness is no longer quality,
it is sameness: the scene-graph prototype "replaced a uniform lattice of pebbles with a uniform
lattice of boxes". Partition the 15 bands into ~6 constraints + ~8 style axes + ~1 quality term
and run MAP-Elites over `interiorFrac` x `routeCapacityFrac`. Offline search power is ~29,000x
the online budget (576,000 evaluations overnight vs 20 per request) at zero latency cost,
because scoring is pure — archive elites offline, sample-and-mutate online.

---

## 7. Do not build

- **WFC as the generator.** Its guarantee is local similarity to an exemplar, not playability;
  the decision problem is NP-hard by its author's own statement; the best path-constraint
  implementation tops out at 2 independent routes and we need 3. Keep it for skinning.
- **Aperiodic tilings.** Penrose has Ammann bars — perfectly straight lines across the whole
  tiling. Aperiodic != no sightlines, and aperiodicity fights our mandatory point symmetry.
- **BSP for anything but base pockets.** A BSP tree is 1-connected; an axis-aligned cut
  spanning the domain leaves a straight street, and a straight street is a weapon here.
- **Solvers at the pixel layer.** clingo on 7,192 routing cells grounds to ~50M+ atoms; on a
  60-node skeleton graph it solves in single-digit ms. Topology layer only.
- **Thresholded noise as a room generator.** The Euler-characteristic density of a Gaussian
  excursion set is strictly positive (blob regime, no enclosed holes) at every threshold our
  cover cap permits; you would need >50% wall to reach the hole regime. This is topological, so
  no octave count or domain warp touches it — a warp is a diffeomorphism and diffeomorphisms
  preserve topology. Noise is a **texture layer**, downstream of structure.
- **Bigger K, NSGA-II over 15 objectives, PCGRL/PCGML** (7 hand-authored maps is not a corpus),
  and any hill-climbing before the ranker is fixed — you cannot hill-climb a plateau.

---

## 8. The standing methodological rules

Every one was learned by producing a confidently wrong number.

1. **Run the hand-authored `arena` as CONTROL in every batch.** A metric that flags your
   control is wrong; a metric that skips it is worse. Both have happened here.
2. **Never report a count without its fraction.** A count cannot tell "one narrow doorway"
   from "one enormous gap".
3. **Merge >= 3 seeds before judging**, and remember a capture *ends* the episode, so episode
   length is itself an outcome.
4. **A metric earns fitness status only when an intervention moving it has been shown to move
   the OUTCOME.** The CQB-plant change perfected its mechanism (moving-while-firing 63% ->
   0.1%) and moved hit rate 36.0 -> 36.1 while kills fell 34%. That costs ~3.2 machine-hours
   per metric, which is why the objective may hold 2-3 quality terms, not 15.
5. **Read the ranking next to the render, always.** Two independent agents found that their
   best-scoring items render as a *barcode* and as *confetti*, while a mid-table random mix was
   the best-looking map produced. `interiorFrac` per unit cover rewards fine-grained parallel
   layouts, which look like nothing.
