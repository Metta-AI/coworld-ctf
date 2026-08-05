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
