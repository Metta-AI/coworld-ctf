# The long-diagonal band, decided on play: reading A, and B refuted

Task `5e3d4a42`, epic `3757029c` (LAND THE GENERATOR). Branch
`maxwell/mapgen-diagonal-bands` off `maxwell/mapgen-city-clip` @ `8c9d7dd`,
which already carries the W0 row-cover fix (`239cb9c`).

The task named two readings and told me to settle them on evidence:

> **A.** Long diagonals are a real property of any large board and the band is
> mis-calibrated for the large size class. Then the fix is a size-scaled band,
> and `arena-large` is fine.
> **B.** Long diagonals are a genuine defect that `arena-large` also has. Then
> the generated maps AND the control both need shortening.

---

## The decision

**A, on its mechanism. B is refuted. Nothing gets shortened, and `arena-large`
is not exempted from anything — it passes the corrected band on its merits.**

But A's *remedy* as written — "size-scale the same bound" — would have kept a
threshold that no measurement supports, so the band is re-cut rather than
rescaled. Three findings drive it, in order of weight:

1. **The band's premise is refuted by play.** It caps the longest open line at
   `GunRange` = 1050 px because "a lane longer than the gun's own reach cannot
   be contested from either end". Across **35,335 resolved shots in 210 stored
   episodes, not one damaged anybody past 832 px.** `P(hit)` measured 13% at
   750–900 px and **0 of 7 at 900–1050 px**. `GunRange` is a REACH. This is the
   same error `IsovistRangePx` was corrected for — its comment even says "this
   metric was the straggler", and `sightlineMaxPx` is the straggler it meant.

2. **The px cap was wrong in both directions at once**, which is the epic's own
   test for a broken metric. It **flagged the `arena-large` CONTROL** (1149 px
   = an entirely ordinary 0.631 of its diagonal) while **passing three 816×816
   boards open across 0.88–0.90 of themselves — two of which score a perfect
   `staticScore` of 1.000.** Skipping the control is worse than flagging it;
   this bound did both.

3. **The quantity really is size-dominated**, which is A's mechanism and it
   holds: over 240 measured maps the longest line sits at a median of
   **0.53–0.62 of the board diagonal across a 1.53× range of board sizes**, and
   the two hand-authored maps sit at 0.541 and 0.631. A cap in px therefore
   measures how big a board is, not how it was built.

**The change.** `sightlineMaxPx` stays REPORTED in px and stops being gated in
px. The gated form is a new scale-free field `sightlineOpenFrac` — the same
longest line as a share of the board's own diagonal — banded at
`SightlineOpenFracCap = 0.85`.

---

## 1. What was measured, and on what

| evidence | n | engine | notes |
|---|---|---|---|
| stored play, 2 teams | **210 episodes**, 41 maps | GV38 | 16 seats, all boards 1235×659 |
| fresh play, 4 teams | **15 episodes**, 3 boards | current tree | 16 seats, all boards 1248×1248 |
| static, both team counts | **240 maps** + 8 control scorings | — | 2 trees × 2 team counts × 60 seeds |

**The generator-drift confound is removed rather than bounded.** The 210
episodes were played from mapSpec *files* on disk (`/tmp/spread_wide/*.json`,
`base_sha 4a013df`). Re-generating `(seed, attempt)` on today's tree would score
a different map than the one that was played — the archetype and lane-clip work
has moved every seed since. `tools/sightline_probe.nim` scores the spec files
themselves, so the geometry and the play come from the same bytes.

**Instrument check.** The probe reproduces the two documented control values
exactly — `arena` 758 px diagonal, `arena-large` 1149 px, `longRunFrac` 0.169,
`diagLongRunPxFrac` 0.183 — before any of the numbers below were read.

**The link-time ranker trap** (`map_metrics` installs `mapFitness` at module
init; a probe reaching `generateCtfMap` through `ctf/arena` alone silently
measures FIRST-VALID) is now an `doAssert` in both new tools rather than a thing
to remember.

