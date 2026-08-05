# Search-Based PCG and Optimisation

**Research dimension:** using a *fitness function to search for* good maps, rather than
*constructing* them directly.

**Status:** research note. Nothing here is implemented; the worktree touches no source.

**Date:** 2026-08-05. **Repo state:** `src/ctf/map_metrics.nim` (~45 metrics, 15 bands),
`src/ctf/arena.nim:2447 selectBestMap` (best-of-K), `MapSelectionK` = 12/8/6/4/2/1.

---

## 0. Verdict up front

1. **We are already doing search-based PCG, in its weakest possible form.** Best-of-K
   with a static fitness is the textbook *generate-and-test* / *elitist (μ+λ) with μ=1,
   λ=K, one generation* configuration. The measured +0.061 median gain is exactly what
   the order-statistic arithmetic predicts and nothing more.

2. **Our fitness function saturating at 1.000 is not a surprise, it is a proof.** The
   score is a weighted mean of *flat-topped* band satisfaction terms. Its maximum is
   attained on a plateau, not at a point. A generator good enough to land inside all 15
   bands makes the ranker constant, and I can show from the code that this silently
   reverts best-of-K to **best-of-1** — `selectBestMap` uses strict `>`, so on an all-ties
   field it returns the *first valid attempt*, which is precisely the pre-selection
   behaviour we spent the work to remove.

3. **The single highest-value technique in this dimension for us is MAP-Elites**, and
   not for the reason it is usually adopted. It fixes diversity *and* it fixes
   saturation, because an archive cannot saturate the way a scalar can: to raise
   QD-score you must fill cells the generator has never reached.

4. **The single biggest structural insight is that search should move offline.** Best-of-K
   pays an *online* budget (~1 s per map request → ~20 static evaluations). An archive
   built overnight buys ~500,000. That is a 4-order-of-magnitude change in search power
   for zero change in request latency, and it is available today because
   `evaluateMap` is already a pure function.

5. **The single biggest danger is the same fact.** Search power is Goodhart pressure.
   Our 15 bands were calibrated by *observation* (arena vs. the 20-seed pool) and not one
   of them by *intervention*. The CQB-plant episode — mechanism perfected
   (moving-while-firing 63% → 0.1%), outcome unchanged (hit rate 36.0 → 36.1), and the
   real outcome moved the *wrong way* (kills −34%, deaths +34%) — is textbook **causal
   Goodhart**, and it is the exact failure mode a 500,000-evaluation search would find and
   exploit. **Do not raise search power before validating the surrogate.** Section 10 gives
   a 3-hour experiment that decides this.

6. **The honest ceiling: search cannot invent what the generator cannot express.**
   Best-of-K moves the *tail* of a distribution; it never moves the *mode*. Our own
   numbers prove it — after selection, `interiorFrac` still sits near the pool's 0.118
   against the arena's 0.342. Filtering harder makes better scatter. It does not make
   architecture. See §13.

---

## 1. What we already have, stated precisely

### 1.1 Best-of-K *is* search-based PCG

`arena.selectBestMap` (`src/ctf/arena.nim:2447`) draws candidates `0, 1, 2 …` for one
seed, gates each with `validateGeneratedMap`, scores the survivors with
`map_metrics.staticFitness`, and returns the argmax of the first K that pass.

In the Togelius/Yannakakis/Stanley/Browne taxonomy this is:

| Taxonomy axis | Our position |
|---|---|
| Online / offline | **Online** — runs at map-request time, inside the latency budget |
| Necessary / optional content | **Necessary** — a bad map breaks the match |
| Random seeds / parameter vectors | **Random seeds** (`seedStream`, attempt index) |
| Stochastic / deterministic | Stochastic generator, deterministic given (seed, attempt) |
| Constructive / generate-and-test | **Generate-and-test** |
| Representation | **Direct-ish** — the generator's own parameterisation, not searched over |
| Evaluation function | **Direct** (static geometric measures), *not* simulation-based |
| Search operator | **None.** We *sample*; we do not mutate, recombine, or hill-climb |

That last row is the important one. Everything the field calls "search-based PCG"
involves a *search operator* that moves from a candidate toward a better one. We have
none. We draw i.i.d. samples and take the best. In evolutionary terms we run **one
generation with no variation operator** — which is to say, random search with elitism.

This matters because it caps the achievable gain at a known quantity. For K i.i.d. draws
from any continuous quality distribution, the expected quality *percentile* of the max is
`K/(K+1)`. Our own code comment says exactly this. At K=12 that is the 92nd percentile of
the generator's own range — and the generator's range is the thing that is wrong.

