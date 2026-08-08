# The re-weight failed. No weighting of these bands ranks play.

Task 013a9c98, epic 3757029c, lane D. Analysis only — this plays nothing and
generates nothing new. Every number comes from evidence already paid for:
the 361-candidate / 118-valid static sweep and the 210 stored episodes under
`docs/evidence/`, both taken at base `4a013df`.

Re-derive any number here with:

    python3 tools/band_reweight.py {reliability,census,corr,compare,crossval}
    nim c -d:release -o:/tmp/bandcmp tools/band_compare.nim && /tmp/bandcmp
    nim c -d:release -o:/tmp/specks  tools/exposed_vs_specks.nim && /tmp/specks

## The headline

I was asked to re-weight `staticScore`'s bands against the stored episodes. I
could not, and the failure is the result.

**The best non-negative re-weighting of the 15 measured bands ranks the 40
generated maps against play at rho = +0.109, 95% CI [-0.25, +0.43], p = 0.503,
n = 40**, held out over 5-fold cross-validation x 200 repeats. That is
indistinguishable from zero. The in-sample number for the same fit is +0.467,
which is the number this doc exists to not report.

It is not that the weights are wrong. It is that the weights have nothing to
work with:

- **7 of 15 bands are fully saturated** — one distinct sub-score level across
  all 118 valid maps, 0/118 breached. They carry 10.0 of 23.0 weight (43.5%)
  and cannot change the ranking of anything.
- **The three strongest signals in the entire set are all saturated.** Against
  dead floor: `midOpenFrac` **-0.721**, `longRunFrac` **-0.662**, `visDegreeCv`
  **+0.433** — all p < 0.01, all one level, all 0/118 breached. The rubric
  measures them, weights them, and cannot act on any of them.
- **The top-weighted band points the wrong way.** `interiorFrac` carries the
  largest weight (3.0) and correlates **+0.740 (p < 0.001) with dead floor**
  and **-0.419 (p = 0.007) with steals**. More enclosure, more dead floor,
  fewer steals — and the rubric pays for it.
- **One band inverts a real signal.** `standRingOpenMin`'s metric correlates
  +0.397 (p = 0.011) with steals; its *sub-score* correlates -0.395. The band
  takes a signal that exists and scores it backwards.

The only fit that reaches significance (rho = +0.348, 95% CI [+0.04, +0.61],
p = 0.028) has to **invert 5 of 8 bands** — `interiorFrac`, `routeCountMin`,
`chokeCount`, `standRingOpenMin`, `midCrossCount`. That is not a re-weighting.
It is the rubric's design intent refuted, and it is reported as a negative
control, not offered as a stick.

## What the data does NOT establish

Stated first, because everything below is weaker than it looks.

1. **It does not establish that any band set here ranks play.** Not
   `DefaultBands` (rho = -0.293, CI [-0.53, +0.00], p = 0.067 — pointing the
   wrong way), not the fitted re-weight (+0.109, p = 0.503), not
   `ControlSeparationBands` (-0.230, CI [-0.51, +0.10], p = 0.153). All three
   CIs contain zero. **`ControlSeparationBands` is not a validated ranker and
   is not proposed as one.**
2. **It does not establish that `interiorFrac` is bad for play.** n = 40 maps
   from one generator at one base. The correlation is strong and consistent,
   but this is observational — nothing here manipulated enclosure and measured
   the result.
3. **It does not cover 31.3% of the weight now shipping.** `DefaultBands` has
   grown from 15 bands to 21 since the evidence base. The six added —
   `sightlineMaxPx`, `diagLongRunPxFrac`, `routeCountDesign`, `chokeExcessPx`,
   `standCoverMin`, `standCoverGapMaxPx` — carry 10.5 of 33.5 weight and have
   **never been measured against play or against this population.** Every
   correlation in this doc is computed on the 15 that were.
4. **The objective is barely measurable at this n.** Split-half reliability for
   steals/1k ticks is r = 0.385, Spearman-Brown 0.556 — so an observed |rho|
   against steals is capped near sqrt(0.556) = 0.75, and small true effects are
   invisible. The 0.92-0.98 reliability figures quoted around this epic belong
   to *dead floor* (0.912) and *close contact* (0.817), not to the objective.
