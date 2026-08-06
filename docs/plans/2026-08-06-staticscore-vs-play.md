# Does `staticScore` predict how a map plays?

**Base commit** `4a013df` (`maxwell/mapgen-rebuild`). Branch
`maxwell/mapgen-score-validation`. Lane C of epic `3757029c`, task `945a5b9e`.

`staticScore` ranks every candidate the generator draws, it is the ranker
`arena.generateCtfMap` selects best-of-K on, and the epic's definition of done
is written in its units (`interiorFrac >= 0.30`, `staticScore no worse than
0.939`). It had never been compared against a played episode. This is that
comparison.

Read the two halves separately. The **static half** needs no episodes, covers
117 maps, and is not sensitive to any of the caveats in the dynamic half. The
**play half** is a 21-map correlation and its interval is wide; what it can and
cannot rule out is stated rather than glossed.

---

## 1. Getting the measuring instrument back

A correlation needs variance on both axes and the shipped generator no longer
supplies any: it draws K candidates and ships the winner, so the shipped
population piles up near the top (2-team median 0.972, 50-map sheet mean
0.953). The task framed this as a closing window. It is not closed, because the
spread was never a property of the generator — only of which candidates you
look at.

`tools/score_spread.nim` sweeps the **attempt index** instead of the seed.
`generateMapAttempt` routes `attempt` through `map_seed`'s `stream` scenes and
NOT its `seedStream` ones, so the board **shell** — size class, symmetry, team
layout, endzone archetype — is identical across every attempt of one seed while
terrain, cover and pickups redraw. Attempts of one seed are the same board
built differently.

That is a *better*-controlled axis than the old generator's cross-seed spread,
because board scale, spawn geometry and objective placement are held fixed and
only the architecture the score claims to measure moves.

40 seeds x 9 attempts at `standard` size gives **117 valid maps spanning
staticScore 0.798 to 1.000**. Standard size is also the arena's own 1235x659,
so the control sits on the same board scale as every candidate and no scale
confound is available.