---

## 2. The engagement envelope, and a constant that was flagged UNVERIFIED

Every shot in this engine emits exactly one `shot_impact` carrying the distance
it travelled, whether it hit a player, a wall, or expired at max range. So this
is the complete distribution, not a sample of the hits.

| travel px | impacts | share | hit a player | P(hit \| impact) |
|---|---|---|---|---|
| 0–130 | 10,932 | 30.9% | 7,067 | 64.6% |
| 130–262 | 17,203 | 48.7% | 13,131 | **76.3%** |
| 262–400 | 4,838 | 13.7% | 2,361 | 48.8% |
| 400–525 | 1,524 | 4.3% | 509 | 33.4% |
| 525–700 | 650 | 1.8% | 132 | 20.3% |
| 700–800 | 135 | 0.4% | 20 | 14.8% |
| 800–900 | 46 | 0.1% | 7 | 15.2% |
| **900–1050** | **7** | **0.02%** | **0** | **0.0%** |

Longest shot that damaged anybody, over all 210 episodes: **832 px**. Longest
shot of any kind: 992 px. Damaging shots past 1050 px: **zero**.

`map_rules.LethalEnvelopePx` carries a note reading *"UNVERIFIED DEPENDENCY: no
hit-rate-versus-range measurement from the field has been taken."* **Here it
is**, against that comment's own model `P(hit) ≈ atan(14/t) / 5.625°`:

| range | measured | model | ratio |
|---|---|---|---|
| 142–200 | 81.4% | 83.2% | 0.98 |
| 200–262 | 67.2% | 61.7% | 1.09 |
| 262–350 | 49.9% | 46.6% | 1.07 |
| 350–450 | 42.5% | 35.6% | 1.19 |
| 450–600 | 26.6% | 27.2% | 0.98 |
| 600–750 | 13.9% | 21.1% | 0.66 |
| 750–900 | 13.0% | 17.3% | 0.75 |

The lattice model holds to within 20% out to 600 px and the field runs
**below** it beyond that — long shots do worse than the geometry predicts,
because the target has time to leave the 28 px acceptance corridor. The
constant's derivation is corroborated; the note can be narrowed to "measured in
self-play, not yet in the league".

---

## 3. The band flags lanes that nothing ever uses

17 of the 40 played maps breach the px cap, all at 1074 px, all on boards of
identical size, all played on the same five episode seeds.

Across those 17 maps: **longest shot of any kind 986 px, longest shot that
damaged anybody 832 px.** Nothing ever traversed more than **92%** of the lane
the band flagged, and the median map's share of damaging shots past 600 px is
**0.00%**.

Three further findings say the metric is not measuring what the band claims:

- **The "breach vs clean" contrast is confounded with the carrying axis, not
  with length.** All 17 breaching maps are ROW-carried; all 22 diagonal-carried
  maps are clean. So the apparently significant breach-vs-clean gaps
  (`dmgP95` p=0.006, kills p=0.002) are a row/diagonal contrast wearing a
  length label.
- **Within the diagonal-carried maps, longer runs the WRONG WAY.**
  `rho(sightlineMaxPx, kills) = −0.620, p < 0.001`;
  `rho(sightlineMaxPx, longest damaging shot) = −0.472, p = 0.017`.
- **The metric samples 8 of the 32 aim slots and is not an upper bound on
  engagement distance.** Every shot in the engine is on an 8-brad multiple;
  only **25.8%** of damaging shots travel on one of the four scanned axes. On
  **3 of 40 maps the longest damaging shot was LONGER than the longest line the
  metric can find** (up to 118% of it), and on the worst of those every one of
  the over-length shots is off-axis.

---

## 4. The direct 4-team test: what a long line has to be before it does anything

The breach the task names is at 4 teams, so it was tested there. Three
1248×1248 boards, 5 episodes each, 16 seats, same engine, same episode seeds.
The first two are the SAME SEED (1010) before and after the lane clip — same
board shell, same size, same objective layout.

