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

## 6. FI-2Pop and our 77% rejection rate

### 6.1 The technique

[Kimbrough, Koehler, Lu & Wood, "On a Feasible–Infeasible Two-Population (FI-2Pop) genetic
algorithm for constrained optimization: Distance tracing and no free lunch," *European
Journal of Operational Research* 190(2):310–327,
2008](https://www.sciencedirect.com/science/article/abs/pii/S0377221707005668) maintains
**two** populations:

- the **feasible** population is selected and bred on the *objective function*;
- the **infeasible** population is selected and bred on *how small its constraint violation
  is* — i.e. infeasible individuals compete on getting closer to feasibility;
- **the two never interbreed directly.** Cross-population influence happens only when an
  offspring migrates: a feasible parent's child that violates a constraint moves to the
  infeasible pool, and vice versa.

The reported advantages are that it beats penalty-function constraint handling, and that it
can be initialised with an **empty feasible population** and still find its way in — the
infeasible pool does the work of locating the feasible region.

### 6.2 Why it applies to us, precisely

We currently draw 35–55 candidates to obtain K=12 valid ones on a 4-team standard board,
and the 23–45 rejects are **discarded with no information extracted**. Every one of them
was a sample of the boundary of our feasible region, and we threw it away. FI-2Pop's whole
proposition is that those samples are the cheapest map of the constraint surface you will
ever get.

### 6.3 The one thing we are missing: a graded violation function

`selectBestMap` tests feasibility as `validateGeneratedMap(candidate).len == 0`, and
`MapMetrics.reason` records only the **first** validator failure. FI-2Pop needs *how badly*,
not *which*. So the prerequisite work is:

1. Have each validator return a **scalar residual** in a normalised unit — px of corridor
   shortfall, count of sealed pockets, permille of cover missing, etc. — rather than a
   string.
2. Define `violation(m) = Σ_i w_i · normalised_residual_i`, which is the fitness of the
   infeasible population.
3. Record **all** failures, not the first, so the residual is complete.

This is bounded work in `map_rules.nim`, and it is a prerequisite for FI-2Pop, for
Constrained MAP-Elites (§5.5), and for debugging the generator at all. It is worth doing
independent of any search algorithm.

### 6.4 ⚠️ Do the cheap thing first: look at the failure histogram

Before building an algorithm to cope with a 77% rejection rate, spend twenty minutes
dumping the histogram of *which validator* rejects, over ~2000 attempts per
(teams × size class).

If 90% of rejections are one validator, the feasibility problem is not a search problem at
all — it is one generator/validator interaction, and a targeted fix beats FI-2Pop by a mile
and costs a fraction as much. **Always look at the failure histogram before building an
algorithm to cope with failures.** We have never looked. There is also the unreconciled
47%-vs-22% pass-rate discrepancy from §1.3 to settle in the same run.

Estimated payoff *if* the rejections turn out to be diffuse (i.e. FI-2Pop is genuinely
warranted): raising 4-team standard from 22% to ~60% would cut the online cost of best-of-K
by ~2.7× and give an offline QD run ~2.7× more useful evaluations for the same wall clock.
That number is an estimate, not a measurement.

---

## 7. Deliverable 3a — expressive range analysis: the plan

### 7.1 What ERA is and why we need it

[Smith & Whitehead, "Analyzing the expressive range of a level generator," *Proceedings of
the 2010 Workshop on Procedural Content Generation in Games*
(PCG'10)](https://dl.acm.org/doi/10.1145/1814256.1814260) introduced the idea that the
right unit of analysis for a generator is not any individual output but **the space of
outputs**. Method: generate a large sample, annotate each with a couple of behavioural
metrics, and plot the sample as a 2D histogram/heatmap. Their Launchpad study used
*linearity* (x, 0.0–0.65) and *leniency* (y, −1.0–1.0), with hexbin shading by count. The
stated payoff is that this "can expose unexpected biases in the generation algorithm and
holes in the expressive range."

We have no such instrument. Every claim in this dimension — "seeds look near-identical",
"the generator makes scatter not architecture", "best-of-K improved things" — is currently
unfalsifiable, because none of them is a statement about an individual map and we only
measure individual maps.

### 7.2 Build order (cheapest and most decisive first)

**Step 1 — the metric-free check (build this first; ~half a day).** Following
[*Compressing and Comparing the Generative Spaces of Procedural Content
Generators*](https://arxiv.org/abs/2205.15133), skip metrics entirely for the first pass:
downsample each generated map's occupancy grid to e.g. 64×64, stack the sample into a
matrix, project to 2D with PCA (the paper tested PCA, SVD, MCA and t-SNE, and found MCA
best overall for categorical level data, with results "inconsistent across domains"), and
scatter-plot.

Why first: it answers the *live* complaint — "I replaced a uniform lattice of pebbles with
a uniform lattice of boxes; seeds look near-identical" — **directly, without depending on
having guessed the right metric**. If 40 scene-graph seeds land in a tight blob and the 7
hand-authored maps land far outside it, that is the whole argument in one image, and it
cannot be waved away as a metric artefact. It is also nearly free: 40 maps, no simulation,
no new metrics.

**Step 2 — pick the ERA axes by criterion, not by taste (~half a day).** We have 150
held-out seeds with full metric vectors. Compute, over all 45 metrics, the three tests from
[*The Right Variety: Improving Expressive Range Analysis with Metric Selection
Methods*](https://arxiv.org/abs/2304.02366):

- **fitness independence** — discretise the candidate 2D plot and check that fit content is
  spread across it, not piled in one corner;
- **mutual correlation** — Spearman's ρ between the pair; low is good, because a correlated
  pair makes most of the plot unreachable in principle;
- **alternative-metric correlation** — the chosen pair should *correlate with* the metrics
  you left out, so you are not leaving diversity unmeasured.

The paper's own recommendation is to rank candidate pairs by the average of the three, and
to prefer pairs that **combine a structural metric with an agent-evaluated one**. We only
have structural metrics today, which is itself a finding: our ERA will be
structure-only until `MapPlay` is wired in.

**Step 3 — the ERA harness (~1–2 days).** A `tools/map_range.nim` that generates N maps for
a given (generator, teams, size class, K) and emits one CSV row per map: seed, attempt,
config, valid, reason, and all 45 metrics. At 50 ms/map, N = 2000 costs **100 seconds**.
This is the cheapest instrument in the whole programme and everything else reads from it.

**Step 4 — the plot and the report.** Hexbin heatmap over the chosen pair, plus:

- **The controls overlaid as labelled points** — the arena and all 6 MW2 maps. This is
  non-negotiable. A generative-space plot without the hand-authored controls on it cannot
  tell you whether the generator is anywhere near the region you want.
- **Coverage** — occupied bins / bins inside the feasible region of the plot.
- **Concentration** — entropy (or Gini) of the bin-count histogram. "How much of the mass is
  in how few bins" is the numeric form of "every map looks alike."
- **Holes** — bins that are feasible-in-principle and empty. These are the work items.

**Step 5 — version diffs.** Two generators as two contours on one plot. The headline claim
becomes "generator B covers 3.1× the area of generator A at equal feasibility", which is a
falsifiable sentence about a space, not a median of a saturated scalar.

---

## 8. Cost analysis against our real budget

### 8.1 The numbers

| Quantity | Value | Source |
|---|---|---|
| Static evaluation, standard board | ~50 ms | brief |
| Static evaluation, giant board | ~2.4 s | brief |
| Simulated episode, 32 seats | ~97 s | brief |
| Online generation budget | ~1 s | current K schedule targets this |
| Current K | 12 / 8 / 6 / 4 / 2 / 1 by size class | `map_rules.MapSelectionK` |
| `MapGenMaxAttempts` | 100 | `arena.nim:1085` |

### 8.2 The search-power table — the single most important arithmetic here

| Regime | Wall clock | Static evals (standard) | Static evals (giant) | Sim episodes |
|---|---|---|---|---|
| **Online, per request** | 1 s | **20** | 0.4 | 0.01 |
| Offline batch | 1 h | 72,000 | 1,500 | 37 |
| **Offline overnight** | 8 h | **576,000** | 12,000 | 297 |
| Offline, one machine-week | 168 h | 12.1 M | 252,000 | 6,200 |

**Offline search power is ~29,000× the online budget, for zero change in request latency.**

That number decides the whole dimension. Compare against what the literature actually
spends: the FPS MAP-Elites work used 400 iterations × 10 emitters ≈ **4,000 evaluations**
(with 5 simulated matches each); Talakat ran for 24 hours; typical MAP-Elites papers sit at
10⁵–10⁶ evaluations. **576,000 static evaluations overnight on one machine is a fully
respectable MAP-Elites budget.** We can run a real QD algorithm tonight with the evaluator
we already have.

By contrast, no amount of raising K helps online. K=12 → K=24 doubles latency to buy the
96th percentile instead of the 92nd of a distribution whose *mode* is the problem (§13).

### 8.3 Giant boards are the awkward case

12,000 evaluations overnight across a 100-cell archive is 120 evaluations per cell — thin
but usable. Three options, in order of preference:

1. **Transfer from the standard archive.** The genotype is a scene-graph parameter vector;
   seed the giant archive with the standard archive's elites re-expanded at giant scale.
   Both recommended BC axes are scale-free fractions precisely so this works.
2. **Split the evaluator.** MAP-Elites needs the *BC vector* on every candidate and the full
   45-metric report only on archive insertion. If `interiorFrac` + `routeCapacityFrac`
   alone can be computed in a fraction of the 2.4 s, that is a direct multiplier on search.
   **Action: profile `evaluateMap` and find out** — the caps in the source
   (`VisibilitySampleCap = 400`, `ChokeCandidateCap = 1500`, the max-flow, the isovist
   sweep) suggest the cost is concentrated in a few stages, several of which neither BC
   axis needs.
3. Run giants for a week instead of a night. They are the rarest size class; there is no
   reason their archive must be rebuilt on the same cadence.

### 8.4 Simulation is affordable only where we place it deliberately

297 episodes overnight, at ≥3 episodes per map for a stable `MapPlay`, is **~99 maps per
machine-night**. That is nowhere near enough to be a QD fitness (the FPS paper's
4,000 maps × 5 matches would be ~539 machine-hours for us). It is comfortably enough for
the two jobs simulation should actually do:

- **Calibrate and validate the static surrogate** (§10.2) — 40 maps × 3 episodes = 3.2 h.
- **Final head-to-head on a handful of finalists** — e.g. the 10 archive corners, 3 episodes
  each = 0.8 h.

That is exactly the DSAGE division of labour: cheap model in the inner loop, ground truth
at the archive boundary.

---

## 9. Multi-objective: is scalarising ~45 metrics into one number a mistake?

**Yes, but not for the reason it looks like, and NSGA-II is not the fix.**

### 9.1 The real defect of a weighted sum

A linear scalarisation `Σ wᵢ fᵢ` can only ever find solutions on the **convex hull** of the
Pareto front. Solutions in a non-convex region of the front are optimal-in-principle and
**unreachable at every possible weight vector** — this is a theorem, not a tuning problem
(Das & Dennis, "A closer look at drawbacks of minimizing weighted sums of objectives for
Pareto set generation in multicriteria optimization problems," *Structural Optimization*
14:63–69, 1997). So there exist map designs that are genuinely non-dominated and that
`staticScore` can never prefer.

### 9.2 The defect we can actually measure today

Our weights are hand-set in the range 1.0–3.0 with no sensitivity analysis. **Cheap
experiment, one afternoon, no new machinery:** on the 150-seed held-out pool, perturb the
weight vector (Dirichlet noise around the current values) a few thousand times and measure
how often the argmax-of-K changes.

- If the winner changes often, the weights are load-bearing *and* unjustified, and that is
  a bug of the same class as the saturation.
- If the winner never changes, the weights do not matter and should be deleted.

Either answer is worth having, and nobody knows which it is.

### 9.3 Why NSGA-II is nevertheless the wrong prescription at 15 objectives

Pareto dominance degenerates in many-objective settings: as the objective count rises past
roughly 4, the fraction of mutually non-dominated candidates approaches 1, non-dominated
sorting stops discriminating, and the algorithm's selection pressure collapses onto its
secondary criterion — crowding distance, i.e. **diversity**. (This is the motivating
observation for NSGA-III; see Deb & Jain, *IEEE Trans. Evolutionary Computation* 18(4),
2014.)

Which produces a mildly funny conclusion:

> Running NSGA-II on our 15 banded objectives would give us diversity-driven selection with
> extra steps and an uninterpretable population. MAP-Elites gives us diversity-driven
> selection *on purpose*, with an archive you can look at. If the many-objective answer is
> "you get diversity selection anyway", take the version that was designed for it.

### 9.4 Where multi-objective *is* right for us

After the §5.2 partition, the objective count drops to ~1, and the question mostly
evaporates. It returns in exactly one place: **if the intervention test (§11.4) promotes 2–3
metrics to genuine quality and they conflict** — the classic pair being "balanced" versus
"decisive/fast-paced" — then a 2–3 objective Pareto front is precisely the right structure,
and NSGA-II is entirely well-behaved at that count. The QD literature also has a native
answer here, multi-objective quality-diversity, which keeps a Pareto front *per archive
cell* (see e.g. [*Multi-Objective Quality-Diversity in Unstructured and Unbounded
Spaces*](https://arxiv.org/abs/2504.03715) for the current state of that family).

**Sequencing:** partition first (§5.2), intervention-test the survivors (§11.4), and only
then ask whether the 2–3 survivors need a Pareto front. Do not start at NSGA-II.

---

## 10. Surrogate models — and the fact that `staticScore` already is one

### 10.1 The reframe

The literature on surrogate-assisted QD — canonically [Bhatt, Tjanaka, Fontaine &
Nikolaidis, "Deep Surrogate Assisted Generation of Environments," *NeurIPS*
2022](https://arxiv.org/abs/2206.04199) — is usually read as "train a network so you can
skip the expensive simulation." DSAGE maintains a **ground-truth archive** (populated by
real evaluations) *and* a deep surrogate that predicts agent behaviour, exploiting the
surrogate in the inner loop and correcting with ground truth at insertion.

Read our stack against that structure and the finding writes itself:

> **`staticScore` already *is* our surrogate model for simulated play quality. It is
> hand-written rather than learned, and — unlike DSAGE's — it has never been trained,
> calibrated, or validated against the ground truth it proxies.**

We have a `MapPlay` type in `map_metrics.nim` with `balanceEntropy`, `pace`,
`fightTimeFrac`, `deadFloorFrac`, `biggestDeadPx`, populated by `tools/map_playtest.nim`.
Nobody has ever correlated it with `staticScore`. Until that is done, **every rank
best-of-K has ever produced is unfalsified**, and so is every claim in this document about
what search should optimise.

### 10.2 The 3-hour experiment that decides the dimension

1. Take ~40 maps spanning the full observed `staticScore` range — the 20-seed curated pool
   (0.717 / 0.870 / 0.932), the arena (1.000), the 6 MW2 maps, and a spread of generated
   seeds.
2. Run ≥3 episodes each: 40 × 3 × 97 s = **3.23 hours**, single machine, trivially
   parallel across the fleet.
3. Compute Spearman ρ between (a) `staticScore` and (b) **each band's individual sub-score**
   against each `MapPlay` outcome.

Reading the result:

| Outcome | Meaning | What to do |
|---|---|---|
| aggregate ρ ≈ 0 | `staticScore` is a *style filter*, not a fitness | Stop calling it fitness. Re-aim the whole search programme at `MapPlay`, or accept that we are optimising taste and say so out loud. |
| per-band ρ mixed | **The most likely outcome, and the most valuable** | You have just discovered which of the 15 bands are real. Those become the quality terms; the rest become constraints or BC axes. |
| some band ρ < 0 | That band is actively harmful | Best-of-K has been *selecting against* play quality on that axis, silently, since it shipped. |

**Do this before the old generator is retired.** The experiment needs *spread* in
`staticScore` to compute a correlation at all, and the old column-lattice generator's
0.717–0.932 range is the only spread we have. The scene-graph generator, by scoring 1.000
on 39/40, **destroys the measurement instrument**. This is time-sensitive in a way nothing
else in this document is.

### 10.3 Should we train a learned surrogate?

**Not yet.** A learned model predicting `MapPlay` from geometry needs ~1,000+ (map, outcome)
pairs = 1,000 × 3 × 97 s ≈ **81 machine-hours** just for the training set, and it would be
learning a proxy for a proxy. The sequencing is:

1. Run §10.2. If the static metrics already predict play outcomes well, a learned surrogate
   buys nothing — use the metrics.
2. If they predict *poorly* but play outcomes clearly differ between maps, **then** a learned
   surrogate over raw geometry is the natural next step and DSAGE is the blueprint.
3. If play outcomes barely differ between maps at all, that is the most important finding
   available and it retires several research dimensions at once.

Note also the classification: a surrogate is **(C)** with respect to map quality. It changes
what search costs, never what search can reach. It is a budget instrument.

---