5. **Kill balance is unusable.** Spearman-Brown 0.115 (full) / 0.205
   (windowed). It is noise. No fairness claim should be built on it.
6. **The 1238-tick matched window discards 96.9% of the objective** — 6 steals
   inside the window against 195 across full episodes. Every objective number
   in this doc is therefore computed on FULL episodes. The windowed file is
   correct for dead floor and close contact and wrong for steals.

## The partition: constraint / style axis / quality

`docs/research/mapgen-search-based.md` argues the bands are really constraints
plus style axes plus one quality term, and that scoring style AS quality is
what makes the rubric saturate near 1.000. The evidence supports that, and the
partition below is cut by measurement, not by taste. The rule:

- **CONSTRAINT** — 0/118 breached *and* a violation would be catastrophic or is
  structurally impossible. Belongs in the validator as pass/fail.
- **STYLE AXIS** — discriminates, but its direction against play is unsupported
  or actively wrong. Belongs in a behaviour space where being *different* is
  the point. Being high is meaningless.
- **QUALITY** — discriminates *and* separates the control from the population
  in a direction the evidence does not contradict. Only these belong in a score.

All correlations are rho of the raw METRIC over n = 40 generated maps, full
episodes. Where the band's SUB-SCORE points opposite to its own metric that is
called out, because it means the band is scoring a real signal backwards.

| band | w | levels | breached | rho vs dead floor | rho vs steals | verdict |
|---|---|---|---|---|---|---|
| `standRingSpread` | 2.0 | 1 | 0/118 | +0.155 (ns) | -0.056 (ns) | **CONSTRAINT** — tautological |
| `standCoverSpread` | 2.0 | 1 | 0/118 | -0.100 (ns) | +0.087 (ns) | **CONSTRAINT** — tautological |
| `routeCountMin` | 1.5 | 2 | 17/118 | +0.222 (ns) | -0.122 (ns) | **CONSTRAINT** — a map under 2 routes is broken, not low-quality |
| `chokeCoveredPenalty` | 1.5 | 2 | 39/118 | -0.206 (ns) | +0.049 (ns) | **CONSTRAINT** — already binary |
| `interiorFrac` | 3.0 | 63 | 62/118 | **+0.740** (p<0.001) | **-0.419** (p=0.007) | **STYLE** — top weight, points the wrong way |
| `standRingOpenMin` | 1.5 | 17 | 102/118 | **-0.448** (p=0.004), sub **+0.447** | +0.397 (p=0.011), sub **-0.395** | **STYLE** — band inverts its own signal, both axes |
| `chokeCount` | 1.0 | 5 | 35/118 | -0.374 (p=0.018), sub +0.200 | +0.252 (ns) | **STYLE** — also inverted |
| `detourMax` | 1.0 | 21 | 46/118 | -0.250 (ns), sub -0.482 | +0.160 (ns) | **STYLE** |
| `midCrossCount` | 1.5 | 2 | 5/118 | +0.306 (p=0.054) | -0.239 (ns) | **STYLE** |
| `midOpenFrac` | 1.0 | 1 | 0/118 | **-0.721** (p<0.001) | **+0.396** (p=0.012) | **STYLE, saturated** — the STRONGEST signal in the set, zero influence |
| `longRunFrac` | 1.5 | 1 | 0/118 | **-0.662** (p<0.001) | +0.293 (ns) | **STYLE, saturated** — 2nd strongest, zero influence |
| `visDegreeCv` | 1.0 | 1 | 0/118 | **+0.433** (p=0.005) | -0.130 (ns) | **STYLE, saturated** — 3rd, zero influence |
| `collisionCoverRatio` | 1.5 | 1 | 0/118 | +0.281 (p=0.079) | -0.259 (ns) | **STYLE, saturated** |
| `exposedFrac` | 1.0 | 1 | 0/118 | -0.173 (ns) | +0.041 (ns) | **QUALITY** — saturated at its shipped bound, re-cut below |
| `routeCapacityFrac` | 2.0 | 3 | 47/118 | +0.222 (ns) | -0.122 (ns) | **QUALITY** — weakest of the two, flagged below |