### 1.2 The saturation bug, provable from the code

```nim
# map_metrics.nim:1243
proc subScore(band: Band, value: float): float =
  if value >= band.lo and value <= band.hi: return 1.0     # <- FLAT TOP
  ...
proc staticScore*(m: MapMetrics, bands = DefaultBands): float =
  if not m.valid: return 0.0
  ... total += r.sub * r.band.weight ...
  total / weight                                            # <- max 1.0, on a PLATEAU
```

```nim
# arena.nim:2504 (inside selectBestMap)
    if value > result.score:      # <- STRICT greater-than
      result.score = value
      result.gameMap = candidate
```

Compose those two facts:

> When every candidate scores 1.000, `value > result.score` is false for candidates
> 2..K, so `selectBestMap` returns **attempt 0** — the first valid draw. Best-of-K
> degenerates to first-valid, with the full cost of K still paid.

The sibling scene-graph prototype scoring 1.000 on 39 of 40 seeds means best-of-K is,
today, **doing no selection at all on that generator** while spending 8–12× the
generation cost. This is not a subtle statistical worry; it is a switch that is already
off.

Two corollaries worth writing down:

- **Any tie-breaking rule is now the real selector.** With a saturated fitness, whatever
  arbitrary rule breaks ties (here: RNG attempt order) *is* the generator's quality
  policy. This is [regressional Goodhart](https://arxiv.org/abs/1803.04585) in its purest
  form: selecting the argmax of a proxy selects for the proxy's noise once the signal is
  exhausted.
- **The `0.840 → 0.901` result was measured on the *old* generator.** It is a fact about
  a generator whose quality distribution had spread. It does not transfer to a generator
  that has none. Re-measuring `median staticScore` on the scene-graph prototype and
  reporting "0.901 → 1.000" would be reporting the *instrument going out of range*, not an
  improvement.

### 1.3 A pass-rate discrepancy worth reconciling

`arena.nim:2461` documents the gate as passing **"~47% of 4-team first attempts."** The
brief for this work states **22–23%** for 4-team small/standard (35–55 attempts to find
K=12 valid). Both cannot be current. This matters because:

- `MapGenMaxAttempts = 100` and `generateCtfMap` **raises** when zero candidates validate.
- At p = 0.223, drawing 100 gives mean 22.3 valid (sd 4.16), so P(fewer than K=12 valid)
  ≈ 0.7% of seeds. On those seeds we silently ship best-of-*fewer-than-K*. The accounting
  is recorded (`MapSelection.valid`) but nothing reads it.
- If a future generator's pass rate fell to 3%, P(zero valid in 100) = 0.97¹⁰⁰ ≈ **4.8%
  of seeds raise**. The rejection loop's safety margin is a function of a pass rate that
  is not monitored as an SLO. See §6 and §13.2.

**Action:** re-measure the pass rate per (teams × size class), record it next to
`MapSelectionK`, and add a regression test that fails when it drops below the level that
makes K reachable. This is cheap and it is the kind of thing that fails silently.

### 1.4 What "we filtered out the bad ones" is and is not worth

**It is worth:** a guaranteed order statistic. If the generator produces a map that the
fitness *can see* is bad with probability q, best-of-K ships one with probability ≤ qᴷ,
provided "bad" implies "lowest-scoring". That is a real and cheap win, and 123/150
improved with 0 regressed is a clean demonstration of it.

**It is not worth:**

- **Anything about properties the fitness does not measure.** For those, K provides
  exactly zero protection. Not "less protection" — zero.
- **Neutrality on unmeasured properties.** This is the part usually missed. Selection is
  not a no-op on things you did not measure; it *shifts* them. If some unmeasured badness
  co-varies positively with a measured good, selecting hard on the measured good actively
  *enriches* the badness. Concretely: `interiorFrac` carries weight 3.0, and if enclosed
  floor co-varies with (say) unreachable pockets, dead corners, or spawn camping angles,
  best-of-K systematically selects toward them. Nobody has checked.
- **Any guarantee at all.** Best-of-K is category **(B)**. Our only category **(A)** is
  `validateGeneratedMap`, and only for the properties it actually tests.
- **Moving the mode.** §13.

---

## 2. The field: search-based PCG in one page

[Togelius, Yannakakis, Stanley & Browne, "Search-Based Procedural Content Generation: A
Taxonomy and Survey," *IEEE TCIAIG* 3(3):172–186,
2011](https://ieeexplore.ieee.org/document/5756645) is the canonical reference; the
[PCG Book chapter 2](http://pcgbook.com/) is the same material in book form. Its three
load-bearing distinctions:

**(a) Constructive vs. generate-and-test.** A constructive generator builds content once
and ships it; a generate-and-test generator produces candidates and evaluates them,
looping until acceptable. Search-based PCG is the sub-case of generate-and-test where the
test returns a *grade*, not a *pass/fail*, and that grade drives search. We are here, with
one generation.

**(b) Representation: direct vs. indirect encoding.** In a *direct* encoding, the genotype
maps one-to-one-ish onto the artefact (e.g. a genome that is the tile grid). In an
*indirect* encoding, the genotype is a compact recipe — a parameter vector, a grammar
expansion, a description-language script — and a deterministic constructor expands it.
The trade-off the survey draws:

| | Direct | Indirect |
|---|---|---|
| Search space size | Enormous (|tiles|^cells) | Small |
| Locality (small genotype change → small phenotype change) | Good | Often poor |
| Fraction of space that is *valid* | Vanishing | Can be made high by construction |
| Expressiveness | Everything | Only what the constructor can build |
| Evaluation cost per useful step | Terrible | Good |

**This is the crux for us.** Our maps are ~1500×800 px of geometry; a direct encoding is
not searchable at any budget we have. An indirect encoding — the generator's own
parameters, or better, a scene-graph description — is the only tractable genotype, and
choosing it *is* choosing the expressive range. Every result in this document assumes an
indirect encoding. The sibling scene-graph prototype is, whether or not it was designed
as one, **the genotype language this whole dimension needs**, and it should be exposed as
a mutable parameter vector rather than only as a seeded constructor.

**(c) Evaluation function: direct, simulation-based, or interactive.**

- **Direct** — compute a number from the artefact's geometry. Cheap. `staticScore` is
  this. Risk: it is a *proxy*, and its relationship to the thing you care about is
  assumed, not measured.
- **Simulation-based** — play the artefact with an agent and measure the play. Expensive.
  Our `MapPlay` type exists (`map_metrics.nim`) and is populated by
  `tools/map_playtest.nim`; a full episode is ~97 s at 32 seats.
- **Interactive** — a human grades it. Highest fidelity, lowest throughput. This is
  Maxwell rejecting correct-footprint maps twice; it is a real evaluation channel and it
  has already fired.

A well-known result across the QD/PCG literature (and visible in the FPS MAP-Elites work
below) is that *direct* fitness functions are where the pathology lives, because they are
cheap enough to be optimised to death. §11.

---

## 3. Technique table with (A)/(B)/(C) classification

**(A) HARD GUARANTEE** — cannot produce a violating map.
**(B) DISTRIBUTION SHIFT** — makes good output likelier; still needs filtering.
**(C) COSMETIC** — changes cost, presentation, or plumbing; does not change what ships.

| # | Technique | Class | What it actually guarantees | Verdict for us |
|---|---|---|---|---|
| 1 | `validateGeneratedMap` (hard gate / rejection sampling) | **A**, narrowly | No map ships that fails *the properties it tests*. Nothing else. | Already have. Our only (A). Keep it the only (A) and stop asking the ranker to do its job. |
| 2 | Best-of-K / elitist random search | **B** | Ships the argmax of K i.i.d. draws — the K/(K+1) quantile of the *generator's own* range. | Have it. **Currently disabled by saturation.** Worth keeping; not worth expanding K. |
| 3 | Hill climbing on the map | **B** | Local optimum of the fitness. No feasibility guarantee. | Weak alone (our landscape is band-plateau'd → zero gradient). Useful only as an *emitter* inside a QD archive. |
| 4 | Simulated annealing | **B** | Asymptotically global optimum, at infinite time. | The classic answer for layout, and genuinely applicable to *placement refinement* (moving obstacles to hit a `collisionCoverRatio` target). Not a fix for "no architecture". Low priority. |
| 5 | Tabu search | **B** | Escapes cycles in a local search. | No. Our bottleneck is not search-trajectory cycling. |
| 6 | Genetic algorithm on an indirect encoding | **B** | Nothing. Improves the fitness you gave it. | The right *substrate*, but on its own it collapses diversity — one optimum, and our optimum is a plateau. Use it inside MAP-Elites, not standalone. |
| 7 | **FI-2Pop GA** (feasible + infeasible populations) | **B** | Nothing, but it *converts wasted rejections into search progress*. | **Directly relevant** — we reject 77–78% of 4-team candidates and learn nothing from them. §6. |
| 8 | **MAP-Elites / Quality-Diversity** | **B** for any one map; **A-like for the SET** | If a cell is occupied, a map with that behavioural signature exists and is retrievable. That is a hard guarantee about *coverage*, not about quality. | **The highest-value item in this dimension.** Fixes diversity and un-saturates the objective in one move. §5. |
| 9 | **Constrained MAP-Elites (CME)** = FI-2Pop × MAP-Elites | **B** + coverage | Same, plus feasibility handled as a separate population rather than as a score of 0. | What we should actually build. Khalifa et al.'s Talakat is the reference implementation. §5.5. |
| 10 | Novelty search (no objective) | **B**, quality-blind | Behavioural spread. Explicitly optimises *nothing* about quality. | Not as the primary driver. But: **at fitness saturation it is the only remaining signal**, and that is exactly where we are. §4.5. |
| 11 | Novelty search with local competition / surprise search | **B** | Spread + within-niche quality. | Same family as MAP-Elites, more moving parts, no clear advantage for a grid-friendly BC space like ours. Skip. |
| 12 | CMA-ES / CMA-ME emitters | **B** | Faster convergence in *continuous* genotype spaces. | Only if the scene-graph genotype is exposed as a real-valued vector. If it is, CMA-ME is a strict upgrade over uniform mutation. Phase 2. |
| 13 | Multi-objective (NSGA-II, Pareto fronts) | **B** | A non-dominated set instead of one point. | Correct diagnosis (scalarising is lossy), wrong prescription at 15 objectives — Pareto dominance degenerates. §9. |
| 14 | Surrogate / learned fitness model | **C** *for quality* | Nothing about the artefact. Changes *cost*, not the ceiling. | Important, but not as a speed-up. Important because **`staticScore` already is a surrogate and has never been validated against the ground truth it proxies.** §10. |
| 15 | Expressive range analysis | **C** — it is *measurement*, not generation | Nothing. It tells you what your generator can and cannot make. | Not optional. We currently cannot say "this generator makes 5 kinds of map", and every claim in this dimension is unfalsifiable without it. §7. |
| 16 | PCGRL (RL level designer) | **B** | Fast inference after expensive training; still needs the same fitness. | Not at our scale. §12. |
| 17 | PCGML (learn from a corpus) | **B** | Output resembling the training corpus. | We have ~7 hand-authored maps. That is not a corpus. §12. |
| 18 | Repair operators / constraint-preserving representation | **A**, when total | If the encoding cannot *express* a violation, none can be generated. | **This is the only route from (B) to (A) inside a search framework** — and it lives in the *constructive*/*partition* dimensions, not this one. Flagging the handoff explicitly. |

**Honest summary of the column:** search-based PCG contains exactly one (A), and it is not
really a search technique — it is "make the representation incapable of being wrong",
which is constructive PCG wearing a search hat. Everything else in this dimension is (B).
Anyone who tells you a fitness function guarantees a property is describing a rejection
filter and should say so.

---

## 4. Deliverable 1 — how to fix a saturating fitness function

### 4.1 Diagnosis: the rubric contradicts its own prose

`DefaultBands` documents `interiorFrac` like this:

> *"enclosed floor … arena 34.2%, pool median 11.8% — the scatter-vs-buildings
> discriminator"* — and above it: *"The arena is honest SCATTER by design, so its 34% is
> the **FLOOR to beat**, not the target."*

The band is `lo: 0.25, hi: 0.65`. A map at 0.26 and a map at 0.60 score **identically**.
The prose says *beat 0.342*; the formula says *don't bother*. The band table's own comments
already know something the scoring function structurally cannot express.

Generalise that and you have the whole diagnosis:

> **A band expresses "acceptable range". An acceptable range contains no information about
> which point inside it is better. Therefore no function of the band table can be a good
> ranker, and no reweighting, rescaling, or margin tweak will make one.** The preference
> information is not in the data structure.

Two further consequences, both of which we are living:

- **A rubric on which your reference artefact scores exactly 1.000 cannot express
  "better than the reference."** The arena scores 1.000 by construction (every bound was
  calibrated to contain it). The ceiling was placed at the control. Anything above the
  control is invisible.
- **Reaching 1.000 is therefore not "we made a perfect map." It is "we made a map that is
  at least as acceptable as the arena on 15 axes."** That is a real and useful statement —
  it is just a *feasibility* statement, not a *quality* statement.

### 4.2 The trap: "just tighten the bands"

The obvious response to 39/40 seeds at 1.000 is to narrow the bands. Do not do this as the
ranking fix. Three reasons:

1. **It makes "be the arena" the objective.** Every bound carries `control:` = the arena's
   value. Tightening toward the control encodes one hand-authored map's *accidents*
   (`chokeCount 0`, `standRingOpenMin 0.892`, `midCrossCount 5`) as law. That destroys
   diversity — the exact problem we are trying to solve.
2. **It has no fixed point.** Any generator that beats the tightened bands re-saturates.
   You are on a treadmill, and each turn of it further narrows the expressive range.
3. **It is extrapolation into unobserved territory.** `interiorFrac` has `hi: 0.65` but we
   have never *seen* a map above ~0.35 — the control is 0.342 and the pool median 0.118.
   The upper half of that band has never been validated by anything. Tightening toward it
   is [extremal Goodhart](https://arxiv.org/abs/1803.04585): optimising into a region where
   the proxy–goal relationship was never established.

Tightening bands is legitimate as **gate recalibration** — raising the feasibility bar
once a generator reliably clears the old one. It is never the ranking fix.

### 4.3 The structural fix: one metric, one role

Split the metric suite into three disjoint roles, and enforce that **a metric appears in
exactly one of them**:

```
Feasibility   F(m) ∈ {0, 1}     validator + hard bands + fairness bands.  A GATE.
Behaviour     B(m) ∈ R^d        the axes we want VARIETY along.  Drives an ARCHIVE.
Quality       Q(m) ∈ R          the (very few) things where more is genuinely better.
```

Today `interiorFrac` is doing all three jobs at once and doing all three badly: it is a
soft gate, it is the highest-weight quality term (`weight: 3.0`), and it is simultaneously
the thing we most want variety in. That single overload explains most of the saturation.

§5.2 applies this partition to all 15 bands. The result — worth previewing, because it is
the finding of this document — is **6 constraints, 8 behaviour axes, and about 1 quality
term.** We have been treating all 15 as quality.

### 4.4 Where ranking information can actually come from

Once you accept §4.1, there are exactly three sources of preference, and only three:

| Source | Cost | Trustworthiness | Status |
|---|---|---|---|
| **Simulation** (`MapPlay`: balanceEntropy, pace, fightTimeFrac, deadFloorFrac) | ~97 s/episode, ≥3 episodes | Ground truth, modulo agent policy | Type exists, plumbed via `tools/map_playtest.nim`, **never used as a ranker** |
| **Diversity** (distance to the rest of the archive / the shipped corpus) | free — we compute the metrics anyway | A preference we genuinely hold and can state ("seeds must not look alike") | Not implemented |
| **A human** (Maxwell looking at it) | minutes, does not scale | Highest fidelity | Has already fired twice, informally |

Note what is *not* on that list: any further transformation of the static geometry. The
static metrics are an *input* to preference, not a source of it.

### 4.5 The recommendation: at saturation, rank on diversity

This is the Lehman–Stanley result applied literally. [*Abandoning Objectives: Evolution
Through the Search for Novelty Alone*](https://direct.mit.edu/evco/article-abstract/19/2/189/1365/)
(Lehman & Stanley, *Evolutionary Computation* 19(2), 2011) shows that when an objective
function stops providing gradient toward the goal, searching for behavioural novelty
outperforms searching for the objective. Our objective has stopped providing gradient in
the strongest possible sense: it is *constant* on 39 of 40 candidates.

So:

> **Our fitness saturating at 1.000 is not a crisis. It is the signal to switch from
> quality search to diversity search.** The generator is now good enough that
> "is it acceptable?" is answered yes, and the only question left worth asking is
> "is it *different*?"

Concretely, replace the ranker with a lexicographic rule:

```
rank(candidate) = ( feasible?,                       # gate: 0 or 1
                    -distance_to_nearest_shipped,     # novelty: the actual ranker
                    quality )                         # tie-break, once validated
```

where `distance_to_nearest_shipped` is Euclidean distance in the normalised BC space of
§5.3, against the maps already shipped in this session/pool. This is implementable inside
`selectBestMap` without touching the generator — it needs one extra argument (the
reference set) and one distance function.

**Cost:** zero extra `evaluateMap` calls. We already compute the vector.

### 4.6 If you must keep a scalar: rank against a frozen reference population

Some callers want a single comparable number. The fix that always ranks and never
saturates is to make the score a **percentile within a frozen reference population**
rather than an absolute band satisfaction. This is the scalar analogue of
[MAP-Elites with Sliding Boundaries](https://arxiv.org/abs/1904.10656) (Fontaine, Lee,
Soros, De Mesentier Silva, Togelius & Hoover, GECCO '19), which slides archive cell
boundaries according to the *density* of what has actually been evolved, precisely so that
a region everyone reaches stops counting as distinguished.

Concrete shape:

1. Generate N = 2000 maps per (teams × size class) from the *current* generator; dump all
   45 metrics. Freeze as a versioned artefact, e.g.
   `tests/fixtures/map_reference_population_v1.csv`. Treat it exactly like a test fixture:
   it changes only in a commit that says it changed.
2. `percentileScore(m)` = weighted mean over metrics of the candidate's empirical
   percentile within that frozen population (two-sided for band-shaped metrics: distance
   from the population median in percentile terms, signed by the band's direction).
3. Because it is a rank statistic, it is **total by construction** — no plateau, ever.
4. Because the reference is frozen and versioned, it *is* comparable across generator
   versions: "the scene-graph generator's median map is at the 97th percentile of the
   v1 column-lattice population" is a sentence with content, and it does not cap.

**Trade-off, stated honestly:** this measures *unusualness relative to the old generator*,
not goodness. It is a good instrument for tracking generator change and a bad objective to
optimise hard (a maximally weird map wins). Use it for reporting; use §4.5 for selection.

### 4.7 Retire `median staticScore` as the headline number

`median staticScore` is now an instrument reading at the top of its range. Replace the
generator scorecard with four numbers that have headroom:

| Metric | Definition | Today (est.) | Ceiling |
|---|---|---|---|
| `feasible%` | fraction of first attempts passing the gate | 22–23% (4-team std) | 100% |
| `coverage` | occupied archive cells / reachable cells, 10×10 archive | **unknown, likely <10%** | 100% |
| `QD-score` | Σ quality over occupied cells | unknown | 100 (10×10) |
| `minSlack` | min over bands of (distance to nearest bound)/margin | reported by `bandReport` | — |

`coverage` is the one to lead with. It is the number that says "this generator makes N
kinds of map", it is currently unmeasurable because we have no archive, and it is the
number the scene-graph prototype's own report is complaining about in prose
("seeds look near-identical").

---

## 5. Deliverable 2 — diversity as a first-class objective: MAP-Elites for CTF maps

### 5.1 What MAP-Elites is, and why it is the right shape for our problem

[MAP-Elites](https://arxiv.org/abs/1504.04909) (Mouret & Clune, 2015) discretises a
low-dimensional *behaviour* space into cells, and keeps the single best-performing
solution found for each cell. It returns not one optimum but an **archive**: a diverse set
of high-performing solutions, one per behavioural niche.

Why this is the right shape for us, specifically:

- **It makes diversity structural rather than a term in a sum.** You cannot trade
  diversity away for quality, because they live in different data structures. A weighted
  "+ diversity bonus" term always gets traded away; an archive cell cannot be.
- **It cannot saturate the way our scalar does.** Filling every cell of a 10×10 archive
  requires producing maps at `interiorFrac` 0.05 *and* 0.55, which today's generator has
  never done. The objective has ~90 cells of headroom on day one.
- **It doubles as expressive range analysis.** [Gravina, Khalifa, Liapis, Togelius &
  Yannakakis, "Procedural Content Generation through Quality Diversity," IEEE CoG
  2019](https://arxiv.org/abs/1907.04053) list "online expressivity analysis" as one of
  four core reasons QD suits PCG: the archive *is* the expressive-range plot, computed
  during the run.
- **There is direct precedent in exactly our genre.** ["Procedural Generation of First
  Person Shooter Maps using MAP-Elites"](https://arxiv.org/html/2605.30570v1) illuminates
  FPS map space using **area × maxSymmetry** (pure topology) and **pace × averageEccentricity**
  (mixed), with fitness = *entropy of match balance averaged over five matches* between
  deliberately mismatched bots. Archive 10 bins per feature = 100 cells; 400 iterations ×
  10 emitters. They screened **69 candidate features** down to those pairs. That is the
  same problem we have with 45 metrics, solved the same way.

### 5.2 The three-way partition of our 15 bands

Applying §4.3 to `DefaultBands`. The test for each row is: *do we want every shipped map
to satisfy this (constraint), do we want variety along it (behaviour), or is more of it
genuinely and causally better (quality)?*

| Band | Role | Why |
|---|---|---|
| `routeCountMin` (bandHard) | **CONSTRAINT** | Already hard. One route is a corridor. |
| `standRingSpread` | **CONSTRAINT** | *Fairness.* We never want variety in whether the teams got equal objectives. A symmetric map must score 0. |
| `standCoverSpread` | **CONSTRAINT** | Fairness, same argument. |
| `chokeCoveredPenalty` | **CONSTRAINT** | "One camper owns every route" is never acceptable at any setting. |
| `exposedFrac` | **CONSTRAINT** (cap) | A cap with control 0.038 and pool median 0.22 — this is a floor-quality gate, not a dial. |
| `standRingOpenMin` | **CONSTRAINT** | Its own note says the upper bound is *structural* (the engine carves protected floor around every pedestal). A metric whose range the engine dictates cannot be a design dial. |
| `interiorFrac` | **BEHAVIOUR** | The scatter↔architecture axis. **The** axis. |
| `routeCapacityFrac` | **BEHAVIOUR** | Tight↔open. Explicitly scale-free by construction. |
| `longRunFrac` | **BEHAVIOUR** | Sightline character: brawler map ↔ gallery map. Both are legitimate maps. |
| `chokeCount` | **BEHAVIOUR** | "Zero is a field; too many is a map of doorways" — that is a *description of an axis*, in the band's own note. |
| `midCrossCount` | **BEHAVIOUR** | Lanes across midfield. |
| `midOpenFrac` | **BEHAVIOUR** | Its note says to read it *with* the count — i.e. it is one coordinate of a 2D character, which is what a BC pair is. |
| `detourMax` | **BEHAVIOUR** | Sprint ↔ winding. |
| `visDegreeCv` | **BEHAVIOUR** | Uniform board ↔ good-and-bad ground. |
| `collisionCoverRatio` | **QUALITY (candidate)** | "First contact should happen where there is cover" is a genuine design claim about *outcomes*. It is the only band that is. **It must pass the intervention test in §11.4 before it is allowed to be the ranker.** |

**6 constraints, 8 behaviour axes, 1 quality candidate.** That is the whole explanation of
the saturation: we have been scoring a feasibility check and a style descriptor as if they
were quality, and once both are satisfied there is nothing left to rank on. There never
was.

**Hard rule that falls out:** *anything with `kind: bandHard`, or any band whose purpose is
fairness, is a constraint and must never be a BC axis.* A BC axis is something you are
happy to see variety in. You are not happy to see variety in whether the red team's
pedestal is easier to defend than blue's.

### 5.3 The recommended archives

**Archive A — primary, 2D, human-legible, ERA-plottable.**

| Axis | Metric | Bins | Range | Arena | Pool |
|---|---|---|---|---|---|
| x | `interiorFrac` | 10 | 0.00 – 0.60 | 0.342 | median 0.118 |
| y | `routeCapacityFrac` | 10 | 0.05 – 0.65 | 0.316 | 0.4 – 0.6 |

100 cells. Both are already computed inside `evaluateMap` — **zero additional evaluation
cost.** Both are fractions, so they are scale-free and one archive serves every size class.

Why this pair, on the Right Variety criteria
([arXiv:2304.02366](https://arxiv.org/abs/2304.02366), which proposes exactly three tests:
*fitness independence*, *mutual correlation*, and *alternative-metric correlation*):

- **Structurally different quantities**, so low mutual correlation is plausible:
  `interiorFrac` is a *local* 8-direction 120 px enclosure probe; `routeCapacityFrac` is a
  *global* vertex-disjoint max-flow min-cut normalised by the board's short side. One is
  texture, one is topology.
- **The plane is the design question.** "How much stuff" × "how much room to move" is
  literally the scatter-vs-architecture plane the band notes call the discriminator.
- **The hole is immediately visible.** The arena sits at (0.342, 0.316); the pool sits in a
  blob around (0.118, 0.5). The generator's output and the control are in *different
  regions of the plane*, and one plot says so.

**Archive B — secondary: `detourMax` × `visDegreeCv`.** Route shape × exposure texture.
Arena (1.295, 0.524), pool (1.14, 0.28) — again the control is outside the blob.

**Archive C — if going to 3–4D:** add `midCrossCount` (integer, natural bins 2–12) and
`chokeCount` (0–6). ⚠️ Both are **counts**, so they scale with board size; either bin them
per size class or normalise before use. A regular grid costs 10^d cells, so beyond 3D use
[CVT-MAP-Elites](https://arxiv.org/abs/1610.05729) (Vassiliades, Chatzilygeroudis &
Mouret), which places *k* centroids from a centroidal Voronoi tessellation instead of a
grid and therefore lets you choose the archive size directly, independent of dimension.

**Do not guess — measure first.** We already have 150 held-out seeds with full metric
vectors. Computing the pairwise Spearman ρ matrix over all 45 metrics, plus the
fitness-independence score for each candidate pair, is a half-day of analysis with no new
machinery, and it either confirms the pair above or replaces it with a better one. This is
the cheapest high-value experiment in this document. Do it before writing any archive code.

### 5.4 The archive as a generator: the offline/online split

This is the structural move that makes everything else affordable, and it is available
today because `evaluateMap` is documented as a pure function.

```
OFFLINE  (overnight, per teams × size class)
  genotype  = the scene-graph parameter vector  (indirect encoding, §2b)
  loop:     select a random occupied cell -> mutate its elite -> construct -> gate ->
            evaluate -> place in the cell its BC vector lands in, if it beats the
            incumbent
  output:   archive of ELITE GENOTYPES (not maps) — a versioned data artefact

ONLINE   (map-request time)
  seed -> pick an occupied cell (uniform, or from a designer-chosen sub-region = a
          "map style" selector) -> take that cell's elite genotype -> apply a small
          seeded mutation -> construct -> validate -> ship
```

Properties of this design:

- **Latency goes DOWN, not up.** One construction + one validation, versus today's 35–55
  attempts to fill K=12. It is *faster* than what we ship now.
- **Character is archive-guaranteed.** Every shipped map came from a cell that was proven
  reachable and feasible offline. That is the (A)-like coverage guarantee from the
  technique table: not "this map is good", but "a map of this character exists and we can
  produce one".
- **Maps are still fresh.** The elite genotype is *mutated*, not replayed. Seeds do not
  repeat maps.
- **Fully deterministic and replay-safe.** seed → cell → genotype → mutation is a pure
  function chain, which is the same contract `selectBestMap` already requires.
- **It gives us a style dial for free.** "Give me a tight-architecture map" = restrict the
  cell sampler to a sub-region of the archive. That is the mixed-initiative capability
  [Interactive Constrained MAP-Elites](https://arxiv.org/abs/1906.05175) (Alvarez, Dahlskog,
  Font & Togelius, IEEE CoG 2019) was built to provide, and we would get it as a side
  effect.

**Risks, stated:**

- The archive becomes a **versioned asset with a lifecycle** — it must be regenerated when
  the generator or the metric definitions change, exactly like a test fixture. Stale
  archive = silently shipping the old generator.
- **League memorisation.** A fixed archive of ~100 cells is a bounded family of map
  characters; an opponent could in principle adapt to it. Mitigations: mutation radius,
  larger archive (CVT lets you pick 1000 cells as easily as 100), and periodic
  regeneration. This is a real consideration for a competitive league and should be
  decided deliberately rather than discovered.
- If a cell's elite is feasible but its *mutation neighbourhood* is mostly infeasible, the
  online step degrades into a rejection loop again. Fix: store per-cell the measured
  feasible-rate of mutations, and prefer cells with a healthy one. Cheap, and it is data
  the offline run produces for free.

### 5.5 Constrained MAP-Elites: the version we should actually build

Plain MAP-Elites discards infeasible candidates. At a 22–23% feasible rate that throws
away 77% of the compute. **Constrained MAP-Elites** ([Khalifa, Lee, Nealen & Togelius,
"Talakat: Bullet Hell Generation through Constrained Map-Elites," GECCO
'18](https://arxiv.org/abs/1806.04718)) fuses MAP-Elites with FI-2Pop: **each cell holds
two populations**, feasible and infeasible. Chromosomes migrate *across* cells when their
BC changes and *between* populations when their feasibility changes. Talakat used a 3D BC
map (entropy × risk × distribution, 11 bins each = 1331 cells), 50 chromosomes per cell
split across the two populations, and — the key part — the **infeasible** population is
scored by *how close to feasible it is*, not by quality.

That is exactly our situation with the roles renamed. §6 develops it.

---
