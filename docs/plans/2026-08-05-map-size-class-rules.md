# Size-class and team-count rule sets, split by visibility regime

**Status:** parameter table LANDED (`src/ctf/map_rules.nim`), two brittle tools
FIXED, corridor-width change RECOMMENDED with measured churn but deliberately
NOT shipped. Generator output is byte-identical to `c49cbe6`.

**Update (GameVersion 38): §7.2 SHIPPED, and it took `ShoutRange` with it.**
`GrenadeMaxRange` and `ShoutRange` are `GunRange div 4` = 262 px on every size
class; neither is re-derived per map install any more (both are compile-time
constants in `sim_types`, and `arena.selectCtfMap` no longer installs a weapon
reach at all). §7.2's own recommendation against moving `ShoutRange` was
OVERRULED — see the amendment there for why the "it is only a coordination
channel" argument does not survive the regime framing.

**Stage 2 of the map-generator rebuild.** Stage 1 was the hex coordinate kernel
(`src/ctf/hex.nim`) and the burrow connectivity tool (`src/ctf/burrow.nim`).
This stage produces the numbers; the structure pass consumes them.

---

## 0. What is wrong today, in one number

`arena.scaledGenShell` says it outright: *"Obstacle SIZES never scale."* A
colossal board is therefore the standard map photocopied at 520% — the same
56 px pebbles, 27x as many, spread over 27x the ground.

The reason one parameter set cannot serve all six classes is that **`GunRange`
has been frozen at 1050 px since GV34 while board area spans 37x**. Measure
that with one quantity: `coneCoverage`, the fraction of the playfield one
unoccluded vision cone covers. `VisionConeDeg` = 60 (half-angle),
`visionRange` = 1.5 x `GunRange` = 1575 px, so the cone is a 120-degree sector
of area `pi * 1575^2 / 3` = **2,597,704 px^2**.

| class | rect playfield | coneCoverage | square-4 | hex | regime |
|---|---|---|---|---|---|
| small | 588,000 | **4.418** | 3.901 | 4.430 | occlusion-limited |
| standard | 813,865 | **3.192** | 2.819 | 3.200 | occlusion-limited |
| large | 1,376,342 | **1.887** | 1.668 | 1.892 | occlusion-limited |
| huge | 2,636,478 | **0.985** | 0.870 | 0.987 | mixed |
| giant | 5,500,443 | **0.472** | 0.417 | 0.473 | mixed |
| colossal | 22,008,194 | **0.118** | 0.104 | 0.118 | range/navigation-limited |

On small/standard/large ONE stance sees 1.9-4.4 whole maps: nothing is out of
reach and nothing is undiscoverable, so **sightline control is the entire
design** and encounter density takes care of itself. On colossal a stance sees
12%: sightline control barely matters and **encounter density is the design
problem** — the map must funnel players toward contact rather than hand them
cover to hide behind.

The regime cuts sit at the geometric midpoints of the two gaps in the data
(`sqrt(1.887 * 0.985)` = 1.363, `sqrt(0.472 * 0.118)` = 0.236), rounded to
**1.4** and **0.25**. All three board families agree on every class at those
cuts, with the square-4 family the tightest case and still clear — pinned by
test.

A second number worth carrying around: at `MaxSpeed / MotionScale` = 2.75
px/tick = 66 px/s, crossing a colossal board ONCE takes 97 seconds. Games end
around 100 s.

---

## 1. The result: what scales, and what does not

The single most useful finding of this stage:

> Because gun range, player speed, fire rate and hit points are all FIXED,
> **every tactical LENGTH is regime-invariant**. Only COUNTS and DENSITIES
> change with the class.

Invariant across all six classes and all four team counts:

| quantity | value | derivation |
|---|---|---|
| `maxExposedRunPx` | **132** | `TicksToKill * speed`; `ShotsToKill` = `HitPoints * 100 / FieldAccuracyPct` = 5, `TicksToKill` = 4 * `FireCooldownTicks` = 48 ticks, x 2.75 px/tick |
| `wallSpanPx` | **264** | rounding a wall of span S costs S/2 of detour; for the separation to be worth anything that must exceed one kill's travel, so S >= 2 * 132 |
| `strafeWindowPx` | **28** | `2 * (PlayerHalf + BulletHalfWidth)` — the lateral move that turns a locked-in max-range hit into a miss. Takes 10.2 ticks, inside the 12-tick `FireCooldownTicks`, so it is a move a player can actually make |
| `chokepointSpacingPx` | **1050** | two chokepoints are tactically distinct exactly when a defender holding one cannot shoot into the other |
| `minPickupSpacingPx` | **1050** | two pickups inside one gun range are one pickup; a single camper covers both |
| `minCorridorWidthPx` (recommended) | **68** | two drawn cog bodies abreast, `2 * SoldierBodyPx` |
| `hubRadiusPx` ceiling | **525** | `GunRange / 2`: a hub wider than this is two engagements, not one |

The one exception is **`coverSizePx`, which scales as `sqrt(class scale)`** —
the geometric mean between today's "never scale" and a photocopy's "scale
linearly". Section 3.

---

## 2. Cover density: the mean-free-sightline law

### The law

In 2D, a random line meets convex bodies of number density `n` and mean
perimeter `P` at rate `n * P / pi` (Cauchy: a convex body's mean projected
width is `P / pi`). With area fraction `phi = n * A`, the **mean free
sightline** is

```
lambda = pi * (A/P) / phi        =>        phi = pi * (A/P) / lambda
```