Six constraints, seven style axes, two quality candidates. That is close to the
research doc's ~6 / ~8 / ~1 prediction, arrived at independently.

### The two tautological fairness bands are now an assertion

`standRingSpread` runs 0.000..0.0056 against a <= 0.10 bound; `standCoverSpread`
runs 0.000..0.0007 against <= 0.04. The worst map in 118 spends **5.6%** and
**1.75%** of its allowance. They cannot be breached because the generator emits
only symmetric boards (`symMirror` + `symRot180`, `layoutSides`, 118/118), so
the gap is zero *by construction*.

Scoring a constructive guarantee costs something measurable: the two carry
**4.0 of 23.0 weight (17.4%)** and, being constant, act as a constant term in a
weighted mean — diluting every band that *can* rank by 17.4% while ranking
nothing.

They are now `fairnessViolations()` in `src/ctf/map_metrics.nim`, bounds lifted
verbatim so promoting it rejects exactly the maps the bands were written to
reject and no others. It is **not wired into `arena.validateGeneratedMap`** —
another lane holds that file, and promotion is one line at the end of that proc:

    for v in gameMap.evaluateMap().fairnessViolations(): return v

"Never fires across 118 maps" is also the signature of a *dead* detector, and
the two readings are indistinguishable without a map built to violate it. So
`tests/test_band_reweight.nim` gives it a **positive control**: a `MapMetrics`
constructed unfair, asserted rejected, both violations reported together.

### The saturated bands: two given discrimination, five left as style

`exposedFrac` was capped at 0.20 with a population max of 0.1886 — a bound no
member of the population can reach. Re-cut **at the control's own measured
value**, 0.0385 (arena 0.038442, one rounding step of slack so the control is
not left on the boundary). Arena 0.0384; the 40 played generated maps run
0.0809..0.1731 — the control sits **2.1x below the generated minimum, 0/40**.

`routeCapacityFrac` floor re-cut from 0.12 to 0.3190. Arena 0.3200; generated
0.0400..0.2000, control **1.6x above the generated maximum, 0/40**.

Both bounds are set at the control's measured value on the side the control
sits — this file's own `Band.control` doctrine ("a bound can never drift away
from the thing that justified it") applied literally. **Zero parameters are
fitted to play.** The arena scores 1.000 by construction, so the stick cannot
flag the control by accident.

The other five saturated bands are *not* re-cut. Re-cutting them at the control
would be the same move applied without the control separation that justifies it
— for `longRunFrac` the arena measures 0.1104, the **highest** of the maps
around it, so a control-cut bound would score the population *better* than the
control on the band whose signal is strongest. They go to the behaviour space.

## The rank comparison, control in the same batch

### The decisive map

The brief names this map `gen:1023` with 0 steals over 3 episodes against the
arena's 5. The stored evidence disagrees on all three identifiers, so the real
one is used here: the map that ties the control at exactly 1.0000 with **zero
steals across five full episodes** is **`s1011a0`** (seed 1011, attempt 0). The
arena recorded **8 steals across 5 episodes** (1.60/ep), not 5. Seed 1023's map
is `s1023a4`, which scores 0.9483 and recorded 1 steal. The phenomenon is
exactly as described; the label and counts were not.

| stick | arena | `s1011a0` | separated? |
|---|---|---|---|
| `DefaultBands` | 1.0000 | **1.0000** | **NO — tied** |
| fitted re-weight | 1.0000 | **1.0000** | **NO — tied** |
| `ControlSeparationBands` | 1.0000 | 0.5704 | yes, gap 0.43 |

**The fitted re-weight still scores it 1.000. By the brief's own test, the
re-weight failed, and I am saying so.**

`ControlSeparationBands` does separate it — but it does **not demote it**:
`s1011a0` moves from rank 3 to **rank 2 of 41**. A map on which the objective
never once happened is still the second-best generated map under the new stick.
Separation is not ranking, and this is why the set is not offered as a ranker.

Why the tie existed at all, on the decisive pair:

