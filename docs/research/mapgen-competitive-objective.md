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

## 0. The four headline results

Read these first; the rest of the document is their derivation and their consequences.
**Read 0.4 first — it is the largest single correction and it changes range-derived numbers
throughout this epic.**

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
at the stand. See §3.4 for the derivation and §3.6 for the version that also accounts for 0.4.

**0.4 — `GunRange = 1050 px` is a REACH, not an engagement range; the aim lattice caps the real
lethal envelope at ~140–260 px.** Aim is quantised to 32 slots 11.25° apart and re-snapped every
tick; the gun hit test accepts a ray within `PlayerHalf + BulletHalfWidth = 14 px` of the *solid*
13 px body (not the 34 px drawn one); there is no aim assist. One slot's worst-case pointing error
equals that 14 px window at **`R_slot = 14 / tan(5.625°) = 142 px`**, and beyond it hit probability
falls as `arctan(14/t) / 5.625°` — 0.47 at 300 px, **0.14 at `GunRange`**, where time-to-kill is
10.5 s. Three independent engine constants agree on the envelope: `FieldAccuracyPct = 55` is
achieved at 259 px, `GrenadeMaxRange = ShoutRange = GunRange/4 = 262 px`, and the observed 1.0–1.9 s
TTK band implies 142–225 px. **You can see 6× further than you can kill.** §3.6 derives it from the
simulator source and lists the numbers it invalidates — `ChokepointSpacingPx` (4× too large),
`chokeCoveredPenalty`'s 1050 px isovist, `longRunFrac`'s 600 px cut, and any encounter-density law
calibrated on gun or vision range (overstated 12–16×).

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
| Drawn body — **art and the spray cone only** | `SoldierBodyPx = 34`, `PlasmaArcBodyRadius = 17` | 34 px |
| Solid body — collision **and the gun/grenade hit tests** | `PlayerHalf = 6` | 12–13 px |
| Bullet corridor half-width | `BulletHalfWidth = 8.0` | acceptance half-window **14 px** |
| Speed | `MaxSpeed / MotionScale = 704/256` | 2.75 px/tick = 66 px/s at 24 Hz |
| Carrier speed | `CarrierSpeedPct = 70` | 1.925 px/tick = 46.2 px/s |
| Shot cadence | `FireCooldownTicks = 12` | 0.5 s between shots |
| Time to kill | `TicksToKill = (ShotsToKill−1) × 12`, `ShotsToKill = 5` | 48 ticks = 2.0 s (observed 1.0–1.9 s) |
| Assumed field accuracy (baked into `ShotsToKill`) | `FieldAccuracyPct = 60` | 60% |
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

**Three body sizes are in play and they disagree by up to 2.8×. Getting this wrong invalidates
every geometric threshold, so it is worth stating flatly:**

| Purpose | Size | Source |
|---|---|---|
| Passability / wall collision | ±`PlayerHalf` = 12–13 px | `sim.nim` movement |
| **Gun and grenade hit tests** | ±`PlayerHalf` silhouette, sampled every 3 px, inside a ±`BulletHalfWidth` = 8 px corridor → **28 px total acceptance width** | `selectFireTarget`, grenade blast (GV30) |
| Spray cone, and everything the viewer sees | 34 px (`PlasmaArcBodyRadius` = 17) | `rig_art.nim`, arc resolution |

The gun does **not** shoot at the 34 px silhouette — it shoots at the 13 px solid body inside a 16 px
corridor. Source-engine geometry has no analogue of this split (there the collision hull *is* the
functional body), so an imported Source number has to be matched to whichever of the three is doing
the same job: **32 HU ↔ the drawn 34 px for map-legibility numbers (corridors, room sizes), and
32 HU ↔ the 13 px solid body for anything about how hard a target is to hit.** The two bridges differ
by 2.6× and §3.6 shows that the second one is the one that decides how this game actually plays.

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
  **Our gun *reaches* ~48% further, relative to the player, than TF2's "medium range".** Applying
  the 32-HU bridge to a 49-HU game produced a spurious 4% match.

  **But reach is not lethality.** §3.6 shows the aim lattice caps our *effective* engagement range at
  ~260 px = 7.6 body-widths, against TF2's 20.9. Normalised properly, **our lethal envelope is
  2.7× SHORTER than TF2's medium range, not 48% longer.** Both statements are true and they are about
  different quantities; conflating them is how `ChokepointSpacingPx` came to be four times too large.

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

## 3. The math: six derivations that turn guidance into thresholds

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

**All of the above assumes the shooter can actually hit.** §3.6 shows that is only true inside
~260 px; at 500 px the real TTK is 114 ticks and the exposure budget is 314 px axis / 444 px
diagonal. So this table is the **short-range** table, and short range is where it matters — but do
not apply it to a gap whose nearest threat position is 600 px away.

`MaxExposedRunPx = 132` **[engine]** is therefore the *most conservative corner* of this table: an
axis-aligned crossing by a full-speed runner against a pre-aimed shooter at ~240 px with no windup
credit. It is
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

### 3.6 The aim lattice caps the real engagement range at ~142–260 px, not 1050 px

**This is the most consequential thing in this document. It invalidates numbers throughout the
epic.** It is derived from the simulator source, not from comments or documentation.

#### The evidence, from `src/ctf/sim.nim` and `src/ctf/sim_types.nim`

1. **The aim is quantised to 32 slots and re-snapped every tick.** `sim.nim` (movement update):

   ```nim
   let slot = player.aimBrads div AimStepBrads
   player.aimBrads =
     (((slot + steps) mod AimRotations + AimRotations) mod AimRotations) * AimStepBrads
   ```

   with `AimRotations = 32`, `AimBradsTurn = 256`, `AimStepBrads = 8` → **11.25° per slot**
   (`sim_types.nim`: "The aim is always one of these 32 slots — there are no finer-grained angles").
   The comment is confirmed by the arithmetic: the value is reconstructed as `slot * AimStepBrads`,
   so an off-grid angle cannot persist.