`A/P` is the only shape property that matters; call it the cover modulus `m`.
For a disc of diameter W it is `r/2 = W/4`. Our stock mix (28 px discs, 28 px
diamonds, 18x60 stubs, chevrons) averages 10-20% below the disc figure, so the
disc is the conservative reference.

### The law reproduces the hand-tuned band

`CoverPermilleMin` = 40 and `CoverPermilleMax` = 170 have shipped since GV25.
Nobody derived them; they were tuned by hand. Feed the standard class (W = 56,
m = 14) into the law:

| target | permille | shipped constant |
|---|---|---|
| `lambda = GunRange` (no average ray crosses a full gun range unbroken) | **42** | `CoverPermilleMin` = 40 |
| `lambda = GunRange / 4` (an average ray still gets a quarter of a gun range) | **168** | `CoverPermilleMax` = 170 |

Within 5% and 1%. **The hand-tuned floor IS the gun-range criterion and the
hand-tuned ceiling IS the quarter-gun-range criterion.** That is the evidence
the model is the right one, and it is pinned by
`tests/test_map_rules.nim` — "it reproduces the hand-tuned band that has
shipped since GV25".

### The regime sets the band, and the range regime INVERTS it

| regime | `lambda` band | why |
|---|---|---|
| occlusion | `[GunRange/4, GunRange]` = 262-1050 | ceiling: everything is in range of everything, so no average ray may cross a whole gun range or the map is unsurvivable. Floor: below a quarter of a gun range the gun's reach is wasted and the map is a maze. |
| mixed | `[GunRange/2, visionRange]` = 525-1575 | spans both |
| **range** | `[GunRange, visionRange]` = 1050-1575 | **inverted, deliberately.** On a board where a cone sees 12%, breaking sightlines is how you make a map nobody can find anyone on. Rays must run at least a gun range so contact happens, and at most a vision range so no lane is dead ground you cross blind. |

Consequence: **colossal carries LESS cover than standard** (64-96 permille
against 42-168), and what replaces it is structure — section 4 — and trenches
— section 5.

---

## 3. Obstacle size: sqrt(scale), and why both endpoints are wrong

Today's rule (never scale) and the obvious alternative (scale linearly) are
both wrong, and they are wrong in opposite directions:

- **Hold size fixed.** To reach its cover budget at 56 px pieces, colossal
  needs **711 obstacles** — a mapSpec every client downloads, and a field of
  sub-resolution pebbles nobody can navigate by. (At `visionRange`, a 56 px
  feature subtends 2.0 degrees, one fifth of a single 11.25-degree aim slot: it
  is not a landmark, it is noise.)
- **Scale linearly.** A colossal piece is 291 px, `m` = 72.75, and at a 100
  permille budget `lambda` = 2285 px — past `visionRange`. The board goes
  blind between features.

The geometric mean satisfies both: `W = 56 * sqrt(scale)`.

| class | W | pieces at mid-band | pieces at fixed W = 56 |
|---|---|---|---|
| small | 52 | 27 | 23 |
| standard | **56** | 35 | 35 |
| large | 64 | 51 | 67 |
| huge | 75 | 44 | 80 |
| giant | 90 | 78 | 201 |
| colossal | 128 | **137** | **711** |

Piece count then grows as `sqrt(area)` — 35 to 137 across a 27x area span —
and every class stays inside its own sightline band.

**The floor is also derived, and the hand-tuned 56 clears it.** A defender at
depth `c` behind cover of width `W`, hidden from a shooter at distance `d` who
is free to slide `S` sideways during the exchange, needs
`W >= (34*d + S*c) / (d + c)`. At the occlusion regime's own engagement
distance (`d` ~ 300, the band midpoint), one body of depth (`c` = 34) and one
kill's worth of slide (`S` = 132), that is **W >= 47 px**. The shipped 56
clears it by 19%; a one-body 34 px piece would not.

---

## 4. Lanes and chokepoints: one formula, the regime falls out

Lane count is the **minimum of two ceilings**, both floored (a ceiling is
floored, never rounded), with 3 as the hard minimum because below three there
is no route CHOICE:

```
packLimit    = crossSection / (nominalLane + coverSize)
contactLimit = ContactReference / (nominalLane * traverse)
laneCount    = max(3, floor(min(packLimit, contactLimit)))
```

- `nominalLane` = `2 * SoldierBodyPx + 2 * strafeWindow` = **124 px**.
- `ContactReference` = the **huge** rect playfield, 2,636,478 px^2 — the class
  at the occlusion/mixed boundary (`coneCoverage` ~ 1.0). Contact rate falls as
  1/area with everything else fixed, so a board keeps the boundary class's
  contact rate only if players are confined to a route network of that area.

| class | packLimit | contactLimit | lanes | lane width |
|---|---|---|---|---|
| small | 3.07 | 20.3 | **3** | 158 |
| standard | 3.55 | 17.5 | **3** | 158 |
| large | 4.45 | 13.4 | **4** | 124 |
| huge | 5.86 | 9.65 | **5** | 124 |
| giant | 7.91 | 6.66 | **6** | 124 |
| colossal | 13.5 | **3.32** | **3** | 158 |

**Packing binds on the three occlusion classes, the two cross over in the
mixed regime, and contact binds hard on colossal** — where the answer is
*fewer lanes than would fit*. That collapse from 6 back to 3 IS the funnel the
range regime needs, and it fell out of the formula rather than being asserted.

Lane WIDTH follows traffic — a team's players spread over its lanes, each
needing a body plus dodge room on both sides of the file — floored at
`nominalLane` so a lane always passes two abreast.