| metric | arena | `s1011a0` | ratio | `DefaultBands` sub |
|---|---|---|---|---|
| `exposedFrac` | 0.0384 | 0.0879 | 2.3x | **1.0000 both** |
| `routeCapacityFrac` | 0.3200 | 0.1600 | 2.0x | **1.0000 both** |

Two metrics differ by more than 2x and the rubric scores both a perfect 1.0.
The bounds are wider than the population, so the difference cannot reach the
score. This is pinned in `tests/test_band_reweight.nim` rather than left in a
doc that cannot fail.

### The stored population, 41 played maps

`DefaultBands` range 0.7979..1.0000, **5/118 at exactly 1.000, 13 tied**.
`ControlSeparationBands` range 0.1100..1.0000, **1/118 at 1.000, 0 tied**.
rho between the two sticks over 118 maps = **+0.515** — different rulers.

Top of the table, both sticks, control in the same batch:

| label | Default | rank | CtlSep | rank | dead floor | steals/1k |
|---|---|---|---|---|---|---|
| **arena** | **1.0000** | **1** | **1.0000** | **1** | **0.326** | **0.784** |
| `s1036a0` | 1.0000 | 2 | 0.5269 | 4 | 0.444 | 0.290 |
| `s1011a0` | 1.0000 | 3 | 0.5704 | 2 | 0.612 | **0.000** |
| `s1026a1` | 0.9861 | 4 | 0.3370 | 22 | 0.485 | 0.087 |
| `s1014a4` | 0.9822 | 5 | 0.2532 | 29 | 0.543 | 0.172 |

The control beats all 40 generated maps on **both** play axes — 0/40 better on
steals, 0/40 better on dead floor — while `DefaultBands` cannot distinguish it
from two of them.

### Today's shipping pool — where the new set fails too

The generator has moved since `4a013df` (six archetypes, the 4-team fix, a
re-curated pool), so a seed does not reproduce the same map. `tools/band_compare.nim`
scores the 20 curated pool maps at HEAD, arena in the same batch:

| | `DefaultBands` | `ControlSeparationBands` |
|---|---|---|
| maps at exactly 1.000 | **1/21 (4.8%)** | **3/21 (14.3%)** |
| arena | 1.0000, beaten 0/20, **tied 0/20** | 1.0000, beaten 0/20, **tied 2/20** |
| range | 0.9394..1.0000 | 0.4443..1.0000 |
| fairness violations | — | 0/21, as the evidence predicted |

**This cuts against my own band set and it is the most important result here.**
On today's pool `DefaultBands` ties nothing — the 1.000-tie pathology lived in
the `4a013df` population and the re-curated pool no longer shows it. Meanwhile
`ControlSeparationBands` introduces **two new ties** (`pool:1015`, `pool:1020`),
because a bound cut *at* the control gives discrimination **below** the control
and none above it. On a population that straddles the control, the ceiling
returns.

That is a structural flaw in the control-cut rule, not a tuning error. It is
why `ControlSeparationBands` ships as an additional named set for measurement
and **not** as a replacement.

## The cover measurement, and a correction

The epic owner's `docs/plans/2026-08-06-what-the-cover-is-made-of.md`
(`maxwell/mapgen-rebuild` @ `cd495cc`) profiles what generated cover is made of.
Both bands I kept read on enclosure, so this is the distribution they operate
over, and it prompted a specific hypothesis worth testing.

**The mechanism is real.** `exposedFrac` counts, per open pixel, how many of 8
directions are blocked within `EnclosureReachPx = 120`. A 4 px speck 100 px
away blocks its direction exactly as hard as a 60 px one-body shape. The cover
doc names 120 px as precisely the reach below which "a shape cannot enclose",
and reports 74.5% (2-team) / 88.4% (4-team) of generated shapes as sub-body.
So the band *should* be purchasable with grit.

**I tested it and it is not.** `tools/exposed_vs_specks.nim` scores today's 20
pool maps on `exposedFrac` and sub-body content in one batch:

    rho(exposedFrac, speck COUNT)     = +0.038   n = 20
    rho(exposedFrac, speck FOOTPRINT) = +0.044   n = 20