2. **The shot is fired down the snapped aim.** `sim.nim:968` → `sim.jitterDirection(headingBrads)`,
   and every call site takes `headingBrads` from `player.aimBrads` / `attacker.aimBrads`
   (`sim.nim:681, 756, 1216, 1234`). `jitterDirection` calls `aimVector(headingBrads)` and rotates it
   by a Gaussian draw. **There is no aim assist and no snap-to-target anywhere in `sim.nim`** (grep
   for `assist|snapTo|autoAim|aimAssist|nearestTarget` returns nothing).

3. **The hit test uses the SOLID body, not the 34 px drawn body.** `selectFireTarget`:

   ```nim
   for off in countup(-PlayerHalf, PlayerHalf, ExposureSampleStep):   # PlayerHalf = 6
     ...
     if abs(vx * uy - vy * ux) > BulletHalfWidth: continue            # BulletHalfWidth = 8.0
   ```

   So a fully-exposed, centred body is hit iff the ray passes within
   `PlayerHalf + BulletHalfWidth = 14 px` of its centre. The engine states this identity itself in
   `aimJitterSigma`: "`PlayerHalf + BulletHalfWidth` is the corridor's continuous acceptance
   half-window for a centered silhouette." The grenade blast uses the same solid box
   (`sim.nim:1343–1350`, GV30). **Only the spray cone uses the 34 px drawn body.**

4. **Jitter is an order of magnitude smaller than the lattice.**
   `σ = asin(14 / 1050) / AimJitterCentralZ = 0.013333 / 1.2815516 = 0.010404 rad = 0.596°`,
   calibrated so a fully visible body at max range is hit 80% of the time *given a perfectly aimed
   ray*. The half-slot pointing error is 5.625° — **9.4× larger than σ**. The dominant source of
   miss is therefore the lattice, not the jitter, and the jitter calibration never accounted for it.

#### The quantity the coordinator asked for

One slot's worst-case pointing error is half a slot, `δ = 5.625°`. Its lateral miss at range `t` is
`t·tan δ = 0.09849·t`. Setting that equal to the acceptance window:

```
    R_slot  =  (PlayerHalf + BulletHalfWidth) / tan(5.625°)  =  14 / 0.098491  =  142 px
    (strict "one body half-width", ignoring the bullet corridor:  6 / 0.098491 = 61 px)
```

**`R_slot` = 142 px is the range ceiling below which the aim lattice is guaranteed to be able to put
the ray on a fully exposed body. Beyond it, whether you can hit at all depends on where the target
happens to sit relative to the 32-slot grid.** For a target at a bearing uniform within its slot:

```
    P(hit | range t)  ≈  min(1,  arctan(14 / t) / 0.0981748 rad)
    TTK(t)            =  FireCooldownTicks · (HitPoints / P(t) − 1)  =  12 · (3/P(t) − 1) ticks
```

| range t | P(hit) per shot | TTK | note |
|---|---|---|---|
| ≤ 142 px | **1.00** | 24 t = **1.00 s** | the fast end of the observed 1.0–1.9 s TTK band |
| 200 px | 0.712 | 39 t = 1.61 s | inside the observed band |
| **237 px** | 0.600 | **48 t = 2.00 s** | **exactly `TicksToKill`** |
| **259 px** | **0.550** | 54 t = 2.24 s | **exactly `FieldAccuracyPct = 55`** |
| 300 px | 0.475 | 64 t = 2.66 s | |
| 500 px | 0.285 | 114 t = 4.76 s | |
| 1050 px | 0.136 | 253 t = **10.5 s** | `GunRange`. Against a moving target, effectively never |

Three independent constants land on the same answer, which is the strongest evidence that this is
real and not an artefact of my model:

- The engine's own **`FieldAccuracyPct = 55`** — the accuracy it *assumes* when deriving
  `ShotsToKill` and `TicksToKill` — is achieved at **259 px**.
- **`GrenadeMaxRange` = `ShoutRange` = `GunRange div 4` = 262 px**. Whoever set the grenade and shout
  radii to a quarter of the gun range set them, by a completely different route, to the true lethal
  radius. Agreement to 1.2%.
- The **observed TTK band of 1.0–1.9 s** corresponds to engagement ranges of 142–225 px.

**Conclusion: `GunRange = 1050 px` is a REACH, not an engagement range. The real lethal envelope of
this game is ~140–260 px — one quarter of the gun and one sixth of the vision range.** Coworld CTF
is a knife fight conducted inside an enormous see-but-cannot-hit band. This is consistent with the
already-recorded field truth that after GV36 "ranged fire is dead" and the spray — a cone weapon that
needs no pointing precision — became 51% of kills.

**Caveats, stated honestly.** (a) A policy that *strafes to align a slot ray with its target* recovers
range; the model assumes it does not, and the field evidence (spray dominance) says current policies
mostly do not. (b) Against a laterally moving target, successive shots sample independent bearings,
which the model already assumes. (c) The 80%-at-max-range jitter calibration means even a
slot-aligned ray misses 20% at 1050 px, so the table is if anything optimistic at long range. **The
one measurement that would settle it is hit-rate-versus-range from the free field-diagnosis loop, and
that is cheap — run it.**

#### What this invalidates