`maxOpenRunPx` (longest straight unobstructed run permitted) ramps between two
derived endpoints: **`GunRange` = 1050** in the occlusion regime (a run longer
than the gun makes a position nobody can answer) and **`visionRange` = 1575**
in the range regime (a run you can see the end of makes contact; a longer one
is dead ground you cross blind). Mixed takes the midpoint, 1312.

`chokepointsPerRoute` = `traverse / 1050`, so 1, 1, 2, 2, 3, 6.

---

## 5. Trenches, pickups, hub

### Trenches

A trench (`TrenchSize` = 56, walkable, `TrenchMissPct` = 70, transparent) is
the **only cover that costs no sightline**. Walls deliver protection in
proportion to how often a ray meets one, i.e. inversely to `lambda`, so the
share trenches must carry rises with the band midpoint. Anchored at 250
permille for the occlusion regime, which is what the generator's own
density-mode roll rates (17/25/50 percent by candidate class) already produce:

| regime | trench share | trench permille | derived count |
|---|---|---|---|
| occlusion | 250 | 32 / 35 / 40 | 7 / **9** / 13 |
| mixed | 400 | 49 / 60 | 23 / 41 |
| range | 500 | 80 | **107** |

The standard class's 9 matches what the generator actually digs (~8-10) —
another retro-validation.

**FINDING: `mapPits` is capped at 64 and colossal's derived budget is 107.**
Either the cap rises or the trench size rises with the class (it does, in the
table: `trenchSizePx` = `coverSizePx`). Pinned by test so it cannot be
forgotten.

### Pickups

For k pickups spread over area A the mean distance to the nearest is
`0.5 * sqrt(A/k)`. Budget one gun range of detour for a kit — beyond that the
trip costs more than the fight it was meant to survive — so
`k >= A / (2 * GunRange)^2`, rounded up to a whole symmetry orbit (a pickup set
that is not a whole orbit is not team-fair). Everything up to giant needs
exactly one orbit; colossal needs three.

**FINDING: today's kit pair is inside one gun range of itself.** The generator
draws `y1` in [16%, 34%] of the height and places the pair at `(y1, H-1-y1)`,
so the pair is 0.32H..0.68H apart = **211-448 px on the standard board**. One
camper covers both. `minPickupSpacingPx` = 1050 is the rule the structure pass
should honour.

### Hub

- **Floor:** a hub fight of `seats` players needs each to hold a strafe disc of
  radius `SoldierBodyPx/2 + strafeWindow` = 45 px at a realistic 70% packing,
  so `R >= 45 * sqrt(seats / 0.7)` — **215 px** for a 16-seat house.
- **Ceiling:** `GunRange / 2` = **525 px**.
- The range regime pins the hub AT the ceiling: on a board where a cone sees
  12% the hub is the encounter-manufacturing device and should be as large as
  one engagement allows. The occlusion regime takes the floor — the whole map
  is already one engagement.

Ladder: 215 (occlusion) / 262 (mixed) / 525 (range).

**FINDING: today's `flagRing` is `round(70 * scale)` — 70 px on the standard
board against a 215 px floor.** A hub fight there is body-blocked.

---

## 6. Team-count rule sets

Verified numerically against `src/ctf/hex.nim`'s own functions
(`teamGroup`, `spawnCells`, `orbit`, `actsFreely`, `adjacentBaseSeparation`,
`supportsSixTeams`, `aspectOk`), not against the prose.

| teams | family | group | mirrored teams | seat plans | sized for | ships on |
|---|---|---|---|---|---|---|
| 2 | rect 1235x659 | C2 | 0 | 12,14,...,32 | 16 | every class |
| 3 | hex | C3 | 0 | 12,15,18,21,24,27,30 | 15 | **huge, giant, colossal** |
| 4 | square 960 | V4 | **2** | 16,20,24,28,32 | 16 | every class |
| 6 | hex | C6 | 0 | **24, 30** | 24 | **giant, colossal** |

### Aspect

Any group transitive on 3 or 6 spawns contains a 120-degree rotation, which
confines the bounding-box aspect to `[sqrt(3)/2, 2/sqrt(3)]` = [0.866, 1.155].
The rect shell's 1235/659 = 1.874 is far outside it, so **3 and 6 teams have no
rectangular option at all** — `familyForTeams` returns `boardHex` and nothing
else. Every hex class passes `aspectOk`; the standard hex class is 969x1119.

### Handedness

C4 is not a subgroup of D6 (crystallographic restriction), so 4 teams take the
Klein four-group V4 and **two of the four see a MIRROR world**. Confirmed
directly: `mirroredTeams(4)` counts the non-rotations in `teamGroup(4)` and
gets 2.

**No field in `MapRules` is handed.** Everything the table emits is a count, a
length or a density — quantities a reflection preserves. There is no per-team
accessor at all: one rule set serves all four teams, so a "lanes favour the
left flank" style parameter cannot exist. (The rect family independently draws
`symMirror` half the time, with the same handedness cost, symmetric between the
two teams.)

### Adjacent-base separation — the 6-team claim, verified

Bases ride a ring at `SixTeamBaseFraction` = 0.75 of the circumradius, so
adjacent separation is `2 * f * R * sin(pi/N)` — at N = 6 that collapses to
exactly `f * R`, the worst case of any N. Requiring one gun range of clearance:

| teams | min circumradius | min class |
|---|---|---|
| 3 | 808 | huge (R = 1006) |
| 6 | **1400** | **giant (R = 1454)** |