| board | longest line | of board diag | hits >600 px | hits >900 px | longest hit | late frames |
|---|---|---|---|---|---|---|
| gen:1010 post-clip | 944 px | 0.53 | 1.59% | **0.00%** | 878 px | 0.04% |
| gen:1010 pre-clip | **1318 px** | 0.75 | 0.81% | **0.00%** | 766 px | 0.08% |
| gen:1028 | **1701 px** | **0.96** | **4.44%** | **0.63%** | **1003 px** | 0.00% |

**A 1318 px lane produces nothing. A board-length one does.** And the causal
link is visible in the headings:

- On **gen:1028**, the two longest damaging shots of the batch (1003 px and
  978 px) both travel on a 45° heading, and diagonals carry **29% of its hits
  over 600 px against a 9% base rate** — a 3.2× enrichment. The open diagonal
  is being used.
- On **gen:1010 pre-clip**, with its 1318 px diagonal, **0 of 5** long hits are
  diagonal. Its single longest hit (766 px) is due west, along a row.

**gen:1028's diagonal was verified independently of the metric.** Rendered and
re-measured off the sim's own integer wall predicate: open corner to corner,
both diagonals (quad symmetry), median perpendicular clearance 165 px, tightest
interior pinch 27 px — walkable end to end for a 12 px body. Its layout is
`corners`, so the Red and Yellow pedestals sit **directly on that line**: it is
a pedestal → centre → pedestal corridor, not an incidental sliver. The raw-mask
measurement reads ~2–6% longer than the metric on both boards, which is the
metric's occupiable-end requirement (an eroded mask, trimmed to where a body
fits) and not a discrepancy.

---

## 5. Testing A directly: is it a size property?

Yes on the mechanism, and the failure is symmetric.

| batch | n | median `sight/diag` by size class |
|---|---|---|
| 2 teams, pre | 59 | 1050×560: 0.520 · 1235×659: 0.584 |
| 2 teams, post | 58 | 1050×560: 0.640 · 1235×659: 0.654 |
| 4 teams, pre | 60 | 816²: 0.613 · 960²: 0.595 · 1248²: 0.582 |
| 4 teams, post | 60 | 816²: 0.619 · 960²: 0.547 · 1248²: 0.529 |
| controls | 2 | arena 0.541 · arena-large 0.631 |

A near-constant ratio against a fixed px cap is exactly a size-class filter:
in the pre-clip 4-team batch the breach rate runs 1/19 on 816², 2/18 on 960²
and **9/23 on 1248²**. Same generator, same rules, three answers.

And the other half, which A as written does not cover — **what the px cap
misses**, on the current trunk at 4 teams:

| map | board | longest line | of diag | px cap says | corrected band says |
|---|---|---|---|---|---|
| gen:1028 | 1248² | 1701 | 0.964 | FLAG | FLAG |
| gen:1054 | 1248² | 1701 | 0.964 | FLAG | FLAG |
| gen:1037 | 816² | 1038 | 0.899 | ok — **`staticScore` 1.000** | FLAG |
| gen:1047 | 816² | 1019 | 0.883 | ok — **`staticScore` 1.000** | FLAG |
| gen:1019 | 816² | 1016 | 0.880 | ok | FLAG |
| gen:1040 | 1248² | 1363 | 0.772 | FLAG | ok |
| gen:1035 | 1248² | 1168 | 0.662 | FLAG | ok |
| gen:1027 | 1248² | 1077 | 0.610 | FLAG | ok |
| **CONTROL arena-large** | 1606×858 | 1149 | 0.631 | **FLAG** | **ok** |

Two boards scoring a perfect 1.000 are open across nine tenths of themselves and
no band in the suite sees it.

---

## 6. Breach fractions, both team counts, before and after, controls in the batch