| Number | Status | Correction |
|---|---|---|
| `ChokepointSpacingPx = GunRange` = 1050 px | **wrong by ~4×** | One defender can only *cover* ~260 px, not 1050. Chokepoints need to be ~260 px apart to be independently defensible; at 1050 px the generator produces ~4× too few chokepoints (`traversePx / 1050`) and a far more open board than intended |
| `chokeCoveredPenalty` — "1 when ONE **1050 px** isovist watches every chokepoint" | **measuring the wrong thing** | At 1050 px a camper can *see* every chokepoint but can only *kill* at ~260 px. Compute the penalty on a **260 px** isovist. Keep the 1050 px version as a separate "watched" (information) metric — they are different design facts |
| `longRunFrac` — share of open axis runs over **600 px** | **threshold 2.3× too long** | A 600 px run is not lethal; a 260 px run with a shooter at the end is. Re-cut at ~260 px, or better, at the heading-corrected `S_max` of §3.3 |
| Visibility regimes (`coneCoverage` from the 1575 px cone) | **correct, but they are AWARENESS regimes** | Under an *engagement* metric (260 px disc) the areas fall by ~37×: small 4.42 → 0.12, colossal 0.118 → 0.003. **On the lethality axis every board is range-limited.** The occlusion/mixed/range trichotomy describes what players *know*, not where they can *kill* |
| `MaxExposedRunPx = 132 px` | **survives, for a different reason** | `TicksToKill = 48` corresponds to a ~237 px engagement, so 132 px is the exposure budget *against a defender at ~240 px*. It is not "the run you can make under fire from anywhere in gun range" — beyond ~300 px the real budget is 2–8× larger |
| Any encounter-rate or population-density law calibrated on `GunRange` or `visionRange` | **must be re-based** | The *lethal* disc is π·260² = 2.1×10⁵ px². The gun disc is 3.5×10⁶ px² (16×) and the vision cone 2.6×10⁶ px² (12×). A density law calibrated on either overstates the contact rate that matters by more than an order of magnitude |
| §3.4's cover-cadence derivation | **strengthened, see below** | It is range-conditioned, and the range it implies is the real combat envelope |
| `RecommendedCorridorWidthPx = 68`, `NominalLanePx = 124` | **unaffected** | These are legibility/traffic numbers built on the drawn body, which is the right anchor for them |
| `visionRange = 1.5 × GunRange = 1575 px` | **unaffected, but reframe it** | You can see **6× further than you can kill**. That see-but-cannot-hit band is a first-class design primitive nobody has written down, and it is what makes shout (262 px) and the fog channel valuable |

#### The cover band, re-derived with the lattice in it

§3.4 required the cover gap `g` to be at most one time-to-kill of carrier travel. With TTK now a
function of the *defender's* engagement range `t`, and carrier speed 1.925 px/tick:

```
    g(t) = 1.925 · TTK(t)          f = 56² / (g + 56)²
```

| defender at | TTK | carrier gap `g` | required cover fraction `f` |
|---|---|---|---|
| 162 px | 29 t | 56 px | **25%** ← top of the measured band |
| 200 px | 39 t | 74 px | 19% |
| 236 px | 48 t | 92 px | **14%** ← centre of the measured band |
| 262 px | 54 t | 104 px | 12% |
| 296 px | 63 t | 121 px | **10%** ← floor of the measured band |

**The measured 10–25% stand-side band maps exactly onto defender engagement ranges of 162–296 px —
which is the real combat envelope derived independently above (142–262 px).** The band is not a
tuning constant. It is the cover density that keeps a carrier alive against a defender shooting from
the only ranges at which shooting works. Two independent derivations, from opposite ends, meeting in
the same 150–300 px window.

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
| D1 | Stand-side cover fraction within 200 px of each pedestal | **10–25%** — *intent only; see §4.2* | **N★** | all |
| D2 | Carry-route cover cadence: no exposed run > carrier budget anywhere on the shortest carry route | ≤ 92 px axis / 131 px diagonal ⇒ f ≥ 9–14% in a 200 px corridor | N⊢ | all |
| D3 | Vertex-disjoint routes between each base pair **and** on the carry route | intent **k ≥ 3**; **shipped `routeCountMin ≥ 2`**; k = 1 fatal | **N★** | all |
| D4 | Carry route contains no dead end | exact | N⊢ | all |
| **E. Sightline and exposure** ||||
| E1 | Max exposed run on any required route, heading-, acquire- **and range-**corrected | see §3.3 and §3.6 | N⊢ | occl. |
| E2 | Angle count `A(p)` on required routes | `A ≤ 3`, and `A ≤ 2` on the carry route (proposed, untested) | C† | occl. |
| E3 | Exposure fraction `Ω(p)` on required routes | `Ω ≤ 0.5` (proposed, untested) | C† | occl. |
| E4 | No single position covers all chokepoints | exact — **shipped as `chokeCoveredPenalty`, but on a 1050 px isovist; re-cut at 260 px (§3.6)** | C† | all |
| E5 | Every power position has a D4-image counter-position | exact (free under B1) | C† | all |
| **F. Architecture — shape, not density** ||||
| F1 | `coverFrac` (components ≤ ~2 w) banded separately from `structureFrac` | derived 5–9% global, 10–25% stand; **shipped is a single global `CoverPermille 40–170` (4–17%)** | N⊢ | all |
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

### 4.2 Shipped vs intent — the drift this section exists to catch

Verified against `map_metrics.nim` / `map_rules.nim` on this branch. **Where design intent and the
enforced band disagree, the enforced band is what ships and the intent is decoration.**

| Property | Design intent | What the validator actually enforces | Verdict |
|---|---|---|---|
| Route count | `k ≥ 3` vertex-disjoint | `Band("routeCountMin", lo = 2.0, kind = bandHard)` — **`k ≥ 2`** | **Divergent.** k = 2 admits a two-corridor map; the intent was three. Either raise the band or stop citing 3 |
| Stand-side cover | absolute **10–25%** within 200 px | **no absolute stand rule**. What ships is `standRingOpenMin` (0.25–0.95), `standRingSpread` (≤ 0.10) and `standCoverSpread` (≤ 0.04) — i.e. **fairness spreads between teams**, plus a global `CoverPermille 40–170` | **Divergent, and this is the highest-value gap in the suite.** A perfectly *symmetric* pair of naked stands scores 0 on both spreads and passes. The causally-established property (§6.1) is an **absolute floor**, and no absolute floor is enforced |
| Cover fraction | 5–9% global / 10–25% stand (§3.4, §3.6) | one global band, 4–17% | **Under-specified**, not wrong. One band cannot express a phase-dependent requirement |
| Chokepoint coverage | no position covers all chokepoints | `chokeCoveredPenalty`, computed on a **1050 px** isovist | **Present but mis-ranged** (§3.6). Re-cut at 260 px |
| Chokepoint spacing | independently defensible | `ChokepointSpacingPx = GunRange = 1050` | **Wrong by ~4×** (§3.6) |
| Collision-point cover | Güttler's principle | `collisionCoverRatio` 0.70–2.40, arena 1.46, **pool median 0.83, pool min 0.05** | **Present and well-calibrated.** The pool minimum of 0.05 says some generated maps have essentially no cover where the teams meet |
| `interiorFrac` | architecture discriminator | banded 0.25–0.65 at **weight 3.0 — the highest weight in the set**, labelled "the single highest-value static metric" | **The Goodhart exposure in §6.3 is aimed at the most heavily weighted term in the score.** Treat as urgent |

