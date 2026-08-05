# What makes a competitive shooter map good — formalised for Coworld CTF

**Research dimension: THE OBJECTIVE.** Every other strand of the map-generator rewrite covers a
*technique*. This document covers the *target*: "always good" is meaningless until "good" is a
formal, measurable property, because a generator can only guarantee what someone has written down.

**Status:** research note. It proposes a property set, thresholds, and an evidence classification.
It does not change any source. Numbers marked **[engine]** are read out of `src/ctf/sim_types.nim`,
`src/ctf/map_rules.nim` and `src/ctf/sim.nim` on this branch; numbers marked **[measured]** come from
our own episode re-simulations; numbers marked **[lit]** are cited; claims marked **[folklore]** are
confident published assertions with no evidence behind them.

---

## 0. The three headline results

Read these first; the rest of the document is their derivation and their consequences.

**0.1 — Our movement metric is L∞ (Chebyshev), not Euclidean, and nothing in our metric suite
knows it.** `sim.nim` clamps `velX` and `velY` independently to `±maxSpeed` with no diagonal
normalisation **[engine]**. The set of achievable average velocities is therefore the *square*
`[−v, v]²`, not the disc of radius `v`. Sustained speed along a heading θ is

```
    v(θ) = v / max(|cos θ|, |sin θ|)          v = 2.75 px/tick = 66 px/s
    v(0°) = 66 px/s          v(45°) = 93.3 px/s          → 41.4% anisotropy
```

Travel time between two points is `max(|dx|, |dy|) / v`, not `√(dx²+dy²) / v`. Every distance-derived
quantity we compute — time-to-contact, "equal distance from both spawns", lethal exposure run,
detour budgets — is wrong by up to 41% in a *heading-dependent* way. This is the single largest
unmodelled term in the objective.

**0.2 — The exact fairness group of this game is D4, so 3- and 6-team maps cannot be made exactly
fair by any rotation.** Movement is 8-way d-pad, quantised to 45°; aim is 32 slots, quantised to
11.25° (`AimRotations = 32`, `AimStepBrads = 8`) **[engine]**. A team-permuting isometry must
preserve *both* lattices *and* the L∞ metric. The isometry group of L∞ in the plane is D4 (order 8:
rotations by 0/90/180/270° and reflections about the two axes and the two diagonals). k-fold
rotational symmetry is exact iff `k ∈ {2, 4}`. For k = 3 the required 120° rotation is
`256/3 = 85.33` brads — not even an integer number of brads, let alone a multiple of the 8-brad aim
step, and it maps the d-pad's 8 headings off-lattice entirely. This is the mechanical root of the
already-recorded "C4 is not in D6" finding, and it is *stronger* than the aspect-ratio argument: no
board shape can fix it.

**0.3 — Our measured 10–25% stand-side cover band is not an empirical accident; it is the
carrier-speed exposure inequality.** A square lattice of `BaseCoverSizePx = 56` blocks with gap `g`
has wall fraction `f = 56² / (g + 56)²`. Setting `g` equal to the distance a *carrier* covers in one
time-to-kill (`CarrierSpeedPct = 70`, `TicksToKill = 48`, so 92 px axis-aligned / 131 px diagonal)
gives `f = 14.3%` and `f = 9.0%` respectively — the centre and the floor of the measured band.
Setting `g` for a *non-carrier* at full speed (132 px / 187 px) gives 8.9% and 5.3%. That is why the
invariant is *specific to the pedestal*: the pedestal is the only place where anyone is moving at
0.7×. The global validator band (4–17%) is roughly right for full-speed traffic and fatally too loose
at the stand. See §3.4 for the full derivation.

---

## 1. The engine's own geometry

Published FPS design guidance is only usable if the scale bridge is sound. This section fixes it and
finds one place where the currently-assumed bridge is wrong.

### 1.1 Constants **[engine]**

| Quantity | Symbol / source | Value |
|---|---|---|
| Gun range | `GunRange` | **1050 px**, frozen since GV34 |
| Vision range | `1.5 × GunRange` | 1575 px |
| Vision cone | `VisionConeDeg = 60` (half-angle) | **120° full**, rides the aim |
| Drawn body / hitbox | `SoldierBodyPx = 34`, `PlasmaArcBodyRadius = 17` | 34 px |
| Solid collision footprint | `PlayerHalf = 6` | 12–13 px |
| Speed | `MaxSpeed / MotionScale = 704/256` | 2.75 px/tick = 66 px/s at 24 Hz |
| Carrier speed | `CarrierSpeedPct = 70` | 1.925 px/tick = 46.2 px/s |
| Time to kill | `TicksToKill = (3−1) × FireCooldown` | 48 ticks = 2.0 s (observed band 1.0–1.9 s) |
| Fire windup | `FireWindupTicks = 5` | 0.21 s |
| Lethal exposure run | `MaxExposedRunPx` | **132 px** axis-aligned (see §0.1 — 187 px diagonal) |
| Aim lattice | `AimRotations = 32`, `AimStepBrads = 8` | 11.25° per slot |
| Aim turn rate | `AimTurnRate = 1` slot/tick (league 5 ≈ 5 slots/tick) | 11.25°/tick default; 56.25°/tick live |
| Grenade / shout radius | `GunRange div 4` | 262 px on every board |
| Grenade blast | `GrenadeBlastRadius = 52` | 52 px |
| Nominal cover piece | `BaseCoverSizePx = 56` | scaled by `√sizeScale` |
| Recommended corridor | `2 × SoldierBodyPx` | 68 px |
| Endzone radius | `EndzoneRadiusMin/Max` | 90–220 px |
| Objective | capture-the-heart: steal from enemy pedestal, carry home | conversion decides matches **[measured]** |

Two body sizes matter and they are 2.8× apart. **Use 34 px for anything combat-geometric** (hit
tests use the drawn body; sightlines, cover width, angle counts, silhouette occlusion). **Use 12 px
only for passability.** Source-engine geometry has no analogue of this split — there the collision
hull *is* the functional body — so every imported Source number must be anchored to 34 px.

### 1.2 The scale bridge, and a correction to it