`arena` and `arena-large` are prepended to every batch below and exempted from
nothing. "pre" is `986abfb`, the commit whose writeup recorded the numbers this
task quotes; "post" is this branch.

### Under the px cap (`sightlineMaxPx > GunRange`), as shipped

| batch | generated breaching | arena | arena-large |
|---|---|---|---|
| 2 teams, pre-clip | 16/59 = **27.1%** | ok | **BREACH** (1149) |
| 2 teams, post-clip | 12/58 = **20.7%** | ok | **BREACH** |
| 4 teams, pre-clip | 12/60 = **20.0%** | ok | **BREACH** |
| 4 teams, post-clip | 5/60 = **8.3%** | ok | **BREACH** |

The task quotes 4 of 12 (33%) at 4 teams. That reproduces **exactly** at
`986abfb` — gen:1010 1318, gen:1004 1101, gen:1008 1063, `arena-large` 1149 —
and on the current trunk those same three seeds read 944 / 911 / 1022, so 0 of
the original 12 still breach. Over 60 seeds the honest rate is 20.0% → 8.3%.
That improvement is **not** this task's doing; it arrived with the archetype
and lane-clip work already merged.

### Under the corrected band (`sightlineOpenFrac > 0.85`)

**This band is also the best-of-K RANKER** (`map_metrics` installs
`staticScore` as `arena.mapFitness`), so correcting it does not merely re-label
maps — it changes which candidate each seed ships. Both readings are given
because they answer different questions.

| batch | maps selected by | px > 1050 | openFrac > 0.85 | mean score |
|---|---|---|---|---|
| 2 teams, pre-clip | old band | 16/59 = 27.1% | **0/59 = 0.0%** | 0.9597 |
| 2 teams, post-clip | old band | 12/58 = 20.7% | **0/58 = 0.0%** | 0.9747 |
| 2 teams, post-clip | **new band** | 15/58 = 25.9% | **0/58 = 0.0%** | 0.9767 |
| 4 teams, pre-clip | old band | 12/60 = 20.0% | **3/60 = 5.0%** | 0.9568 |
| 4 teams, post-clip | old band | 5/60 = 8.3% | **5/60 = 8.3%** | 0.9701 |
| 4 teams, post-clip | **new band** | 11/60 = 18.3% | **3/60 = 5.0%** | 0.9732 |

Controls in every batch, exempted from none: `arena` 758 px / 0.541 / 1.000;
`arena-large` 1149 px / 0.631, score **0.905 → 0.921** because it stops paying
for a breach that was a bug in the band.

Three things to read off that table:

- **The 4-team population got WORSE under the correction's own measure, not
  better.** The px cap reported 20.0% → 8.3% across the recent generator work;
  the corrected band reports 5.0% → 8.3% on those same two trees. The recent
  work lowered the median and made the TAIL heavier — the two 1701 px boards do
  not exist in the pre-clip batch at all. The band that flagged less was hiding
  a regression.
- **Selection then removes some of it, and cannot remove all of it.** Once the
  corrected band is also doing the ranking, 4-team breaches fall 5/60 → 3/60:
  seeds 1037 and 1047 stop shipping their 0.90-open boards (1038 px → 566 px,
  1019 px → 586 px) because a better candidate now outscores them. Seeds 1019,
  1028 and 1054 have no better candidate inside K. That is best-of-K moving the
  measure without moving the support, exactly as advertised.
- **`px > 1050` goes UP under the new selection** (8.3% → 18.3% at 4 teams,
  20.7% → 25.9% at 2). That is the change working as intended, not a
  regression: the generator stops spending candidates avoiding long-but-not-open
  lines, which play says cost nothing, and spends them on openness instead.
  Anyone still reading the px number will see it rise.

---

## 7. What this does NOT establish