Per-class separation at N = 6: small 356, standard 419, large 545, huge 755,
**giant 1090**, colossal 2181 px. **The brief's claim is confirmed: 6ffa ships
on the GIANT class only** (giant and colossal), and it matches
`hex.supportsSixTeams` exactly.

**NEW, not in the brief: 3ffa cannot ship below huge either.** Same formula,
milder constant — at N = 3 the separation is 1.299 * R, so the floor is an
808 px circumradius and small/standard/large all fail (617 / 726 / 944 px).

The gate is **FFA-only** (`teamCount >= 3`). Two-team CTF is exempt and
shipping proves it: the standard rect board's two homes are 935 px apart,
inside one gun range, and it has always played fine — there is exactly one
enemy and terrain is authored between them.

### Seats

`seatPlans(n)` = every total that deals evenly, seats at least
`MinSeatsPerTeam` = 4 each, and fits `MaxPlayers` = 32. The classic mistakes
fall out by construction:

- 16 seats on 3 teams deals 6/5/5 (16 mod 3 = 1) — **not** in `seatPlans(3)`;
  15 and 18 are.
- `seatPlans(6)` = **{24, 30}** exactly.
- 6ffa8 = 48 seats does not fit `MaxPlayers` = 32 at all.

---

## 7. The two open decisions

### 7.1 `MinCorridorWidth`: RAISE TO 68 — recommended, not shipped

26 px clears the 13 px SOLID footprint (`PlayerHalf` = 6) but not the 34 px
DRAWN silhouette, so two cogs abreast in a minimum corridor visually overlap.
Two drawn bodies need `2 * SoldierBodyPx` = 68. Source's published minimum
hallway is 64 units and the standard rule is "at least double the player
width". The scale bridge: matching `SoldierBodyPx` = 34 to Source's 32-unit
player gives 1 unit ~= 1.06 px, under which TF2's 1024-unit medium-range cap =
1088 px lands **within 4% of our `GunRange` = 1050**. Published level-design
metrics transfer here once anchored. Our column SPACING of 72 px already obeys
the rule; only the corridor minimum does not.

**Measured blast radius** (`validateGeneratedMap` over all 402 rows of
`tests/fixtures/map-validation-baseline.tsv` plus the 20 curated pool seeds,
release build, one build per value):

| MinCorridorWidth | baseline pass / 402 | rows whose verdict CHANGES | pool seeds still valid / 20 |
|---|---|---|---|
| **26 (today)** | 305 (75.9%) | — | **20** |
| 34 | 293 (72.9%) | 25 | 20 |
| 44 | 247 (61.4%) | 74 | 17 |
| 52 | 213 (53.0%) | 113 | 15 |
| **68** | **114 (28.4%)** | **222 (55%)** | **7** |

At 68 the churn is: rewrite all 402 baseline rows, re-curate the whole pool
(13 of 20 seeds die), regenerate `docs/pool-review.html` and the 20
`PoolRenderHashes` in `tests/test_map_editor_core.nim`. It also changes map
OUTPUT, not just verdicts — `MinCorridorWidth` feeds the stub border-anchoring
at `arena.nim` ~1750.

**And the column generator physically cannot serve 68 px.** Its slot period is
88-120 px around 56-60 px obstacles, so no gap between adjacent kept slots can
exceed **64 px**. The 28% that survive at 68 do so only through CLEARED slots
(the "at least one gap" rule guarantees one per column, at `2 * period -
obstacle` >= 116 px). Raising the constant without replacing the column
generator would ship a pool selected almost entirely on where the clear-mask
happened to fall.

**Decision: land 68 as `map_rules.RecommendedCorridorWidthPx` and as every rule
set's `minCorridorWidthPx` — what the structure pass must BUILD to — and leave
`arena.MinCorridorWidth` at 26, which is what the legacy column generator is
validated against.** Raising it belongs to the same change that replaces the
generator, so the pool is re-curated once rather than twice.

If someone wants an incremental step now: **34 px is nearly free** — 25 changed
rows, zero pool seeds lost — and it is exactly one drawn body.

### 7.2 `GrenadeMaxRange`: pin to the gun — SHIPPED in GameVersion 38

`GrenadeMaxRange` and `ShoutRange` were both `MapWidth div 5` and therefore
scaled with the board, while `GunRange` has been frozen since GV34. Both
columns below are the SAME number for the shout, which is why it moved too.

| class | rect shell | before (grenade = shout) | vs GunRange | after (GV38) |
|---|---|---|---|---|
| small | 1050 | 210 | 0.20x | 262 (+25%) |
| standard | 1235 | 247 | 0.24x | 262 (+6%) |
| large | 1606 | 321 | 0.31x | 262 (-18%) |
| huge | 2223 | 444 | 0.42x | 262 (-41%) |
| giant | 3211 | 642 | 0.61x | 262 (-59%) |
| **colossal** | 6422 | **1284** | **1.22x — INVERTED** | 262 (-80%) |

Confirmed: the inversion needs a shell wider than `5 * GunRange` = 5250 px, so
it happens on colossal only. The 4-team square colossal (4992 px) stays
*barely* under it at 998 px, which is itself a sign the number is accidental.

**Not intended.** The grenade is a short-range, chargeable, arcing weapon; its
whole identity is "closer than the gun". Tying it to `MapWidth` is a fossil of
the era when the gun was ALSO map-wide — GV34 froze the gun and left these two
scaling.

**Recommendation, now shipped: `GrenadeMaxRange = GunRange div 4` = 262 px.**
It reproduces the standard board's historical 247 px within 6% and cannot
invert again. Per-class delta: small +25%, standard +6%, large -18%, huge -41%,
giant -59%, colossal -80%.