The working bridge is: Source/GoldSrc/CS player width = **32 Hammer units**
([Valve, *GoldSrc Dimensions*](https://developer.valvesoftware.com/wiki/GoldSrc_Dimensions);
[Valve, *CS:GO Mapper's Reference*](https://developer.valvesoftware.com/wiki/CS:GO_Mapper%27s_Reference)),
matched to our 34 px drawn body → **1 HU ≈ 1.0625 px**.

Two independent checks:

- **Corridors — the bridge holds.** Valve: "a corridor must be wider than 32 units to be accessible",
  and 64 units is the standard HL2 hallway **[lit]**. 64 HU × 1.0625 = 68 px = exactly our
  `RecommendedCorridorWidthPx = 2 × SoldierBodyPx`. This agreement is real and was arrived at
  independently, which is good evidence the bridge is anchored correctly.

- **Weapon range — the bridge does *not* hold, and the brief's 4% agreement is an artefact.** The
  1024-unit figure is TF2's damage-falloff distance
  ([TF Wiki, *Damage*](https://wiki.teamfortress.com/wiki/Damage): 150% at 0 units, 100% at 512,
  50% at ≥1024). But **TF2 does not use the 32-unit player.** TF2's own mapper reference gives the
  player as **49 units wide, 83 tall**, and instructs mappers porting from standard-scale games to
  "scale the entire map (and all props) up 1.5×"
  ([Valve, *TF2 Mapper's Reference*](https://developer.valvesoftware.com/wiki/Team_Fortress_2/Mapper%27s_Reference)).
  Normalised by each game's own player width — the only defensible comparison — TF2's medium-range
  cap is `1024/49 = 20.9` body-widths, while our `GunRange` is `1050/34 = 30.9` body-widths.
  **Our gun reaches ~48% further, relative to the player, than TF2's "medium range".** Applying the
  32-HU bridge to a 49-HU game produced a spurious 4% match.

  This is not a small correction. It says our weapon is *long* by shooter conventions, which is
  exactly consistent with the occlusion-limited regime finding in §5: on our small/standard/large
  boards the gun outranges the playfield, and no published FPS geometry guidance was written for
  that situation.

  Other useful TF2 anchors, in TF2 body-widths, for reference: sentry detection range 1100 HU =
  22.4 bw; sticky-jump max 1600 HU = 32.7 bw; explosion radius 146 HU = 3.0 bw (ours: 52/34 =
  1.5 bw — our grenade is *half* as wide relative to the player as a TF2 rocket).

### 1.3 The two lattices

- **Movement lattice.** `inputX, inputY ∈ {−1, 0, +1}` **[engine]** → 8 headings, 45° apart, with no
  normalisation. Velocity polytope = square. Symmetry group = D4.
- **Aim lattice.** 32 slots at 11.25°. Symmetry group = D32 ⊃ D4.
- **Shot geometry is achiral.** The muzzle offset exists only in `rig_art.nim` / `broadcast.nim`
  (art); the simulated shot originates on the body along the aim axis **[engine]**. So unlike a
  real FPS — where a right-shoulder weapon makes right-hand corners genuinely easier and mirror
  symmetry genuinely unfair — **reflection is a legitimate fairness operation for us**, provided the
  mirror axis is in D4 (0°, 45°, 90°, 135°).

The intersection is **D4**. Any team-permuting map transform outside D4 introduces a *measurable*
residual asymmetry; §3.2 gives the metric.

---

## 2. What the literature actually says (and how much of it is evidence)

Sorted by evidential weight, strongest first. This ordering matters: a great deal of level-design
writing is confident, widely repeated, and completely unevidenced.

### 2.1 Primary, evidence-bearing

**Güttler & Johansson (2003), "Spatial Principles of Level-Design in Multi-Player First-Person
Shooters", NetGames 2003.**
[PDF](https://svn.sable.mcgill.ca/sable/courses/COMP763/oldpapers/guttler-03-spatial.pdf).
The origin of the **collision point**: "the location that marks the clash of players and hence the
set of relevant tactical choices". Their claims, verbatim where load-bearing:

- The collision point is *not* authored directly; it is "a result of the distance between the two
  teams' starting points and the location of hostages or bomb targets". It is therefore **derivable
  statically** — which is exactly what our generator should be doing.
- Fairness criterion: on de_dust "the two teams are able to reach the collision zone almost
  simultaneously, as the distances from their respective starting points are approximately equal".
  **Equal time-to-contact is the operative fairness test, not geometric symmetry.**
- Cover must be concentrated *at* the collision point: it "is equipped with fairly many objects
  usable for affording cover to the players, as well as ... differentiated height of terrain".
- Contact must be *forced*: "It is not in principle necessary for the two teams to meet, but in case
  they don't, the game will be reduced to a race against time."
- Multiple objectives are necessary for tactical choice: their worked examples A→B→C show that
  adding cover alone (B) still fails because "the opponent team ... easily can predict how the
  terrorists will move"; only adding a *second* objective (C) makes the level winnable for both
  sides.
- **The paper's own negative result is the most valuable part.** Their `cs_citymall` was
  architecturally excellent and failed: "the players collide in a completely other area of the level,
  where almost no cover was available, because the collision points wasn't anticipated in the design
  phase ... almost half the level wasn't used." Predicting the collision point statically is
  *necessary*; verifying it by play is *also* necessary. Neither substitutes for the other.

**Hullett & Whitehead (2010), "Design Patterns in FPS Levels", FDG 2010.**
[PDF](https://users.soe.ucsc.edu/~ejw/papers/hullett-fps-fdg2010.pdf).
Ten patterns in four families — Positional Advantage (*sniper location, gallery, choke point*),
Large-scale Combat (*arena, stronghold*), Alternate Gameplay (*turret, vehicle section*), Alternate
Routes (*split level, hidden area, flanking route*). Each has explicit *affordances* (the parameters
a designer varies) and *consequences*. **Caveat the paper states itself:** "The design patterns
presented in this paper were developed from an analysis of single-player levels." They are a
vocabulary, not a spec, and their pacing/tension consequences are about a solo player versus scripted
NPCs.

Directly reusable affordance lists (these are good generator parameters):
- Choke point: *width of the opening*, *length*. "Increasing the width lessens the effects as more
  characters are able to move through at a time. Increasing the length can also reduce effects as
  characters have a place to retreat to."
- Stronghold: *size*, *amount of cover*, *number and type of access points*.
- Flanking route: *the position that can be reached by flanking*, *the amount of cover while
  flanking*.

**Hullett (2012), "The Science of Level Design", PhD dissertation, UC Santa Cruz.**
[PDF](https://users.soe.ucsc.edu/~ejw/dissertations/Ken-Hullett-dissertation.pdf) ·
[eScholarship](https://escholarship.org/uc/item/1m25b5j5).
This is the *empirical* version — an n-subject user study logging in-game behaviour against pattern
variants, with significance testing at p < 0.05. It also has a dedicated **multiplayer** chapter that
the FDG paper does not, and that chapter is the closest thing in the literature to a spec for our
game type:

- **Conflict point** (the multiplayer generalisation of collision point): "a location in a level
  which is designed to bring opposing forces into an encounter ... designers can utilize elements of
  a conflict point such as chokepoints, strongholds, pickups, and objectives."
- **CTF specifically:** "The flag's starting location serves as a point of conflict, and is often a
  strongly fortified location, making defense easy and requiring coordinated offense to capture ...
  Flag carriers are encouraged to use alternate paths and shortcuts in order to evade the opposing
  team. Levels are often symmetric to ensure balance. Respawn times are long, allowing a team to
  press their advantage."
- **Respawn is a level-design variable, not a rules variable:** "More strategic game types such as
  Capture the Flag utilize a longer respawn time, and place the player *further from the main
  conflict points*."
- **Balance is defined by opportunity, not geometry:** "Multiplayer level balancing focuses on
  design decisions which give players an equal opportunity at successfully attaining the intended
  gameplay experience."
- **Multiplayer inverts single-player patterns:** "In Halo: Combat Evolved single-player, a sniper
  location provided a significant advantage to the player. In the multiplayer game, players in sniper
  locations must also be wary of counter attack from *the complementary sniper location on the other
  side of the level*." Every power position must have a counter-position. This is a *pairing*
  constraint on power positions, and we have nothing like it.

**Ballabio & Loiacono (2019), "Heuristics for Placing the Spawn Points in Multiplayer First Person
Shooters", IEEE CoG 2019.** [PDF](https://ieee-cog.org/2019/papers/paper_59.pdf).
The only formal treatment of spawn placement we found. Two principles — **safety** and
**uniformity** — operationalised on a *visibility graph*:

```
    t* = argmax_t ( w_v·v(t) + w_hw·h_w(t) + w_he·h_e(t) )     w = (1, 0.5, 0.5)

    v(t)   = 1 − normalised degree of t in the visibility graph   → prefer LOW visibility
    h_w(t) = normalised distance from the room's walls            → prefer OPEN within the room
    h_e(t) = normalised distance to the nearest placed element    → prefer SPREAD
```

Validated by a "Target Reaching" user task: heuristic placement cut average search time 18% and
search distance 21% vs uniform placement, Wilcoxon signed-rank significant, with the effect largest
on maps with heterogeneous visibility. Their companion item-placement guidelines are equally
relevant and equally absent from our suite: "very strong weapons should be placed in areas that are
strategically disadvantageous, like dead ends or vertically dominated areas, or difficult to reach";
"mid-power weapons ... should be placed in areas that are easy to reach".

**Cardamone, Yannakakis, Togelius & Lanzi (2011), "Evolving Interesting Maps for a First Person
Shooter", EvoApplications / LNCS 6624.**
[Springer](https://link.springer.com/chapter/10.1007/978-3-642-20525-5_7).
The first search-based FPS map generator. Fitness = **average fighting time** from simulated bot
deathmatches in Cube 2: Sauerbraten; four representations compared. The important methodological
point is that the fitness is *simulation-derived*: they could not find a static proxy that worked.

**Lanzi et al., and the MAP-Elites successor (2026), "Procedural Generation of First Person Shooter
Maps using Map-Elites".** [arXiv:2605.30570](https://arxiv.org/html/2605.30570v1).
Fitness = **entropy of the kill distribution**, `H = −Σ (k_i/k_tot) log₂ (k_i/k_tot)`, averaged over
five simulated matches between bots of deliberately mismatched skill (15% and 85%) — "the higher the
entropy, the more balanced the match". Behavioural characteristics for the archive: `area`,
`maxSymmetry = max(xSymmetry, ySymmetry)`, `pace`, `averageEccentricity`.

Their metric inventory is the most complete published one — **69 metrics, split 46 topological
(computable from layout alone) and 23 emergent (require simulation)**. That split is the single most
directly transferable artefact in this literature; §7 adopts it. Their **pace** formula is worth
copying verbatim because it is the only published normalisation of encounter frequency:

```
    pace = 2·(1 + exp(−5·N_x / Σ T_e))⁻¹ − 1
```

where `N_x` = number of fights and `T_e` = time to engage; tuned so pace ≈ 0.9 when the average time
to engage is ~3 s. Also notable: they compute a **visibility matrix** — "for each tile the number of
tiles that are visible from it" — and derive average visibility, visibility local maxima, and maximum
visibility. That is a visibility-graph degree field, and it is what both the spawn heuristic above
and our missing "how many angles cover this point" metric are built on.

**Liapis, Yannakakis & Togelius (2013), "Sentient Sketchbook: Computer-Aided Game Level Authoring",
FDG 2013.** [PDF](http://www.fdg2013.org/program/papers/paper28_liapis_etal.pdf).
Strategy-game maps, but the *architecture of the objective* is exactly what we need — a hard
**playability constraint** plus **paired quality/balance fitnesses**:

- Constraint (feasibility): "A map is playable (or feasible) if all resources and bases are reachable
  from any other base or resource." Infeasible maps go in a separate population (FI-2pop GA).
- Quality: `f_res` resource safety, `f_saf` safe area ("the number of tiles around a base which are
  close only to that base"), `f_exp` exploration (flood-fill from enemy bases until discovery).
- **Every quality metric has a paired balance metric** `b_res`, `b_saf`, `b_exp`, "which have high
  values if all bases have equally safe resources, a similar number of safe tiles and are equally
  difficult to find from enemy bases".
- Navigation metrics displayed alongside: shortest path lengths between bases, **percentage of used
  space** ("passable tiles which are on a shortest path between any two bases or any base and any
  resource"), number of chokepoints, dead ends and open areas, and a **segment decomposition**
  ("passable areas which are surrounded solely by chokepoints").

The quality/balance *pairing* is the structural idea we are missing: for every property P we measure
on a map, we should also measure `spread(P)` across teams. A map can have excellent mean cover and
be unplayable because one team's share of it is zero.

**Turner, Doxa, O'Sullivan & Penn (2001), "From isovists to visibility graphs: a methodology for the
analysis of architectural space", Environment and Planning B 28(1):103–121.**
[UCL Discovery](https://discovery.ucl.ac.uk/160/1/turner-doxa-osullivan-penn-2001.pdf) ·
[journal](https://journals.sagepub.com/doi/10.1068/b2684).
Builds on **Benedikt (1979), "To take hold of space: isovists and isovist fields"**, Environment and
Planning B 6:47–65, which defines the isovist (the region visible from a point) and the scalar
measures extracted from it: area, perimeter, occlusivity, variance, skewness, circularity. Turner et
al. generalise from per-point isovists to a **visibility graph** over a grid of open cells, on which
standard graph measures become spatial ones: *connectivity* (degree = isovist area), *integration*
(inverse mean depth = how easily the whole space is reached visually), *control*, and the
*clustering coefficient* (how convex/enclosed the local visual field is). Implemented in the
open-source depthmapX. **This is the mathematically mature version of everything we currently
approximate with hand-rolled scalars, and the clustering coefficient is a principled replacement for
`interiorFrac` (see §6.4).**

**Togelius, Yannakakis, Stanley & Browne (2011), "Search-Based Procedural Content Generation: A
Taxonomy and Survey", IEEE TCIAIG 3(3).**
Supplies the standard three-way classification of evaluation functions — **direct** (compute a score
from the artefact), **simulation-based** (play it with an agent), **interactive** (ask a human) — and
the observation that direct functions are cheap and usually deceptive while simulation-based
functions are expensive and usually valid. §7 is this distinction applied to our metric suite.

**Smith & Whitehead (2010), "Analyzing the expressive range of a level generator", PCG @ FDG 2010.**
Expressive-range analysis: sample the generator's output, plot it in a 2-D metric space, and look at
what it *cannot* produce. Empty regions "suggest that the generator cannot produce outputs with these
specific metric values regardless of parameter tweaking". **Our 96% first-attempt validator pass rate
is the classic symptom of a generator whose expressive range has never been plotted** — the
validators sit outside the generator's range and are therefore a crash guard, not a filter.

### 2.2 Curated secondary — useful, cites its sources, still not evidence

**The Level Design Book** (Robert Yang et al.), [balance](https://book.leveldesignbook.com/process/combat/balance)
and [circulation](https://book.leveldesignbook.com/process/layout/flow/circulation). The best-organised
compendium of practice, and it does cite its sources (Sirlin on balance; Griesemer's GDC 2010
"Design in Detail"; Garozzo & Snelling's GDC 2015 CS:GO community level design talk). Positions worth
recording:

- Balance vs fairness: **balance** is "the real and perceived fairness of player positioning
  throughout a level"; **fairness** is "the player's overall psychological perception of balance".
  Operationalised: "Competitive multiplayer maps should offer teams an average near-equal ~50% win
  rate." Sirlin's definition is cited: "players of equal skill have an equal chance to win, no matter
  their start conditions."
- Symmetry taxonomy: **bilateral** (duplicate, flip or rotate 180°), **radial** (duplicate, rotate,
  repeat — "rare ... accommodates multiple teams"), **asymmetrical balance** ("very hard to get
  right", "very time consuming").
- **Chokepoint distribution rule:** "Distribute 3–4 chokepoints across the map, one chokepoint per
  lane. **It should be impossible to cover all chokepoints from a single point.**" The second
  sentence is a genuinely formalisable constraint and we do not have it.
- Lanes: "most maps use only 1–3 lanes"; three-lane maps have "three bidirectional critical paths
  that occasionally branch and intersect via smaller lanes"; "lane asymmetry is important, with each
  lane feeling different".
- Balance is contextual: "Map balance matters less when teams switch sides/roles during the game."
  For us this is live — our league seats us as a *strided subset* of a team across four entrant
  policies, so per-seat balance, not per-team balance, is the quantity that matters.

### 2.3 Folklore — flagged as such

These are widely repeated and, as far as we can find, have **no published evidence** behind them.
They may still be true. They must not be encoded as generator constraints without our own test.

- **"Three lanes."** No study establishes 3 as correct, or lanes as a necessary structure. The
  evidence-bearing version of this intuition is a *graph* property (≥ 3 vertex-disjoint routes),
  which many non-lane topologies satisfy. Note also that the "popular CS maps are 3 big circular
  loops" claim and the "3 lanes" claim are different topological statements often used
  interchangeably.
- **"No long sightlines."** See §8.2 — this rule is about sniper dominance in games where weapon
  range ≪ map size. In our occlusion-limited regimes the gun outranges the board, so the rule is
  vacuous as stated and must be restated as a constraint on *exposed run*, not on sightline length.
- **"Cover every N metres."** Every source states cover cadence qualitatively. §4.3 derives it.
- **Dead ends are bad.** Güttler asserts it ("Sudden dead-ends ... are not appreciated features");
  Gee's controlled study (MIT thesis, SMU Guildhall 2008, summarised in Hullett & Whitehead) found
  "dead ends did not negatively impact FPS levels". **The literature contradicts itself here.** For
  us the relevant statement is narrower and testable: a dead end *on the carry-home route* collapses
  the route count to k = 1 and is fatal.

---


---

## 3. The math: five derivations that turn guidance into thresholds

Everything in §4 that has a number behind it comes from one of these.

### 3.1 Travel time is L∞, and headings are not interchangeable

With `velX`, `velY` independently clamped **[engine]**, the achievable average-velocity set is the
square `[−v, v]²`. Consequences:

```
    travel time between p and q (unobstructed)   t = max(|Δx|, |Δy|) / v
    speed along heading θ                        v(θ) = v / max(|cos θ|, |sin θ|)
    v(0°)   = 66.0 px/s     v(30°) = 76.2 px/s
    v(45°)  = 93.3 px/s     ← 41.4% faster than axis-aligned
    carrier: multiply by 0.70 → 46.2 px/s axis, 65.3 px/s diagonal
```

Two things follow that are not currently modelled anywhere:

1. **Path shape is free, endpoints are everything.** In open ground the L∞ time depends only on the
   endpoints, so a "staircase" route costs the same as a straight one. You cannot fix a bad heading
   by routing around it.
2. **Every equidistance argument must be redone in L∞.** The set of points equidistant from two
   bases under L∞ is *not* the perpendicular bisector; it is a piecewise-linear polyline whose
   segments run at 0°, 45° or 90°. A generator that places the "midfield seam" on a Euclidean
   bisector is placing it in the wrong place, by up to `(√2 − 1)/√2 = 29%` of the half-separation.

### 3.2 The exact fairness group is D4, and the residual for k = 3, 6 is 15.5%

A team-permuting transform `g` must preserve (a) the wall geometry, (b) the movement lattice
(8 headings, 45°), (c) the aim lattice (32 slots, 11.25°), and (d) the L∞ metric. (d) is the binding
one: the isometry group of the L∞ plane is the symmetry group of the square, **D4** (order 8). Hence:

| Teams k | Exact k-fold rotation? | Why |
|---|---|---|
| 2 | **yes** | 180° ∈ D4; 128 brads = 16 aim slots; d-pad headings map to d-pad headings |
| 3 | **no** | 120° = 85.33 brads — not an integer brad, not a multiple of the 8-brad slot, off the movement lattice |
| 4 | **yes** | 90° ∈ D4; 64 brads = 8 slots |
| 6 | **no** | 60° = 42.67 brads — same failure as k = 3 |
| 8 | **no** | 45° preserves the movement *headings* and the aim lattice but **not** the L∞ metric — it maps the velocity square to a diamond |

Reflections about 0°, 45°, 90°, 135° are all in D4 and are legitimate, because our shot geometry is
achiral (§1.3). Reflections about any other axis are not.

**The irreducible residual for k = 3 and k = 6.** Put the bases on a ring and let team *i*'s
base→contact axis have heading `θ_i`. Travel time to a point at Euclidean distance D is
`D·max(|cos θ|, |sin θ|)/v`, so team *i*'s time carries a factor `m(θ_i) = max(|cos θ_i|, |sin θ_i|)`
with `m ∈ [1/√2, 1]`. Fairness requires all `m(θ_i)` equal.

`m` has period 90° and satisfies `m(θ) = m(90° − θ)`, so each level set of `m` contains at most two
headings per period. Three headings 120° apart reduce mod 90° to `{φ, φ+30°, φ+60°}` — three
*distinct* values, so they can never all lie in one two-element level set. **No 3-fold or 6-fold
rotational layout can equalise travel speed.** Minimising the spread over φ:

```
    φ = 0°  → headings {0°, 30°, 60°},  m = {1.000, 0.866, 0.866}   spread 1.155  ← minimum
    φ = 5°  → m = {0.996, 0.819, 0.906}                              spread 1.216
    φ = 15° → m = {0.966, 0.707, 0.966}                              spread 1.366
```

**The best achievable 3-team (and 6-team) rotational map still gives one team in three a 15.5%
travel-time penalty** — equivalently, two teams in three arrive 13.4% early. For reference, 13.4% of
a 1000 px approach at 66 px/s is 2.0 s, which is exactly one time-to-kill. This is not a rounding
error; it is a decisive head start.

For k = 4 both `{0°, 90°, 180°, 270°}` (all `m = 1`) and `{45°, 135°, 225°, 315°}` (all
`m = 1/√2`, everyone 41% faster) are exactly fair. For k = 2, any opposed pair is exact.

**Partial remedy for k = 3, 6:** compensate in Euclidean distance rather than heading — set each
team's base-to-frontier distance `D_i ∝ 1 / m(θ_i)`, which restores *time*-to-contact equality
exactly. It does **not** restore local geometry equality (sightline lengths, cover cadence
requirements, and exposure budgets remain heading-dependent, per §3.3), so it is a first-order fix
only. Record the residual rather than pretending it is zero.

### 3.3 The exposure inequality — what "too open" actually means

A player crossing an open gap of span `S` at heading θ, under fire from a shooter already in range
with line of sight, survives iff

```
    S / v(θ)  <  T_kill + T_windup + T_acquire

    T_kill    = TicksToKill = 48 ticks                       [engine]
    T_windup  = FireWindupTicks = 5 ticks                    [engine]
    T_acquire = Δslots / aimTurnRate ticks                   Δ = slots the shooter must rotate
```

Solving for the maximum survivable span:

| case | aimTurnRate | T_total | axis-aligned | diagonal |
|---|---|---|---|---|
| runner, shooter already aimed | — | 48 | **132 px** | 187 px |
| runner, shooter aimed | — | 53 (+windup) | 146 px | 206 px |
| runner, mean random bearing (Δ = 8) | 1 (default) | 61 | 168 px | 237 px |
| runner, mean random bearing (Δ = 8) | 5 (league) | 54.6 | 150 px | 212 px |
| **carrier** (0.70×), shooter aimed | — | 48 | **92 px** | 131 px |
| carrier, mean random bearing | 5 | 54.6 | 105 px | 148 px |

`MaxExposedRunPx = 132` **[engine]** is therefore the *most conservative corner* of this table: an
axis-aligned crossing by a full-speed runner against a pre-aimed shooter with no windup credit. It is
also **the wrong number for the phase that decides matches**, where the correct figure is the carrier
row: **92 px**.

Note the direction of the two corrections: heading (up to +41%) and acquire time (up to +27%) both
*loosen* the budget; carrying (−30%) tightens it. They do not cancel, and which dominates depends on
the phase. A generator that applies one global `maxExposedRun` is answering the wrong question in
both directions at once.

### 3.4 Cover cadence — the derivation that reproduces our measured 10–25% band

Model a cover field as a square lattice of `w = BaseCoverSizePx = 56` px blocks with clear gap `g`
between neighbours. Areal wall fraction:

```
    f = w² / (g + w)²                    ⟺        g = w·(1/√f − 1)
```

Require that no traverse of the field exposes the mover for longer than one time-to-kill, i.e.
`g ≤ S_max` from §3.3:

| mover | heading | S_max | required f |
|---|---|---|---|
| runner | diagonal | 187 px | **5.3%** |
| runner | axis | 132 px | **8.9%** |
| carrier | diagonal | 131 px | **9.0%** |
| carrier | axis | 92 px | **14.3%** |

And from the other side, the density at which a field stops being a field:

```
    f = 25%  ⟺  g = 56 px  — a single gap of one drawn body plus a strafe margin
    f = 35%  ⟺  g = 39 px  — narrower than one drawn body; the space is now a maze, not a field
```

**Our measured stand-side conversion band of 10–25% is exactly the carrier's cadence requirement.**
Its floor (10%) sits on the carrier-diagonal figure (9.0%); its centre (~15%) sits on the
carrier-axis figure (14.3%); its ceiling (25%) is the maze threshold. Maps below the band leave the
carrier a gap longer than one TTK on the only run that matters; maps above it turn the pedestal
approach into a corridor system where a defender needs to cover only one mouth.

Three consequences:

1. **The invariant is a property of the carry phase, not of the pedestal.** It should be enforced
   along the whole carry route out to the endzone, not only in a 200 px disc around the stand. The
   200 px disc was where we happened to measure it. (The 200 px radius is itself sensible — it is
   ~2× the carrier's TTK-distance and ~1.5 endzone radii — but it is not where the requirement
   stops.)
2. **The global band should be lower than the stand band, not the same.** Full-speed traffic needs
   5–9%; the current 4–17% global validator band brackets that adequately at the bottom and is
   harmless at the top. The bug was never the global band. It was having *only* a global band.
3. **The 28% reference-plate figure is a different quantity.** A hand-authored plate's "structure"
   includes the perimeter, solid buildings and interior walls, none of which are 56 px cover blocks.
   Comparing 4–17% cover to 28% structure is apples to oranges and has probably been driving the
   generator toward the wrong target. Split the measurement: **`coverFrac`** (connected components
   with bounding box ≤ ~2 w on both axes) versus **`structureFrac`** (everything else), and band them
   separately.

### 3.5 Angle geometry — what one block actually protects

A cover block of width `w` at distance `d` from a defended point subtends

```
    α(d) = 2·arctan(w / 2d)
    w = 56:   α(50) = 58°     α(100) = 31°     α(200) = 16°     α(400) = 8°
```

The whole 360° threat field at a point therefore needs **≈ 12 blocks at 100 px** to be fully covered,
or ~6 to cover a 180° frontal sector. This is the mathematical content of the intuition that a
*scatter* of blocks protects nobody while *architecture* does: a wall of length L at distance d
subtends up to `2·arctan(L/2d)`, which for L = 400, d = 100 is 127° — one wall does the work of four
blocks, and does it as a *contiguous* sector rather than four slivers with lethal gaps between them.

Define, for a point p:

```
    V(p) = { q : ‖q − p‖ ≤ GunRange  ∧  LOS(q, p) }        the threat set
    A(p) = number of connected components of the bearing-projection of V(p)     the ANGLE COUNT
    Ω(p) = angular measure of that projection / 2π                              the EXPOSURE FRACTION
```

`A(p)` is the level-design term "how many angles can shoot this point", made computable. `Ω(p)` is
its magnitude. The pair distinguishes the two failure modes that a single scalar cannot: high `Ω`
with `A = 1` is *one open side* (survivable — turn your back to it and run); moderate `Ω` with
`A = 5` is a **crossfire** (unsurvivable — there is no facing that is safe, and no single cover piece
helps).

Neither quantity is in our metric suite. Both are static, cheap, and directly actionable.

---

## 4. The property set — what a generator must be *required* to guarantee

**Evidence classes.** These are the whole point of the table; a threshold without one is an opinion.

| Class | Meaning |
|---|---|
| **N★** | **Necessary, causally established by our own intervention.** We changed this and only this on a failing map and the outcome changed. |
| **N⊢** | **Necessary by derivation** from engine constants — true by arithmetic, not by observation. |
| **C∼** | **Correlated in our data, no intervention run.** Goodhart risk; do not optimise directly. |
| **C†** | **Asserted by a cited source, untested here.** |
| **F** | **Folklore.** Confident, widely repeated, no evidence found. |

### 4.0 Summary table

| ID | Property | Threshold | Class | Regime |
|---|---|---|---|---|
| **A. Playability — hard constraints; violation ⇒ infeasible, never scored** ||||
| A1 | Full mutual reachability of every spawn, pedestal, endzone and pickup on the 12 px collision hull | exact | N⊢ | all |
| A2 | No sealed pockets; one open connected component | exact | N⊢ | all |
| A3 | Required routes admit two abreast | width ≥ 68 px (`2 × SoldierBodyPx`) | N⊢ | all |
| A4 | Spawn zones disjoint from every capture circle | clearance ≥ `endzoneRadius + SoldierBodyPx` | **N★** | all |
| A5 | Pedestal, endzone and pickups on occupiable floor | exact | N⊢ | all |
| A6 | Endzone position is *emitted by the map* and read by the policy — no hard-coded home column | exact | **N★** | all |
| **B. Fairness** ||||
| B1 | Team configs related by an element of **D4** about the board centre | exact for k ∈ {2, 4} | N⊢ | all |
| B2 | Heading-speed spread `max m(θ_i) / min m(θ_j)` | 1.000 for k ∈ {2,4}; **≤ 1.155 irreducible** for k ∈ {3,6} | N⊢ | all |
| B3 | L∞ time-to-frontier spread across teams | ≤ 2% | N⊢ / C† | all |
| B4 | The full objective triple (spawn, own pedestal, own endzone) maps under **the same** g | exact | N⊢ | all |
| B5 | Per-**seat** symmetry, not just per-team (we hold a strided subset) | exact | C† | all |
| B6 | Sim-side tie-breaks (resolution order, pickup contention, hit ordering) independent of player index | audit, not a map property | — | all |
| **C. Contact — does the game happen at all** ||||
| C1 | L∞ time-to-first-contact from spawn is finite and bounded | ≤ ~8 s occlusion-limited; ≤ ~20 s range-limited | C† | regime |
| C2 | Equidistant frontier F (in L∞) is non-degenerate and does not coincide with any pedestal | dist(F, pedestal) ≥ `GunRange` | C† | all |
| C3 | Cover fraction on F is in band | 5–9% (full-speed traffic, §3.4) | C† | occl. |
| **D. Conversion — the phase that decides matches** ||||
| D1 | Stand-side cover fraction within 200 px of each pedestal | **10–25%** | **N★** | all |
| D2 | Carry-route cover cadence: no exposed run > carrier budget anywhere on the shortest carry route | ≤ 92 px axis / 131 px diagonal ⇒ f ≥ 9–14% in a 200 px corridor | N⊢ | all |
| D3 | Vertex-disjoint routes between each base pair **and** on the carry route | **k ≥ 3**; k = 1 fatal | **N★** | all |
| D4 | Carry route contains no dead end | exact | N⊢ | all |
| **E. Sightline and exposure** ||||
| E1 | Max exposed run on any required route, heading- and acquire-corrected | see §3.3 table | N⊢ | occl. |
| E2 | Angle count `A(p)` on required routes | `A ≤ 3`, and `A ≤ 2` on the carry route (proposed, untested) | C† | occl. |
| E3 | Exposure fraction `Ω(p)` on required routes | `Ω ≤ 0.5` (proposed, untested) | C† | occl. |
| E4 | No single position covers all chokepoints | exact | C† | all |
| E5 | Every power position has a D4-image counter-position | exact (free under B1) | C† | all |
| **F. Architecture — shape, not density** ||||
| F1 | `coverFrac` (components ≤ ~2 w) banded separately from `structureFrac` | cover 5–9% global, 10–25% stand; structure unbanded | N⊢ | all |
| F2 | Free-sightline **tail**, not mean: 95th percentile of free-ray length | ≤ `GunRange` | C∼ | occl. |
| F3 | Used space — floor on a shortest path between an objective pair | ≥ 50% (proposed; Güttler's failure case was < 50%) | C† | all |
| F4 | Total wall coverage below the maze threshold | ≤ 35% | C† / F | all |
| F5 | `interiorFrac` | **diagnostic only — do not optimise** (see §6.3) | C∼ | all |

### 4.1 The properties that matter most, in detail

**A4 / A6 — the objective plumbing.** These two are not aesthetic. Both have produced a
*deterministic zero*: a map where the respawn wave materialised inside the circle the carrier was
running toward converted **0 of 22**, and a policy driving to a hard-coded `homeDeepX = 150` "home
column" that lay outside the real capture zone on ~3 of 8 seeds went **0/6 → 3/4** on grab→capture
once it steered to the engine-stated endzone. These are the cheapest checks in the whole set and the
most expensive to get wrong. They belong in the *infeasible* population (Liapis's FI-2pop framing),
never in the score.

**B1 / B2 — fairness is a group-theoretic property, and for 3 and 6 teams it is unattainable.**
The practical rule: **generate the fundamental domain once and stamp it with a D4 element.** Do not
generate a whole board and then measure its asymmetry — that is strictly worse, because the residual
is unbounded and the measurement is expensive. For k ∈ {3, 6}, accept that exact fairness is
impossible, apply the distance compensation of §3.2, and *record the 15.5% heading residual in the
map's metadata* so that downstream analysis knows the board is structurally tilted rather than
attributing the tilt to policy.

**B4 is the trap the brief warns about, made concrete.** A perfectly mirrored *wall field* with
objectives placed independently is unfair, and our symmetry check would pass it. The correct
statement is that the *whole labelled configuration* — walls, pedestal, endzone disc, spawn ring
including per-seat ordering, and pickups — is a single object, and `g` maps it wholesale. A useful
implementation: compute a per-team hash over the labelled configuration expressed in that team's own
D4 frame; the hashes must be equal.

**B6 is not a map property and cannot be fixed by one.** If the simulator resolves collisions, hit
detection or pickup contention in player-index order, then team 0 has an advantage on *every map*,
including a perfectly symmetric one. This is the "spawn ORDER breaks the symmetry" channel. It needs
a separate audit: run a perfectly D4-symmetric board with a mirrored policy on both sides and check
that the outcome distribution is symmetric. If it is not, no map work will fix it.

**C2 — the collision point must not be the pedestal.** This is our own inference from Güttler plus
the conversion data, and it is worth stating sharply. If the equidistant frontier coincides with the
pedestal, then the defender arrives at the pedestal at the same moment as the attacker, every time,
and there is no steal — this is Güttler's example B, where the anti-terrorists "easily can predict how
the terrorists will move" and the mission becomes impossible. The threshold `dist(F, pedestal) ≥
GunRange` says: by the time the defender can *shoot* the pedestal approach, the attacker must already
have had an independent decision to make.

**D1 vs D2 — the reframe.** D1 is what we measured; D2 is what D1 is an instance of. The measurement
was taken in a 200 px disc because that is where the pedestal is, but §3.4 shows the binding
constraint is the *carrier's* 0.70× speed, which applies for the entire run home. Maps that pass D1
and fail D2 are the predicted next failure mode: the steal succeeds, the carrier clears the stand,
and then dies in an unfurnished midfield. **This matches the already-recorded field observation that
"we steal now, the carrier dies".** D2 is the highest-value untested property in this document.

**D3 — k ≥ 3 vertex-disjoint routes.** Note two refinements the current formulation misses.
(a) It must hold on the **carry route** specifically, i.e. between the *enemy pedestal* and *our
endzone*, which is a different pair from base-to-base. (b) Vertex-disjointness on a coarse cell graph
overstates real route count, because on a grid you can slip diagonally past a single-cell cut — our
own `map_metrics.nim` notes this. Compute route count on the collision hull with the diagonal-slip
rule the sim actually implements, or the number is optimistic.

**E4 — the joint-coverage constraint.** "It should be impossible to cover all chokepoints from a
single point" **[C†, Level Design Book]** is directly computable: for each candidate defender
position q, count the chokepoints c with `‖q − c‖ ≤ GunRange ∧ LOS(q, c)`; require
`max_q count(q) < numChokepoints`. Our current suite has `chokepointSpacingPx = GunRange` **[engine]**
which is a *pairwise* proxy for the same idea — and pairwise spacing does not imply joint
non-coverage (three chokepoints can be pairwise 1050 px apart and all visible from one point in the
middle). Replace the proxy with the real test.

**F2 — the mean is the wrong statistic for sightlines.** `meanFreeSightlineMinPx/MaxPx` **[engine]**
bands an *average*. The quantity that kills is the tail: one 900 px lane on an otherwise well-broken
board sets the map's character, and it moves the mean by almost nothing. Band a high percentile
(p95) or the max instead, or band the mean *and* the tail. This is a small change with a large
correctness gain and no new machinery.

---

## 5. Per-visibility-regime differences

`coneCoverage` = (area of one 120° cone at 1575 px) / (playfield area) = 2,597,600 px² / A.
Regime cuts **[engine]**: occlusion-limited ≥ 1.4, mixed 0.25–1.4, range-limited ≤ 0.25.

| Class | Playfield px² | coneCoverage | ≈ w × h @ 1.874 | Regime |
|---|---|---|---|---|
| small | 587,700 | 4.42 | 1050 × 560 | occlusion |
| standard | 814,300 | 3.19 | 1235 × 659 | occlusion |
| large | 1,374,400 | 1.89 | 1605 × 856 | occlusion |
| huge | 2,636,478 | 0.99 | 2223 × 1186 | mixed |
| giant | 5,500,443 | 0.47 | 3211 × 1713 | mixed |
| colossal | 22,008,194 | 0.118 | 6422 × 3427 | range / navigation |

### 5.1 Occlusion-limited (small, standard, large)

The gun reaches 85–100% of the long axis, and the small board's width is *exactly* `GunRange`
**[engine]**. A sightline is essentially never range-limited; if you can see it you can shoot it.
**Sightline control is the entire design problem** and every property in family E binds hard.

- C1 (forcing contact) is free — do not spend generator effort on it.
- E1/E2/E3 are the binding constraints. F2 (sightline tail) matters more than F1 (density).
- Spawn safety in the Ballabio & Loiacono sense **[lit]** matters *most* here, because a spawn can be
  covered from most of the board. We do not measure it at all (§7.5).
- `coneCoverage > 1` does **not** mean players see everything: the cone is 120°, so a player sees one
  third of bearings at any instant and **an enemy behind you is invisible at any range**. Range stops
  being the limiter; **facing** becomes the limiter, everywhere, always.

### 5.2 The aimTurnRate coupling — our objective is not stationary

The value of every flanking-related property (E2 angle count, D3 route count, F3 used space) is set
by how expensive it is to turn around, and that is a **league config, not a map property**:

```
    cost of a 180° turn = 16 slots / aimTurnRate ticks, against TicksToKill = 48
    aimTurnRate = 1 (engine default):   16 ticks = 33% of a TTK   → flanking is decisive
    aimTurnRate = 5 (live league):      3.2 ticks = 6.7% of a TTK → flanking is nearly free
```

At the live rate, being flanked costs you 7% of a kill's worth of time; at the default rate it costs
a third. **A map tuned for flanking value under one `aimTurnRate` is mistuned under the other.** This
is the map-side analogue of the already-recorded lesson that economy verdicts expire on physics
changes: *map* verdicts expire on control-rate changes too. Any threshold in family E should be
stated as a function of `aimTurnRate`, or the pool regenerated when the league bumps it.

### 5.3 Mixed (huge, giant)

Both problems, neither dominant. The gun covers under half the long axis, so genuinely range-limited
sightlines appear and cover cadence stops being needed *everywhere* — only on routes. Route-level
metrics (exposure along the actual shortest paths) start to beat field-level metrics (exposure over
all cells), because most cells are no longer on anyone's path.

### 5.4 Range / navigation-limited (colossal) — and a hard feasibility result

One cone sees 11.8% of the board. Finding people is the design problem, and this is the only regime
where the published simulation-based fitnesses were designed to apply: Cardamone et al.'s **average
fighting time** and the MAP-Elites **pace** function **[lit]** both measure encounter frequency,
which is only a free variable when the map is big enough to hide in.

But before tuning encounter density, check that the objective is reachable at all.

**Conversion-feasibility bound (proposed property G1).** A capture requires a full outbound trip at
full speed plus a full return at `CarrierSpeedPct = 70`:

```
    T_convert  ≈  d / v  +  d / (0.7 v)  =  2.43 · d / v   axis-aligned
                                         =  1.72 · d / v   diagonal
    d = L∞ base separation,  v = 66 px/s
```

Taking base separation as 70% of board width (bases inset ~15% from each end) and an episode of
~2410 ticks ≈ 100 s **[measured — verify per size class]**:

| Class | width | d ≈ 0.7 w | T_convert (axis) | fraction of a 100 s episode |
|---|---|---|---|---|
| small | 1050 | 735 | 27 s | 27% |
| standard | 1235 | 865 | 32 s | 32% |
| large | 1605 | 1124 | 41 s | 41% |
| huge | 2223 | 1556 | 57 s | **57%** |
| giant | 3211 | 2248 | 83 s | **83%** |
| colossal | 6422 | 4495 | **165 s** | **165% — impossible** |

**A colossal board cannot be converted even once inside an episode**, before a single tick is spent
on combat, aiming, dying, respawning or route-following. Giant leaves 17 s of slack for everything
that is not walking in a straight line, which in practice is also zero. This is a *structural*
result, not a tuning one: no amount of cover placement fixes it.

Three readings, and we should pick one deliberately rather than by accident:

1. **CTF is not a colossal-board game type.** Restrict capture-the-heart to ≤ huge and give the big
   classes a different objective (territory, elimination, multiple pedestals). This is what the
   arithmetic actually argues for.
2. **Shorten the effective distance** — multiple pedestals, forward endzones, or one-way teleporters
   (Hullett notes Blood Gulch's teleporters exist precisely to shorten the respawn return **[lit]**).
3. **Scale episode length with board width.** `T_convert ∝ w`, so a constant episode length is
   itself the bug.

Whichever is chosen, **G1 belongs in the property set as a hard feasibility constraint**, computed
from board width, `CarrierSpeedPct` and episode length. It is a two-line check that would have
retired an entire size class.

*(Assumptions to verify before acting: episode length in ticks per size class; the base-inset
fraction the generator actually uses; and, independently, whether `GrenadeMaxRange` / `ShoutRange`
pinned at 262 px on a 6422 px board leaves teams unable to coordinate at all — a second colossal
problem with the same root.)*

---

## 6. Necessary vs correlated — the Goodhart classification

### 6.1 The test

**A property is necessary only if we have an intervention.** Take a map that fails, change *only*
that property, hold the seed and everything else, re-simulate. If the outcome moves, the property is
causal. If we have never run that experiment, the property is correlated, however clean the
correlation looks.

By this standard, exactly three of our properties are established:

| Property | Intervention | Result |
|---|---|---|
| **D1** stand-side cover 10–25% | raised cover fraction into band | 0 captures → 18 steals / 6 captures, every episode ending in a capture. Failing maps outside the band: 0-of-21, 0-of-17, 0-of-10 |
| **A4** spawn clear of the capture circle | moved the spawn out of the circle | 0-of-22 → converts |
| **A6** endzone read from the map | steered to the engine-stated endzone instead of `homeDeepX = 150` | grab→capture 0/6 → 3/4 |

Everything else in §4 is either derived arithmetic (N⊢ — true about the *engine*, but not yet shown
to move outcomes) or correlational.

### 6.2 The failure mode we have already paid for

The template case: a change took moving-while-firing from 63% to 0.1%, moved hit rate 36.0 → 36.1,
and dropped kills 34%. The metric was correlated with poor accuracy in observational data because of
a **common cause** — players moving while firing were the ones in bad engagements — so suppressing
the metric severed the correlation without touching the cause, and cost a third of our kills through
a channel nobody had modelled.

The map-side version has exactly the same shape, and we have at least one metric sitting in it.

### 6.3 `interiorFrac` is the highest Goodhart risk in the suite

`interiorFrac` (floor with ≥ 6 of 8 directions blocked within 120 px) separates hand-authored arena
(**0.342**) from the generated pool (**median 0.118**) cleanly. But that is a *population* difference
between hand-authored and generated maps, and hand-authoring differs from generation in a hundred
ways at once. **The common cause is authorship.**

The diagnostic that makes this concrete: many other statistics would separate those two populations
just as cleanly — the fraction of axis-aligned wall edges, the entropy of wall component sizes, the
count of right-angle junctions, the modal wall length. None of them cause good play. A metric that
distinguishes "looks hand-made" from "looks generated" is measuring authorship — and that is exactly
the trap already recorded as *a map is judged on PLAY, not resemblance*, paid for twice on
correct-footprint maps that played badly.

**But do not simply delete it.** `interiorFrac` is a crude proxy for something real: local angular
enclosure, i.e. `Ω(p)` from §3.5. The right move is not to rescue the proxy but to **replace it with
the quantity it approximates** — `Ω(p)` / `A(p)`, or the visibility-graph clustering coefficient
(Turner et al. 2001) **[lit]** — which is unconfounded, has a derivable threshold, and is causal by
construction because it is defined in terms of the shot geometry.

**The intervention that would settle it,** if we want to know: take a generated map at
`interiorFrac = 0.118`, raise it to 0.34 while holding `coverFrac`, the sightline tail and the
stand-side band fixed, and re-simulate. Prediction: little or no movement, because the causal channel
runs through cover cadence and angular coverage, both of which are being held.

### 6.4 The other correlated metrics, ranked by risk

**Wall coverage (any global density) — high risk when used alone.** Any density is achievable by any
arrangement. 28% delivered as one blob, as 200 scattered 56 px dots, or as three long walls are three
completely different maps with identical scores. A density is only meaningful *paired with an
arrangement statistic* — free-sightline tail, run-length distribution, or component-size
distribution. Never band a density on its own.

**The 4–17% vs 28% comparison may not even be the same quantity.** See §3.4(3): split `coverFrac`
from `structureFrac` before comparing anything to a reference plate.

**`meanFreeSightline` band — medium risk, easily fixed.** It is arrangement-sensitive, which is good,
but it is a *mean*, and a single lethal lane is invisible in an average. Band the tail (§4.1/F2).

**`balanceEntropy` — noise, not signal, at our sample sizes.** It is an *outcome* metric over
simulated kills. Using it to pick among K map candidates with a handful of episodes each is selecting
on sampling noise. Either budget enough episodes that its standard error is small relative to the
between-map spread, or drop it from selection and keep it as a post-hoc report.

### 6.5 Best-of-K selection is a Goodhart *amplifier* — the most important structural point

`MapSelectionK` picks `argmax staticScore` over K = 8–16 candidates **[engine]**, and the module
records the expected gain: "E[max of K] is K/(K+1) of the generator's own quality range, so
0.834 → 0.898 and the WORST map 0.636 → 0.804".

Those are gains **in the score**. They are gains in *quality* only if the score is valid. If the score
contains a confounded term, best-of-K does not merely fail to help — it **actively selects the
candidates that exploit the confound hardest**, because those are the ones scoring highest for the
wrong reason. Raising K makes this monotonically worse. And since the validators pass 96% of
first attempts, they are not filtering; the K-selection is therefore doing *all* of the quality work,
through a score whose terms are mostly unvalidated.

**The structural fix is to move evidence-class C properties out of the maximised objective and into
the feasibility test.**

```
    FEASIBLE  (hard, satisficing, Goodhart-safe):  all N★ and N⊢ properties, plus every C
                                                    property expressed as a WIDE band
    SCORE     (maximised, Goodhart-exposed):       only properties with an intervention behind them
```

Constraints are satisficing: once inside the band there is no pressure to go further, so there is
nothing to over-optimise. Objectives are not. This is Liapis's feasible/infeasible two-population
structure **[lit]** and it is the correct shape for a suite where most terms are unvalidated.
Concretely: today's score has about four terms that deserve to be maximised (the three N★ properties
plus G1) and roughly a dozen that deserve to be bands.