- **The 0.85 cut is the midpoint of an interval, not a measured threshold.**
  Play licenses `(0.767, 0.964]`: the 40 played 2-team boards top out at 0.767
  and the played 1318 px 4-team board is 0.747, all with zero hits past 900 px;
  the one board measured above that, at 0.964, produced them. **There is exactly
  one played board above 0.77.** Narrowing this needs more of them, and the
  cheapest way is to play the three 816² boards at 0.88–0.90.
- **The band is now inert at 2 teams** (0 of 59 and 0 of 58). That is the
  correct reading of a population no board of which has ever produced a
  long-range engagement, but it is real dead weight in a score that already has
  43% of its weight unable to rank anything
  (`2026-08-06-staticscore-vs-play.md`). Its weight was left at 2.0 because
  re-weighting is `maxwell/mapgen-stick-reweight`'s work, not this task's.
- **Nothing here is about the objective.** Captures are ~0 on every map in the
  2-team evidence set including the control, so no conversion claim is
  supportable.
- **The 2-team evidence is GV38, self-play, baseline bots, 16 seats, one board
  size.** The hit-rate-versus-range table is a property of the lattice and the
  13 px body and should survive an engine bump, but it has not been checked
  against a league replay. A `GameVersion` change that moves `AimRotations`,
  `BulletHalfWidth` or `GunRange` invalidates §2 and everything cut from it.
- **`diagLongRunPxFrac` was not re-derived.** Its own note says it is
  "CALIBRATED ON AN AXIS-ALIGNED POPULATION" and must be re-cut against a fresh
  one; that is still true and still open. It breaches on 16.7% of the current
  4-team population.
- **The hard gate still rejects none of this**, at either team count, on either
  tree (0 of 62 rejected in the live 4-team batch, both controls included).
  `arena.collectMapDiagnostics` reports the longest line and does not act on it;
  its comment is corrected here to say what the corrected band is cut on, but
  flipping it to a rejection remains the epic owner's call.
- **Three 4-team seeds still ship a near-open board and selection cannot fix
  them** (1019 at 0.880, 1028 and 1054 at 0.964). Best-of-K moved the measure,
  not the support: the generator has no better candidate for those shells
  inside K. gen:1028's is a `corners` layout whose open main diagonal runs Red
  pedestal → centre → Yellow pedestal, so it is an objective-to-objective
  corridor rather than an incidental sliver. That is generator work, not band
  work, and it is now visible to the score for the first time.

### Test status

`test_map_eval` 39, `test_map_select` 26, `test_map_rules` 61, `test_mapgen` 14,
`test_map_lanes` 37, `test_mapgen_graph` 9 — **186 ok, 0 failed**, and no test
was weakened to get there. `test_map_eval`'s `check "sightlineMaxPx" in
breached` was a test that ratcheted BACKWARDS — it asserted the control stayed
flagged, so correcting the band would have turned it red. It was re-derived from
what it meant (the second control is scored against every band and exempted from
none) into three checks: the band is not breached, the value is inside the
bound, and the band is present in the control's scored set at all.

---

## 8. Reproducing

```sh
# static, both team counts, controls prepended and never exempted
nim c -d:release -o:/tmp/stick tools/stick_probe.nim
/tmp/stick --teams 2 --pool --gen 1001-1060
/tmp/stick --teams 4 --gen 1001-1060

# the geometry half of the play join: score the stored specs, not the seeds
nim c -d:release -o:/tmp/sl tools/sightline_probe.nim
/tmp/sl --teams 2 arena arena-large /tmp/spread_wide/s1001a8.json ...

# the 4-team play arms (map_eval play takes a spec path)
nim c -d:release -o:/tmp/mapeval tools/map_eval.nim
/tmp/mapeval play /tmp/specs4t/t4-gen1010.json --episodes 5 --teams 4 --seats 16
```

Engagement distances come from `*.summary.jsonl`: `shot_impact` carries
`distance` (px travelled), `heading_brads`, and a `damages` array that is empty
when the shot hit geometry. Late-frame share is in the paired `*.server.log`
(`Frame pacing: ... late N (X%)`) and is reported with every play number above.
