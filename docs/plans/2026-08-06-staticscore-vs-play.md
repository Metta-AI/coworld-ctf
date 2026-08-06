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

*(filled in below from 21 maps x 5 episodes)*

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