> Locking `size=small` instead gates 35 of 36 attempts on the cover budget
> ("too clogged", 175-257 permille against the small class's allowance). That
> is its own finding and is filed separately; it is not this task.

---

## 2. The static half: 43% of the score's weight cannot rank anything

Over the 117 valid maps, **7 of the 15 bands never leave `sub = 1.0`**. They
carry **10.0 of the 23.0 total weight — 43%** — and cannot change the relative
order of any two maps the generator produces.

| band | weight | metric range over 117 maps | band bound | verdict |
|---|---|---|---|---|
| `standRingSpread` | 2.0 | 0.000 – 0.0056 | <= 0.10 | **tautological** |
| `standCoverSpread` | 2.0 | 0.000 – 0.0007 | <= 0.04 | **tautological** |
| `collisionCoverRatio` | 1.5 | 0.978 – 1.814 | 0.70 – 2.40 | bound never reached |
| `longRunFrac` | 1.5 | 0.018 – 0.101 | <= 0.15 | bound never reached |
| `exposedFrac` | 1.0 | 0.059 – 0.189 | <= 0.20 | bound never reached |
| `midOpenFrac` | 1.0 | 0.260 – 0.634 | 0.10 – 0.70 | bound never reached |
| `visDegreeCv` | 1.0 | 0.302 – 0.473 | 0.30 – 1.20 | bound never reached |

The two marked **tautological** are the important ones. `standRingSpread` and
`standCoverSpread` measure *team-vs-team fairness* — the gap between the two
teams' stand rings. Every map the generator produces is symmetric
(`symMirror` 48, `symRot180` 69, `layoutSides` 117/117), so that gap is zero by
construction: **109 of 117 maps score exactly 0.000**, and the worst map in the
population uses 5.6% of the band's allowance. These two bands spend **4.0 of 23
weight (17%)** re-confirming a property the generator already guarantees.

That is not a tuning problem. Symmetry is a *constructive guarantee*, and a
band that scores a guarantee is measuring nothing — it is a constant term in a
weighted mean, which is a way of diluting every other band by 17%.

The other five are ordinary loose bounds. They are not wrong, and two of them
(`exposedFrac` max 0.189 against a 0.20 cap, `midOpenFrac` max 0.634 against
0.70) are close enough that a different generator would bite on them. On *this*
generator they are inert.

**Only 13.0 of 23.0 weight (57%) can move a ranking.** Within that, the score
is driven about equally by four bands, not by the one it was designed around:

| band | weight | rho(staticScore, its sub-score), n=117 |
|---|---|---|
| `standRingOpenMin` | 1.5 | +0.572 |
| `interiorFrac` | 3.0 | +0.567 |
| `chokeCount` | 1.0 | +0.550 |
| `routeCapacityFrac` | 2.0 | +0.524 |
| `detourMax` | 1.0 | **-0.231** |

`interiorFrac` carries nearly a quarter of the nominal weight and has no more
influence on the outcome than `chokeCount` at a third of its weight. And
`detourMax` runs **negative**: maps that score better on detour tend to score
worse overall. That is an internal contradiction in the rubric, not a play
finding — two bands are pulling against each other.

---

## 3. The play half

**41 maps** (40 generated on 37 distinct seeds, plus the arena as a labelled
point), **5 episodes each, 210 episodes**, all on `standard` 1235x659 boards at
16 seats / 2 teams. Every map is played on the same episode seeds (1..5), so no
map drew luckier seeds than another. Two batches; the second played in shuffled
order, which is what makes the load confound below collapse.

Evidence is re-derived over a **matched 1238-tick window** (the shortest episode
in the pool). Without it, dead floor partly measures how long the episode
happened to last, and episode length varies 1238..5378 ticks because a capture
ends the episode. The unwindowed numbers are kept as a control and differ
exactly where that confound predicts.

**Load confound: clean.** Late-frame share ran 0.0-7.5% (mean 1.6%) and
`rho(staticScore, lateFrac) = -0.029, p = 0.857`. Partial correlations holding
late-frame share constant move every coefficient below by <= 0.02.

**Reliability is high, so a null here is a real null.** Split-half over
episodes, Spearman-Brown corrected, gives ceilings of **0.97** for dead floor,
**0.98** for close contact, **0.92** for pace. The measurement is not too noisy
to see an effect; there is mostly no effect to see.

### staticScore vs play, generated maps only (n = 40)

| outcome | rho | 95% CI | p | reading |
|---|---|---|---|---|
| dead floor | **+0.258** | [-0.06, +0.54] | 0.109 | no signal, and the point estimate points the **wrong way** |
| close contact | +0.336 | [+0.03, +0.63] | 0.034 | aligned, weak |
| kills / 1000 ticks | +0.462 | [+0.21, +0.65] | 0.003 | aligned |
| episode length | -0.073 | [-0.41, +0.28] | 0.652 | no signal |
| kill balance | -0.039 | [-0.37, +0.29] | 0.809 | no signal |
| steals / episode | +0.157 | [-0.06, +0.36] | 0.332 | no signal |
| captures, conversion | — | — | — | **unmeasurable: near-zero on every map** |

So staticScore buys some *combat density* (pace, close contact) and buys
**nothing** on the objective, on episode resolution, or on fairness. On dead
floor it leans the wrong way; unwindowed, that lean reaches significance
(`+0.330, CI [+0.02, +0.59], p = 0.038`).

### interiorFrac vs play, generated maps only (n = 40)

This is the result that matters, because `interiorFrac >= 0.30` is the epic's
acceptance criterion.

| outcome | rho | 95% CI | p | reading |
|---|---|---|---|---|
| **dead floor** | **+0.638** | **[+0.34, +0.84]** | **<0.001** | **strong, tight, and OPPOSITE** |
| close contact | +0.644 | [+0.44, +0.78] | <0.001 | aligned |
| kills / 1000 ticks | +0.461 | [+0.23, +0.63] | 0.003 | aligned |
| episode length | -0.213 | [-0.53, +0.13] | 0.187 | no signal |

Enclosure buys close-quarters contact — that part of the theory holds. It also
strictly costs floor usage, and against a ceiling of 0.97 that is not noise.

As the criterion is actually **used**, a gate:

| group | n | dead floor | close contact | interiorFrac |
|---|---|---|---|---|
| `interiorFrac >= 0.30` (passes) | 13 | **0.615** | 0.480 | 0.351 |
| `interiorFrac < 0.30` (fails) | 27 | **0.542** | 0.395 | 0.225 |
| **arena** (hand-authored control) | 1 | **0.396** | 0.439 | 0.342 |

Mann-Whitney on dead floor, passing vs failing: **p < 0.001**. The gate
selects maps that waste *more* of their floor.

### The control is out of distribution on exactly one axis

| outcome | arena | generated range | generated maps better |
|---|---|---|---|
| **dead floor** | **0.396** | 0.480 – 0.688 | **0 of 40** |
| close contact | 0.439 | 0.275 – 0.575 | 17 of 40 |
| pace | 23.1 | 17.6 – 28.9 | 22 of 40 |
| episode length | 2048 | 1713 – 4813 | 2 of 40 |

The arena is *ordinary* on contact and pace and **unreachable** on floor usage.

This is not an artefact of it having less ground to cover. The arena's open
floor (689,151px) is the **median** of the generated set (688,181px) and its
cover budget (167 permille) sits at the **top** of the generated range
(119-170) — it has more obstruction, not less. In absolute terms the arena
visits **416,579px** of floor against a generated maximum of **363,626px**:
again **0 of 40**. And `rho(interiorFrac, absolute floor visited) = -0.698,
p < 0.0001`.

Note the arena's own `interiorFrac` is **0.342** — it *passes* the criterion,
comfortably. So enclosure does not cause dead floor; the **generator's way of
producing enclosure** does. The target is reachable. The number does not
capture what makes it reachable.

### The bands are weighted close to backwards

Per-band correlation against dead floor, generated maps (n = 40):

| band | weight | rho(metric value, dead floor) | discriminates? |
|---|---|---|---|
| `longRunFrac` | 1.5 | **-0.654** | **saturated — contributes nothing** |
| `midOpenFrac` | 1.0 | **-0.595** | **saturated — contributes nothing** |
| `exposedFrac` | 1.0 | **-0.321** | **saturated — contributes nothing** |
| `standRingOpenMin` | 1.5 | -0.389 | yes (9 levels) |
| `chokeCount` | 1.0 | -0.390 | yes (5 levels) |
| `interiorFrac` | **3.0** | **+0.638** | yes (24 levels) — **wrong direction** |

The three metrics that best predict floor usage *in the right direction* are
all bands whose sub-scores never move, so their weight does nothing. The single
heaviest band predicts it strongly in the wrong direction. That is not a
mis-tuned weight, it is a sign error in the rubric's theory of what a good map
is.

---

## 4. What the harness itself does to the numbers

`server.runFrameLimiter` advances a frame when the wall-clock budget elapses
**or** when every player reports ready. The first branch is a **late frame**: a
bot did not answer in time and the sim stepped anyway on its stale command. So
an episode is only deterministic if every bot keeps up, and on a machine
running 20+ agents they do not.

This is not hypothetical. The arena, on the *same map spec and the same episode
seed*, ran **2573 ticks** in a warm-up probe and **1897 ticks** inside the
loaded batch. The server log says why: the 1897-tick run was 10.1% late frames;
the one arena episode in the batch that scored a capture was 1.6% late.

Every episode therefore carries its own contamination measure, which the server
already prints and which `score_play_corr.py` now reads back
(`Frame pacing: ... late N (X%)`).

**Anyone measuring play in this repo should record it.** A play number without
its late-frame share has an unknown error bar.

The batch-1 flaw is worth naming because it was mine: `cmd_run` submitted maps
in plan order, which is *score* order, so low-scoring maps were played early
and high-scoring ones late while fleet load drifted upward. That makes "what it
scored" and "how contaminated it was" the same variable. Batch 2 plays a seeded
shuffle, and pooling the two collapses the confound to `-0.029`. Any future
play batch in this repo should shuffle.

---

## 5. What this does and does not establish

**Does not**: prove `staticScore` is worthless. It buys real combat density
(pace `+0.462`, close contact `+0.336`), and 39 of 41 maps here were *valid*, so
the hard gates it sits behind are doing their job separately.

**Does not**: prove "less dead floor" is the definition of a good map. A bare
field would score perfectly on it. The reason dead floor carries weight here is
the control: the hand-authored arena beats **all 40** generated maps on it, in
both normalised and absolute terms, while being ordinary on everything else
measured. On this evidence, floor usage is the axis that separates a map
somebody designed from a map the generator drew.

**Does not**: say anything about 4-team maps. Everything here is 2-team,
`layoutSides`, standard size.

**Does establish**, at n = 40 with reliability ceilings near 0.97:

1. `staticScore` does not rank maps by floor usage, and leans against it.
2. `interiorFrac` — heaviest band, and the acceptance criterion — ranks maps
   **backwards** on floor usage, strongly and significantly.
3. 43% of the score's weight cannot rank anything at all, 17% of it
   tautologically.
4. Conversion is not measurable on these maps at all: captures were ~0
   everywhere, so no map-quality claim about the objective can currently be
   supported by play, on any map, including the arena.

**Detectable-effect floor.** At n = 40 the null SD of Spearman is
`1/sqrt(39) = 0.16`, so this design resolves `|rho| >= ~0.31`. Anything weaker
is beyond it and the CIs say so. This is why point 1 is stated as "does not
rank" rather than "is uncorrelated".

---

## 6. Recommendation

**Re-weight the bands, and replace the `interiorFrac >= 0.30` criterion.** Not
one or the other — the second is the urgent one.

1. **Stop steering on `interiorFrac >= 0.30`.** It is not a wrong *target* — the
   arena passes it at 0.342 — it is an **insufficient** one. It is satisfied by
   the arena and by the generator alike, and only the arena also gets its floor
   used. Gating on it selects the number without the property the number was
   chosen to proxy, and every knob tuned to raise it has been buying dead floor.
   Replace it with a criterion the arena passes and the current generator fails.
   Floor usage is the obvious candidate because it is the one axis where that is
   already true, 40 out of 40.

2. **Delete the two fairness bands from the score** (`standRingSpread`,
   `standCoverSpread`, 4.0 weight / 17%). They score a constructive guarantee:
   the generator only emits symmetric maps, so 109 of 117 score exactly 0. That
   belongs in the **validator** as an assertion that fails loudly if symmetry
   ever breaks, not in a ranking as 17% of a weighted mean it silently dilutes.

3. **Re-derive the remaining weights against play, not against intuition.** The
   current set is close to backwards: `longRunFrac`, `midOpenFrac` and
   `exposedFrac` are the three best predictors of floor usage in the right
   direction and all three are saturated to zero influence, while
   `interiorFrac` carries the most weight in the wrong direction. Any
   re-weighting must be re-checked against play, because this rubric has now
   demonstrated that hand-picked weights can invert.

4. **Do not trust any objective/conversion criterion until captures exist.**
   Captures were ~0 on all 41 maps including the control, so conversion rate
   currently measures the bots, not the map. Either the baseline bots need to
   play the objective or episodes need to be far longer before conversion can
   gate anything.

### Cheap next step

`tools/score_spread.nim` + `tools/score_play_corr.py` are the harness; the
expensive part is done. Re-weighting is a *free* re-run: `manifest.json` stores
every band's value and sub-score per map and `rows_*.json` stores every play
outcome, so a candidate weighting can be scored against this same 210-episode
evidence set without playing anything. Only a *new generator* needs new
episodes.

---

## 7. Reproducing

```sh
# 1. the spread (static, ~25s for 361 candidates)
nim c -d:release -o:/tmp/scorespread tools/score_spread.nim
/tmp/scorespread --seeds $(seq 1001 1040 | paste -sd, -) \
  --attempts 9 --size standard --out /tmp/spread

# 2. pick maps spanning the range, arena included automatically
python3 tools/score_play_corr.py select --manifest /tmp/spread/manifest.json \
  --n 20 --out /tmp/plan.json
python3 tools/score_play_corr.py select --manifest /tmp/spread/manifest.json \
  --n 20 --exclude /tmp/plan.json --out /tmp/plan2.json

# 3. play (210 episodes; shuffled order is on by default)
python3 tools/score_play_corr.py run --plan /tmp/plan.json  --episodes 5 --jobs 3
python3 tools/score_play_corr.py run --plan /tmp/plan2.json --episodes 5 --jobs 3 \
  --port 26000 --out /tmp/ctf-score-play2

# 4. matched window, then the confounded control alongside it
python3 tools/score_play_corr.py extract --plan /tmp/plan.json /tmp/plan2.json
python3 tools/score_play_corr.py extract --plan /tmp/plan.json /tmp/plan2.json --no-window

# 5. the tables above
python3 tools/score_play_corr.py analyze --plan /tmp/plan.json /tmp/plan2.json \
  --suffix .win.json
```

### Test status — the base branch is already red, identically

This branch touches `tools/` only, and the map suites fail the **same way on
base `4a013df`** as they do here, verified in a clean detached worktree:

| suite | base `4a013df` | this branch |
|---|---|---|
| `test_mapgen` | 5 failed / 9 ok | 5 failed / 9 ok |
| `test_map_eval` | 1 failed / 26 ok | 1 failed / 26 ok |
| `test_map_rules`, `test_map_select` | pass | pass |

The failing test *names* diff clean between the two. All six failures are one
root cause — `Map generation found no valid layout in 100 attempts from seed
{11, 13, 1015}` — which is the **same failure mode as the `size=small`
finding** in section 1: the generator exhausting `MapGenMaxAttempts` without
validating. That is filed separately and is not this task, but it corroborates
it from a second direction, and the epic's "suite 0 failures" line is not
currently met on its own base.

### Provenance

`tools/map_playtest.nim` here is taken unmodified from
`maxwell/mapgen-play-harness` (`5d57407`, task `3811876a`) — its
`CloseRangePx` and `--ticks` window are load-bearing for section 3.

**The stick did not move under this experiment.** Task `4fb75b77`'s branch
`maxwell/mapgen-metrics-stick` (`0791311`) adds `tools/scan_probe.nim` and
`tools/stick_probe.nim` only; `src/ctf/map_metrics.nim` is **unchanged** from
base `4a013df`, so every number above is against the live rubric. When that
branch does change the bands, section 2 must be re-run — it is 25 seconds — and
sections 3 and 5 can be re-derived from the stored evidence without replaying.