One caveat on the shipped form: it pins to the compile-time `GunRange`
constant, NOT to `config.gunRange`. A league that overrides `gunRange` per game
moves the gun and the derived vision cone (`sim.visionRange` is
`config.gunRange * 3 div 2`) but not the grenade or the shout. Following the
live config would mean threading `sim` through `throwTarget(player)`, which the
render calls with a bare `Player`; it is a real (small) inconsistency, left for
whoever needs a per-game range override to actually change the grenade.

The lower-churn alternative considered and rejected: `min(MapWidth div 5,
GunRange div 2)`, which touches only giant and colossal. It closes the
inversion but keeps the coupling — small and large would still play different
weapons, which is the thing worth removing.

**NOT SHIPPED IN THIS STAGE** (it changes sim behaviour and replay
reproduction, so it needs a `GameVersion` bump) — **shipped immediately after,
as GameVersion 38.** What landed:

- `sim_types.GrenadeMaxRange = GunRange div 4` and
  `sim_types.ShoutRange = GunRange div 4`, both now COMPILE-TIME CONSTANTS.
  They used to be `var`s in the runtime-map block, re-derived from `MapWidth`
  by `arena.selectCtfMap` on every install; those two install lines are gone,
  so a weapon reach is no longer per-map state that a map can move.
- `map_rules.grenadeMaxRangeTodayPx` now reports the shipped constant instead
  of `boardWidth div 5`, and `grenadeOutRangesGun` is false on every class,
  team count and board family — pinned by test, which is the same test that
  used to assert the inversion was live on colossal.
- GameVersion 37 -> 38. The bump is not ceremonial: a grenade's target
  coordinates are hashed state (`sim_state.gameHash` mixes `sx/sy/tx/ty`) and
  replay playback re-simulates each tick and compares that hash
  (`replays.checkReplayHash`), so every GV37 recording would diverge. The
  version string in the file header is the mechanism that stops that — the
  codec refuses to load a replay whose `gameVersion` is not the running one
  (`bitworld/replays.nim`, "Replay game version does not match"). All six
  recorded fixtures were re-recorded.

**Amendment: `ShoutRange` moved too.** This section originally recommended
leaving it alone — "a coordination channel, not a weapon; there is no fixed
physical scale it must respect, and on colossal the fact that you can call out
a contact you cannot shoot is exactly right for the range regime". That was
overruled, and the reasoning it missed is the point of the whole document: the
value of a callout is not that it is *heard*, it is that a mate can ACT on it,
and the radius inside which a mate can act is set by the gun, not by the shell
the map generator happened to draw. A 1284 px bubble on colossal hands out free
coordination exactly on the boards where crossing the ground is meant to be the
problem — it flattens the range regime the same way a board-scaled grenade
does. If everything scales with the map, there is no point to the larger map.
Pinned at 262 px, the standard board's historical 247 px is preserved within
6%, and the "call out what you cannot shoot" play is untouched: what a shout is
ABOUT is anything the caller can see, and vision still reaches 1.5x the gun
(1575 px). 262 px is only how far the voice carries — how close a mate has to
be to receive it.

---

## 8. The two brittle tables

Both hard-failed on any width they had not been told about, which is the
concrete reason a new size class could not ship.

- `tools/gen_map_pool.nim` — `sizeClassIndex` was a `case` over five width
  literals ending in `raise`. Now `gameMap.mapSizeClass()`, derived from
  `MapSizeClassTable`; `SizeQuota` is an `array[MapSizeClass, int]`, so adding
  a class is a compile error rather than a runtime raise.
- `tools/build_pool_review.py` — `SIZE_NAMES` was a width -> name dict that
  KeyError'd. The page now has **no map knowledge at all**:
  `tools/render_map_pool.nim` writes the Nim-resolved `sizeClass` into
  `manifest.json`, and the summary line and the filter bar are built from the
  classes the manifest actually contains, in first-seen order. A manifest
  without the key gets a message telling you to re-render, not a traceback.

`arena.MapSizeNames` and `arena.mapSizeScale` now read the same table, and
`arena.MinCorridorWidth` is exported so tools and tests stop re-declaring it
(`tests/test_burrow.nim` carried its own copy).

---

## 9. The API the structure pass calls

```nim
import ctf/map_rules      # or ctf/sim, which re-exports it through arena

let r = mapRules("giant", 6)          # by size name + team count
let r = mapRules(mszGiant, 6)         # by class enum
let r = mapRules(mszGiant, 4, boardHex)   # explicit family (hex conversion)

if not r.supported: echo r.unsupportedReason
```

`MapRules` fields, grouped: identity (`sizeClass`, `sizeName`, `scale`,
`teamCount`, `family`, `boardWidth/Height`, `playfieldPx`, `crossSectionPx`,
`traversePx`, `coneCoverage`, `regime`); support (`supported`,
`unsupportedReason`); cover (`coverSizePx`, `wallSpanPx`,
`meanFreeSightlineMin/MaxPx`, `coverPermilleMin/Max`, `coverPieces`); routes
(`laneCount`, `laneWidthPx`, `lanePitchPx`, `chokepointSpacingPx`,
`chokepointsPerRoute`, `maxOpenRunPx`, `maxExposedRunPx`,
`minCorridorWidthPx`); fill (`trenchSharePermille`, `trenchPermille`,
`trenchSizePx`, `trenchCount`, `pickupCount`, `minPickupSpacingPx`,
`hubRadiusPx`); layout (`symmetryGroup`, `mirroredTeams`, `seatPlans`, `seats`,
`baseSeparationPx`); ranges (`gunRangePx`, `visionRangePx`,
`grenadeMaxRangeTodayPx`, `grenadeMaxRangeRecommendedPx`,
`grenadeOutRangesGun`).