Both ~0, and the sign is the wrong way for the hypothesis anyway. `pool:1003`
carries 300 shapes at 90.0% sub-body and scores 0.0553; `pool:1002` carries 27
shapes at 11.1% sub-body and scores 0.1432 — over 2x worse with a tenth the
grit. **I built this probe expecting to disqualify my own band and it did not.**
`exposedFrac` is measuring arrangement, not shape count.

### A correction to that doc's headline

`pebble_probe.nim` accumulates `agg.shapes += r.shapes` across seeds and
**never divides it**, while `agg.coverPm` and `agg.interior` on the same
printed row *are* divided (`div generated`, `/ generated.float`). So the row

    2 TEAMS   29/30 seeds  2474 shapes  cover 154pm  interiorFrac 0.292

mixes one **sum** with two **means**. 2474 is the total over 29 seeds — **85.3
shapes per map**, not 2474. The doc's "35 against 2474 is a real 71x" compares
one arena against 29 maps added together. Per map it is **35 vs 85.3 = 2.4x**;
at 4 teams **35 vs 114.7 = 3.3x**, not 98x.

Independently corroborated here: today's 20 pool maps average **67.6 shapes**
(median 51) against the arena's 35 — **1.9x**, same order.

**The direction of that finding survives and the bucket percentages are
untouched** — those are ratios of sums, which are valid pooled means, so
"74.5% of shapes are sub-body" stands. Only the raw count comparison and the
71x/98x magnitude are wrong.

## What this points at

The brief anticipated this outcome and it is the one that occurred: the problem
is not the weights, it is the measurements. Concretely —

- **The bands cannot see the objective.** The rubric's three strongest
  correlates of dead floor (`midOpenFrac` -0.721, `longRunFrac` -0.662,
  `visDegreeCv` +0.433, all p < 0.01) are all saturated, while its
  highest-weighted band (`interiorFrac`, 3.0) is the strongest correlate *in
  the wrong direction*. No coefficient fixes a band that cannot vary — the
  fix is to re-cut those three bounds against the population, which is a
  measurement change, not a weight change.
- **Three bands score their own signal backwards.** `standRingOpenMin`
  (metric -0.448 vs dead floor, sub +0.447), `chokeCount` (-0.374 / +0.200)
  and `interiorFrac` all have sub-scores anti-correlated with the metric's own
  relationship to play. Inverting a bound is free and does not need new
  episodes; it does need someone to decide the direction is intended.
- **Style is being scored as quality.** 7 of 15 bands discriminate on axes with
  no supported direction against play. In a behaviour space they would be
  useful as diversity axes. In a weighted mean they are noise with weight.
- **`interiorFrac` deserves a manipulation, not a correlation.** It is the
  single highest-leverage disagreement between the rubric and the evidence
  (+0.740 with dead floor, p < 0.001, n = 40, while carrying the top weight).
  An A/B that *moves* enclosure and measures dead floor would settle a question
  n = 40 observational maps cannot.
- **Six shipping bands have never been measured at all** (31.3% of weight).

## What shipped

`src/ctf/map_metrics.nim`, **purely additive — `DefaultBands` is byte-identical**
(119 insertions, 0 deletions; block SHA `a8acba1f` on both sides), so the Lane A
agents measuring against it keep their ruler.

- `fairnessViolations()` + `FairnessRingSpreadMax` / `FairnessCoverSpreadMax` —
  the two tautological bands as pass/fail. Not wired in; one line when the
  owner wants it.
- `ControlSeparationBands` — the 2-band set, **for measurement, not as a
  replacement**, for the reasons above.
- `tools/band_reweight.py` (offline derivation), `tools/band_compare.nim`
  (today's pool), `tools/exposed_vs_specks.nim` (the refuted hypothesis).
- `tests/test_band_reweight.nim`, 11 tests, wired into `tests/shard_4.nim`.

Verification: the Nim `subScore` and the Python re-implementation agree
**1770/1770 exact (100.00%)** across 15 bands x 118 maps, so the offline
analysis measures the rubric that actually ships. The `s1011a0` separation
(0.5704) is reproduced by the shipping Nim `staticScore` to within 1e-3 and
pinned as a test.
