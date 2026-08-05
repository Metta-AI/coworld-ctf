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
at the stand. See §4.3 for the full derivation.

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