Table helpers: `MapSizeClassTable`, `DrawableSizeNames`, `sizeClassOf(name)`,
`findSizeClass(name)`, `sizeClassOfWidth(w[, family])`, `boardDims`,
`playfieldPx`, `knownWidths`, `supportedSizeNames(teams)`,
`familyForTeams(teams)`, `seatPlans(teams)`, `seatsFit(total, teams)`,
`nearestSeatPlan(teams)`, `mirroredTeams(teams)`,
`minCircumradiusForTeams(teams)`. From `arena`:
`gameMap.mapSizeClass()` / `mapSizeClassName()`.

**Purity.** `map_rules` reads only compile-time constants from `sim_types`; it
must never read the mutable installed-map globals (`MapWidth`, `MapHeight`,
`FovGridW`, ...), because a rules table that depended on them could not
describe a class other than the one currently loaded. It imports `hex` for the
hex board table. (`GrenadeMaxRange` and `ShoutRange` were on that forbidden
list until GV38 made them compile-time constants; the module reads
`GrenadeMaxRange` now, which is how `grenadeMaxRangeTodayPx` reports what the
sim actually ships rather than a copy of the formula.)

---

## 10. Full tables

Produced by the module itself (`mapRules` over every class x team count).
`regime` and the invariant lengths are omitted where they repeat.

### 2 teams — rect 1235x659 x scale, group C2, 0 mirrored, sized for 16 seats

| class | board | playfield | cone | regime | cover ‰ | sightline | coverSize | pieces | lanes | laneW | chokes | maxOpen | trench ‰ | trenches | pickups | hub |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| small | 1050x560 | 588,000 | 4.418 | occlusion | 39-156 | 262-1050 | 52 | 27 | 3 | 158 | 1 | 1050 | 32 | 7 | 2 | 215 |
| standard | 1235x659 | 813,865 | 3.192 | occlusion | 42-168 | 262-1050 | 56 | 35 | 3 | 158 | 1 | 1050 | 35 | 9 | 2 | 215 |
| large | 1606x857 | 1,376,342 | 1.887 | occlusion | 48-192 | 262-1050 | 64 | 51 | 4 | 124 | 2 | 1050 | 40 | 13 | 2 | 215 |
| huge | 2223x1186 | 2,636,478 | 0.985 | mixed | 37-112 | 525-1575 | 75 | 44 | 5 | 124 | 2 | 1312 | 49 | 23 | 2 | 262 |
| giant | 3211x1713 | 5,500,443 | 0.472 | mixed | 45-135 | 525-1575 | 90 | 78 | 6 | 124 | 3 | 1312 | 60 | 41 | 2 | 262 |
| colossal | 6422x3427 | 22,008,194 | 0.118 | range | 64-96 | 1050-1575 | 128 | 137 | 3 | 158 | 6 | 1575 | 80 | 107 | 6 | 525 |

### 3 teams — hex, group C3, 0 mirrored, sized for 15 seats

| class | board | playfield | cone | regime | cover ‰ | coverSize | lanes | laneW | chokes | trenches | pickups | hub | base sep | ships |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| small | 824x951 | 586,387 | 4.430 | occlusion | 39-156 | 52 | 4 | 124 | 1 | 7 | 3 | 208 | 617 | **NO** |
| standard | 969x1119 | 811,668 | 3.200 | occlusion | 42-168 | 56 | 5 | 124 | 1 | 9 | 3 | 208 | 726 | **NO** |
| large | 1260x1455 | 1,372,939 | 1.892 | occlusion | 48-192 | 64 | 6 | 124 | 1 | 13 | 3 | 208 | 944 | **NO** |
| huge | 1744x2014 | 2,631,494 | 0.987 | mixed | 37-112 | 75 | 8 | 124 | 1 | 23 | 3 | 262 | 1307 | yes |
| giant | 2519x2909 | 5,491,758 | 0.473 | mixed | 45-135 | 90 | 9 | 124 | 2 | 41 | 3 | 262 | 1888 | yes |
| colossal | 5039x5819 | 21,983,313 | 0.118 | range | 64-96 | 128 | 4 | 124 | 4 | 107 | 6 | 525 | 3778 | yes |

### 4 teams — square 960 x scale, group V4, **2 mirrored**, sized for 16 seats

| class | board | playfield | cone | regime | cover ‰ | coverSize | pieces | lanes | laneW | chokes | trenches | pickups | hub |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| small | 816x816 | 665,856 | 3.901 | occlusion | 39-156 | 52 | 30 | 4 | 124 | 1 | 8 | 4 | 215 |
| standard | 960x960 | 921,600 | 2.819 | occlusion | 42-168 | 56 | 39 | 5 | 124 | 1 | 10 | 4 | 215 |
| large | 1248x1248 | 1,557,504 | 1.668 | occlusion | 48-192 | 64 | 58 | 6 | 124 | 1 | 15 | 4 | 215 |
| huge | 1728x1728 | 2,985,984 | 0.870 | mixed | 37-112 | 75 | 50 | 8 | 124 | 2 | 26 | 4 | 262 |
| giant | 2496x2496 | 6,230,016 | 0.417 | mixed | 45-135 | 90 | 88 | 8 | 124 | 2 | 46 | 4 | 262 |
| colossal | 4992x4992 | 24,920,064 | 0.104 | range | 64-96 | 128 | 155 | 4 | 124 | 5 | 122 | 8 | 525 |