Two structural observations about the shipped band list, which is considerably better than the brief
implied:

- **It is already control-anchored.** Every band records the hand-authored arena's measured value in
  `control:` and `map_eval` re-checks the control on every run. That is the right discipline and it
  should not be lost in a rewrite.
- **But every band is calibrated on `control` = the arena and `pool` = today's generator output.**
  That is an *expressive-range* calibration (§7.12), not a *quality* calibration: it encodes "look
  more like the arena and less like the current pool". §6.3 is the argument that this is exactly the
  authorship confound, and the `interiorFrac` note — "arena 34.2%, pool median 11.8% — the
  scatter-vs-buildings discriminator" — states the confound in its own words.

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

The gun *reaches* 85–100% of the long axis, and the small board's width is *exactly* `GunRange`
**[engine]**. But §3.6 splits this in two, and the split is the whole point of the regime idea:

- **Awareness is unlimited.** A sightline is essentially never vision-range-limited. If geometry does
  not cut the angle, you know where they are.
- **Lethality is not.** At 400 px — a third of a standard board — a shot lands 36% of the time and
  time-to-kill is over 3 s. **The board is one awareness zone containing several disjoint lethal
  zones of ~260 px radius.**

So "sightline control is the entire design problem" is half right and the wrong half is the dangerous
one. Sightline control governs *information*; only **short-range** sightline control governs
*killing*. Family E binds hard, but its thresholds must be cut at the lethal radius, not the gun
range — which is precisely the `chokeCoveredPenalty` and `longRunFrac` bug in §4.2.

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
| **D1** stand-side cover 10–25% *(and it is **not** enforced — §4.2)* | raised cover fraction into band | 0 captures → 18 steals / 6 captures, every episode ending in a capture. Failing maps outside the band: 0-of-21, 0-of-17, 0-of-10 |
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

---

## 7. What the literature says we are missing entirely

Ordered by expected value. Items 7.1–7.3 are computable today from data we already have.

**Correction to the brief I was given:** the shipped band list in `map_metrics.nim` is considerably
richer than I was told, and four things I would otherwise have listed as missing are in fact present
— `collisionCoverRatio`, `chokeCoveredPenalty`, `visDegreeFrac`/`visDegreeCv`, and the
`standRingSpread`/`standCoverSpread` fairness pair. Those are marked **[present]** below with what is
actually still absent about them. Claiming a shipped metric is missing would be the worst possible
error in a document like this, so each item below was re-checked against source.

### 7.1 Anything that knows travel is L∞

Nothing in `map_metrics.nim` or `map_rules.nim` models the 41% heading anisotropy of §3.1. Every
"distance", "spacing", "detour budget", "traverse" and "equidistant" in the suite is Euclidean or
grid-Manhattan. **Fix first**: a single `travelTime(p, q) = max(|Δx|, |Δy|) / v` helper, and a
heading-aware `exposureBudget(θ, carrying)`. This is the cheapest large correction available.

### 7.2 Time-to-contact and the collision point

**[present]** `collisionCoverRatio` — "cover within 200 px of the collision point vs map average",
banded 0.70–2.40, arena 1.46 — is Güttler's principle, already implemented and already calibrated.
`midCrossCount` and `midOpenFrac` describe the seam's permeability. So the *place* is modelled.

What is missing is **time**, which is what Güttler's fairness test is actually about:

- **`T_contact(i)`** — L∞ time from team *i*'s spawn to first mutual visibility with any opponent
  along a shortest route. Güttler's fairness test is `spread(T_contact) ≈ 0` **[lit]**, and it is a
  *different* test from geometric symmetry.
- **The equidistant frontier F** — the L∞ isochrone set where all teams' `T_contact` are equal. Its
  shape, its width, its cover fraction, and its distance from the pedestals (§4.1/C2).
- **Pace**, the only published normalisation of encounter frequency (MAP-Elites, §2.1):
  `pace = 2(1 + exp(−5 N_x / Σ T_e))⁻¹ − 1`, tuned so pace ≈ 0.9 at ~3 s mean time-to-engage.

Güttler's `cs_citymall` failure is the canonical warning: the designed climax room went unused
because the collision point landed elsewhere and "almost half the level wasn't used".
`collisionCoverRatio` would catch a *badly covered* collision point; nothing we have would catch a
collision point in *the wrong place*, because the seam is computed geometrically rather than as an
L∞ isochrone. Note also that the pool's `collisionCoverRatio` minimum is **0.05** — some generated
maps have essentially no cover where the teams first meet, which is Güttler's example A.

### 7.3 Angle count `A(p)` and exposure fraction `Ω(p)`; and the cone-restricted isovist

§3.5 defines both. Neither exists in our suite. Two notes on how to compute them correctly here:

- **Use the 34 px drawn body**, not the 12 px hull, for LOS occlusion and for target subtense.
- **Our isovist is not the standard 360° isovist.** Vision is a 120° cone riding the aim
  **[engine]**, so the classical Benedikt isovist area *overstates what any player actually sees by
  a factor of 3*. Compute the standard isovist for *threat* (a shooter can rotate to face you) and
  the cone-restricted isovist for *awareness* (what you will actually notice). These are different
  fields and they justify different design responses. Nobody in the literature has this split
  because mouse-look FPS players can face anywhere instantly; we cannot.
- Glass blocks movement and shots but not vision **[engine]**, so the visibility graph and the
  *threat* graph are genuinely different graphs on our maps. Compute both. A glass-fronted position
  is high-awareness / zero-threat, which is a design primitive nobody else has.

### 7.4 Visibility graph analysis proper

**[present]** `visDegreeFrac` and `visDegreeCv` (banded 0.30–1.20, "unevenness of exposure across
the board; arena 0.52, pool median 0.28 — a uniform board has no good and bad ground") mean a
visibility-degree field already exists and is already used well. The critique is not that it is
absent but that only its *first two moments* are used.

Turner et al. (2001) **[lit]** give a mature toolkit around the same field:
**connectivity** (degree = isovist area), **integration** (inverse mean visual depth), **control**,
and the **clustering coefficient** (local convexity/enclosure — the principled `interiorFrac`
replacement, §6.3). The MAP-Elites paper's "visibility matrix ... for each tile the number of tiles
visible from it" **[lit]** is exactly the degree field; both the spawn heuristic (§7.5) and `Ω(p)`
are functions of it, so one shared computation serves three metrics.

### 7.5 Spawn safety

We check that spawns clear the capture circle (A4, causally established) and nothing else. Ballabio
& Loiacono's validated heuristic **[lit]** says a spawn should additionally minimise **visibility
degree** and maximise **distance to other placed elements**, with an 18–21% measured effect on a
navigation task. On occlusion-limited boards, where a spawn can be covered from most of the map
(§5.1), the absence of this check is a live hazard: the generator may be placing spawns in the
highest-visibility cells on the board by chance.

### 7.6 Route-conditioned metrics — the carry route above all

Every metric we compute is a **field** statistic (averaged over all open cells). What decides matches
is a **path** statistic (what happens along the routes people actually walk). The two diverge sharply
as boards get bigger (§5.3), and the divergence is *maximal* on exactly the path that matters:

- **The carry route** — from the enemy pedestal to our endzone, traversed at 0.70× speed. It has its
  own exposure budget (§3.3), its own cadence requirement (D2), its own route-count requirement (D3)
  and its own dead-end prohibition (D4). We measure **none** of it. Given that "we steal now, the
  carrier dies" is already the recorded field diagnosis, this is the largest single hole in the suite.
- Route-conditioned versions of E1/E2/E3 (max exposed run, angle count, exposure fraction *along the
  route*) are the metrics with the most direct line to conversion.

### 7.7 The quality/balance pairing

**[present, for two metrics]** `standRingSpread` (≤ 0.10) and `standCoverSpread` (≤ 0.04) are
exactly Liapis's quality/balance pairing, applied to the stand ring. The idea is already in the
codebase; it is simply not generalised.

Liapis et al. pair **every** quality metric with a balance metric — `f_res`/`b_res`, `f_saf`/`b_saf`,
`f_exp`/`b_exp` **[lit]**. We pair two, and report the rest as whole-board means.

**A spread is not a substitute for a floor, and conflating them is the single most consequential
mistake in the current suite.** `standCoverSpread ≤ 0.04` is satisfied perfectly by two *equally
naked* stands. The causally-established property (§6.1) is an absolute minimum, and a fairness spread
cannot express it. Every metric needs **both**: a floor/band on the level, and a spread on the
difference. A map with an excellent mean stand-side cover fraction can have one team at 4% and the
other at 22%; today it scores well. **Rule: for every P in the suite, also compute `spread(P)` across
teams and band it.** Under exact D4 symmetry the spreads are identically zero, which makes this cheap
insurance rather than a burden — and it is precisely the check that catches a symmetry bug.

### 7.8 Joint chokepoint coverage and power-position pairing

Two constraints, both formalisable, both absent:

- **[present, mis-ranged]** `chokeCoveredPenalty` — "1 when ONE 1050 px isovist watches every
  chokepoint — one camper owns every route" — already implements the joint-coverage test. But
  1050 px is `GunRange`, and §3.6 shows a camper can only *kill* out to ~260 px. As written the
  metric conflates watching with covering: it flags maps that are actually fine, and misses maps
  where one position genuinely covers every chokepoint at lethal range. **Compute it at 260 px.**
  Keeping the 1050 px version as a separate *information* metric is worthwhile — they are different
  design facts and both matter. Separately, `chokepointSpacingPx = GunRange` is a pairwise proxy for
  the same idea, and is wrong by 4× for the same reason.
- **Every power position has a counter-position** (Hullett 2012 **[C†]**): "players in sniper
  locations must also be wary of counter attack from the complementary sniper location on the other
  side of the level". Free under exact D4 symmetry — which is a good argument for enforcing B1 by
  construction rather than by measurement.

### 7.9 Used space / dead space

Liapis: **used space** = passable tiles on a shortest path between any two objectives **[lit]**.
Güttler's failure case is a used-space failure. We have no such metric; a generator can produce a
board where half the floor is unreachable-in-practice and score perfectly on every density band.

### 7.10 Segment decomposition

Liapis decomposes into **segments** — "passable areas which are surrounded solely by chokepoints" —
plus counts of chokepoints, dead ends and open areas **[lit]**. This yields a *room graph*, which is
what `interiorFrac` gropes toward. A room graph gives us, for free: room count, room size
distribution, room adjacency, dead-end count, and Hullett's *stronghold* and *arena* patterns as
directly detectable structures rather than vibes.

### 7.11 Pickup and objective placement theory

We have `minPickupSpacingPx` **[engine]** and nothing else. Ballabio & Loiacono's guidelines
**[lit]**: strong items in *strategically disadvantageous* positions (dead ends, hard to reach);
mid-power items and their ammo *easy to reach*, because the losing player needs them most; full-armour
pickups in *dangerous* areas. This is a comeback-mechanic theory encoded in geometry, and given that
the heal economy is live and contested for us, it is directly applicable.

### 7.12 Expressive-range analysis of our own generator

Smith & Whitehead **[lit]**: sample the generator, plot the output in 2-D metric space, and look at
the holes. **A 96% first-attempt validator pass rate is the diagnostic signature of a generator whose
range has never been plotted** — the validator bands sit outside the generator's reachable set, so
they are a crash guard, not a filter. Plot `coverFrac × sightlineP95` and `interiorFrac ×
usedSpace` for a few thousand seeds before touching any threshold: the bands should bisect the
generator's cloud, not enclose it.

### 7.13 The emergent half of the metric suite

The MAP-Elites inventory is **46 topological / 23 emergent** **[lit]**. Ours is ~100% topological.
The missing emergent family: average fight time, time-to-engage, target-loss rate, kill-difference,
pace, and kill-distance distribution. **We are unusually well placed to compute these** — the free
field-diagnosis loop re-simulates 411 episodes in 9 minutes — so the usual cost argument against
simulation-based fitness does not apply to us (§9).

### 7.14 Conversion feasibility (G1) and 7.15 per-seat balance

§5.4 and §4.1/B5 respectively. Both are two-line checks with disproportionate consequences.

---

## 8. Where published guidance conflicts with our measurements

Our measurements win. The conflicts are recorded because each one is a place where following the
literature would have cost us, and because each identifies a boundary of the published work's
validity.

**8.1 — Cover belongs at the collision point (Güttler) vs at the pedestal (us).**
Güttler puts the cover budget at midfield, where the teams clash. Our intervention put it within
200 px of the pedestal, and that is what converted (0 → 18 steals / 6 captures). **This is a
refinement, not a contradiction** — Hullett's multiplayer chapter already says the CTF flag location
"serves as a point of conflict" **[lit]** — but the *emphasis* in Güttler and in CS-derived practice
is squarely on midfield, and following it would have sent us to the wrong place. The general
statement that survives: *cover belongs wherever the decisive conflict is, and in symmetric CTF the
decisive conflict is at the pedestal, not at the seam, because conversion decides matches and kills
do not.*

**8.2 — "Avoid long sightlines" reaches the right conclusion here for entirely the wrong reason.**
The rule exists for games where weapon range ≪ map size, so a long lane creates a *sniper* who
outranges everyone. Our gun nominally reaches 85–100% of the long axis, which would make the rule
forbid the map — but §3.6 shows a shot at that range lands 14% of the time. **We have no snipers,
because the aim lattice cannot resolve a body at range.** So long lanes are indeed harmless, but not
because we obeyed the rule: because the mechanic that makes them dangerous elsewhere does not exist
here.

That matters for what we do next. The transferable statement is about **exposed run at lethal
range**, not sightline length: a 1000 px sightline with no threat position inside 300 px of it is
fine; a 200 px sightline with a defender at one end is not. `longRunFrac`'s 600 px cut is measuring
the first thing and calling it the second (§4.2). And it means a *deliberate* long lane is a cheap,
safe way to add legibility and orientation to a board (Güttler's "level orientation" heuristic
**[lit]**) at almost no combat cost — an option no shooter-design source would offer, because in
every other shooter it would be suicide.

**8.3 — "Radial symmetry accommodates multiple teams" is false for k = 3 and 6 in this engine.**
The Level Design Book presents radial symmetry as the natural multi-team answer **[C†]**. §3.2 shows
that the L∞ movement metric admits no order-3 or order-6 isometry, and the residual is an irreducible
**15.5% travel-speed advantage** — 2.0 s on a 1000 px approach, one full time-to-kill. Published
guidance assumes an isotropic movement model. Ours is not isotropic. Our measurement (and the
already-recorded hex work) wins.

**8.4 — "Exploration" as a virtue is inverted for us.** Sentient Sketchbook maximises `f_exp`, "how
difficult every base is to find" **[lit]**; that is an RTS objective. Güttler is explicit in the
other direction for shooters: the design "must make it possible for the players to meet each other
and preferable within a shorter period of time", and if they don't meet "the game will be reduced to
a race against time" **[lit]**. For us, on occlusion-limited boards, contact is free and exploration
is irrelevant; on colossal boards contact is the *binding* problem and exploration is actively
harmful. **In no regime do we want to maximise it.**

**8.5 — The TF2 1024-unit anchor does not transfer.** §1.2. TF2's player is 49 HU, not 32, so the
32-HU bridge mis-scales every TF2 number by 1.53×. Normalised properly, our gun is ~48% longer
relative to the player than TF2's medium-range cap. Use CS/HL2 numbers with the 32-HU bridge and TF2
numbers only in TF2 body-widths.

**8.6 — The literature contradicts itself on dead ends.** Güttler: avoid them. Gee's controlled
study: "dead ends did not negatively impact FPS levels" **[lit]**. Both are about single-player or
loosely-objective play. Our narrower, testable version: a dead end *on the carry route* collapses
`k` to 1 and is fatal (D4). Elsewhere we have no evidence and should not legislate.

**8.7 — "Symmetry guarantees fairness" is false in general and only conditionally true for us.**
Three ways a perfectly mirrored map can still be unfair, of which the literature discusses at most
the first:
  (a) *Chirality.* In a real FPS the weapon sits on one shoulder, so mirror-image corners are not
      equally easy. **We are exempt** — the sim's shot originates on the body along the aim axis and
      the muzzle offset is art only (§1.3) — but this is a property we should keep testing, not
      assume.
  (b) *Turn order.* If the sim resolves collisions, hits or pickup contention in player-index order,
      team 0 wins ties on every map including a perfect mirror. No map property can detect or fix
      this (B6); it needs a mirrored-policy audit.
  (c) *Incomplete transform.* Mirroring walls but not the spawn ring's per-seat ordering, or the
      endzone, or the pickups, leaves a residual our symmetry check would pass. B4 states the fix:
      the transform applies to the whole labelled configuration or it does not apply.

**8.8 — "Levels are often symmetric to ensure balance" understates the measurement problem.**
Hullett states it as the CTF norm **[lit]**. Our own asymmetric-map work found that the obvious
fairness statistic — spawn→enemy-pedestal run length — is *structurally* 1.0 on a mirrored map and
therefore proves nothing; the informative measurement is walk-to-midfield, and an asymmetry assertion
is needed too or a mirror passes trivially. **Symmetry makes the fairness measurement vacuous, not
the map fair.** Enforce symmetry by construction and spend the measurement budget on the residuals
that symmetry does not cover (B6, B5, and the k ∈ {3,6} heading residual).

**8.9 — "Three lanes" vs `k ≥ 3` vertex-disjoint routes.** The lane claim is folklore about geometry;
our route-count claim is a graph property with a fatal-at-k=1 observation behind it. They are not the
same statement, and many topologies satisfy the second without looking like lanes. Prefer ours; it is
measurable and it is the one with evidence.

**8.10 — Generate-and-filter vs constrained optimisation.** The literature's mature form is
constrained search: hard playability constraints and a separate infeasible population (Liapis), or an
archive over behavioural characteristics (MAP-Elites) **[lit]**. Our shape is generate-K,
score-and-take-max, with validators that pass 96% of first attempts. §6.5 argues this is the worst
combination available when most score terms are unvalidated. This is a conflict between our
*architecture* and the literature's, and here the literature is right.

---

## 9. Playtest-free evaluation: what is decidable statically and what is not

The MAP-Elites 46/23 split **[lit]** is the right frame. Applied to our property set:

| Statically decidable (cheap, exact, run on every candidate) | Requires simulation (expensive, valid, run on the shortlist) |
|---|---|
| A1–A6 reachability, clearances, objective plumbing | whether a route is actually *used* |
| B1–B5 symmetry, D4 exactness, heading residual, spreads | whether the win rate is actually ~50% |
| C2 equidistant frontier, C3 frontier cover | C1 realised time-to-first-contact |
| D1–D4 cover fractions, route counts, dead ends | realised grab→capture conversion rate |
| E1–E5 exposure runs, `A(p)`, `Ω(p)`, joint coverage | kill-distance distribution, engagement distance |
| F1–F4 densities, sightline tail, used space | pace, fight time, time-to-engage, target-loss rate |
| G1 conversion feasibility | `balanceEntropy` over kills |
| VGA: connectivity, integration, clustering coefficient | whether the collision point lands where predicted |

**The asymmetry that matters:** static properties are **necessary conditions** — cheap vetoes that
can only prove a map *bad*. Simulation properties are **sufficient evidence** — expensive confirmations
that a map is *good*. Neither substitutes for the other, and Güttler's `cs_citymall` is the proof: the
collision point is *predicted* statically and must be *verified* by play, because the prediction was
confidently wrong and cost half the level.

**Our situation is unusual and we should exploit it.** The standard reason the literature leans on
static proxies is that simulation is expensive. For us it is not: the free field-diagnosis loop
re-simulates 411 episodes of ground truth in ~9 minutes, verified 88/88 against the platform's own
scores. That changes the economics. The right allocation:

```
    per candidate (K = 8–16):   static constraints only — veto, do not score
    per shortlist (top 2–3):    ~20–50 simulated episodes — the emergent metrics
    per pool release:           full re-simulation — conversion rate, per-team win rate, pace
    per metric, once:           the INTERVENTION that promotes it from C∼ to N★
```

The last line is the one that has never been run for most of the suite, and it is the one that would
retire the Goodhart risk permanently.

---

## 10. If you implement one thing

In descending order of expected value per unit of work:

0. **Measure hit-rate versus range** off the free field-diagnosis loop. One query. It either
   confirms §3.6 or refutes it, and §3.6 moves so many numbers that nothing else should be re-tuned
   until it is settled.
1. **Re-cut every `GunRange`-derived threshold at the ~260 px lethal radius** (§3.6): the
   `chokeCoveredPenalty` isovist, `ChokepointSpacingPx`, `longRunFrac`'s 600 px, and any
   encounter-density law. This is a search-and-replace over constants with an outsized effect.
2. **Add an absolute stand-side cover FLOOR** to sit beside the existing `standCoverSpread`
   (§4.2, §7.7). Today two equally naked stands pass. This is the only causally-established property
   in the suite that the validator does not enforce.
3. **`travelTime()` in L∞ and a heading-aware exposure budget** (§3.1, §3.3). One helper; corrects
   every distance-derived threshold.
4. **D2 — carry-route cover cadence** (§3.4, §7.6). The highest-value untested property, and it
   directly attacks the recorded "we steal now, the carrier dies" failure.
5. **G1 — conversion feasibility** (§5.4). Two lines; potentially retires a whole size class.
6. **Move C-class properties from the score into wide feasibility bands** (§6.5), starting with
   `interiorFrac` — currently the highest-weighted term in the score and the largest Goodhart
   exposure (§4.2, §6.3).
7. **Raise `routeCountMin` to 3, or stop claiming 3** (§4.2). Either is fine; the drift is not.
8. **`A(p)` and `Ω(p)`** (§3.5), as the principled replacement for `interiorFrac`.
9. **Band the sightline tail, not the mean** (§4.1/F2), and **give every metric a spread twin**
   (§7.7).
10. **Expressive-range plot of the current generator** (§7.12) before re-tuning any threshold — and
    note that today's bands are calibrated *as* an expressive-range comparison (arena vs pool), which
    is not the same thing as a quality calibration.

---

## 11. Sources

**Primary — academic, evidence-bearing**

- Güttler, C. & Johansson, T. D. (2003). *Spatial Principles of Level-Design in Multi-Player
  First-Person Shooters.* NetGames 2003.
  https://svn.sable.mcgill.ca/sable/courses/COMP763/oldpapers/guttler-03-spatial.pdf
- Hullett, K. & Whitehead, J. (2010). *Design Patterns in FPS Levels.* FDG 2010.
  https://users.soe.ucsc.edu/~ejw/papers/hullett-fps-fdg2010.pdf
- Hullett, K. (2012). *The Science of Level Design: Design Patterns and Analysis of Player Behavior
  in First-Person Shooter Levels.* PhD dissertation, UC Santa Cruz.
  https://users.soe.ucsc.edu/~ejw/dissertations/Ken-Hullett-dissertation.pdf ·
  https://escholarship.org/uc/item/1m25b5j5
- Ballabio, M. & Loiacono, D. (2019). *Heuristics for Placing the Spawn Points in Multiplayer First
  Person Shooters.* IEEE CoG 2019. https://ieee-cog.org/2019/papers/paper_59.pdf
- Cardamone, L., Yannakakis, G. N., Togelius, J. & Lanzi, P. L. (2011). *Evolving Interesting Maps
  for a First Person Shooter.* EvoApplications, LNCS 6624.
  https://link.springer.com/chapter/10.1007/978-3-642-20525-5_7
- (2026). *Procedural Generation of First Person Shooter Maps using MAP-Elites.*
  https://arxiv.org/html/2605.30570v1 — the 46 topological / 23 emergent metric split, the entropy
  fitness, and the `pace` formula.
- Liapis, A., Yannakakis, G. N. & Togelius, J. (2013). *Sentient Sketchbook: Computer-Aided Game
  Level Authoring.* FDG 2013. http://www.fdg2013.org/program/papers/paper28_liapis_etal.pdf
- Togelius, J., Yannakakis, G. N., Stanley, K. O. & Browne, C. (2011). *Search-Based Procedural
  Content Generation: A Taxonomy and Survey.* IEEE TCIAIG 3(3).
  https://nyuscholars.nyu.edu/en/publications/search-based-procedural-content-generation-a-taxonomy-and-survey
- Smith, G. & Whitehead, J. (2010). *Analyzing the Expressive Range of a Level Generator.*
  PCGames @ FDG 2010. https://dl.acm.org/doi/10.1145/1814256.1814260
- Turner, A., Doxa, M., O'Sullivan, D. & Penn, A. (2001). *From isovists to visibility graphs: a
  methodology for the analysis of architectural space.* Environment and Planning B 28(1):103–121.
  https://discovery.ucl.ac.uk/160/1/turner-doxa-osullivan-penn-2001.pdf
- Benedikt, M. L. (1979). *To take hold of space: isovists and isovist fields.* Environment and
  Planning B 6:47–65. — the origin of isovist area, perimeter, occlusivity, variance, skewness and
  circularity.
- *ARENA — Dynamic Run-Time Map Generation for Multiplayer Shooters.* LNCS 8770 (ICEC 2014).
  https://link.springer.com/chapter/10.1007/978-3-662-45212-7_19 — cited for completeness;
  paywalled, abstract only, not used for any threshold in this document.

**Primary — Valve official**

- *CS:GO Mapper's Reference.* https://developer.valvesoftware.com/wiki/CS:GO_Mapper%27s_Reference —
  player 32×32×72 standing / 32×32×54 crouching; corridors must exceed 32 units; wall thickness
  conventions (≥32 non-penetrable, ≤16 penetrable, ≤8 penetrable by most weapons); crate heights
  (72 = blind, 56–60 = headglitch, ≤44 = see over).
- *Team Fortress 2 Mapper's Reference.*
  https://developer.valvesoftware.com/wiki/Team_Fortress_2/Mapper%27s_Reference — player 49 wide ×
  83 tall; class speeds in HU/s; "scale the entire map up 1.5×" when porting from standard scale;
  sentry detection 1100; explosion radius 146; 2Fort room dimensions.
- *GoldSrc Dimensions* / *Hammer Units.*
  https://developer.valvesoftware.com/wiki/GoldSrc_Dimensions ·
  https://developer.valvesoftware.com/wiki/Hammer_Units
- *Damage* (Official TF Wiki). https://wiki.teamfortress.com/wiki/Damage — 150% at 0 units, 100% at
  512, 50% at ≥1024.

*(The Valve wiki serves an anti-scraping challenge to automated fetchers; these pages were read via
the Wayback Machine.)*

**Curated secondary — cites its sources, is not itself evidence**

- *The Level Design Book* (Robert Yang et al.): [Map balance](https://book.leveldesignbook.com/process/combat/balance),
  [Circulation](https://book.leveldesignbook.com/process/layout/flow/circulation).
  Cites in turn: David Sirlin on balance; Jaime Griesemer, GDC 2010 *Design in Detail: Changing the
  Time Between Shots for the Sniper Rifle*; Sal Garozzo & Shawn Snelling, GDC 2015, CS:GO community
  level design; Matthew "Lunaran" Breit (1999) on Quake map balance.

**Folklore — flagged, not relied on**

- "Three lanes"; "avoid long sightlines"; "cover every N metres"; "dead ends are bad" (contradicted
  by Gee's own controlled study). See §2.3.

**Our own measurements (this project)**

- Stand-side cover band 10–25% within 200 px; failures at 0-of-21, 0-of-17, 0-of-10; the fixed map's
  0 → 18 steals / 6 captures.
- `interiorFrac`: hand-authored arena 0.342 vs generated pool median 0.118.
- Spawn-in-capture-circle: 0-of-22.
- Hard-coded `homeDeepX = 150`: grab→capture 0/6 → 3/4 after steering to the engine-stated endzone.
- `k = 1` route count fatal; `k ≥ 3` required.
- Reference plates ~54% open / ~28% structure; current validator band 4–17%.
- Validator first-attempt pass rate 96%.
- Free field-diagnosis loop: 411 episodes re-simulated in ~9 min, verified 88/88.