### 6 teams — hex, group C6, 0 mirrored, sized for 24 seats

| class | board | cone | regime | coverSize | lanes | chokes | trenches | pickups | hub | adjacent base sep | ships |
|---|---|---|---|---|---|---|---|---|---|---|---|
| small | 824x951 | 4.430 | occlusion | 52 | 4 | 1 | 7 | 6 | 263 | 356 | **NO** |
| standard | 969x1119 | 3.200 | occlusion | 56 | 5 | 1 | 9 | 6 | 263 | 419 | **NO** |
| large | 1260x1455 | 1.892 | occlusion | 64 | 6 | 1 | 13 | 6 | 263 | 545 | **NO** |
| huge | 1744x2014 | 0.987 | mixed | 75 | 8 | 1 | 23 | 6 | 263 | 755 | **NO** |
| **giant** | 2519x2909 | 0.473 | mixed | 90 | 9 | 2 | 41 | 6 | 263 | **1090** | **yes** |
| colossal | 5039x5819 | 0.118 | range | 128 | 4 | 4 | 107 | 6 | 525 | 2181 | yes |

---

## 11. What this stage did NOT do

- No structure pass, no biome layer, no ranker.
- **No generator output changed.** `MinCorridorWidth` stays 26,
  `CoverPermilleMin/Max` stay 40/170, the RNG draw order is untouched, and
  `MapSizeNames` is the same five names in the same order.
  `tests/fixtures/map-validation-baseline.tsv` and the pool are unchanged; the
  pool review page is regenerated only because the manifest gained a
  `sizeClass` key. (The GV38 follow-up moved `GrenadeMaxRange` and
  `ShoutRange`, which are weapon reaches read by the sim — it changed no
  geometry, so the generator output and the validation baseline still stand.)
- The soft input is isolated: `FieldAccuracyPct` = 55 (from GV26-GV36 scout
  re-simulations, 48-61%). It is the ONE number in the module that is measured
  rather than derived, it lives in one place, and halving it doubles
  `maxExposedRunPx` and `wallSpanPx`. Everything else follows from
  `sim_types`.

---

# Addendum, 2026-08-05: population fit, and the two axes

Three things landed after the original write-up, and two of them change numbers
above rather than merely adding to them.

## A1. `GunRange` is a REACH, not an engagement range

Aim is exactly `AimRotations` = 32 slots, 11.25 deg apart, and the sim
reconstructs `aimBrads = slot * AimStepBrads` every tick, so an off-grid angle
cannot persist. There is no aim assist anywhere in the sim. A shot is accepted
against the 13 px SOLID body within `BulletHalfWidth` = 8, so the angular
acceptance is `atan(14/t)` against a half-slot of 5.625 deg — and the jitter
sigma of 0.596 deg is **9.4x smaller than the half-slot**, so the LATTICE
decides, not the jitter.

    R_slot = 14 / tan(5.625 deg) = 142 px      (below this, a centred body
                                                cannot be missed)
    P(hit) ~= atan(14/t) / 5.625 deg           0.47 at 300 px, 0.14 at 1050 px

Three independent constants converge on one envelope, which is why this is a
constant and not a guess:

| evidence | implies |
|---|---|
| `FieldAccuracyPct` = 55 is achieved at | **259 px** |
| `GrenadeMaxRange` = `GunRange div 4` | 262 px (agrees to 1.1%) |
| observed 1.0-1.9 s TTK band | 142-225 px |

So `LethalEnvelopePx = 259`, and **every derived number now declares which
axis it lives on**:

- **Awareness** (what you can SEE) — `coneCoverage`, the visibility regimes,
  the mean-free-sightline band and the entire cover budget that follows from
  it. UNCHANGED. Sightlines were always the right clock for cover, which is
  why the retro-validation against the shipped 40/170 band still holds.
- **Lethality** (what you can KILL) — chokepoint spacing, pickup spacing, and
  the contact clock the population law is banded against.

Moved: `ChokepointSpacingPx` 1050 -> 259, which was ~4x too large and produced
~4x too few chokepoints (per-route counts go 1/1/2/2/3/6 -> 4/5/6/9/12/25).
`MinPickupSpacingPx` likewise, since COVERING a pickup is a lethality question.
`MaxExposedRunPx` = 132 survives, because `TicksToKill` = 48 corresponds to a
~237 px engagement — inside the envelope, not out at the reach.

`HubRadiusCapPx` stays on the awareness axis, with the tension **stated rather
than resolved**: the lethality reading gives 130 px, below the 215 px occupancy
floor a 16-seat hub fight needs. No board satisfies both.

**Open dependency, flagged in the constant itself:** no hit-rate-versus-range
measurement from the field has been taken. Everything gated on
`LethalEnvelopePx` moves together if one is.

## A2. Board area as a function of roster

Size was drawn UNIFORMLY over all five classes and `teams` chose only the shell
FAMILY, so a 1v1 landed on giant as often as on small — 2,750,000 px^2 per
player against the tuned board's 50,900, a factor of **54**.

**The anchor.** One configuration is known-good because it has been played and
tuned over many versions: 2 teams x 8 units on 1235x659 = 813,865 px^2.
Everything derives from it and nothing else.

**Why constant density is wrong.** `A = 50,900 * P` puts a 1v1 on 101,733 px^2
— a 319 px board, smaller in every dimension than the gun's own reach. Constant
density has no floor, and the floor is set by the WEAPON, which does not care
how many people are holding one.

**The law.** Contact is kinetic, `t_find = A / (n_e * w * v_rel)`, so holding
time-to-contact fixed gives `A` proportional to `n_e` — the count of
OPPONENTS, not of players, because five sixths of a 6-team field is hostile and
only half of a 2-team one is. Hinged against the floor:

    A_target(n_e) = max( smallest class , 101,733 * n_e )

**The exponent.** The density term's exponent is exactly 1, the floor term's is
exactly 0, and the law is the hinge between them at **5.78 opponents**. Fitted
as a power law across the realistic roster range it comes out **0.455** — so
"board area grows as the square root of headcount" is a decent slogan and a bad
implementation, because below six opponents the answer does not depend on
population at all.

**Cover is part of the answer.** `w` is not a constant: you engage at the
distance terrain allows, so substituting `lambda = pi*m/phi` gives
`t_find ∝ A * phi`. Time to contact is proportional to COVER FRACTION, so an
over-sized board buys contact back by carrying LESS cover — the same conclusion
the visibility regimes reached from the other end. `coverPermilleTarget` is
emitted clamped into the class band, with `coverCompensationSaturated` when the
board is too big for its roster by more than cover can repay.

## A3. Separation versus density, resolved

| | |
|---|---|
| Separation | a HARD lower bound from team count (6 teams need giant) |
| Density | a SOFT target from population (6x1 wants small) |
| They differ by | **9.4x** at 6 teams x 1 unit |

**Separation wins, always** — the failure modes are not comparable. Violating
separation means being shot on the spawn pad, which no skill or terrain
recovers. Violating density means a sparse but valid match, which cover
compensation partly repairs. A hard constraint beats a soft one.

It is then **reported, not papered over**. Bands, all derived from the player's
own loop rather than from `MaxTicks` (5000 is a safety cap, not a match length):

    draw band     [FireCooldownTicks, RespawnTicks] / t_tuned = [0.24, 1.43]
    legality      (TicksToKill + RespawnTicks) / t_tuned      =  2.38

i.e. a configuration stops being a match once first contact costs more than the
fight and the respawn put together.

### The legality matrix

| mode | P | opponents | resolved | stress | contact | verdict |
|---|---|---|---|---|---|---|
| 2 x 1 | 2 | 1 | small | 1.00 | 12.2 s | good (floor-bound) |
| 2 x 4 | 8 | 4 | small | 1.00 | 3.0 s | good |
| 2 x 8 | 16 | 8 | **standard** | **1.00** | 2.1 s | good — reproduces the anchor |
| 2 x 16 | 32 | 16 | large | 0.85 | 1.8 s | good |
| 3 x 5 | 15 | 10 | huge | 2.59 | 5.4 s | UNSUPPORTED |
| 3 x 8 | 24 | 16 | huge | 1.62 | 3.4 s | stressed |
| 4 x 4 | 16 | 12 | standard | 0.75 | 1.6 s | good |
| 4 x 8 | 32 | 24 | huge | 1.22 | 2.6 s | good |
| 6 x 1 | 6 | 5 | giant | **9.37** | 22.7 s | UNSUPPORTED |
| 6 x 4 | 24 | 20 | giant | 2.70 | 5.7 s | UNSUPPORTED |
| 6 x 5 | 30 | 25 | giant | 2.16 | 4.5 s | stressed |
| 6 x 6 | 36 | 30 | — | — | — | UNSUPPORTED (over `MaxPlayers`) |

Conclusions that fall out rather than being asserted:

- **A 1v1 gets `small`**, and its draw set is {small, standard}. Directly
  Maxwell's ask.
- **6-team FFA is viable only at a FULL 30-seat roster**, and even that is
  stressed. 6x1, 6x2 and 6x4 are all unsupported.
- **3-team FFA needs 8 units per side**, not 5.
- **"FFA6 with 6 units each" does not fit `MaxPlayers` = 32** — it is 36 seats.
  6 teams top out at 5 each.

## A4. Wiring, and the churn

`generateMapAttempt` gained `unitsPerTeam` (0 = "caller does not know",
resolving to the seat plan nearest the shipping roster) and draws its size from
`legalSizeNames(teams, unitsPerTeam)` instead of uniformly over five.

Measured churn on `tests/fixtures/map-validation-baseline.tsv`:

| | before | after |
|---|---|---|
| rows differing | — | **161 / 402 (40.0%)** |
| verdicts flipped | — | 113 |
| 2-team first-attempt pass | 92.0% | **79.1%** |
| 4-team first-attempt pass | 47.3% | **36.8%** |

**The pass rate DROPS, and that is expected rather than a regression.** The
draw now concentrates on the smaller classes, and per section 5 those are
exactly the ones the column generator is worst at (22-23% per attempt at 4
teams, against 58-78% on the three largest). Best-of-K absorbs it —
`MapSelectionK` is already 12 for small and 8 for standard — but attempt cost
rises, and this is a direct message to the structure pass: **the classes real
rosters actually want are the classes today's generator handles worst.**

The curated pool was re-generated (41 seeds scanned, 0 rejected, mean
`staticScore` 0.947) and is now 10 small + 10 standard. `SizeQuota`'s three
largest rows are 0 because those classes are now UNREACHABLE for a 2-team
pool at the shipping roster — the old 4/5/4/4/3 asked for eleven maps the
generator can no longer draw, which is an infinite scan, not a slow one.
`docs/pool-review.html` and the 20 `PoolRenderHashes` were regenerated with it.
