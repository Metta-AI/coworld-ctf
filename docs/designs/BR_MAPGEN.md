# BR Mapgen — rules and guidelines for battle-royale map draws

Status: DRAFT, 2026-08-24. Written by porting the banked doctrine of the
2-team 100-map program (the living sheet at
`https://softmaxwell.apps.softmax.com/preview/mapgen-sheet.html`, Program
notes → gates/rulings/banked assets) onto the battle-royale mode.

**The BR generator is a FORK, not a patch (Maxwell's ruling, 2026-08-24).**
The CTF mapgen keeps its restrictions; BR maps come from a duplicate tool
(`tools/brmapkit.nim`, lane `maxwell/br-mapgen`) that copies the good parts —
caves welded masses, the generate/render/validate loop, anti-confetti triage —
and drops the symmetry/layout/team gates entirely: full-board asymmetric
authoring, 16 ring spawns, flagless spec, BR-specific static validators.

**This document does not restate the CTF program. It says, asset by asset,
what transfers unchanged, what must be re-derived, and what dies.** Anything
marked RE-DERIVE must be measured on a BR corpus before it becomes a gate;
transplanting a CTF number would be a category error (see §3.1).

---

## 1. The mode contract this generator draws for

| | |
|---|---|
| Seats | **32** (`MaxPlayers`, `sim_types.nim:454`) |
| Groups | **16 duos** — 2 seats each |
| Field | **3211 × 1713 px** — `giant` (2.6x), the STOCK 1.874:1 aspect kept (§4.1) |
| `gunRange` | **331 px** BR override (stock 1050) — derived, not picked (§4.1) |
| Spawns | 16 positions equally spaced on an inset rectangle ring, k = 0.85 (§4.2) |
| Convergence | **rectangular** zone, same aspect, drawn center, z: 1.00 -> 0.17 (§4.3) |
| Win | last group standing, scored in glory |

---

## 2. Banked assets that TRANSFER UNCHANGED

These are already proven causal on the CTF corpus. Do not re-litigate them;
port them.

### 2.1 Anti-confetti directive (2026-08-20) — transfers, and gets MORE load-bearing

**BR strengthening (2026-08-24, after three generator rounds drifted into
"confetti on a larger scale with rooms"): structures are SUBTRACTIVE.** A place
is a large solid welded mass — the same visual species as an organic caves
blob — with rooms/courtyards/alleys CARVED INTO it as negative space. Never
thin walls placed additively on open ground; shell thickness is structural
(24-48px), and a compound counts as ONE mass. **Coverage floor (2026-08-24, after round 7 shipped bold-but-barren):
total obstacle cover binds to [110, 170] permille — the upper half of the CTF
program's own validated band (caves_404, accepted, sits at 150‰) — plus a
distance-to-cover gate at combat scale (p95 <= 0.75 gunRange). Mass quality
(subtractive, welded) and mass quantity (the permille band) are separate
gates; three generator rounds conflated them.** The anti-confetti ceiling is a
STANDARD derived from the banked reference aesthetic (caves_404, the Pod
Field), never retuned to fit the current generator's corpus** — the round-5
ceiling drift (28 -> 52) was the backwards ratchet and is the case study.
Weld test + thumbnail test at triage. Welded masses, continuous linear
features, walls with mass, **distinct places**.

In CTF "distinct places" was a legibility rule. In BR it is the core content
unit: a battle royale map *is* a set of nameable places you land at, loot, and
rotate between. A confetti field has no places, so it has no landing decision,
so it has no early game. **The weld test is a hard gate on BR draws, not a
triage preference.** `styleScatter` is disqualified for BR by construction.

### 2.2 The item-pull lever — transfers as loot design
W3d-v2: medkits moved into return-contest zones, geometry otherwise identical,
rate 0.375 → 0.542, fairness held. Items are a first-class balance lever.

In BR this is the *primary* lever, not a secondary one. See §4.4 for the
BR-specific strengthening (the loot/exposure gradient).

### 2.3 Cover on the return leg — transfers as cover on the ROTATION
W1a-E2: W1a's exact geometry plus 8 staggered cover pods screening the
crossings, single lever, conversion 0.250 → 0.583, captures went two-sided.

The dangerous leg in BR is moving between places as the circle closes. Same
lever, different leg: **screened movement must exist between every adjacent
pair of places.** An unscreened crossing under a closing circle is a
firing squad, and it is the BR analogue of the walk-in that W1a-E2 fixed.

### 2.4 Keystone-per-map discipline — transfers, STRENGTHENED
Every map declares the ability it exists to exercise at draw time. BR keystones
differ from CTF's (no carrier-route-selection): landing-selection,
rotation-timing, zone-edge-holding, third-party, cqc-warren/open-steppe.
**BR strengthening (2026-08-24): the keystone is MEASURED, not just named** —
each family carries a detector metric with a floor that other families' draws
mostly fail (calibrated with cross-family evidence, like the density gate). The
keystone drives grammar knobs (archetype mix, size variance, connectors, loot
gradient) and never density placement — §4.7 uniformity binds for every family.
A declared keystone the detector cannot find fails the draw.

### 2.5 The measured-fairness ruling — transfers as the governing principle
> "Static 'twin' structures don't balance; only measured per-home return
> exposure does." (W1b-v2 shelved at conversion 0.667 because red completed
> 1 capture in 24 episodes; 3rd proof W3f-v2.)

**This is why BR is tractable at all.** A 16-group map cannot be made fair by
symmetry — there is no C16 obstacle symmetry, and the program already ruled
that symmetry would not license the fairness claim even if there were. BR
inherits the regime the CTF program already moved to: measure per spawn,
gate on a corpus floor.

---

## 3. The gates — RE-DERIVED

CTF gates: `conversion >= 0.417` · `steal-conv in [0, 0.230]` ·
`minority-capture-share >= 0.140`. All three are flag-objective metrics.

### 3.1 Minority-SPAWN win-share floor — the direct analogue
Same construction (p2.5 of the graded corpus at >=5 wins per spawn), measured
per spawn position instead of per home.

**RE-DERIVE THE NUMBER. Do not port 0.140.** That floor sits against a uniform
of 0.5 (2 homes). At 16 groups uniform is 0.0625, so the CTF number is not
merely miscalibrated, it is above uniform — porting it would fail every map
ever drawn. Derive the BR floor from a BR corpus by the same method.

### 3.2 Contested-finish rate — the conversion analogue
Fraction of episodes whose final elimination occurs with >=2 groups alive
inside the final circle. Catches the same failure conversion catches: the
objective resolving without a real fight.

### 3.3 steal-conversion — DIES
No analogue. Drop it rather than force one.

### 3.4 Ring-bias gate — NEW, BR-specific
Win-share must not correlate with a spawn's distance from the drawn circle
center. A centered shrink structurally rewards central spawns; this is the
BR form of the positional unfairness already measured on 4-team boards
(8.9/8.9/23.2/58.9% by slot block). §4.3 is the mitigation; this is the gate
that proves the mitigation worked.

### 3.5 Certification cost — budget for it
The floor needs >=5 wins per spawn to certify. **16 spawns costs ~8x the
episodes of 2 homes**, and the W1b-v2 ruling forbids pooling spawns by
structural class to cheapen it. Budget the corpus before drawing the family.

---

## 4. New rules BR needs that CTF did not

### 4.1 gunRange is DERIVED from the field, not picked

Stock `gunRange` is 1050 px — deliberately "the SMALL generated map's field
width", i.e. map-wide on the smallest board. On any BR-sized field that means
every group can shoot every neighbour at drop, and there is no landing phase.
Map size cannot fix it; `gunRange` can, because it is a per-map AND per-config
field (`sim_types.nim:947`, `:1062`) and aim jitter is *derived* from the live
value, so "a range override keeps the calibration" (`:384`).

**The rule (alpha = 1): gunRange equals the radius of one group's equal-share
territory disc.**

```
G = alpha * sqrt(W * H / (N * pi))        alpha = 1.0, N = 16 groups
```

**G is a CONSTANT of the map, fixed at draw time. It never changes during the
episode.** The equality is a statement about the DROP moment only: at drop a
group can reach exactly to the edge of the territory it owns by area, and no
further. Nobody gets a free shot at a neighbour; contact requires closing.
Then the zone shrinks territory UNDER the fixed gun — reach stays put while
ownership collapses, and that widening gap is the pressure. A range that moved
with territory would erase exactly the gap the mode runs on (and would retune
aim sigma mid-match, since sigma derives from the live gunRange).

**This is scale-invariant.** Substituting W = 1235s, H = 659s:

```
G = 127.245 * s          W/G = 9.706        H/G = 5.179
```

The field is **always 9.7 gun-ranges long by 5.2 tall**, at every size class.
(For reference: PUBG runs ~27 engagement-ranges across, a mobile BR ~3.3. We
sit between them, nearer mobile — correct for short episodes.)

| class | s | W x H | **G** | sigma | ring spacing | /G |
|---|---|---|---|---|---|---|
| small | 0.85 | 1050 x 560 | 108 | 5.80 deg | 171 | 1.58 |
| standard | 1.0 | 1235 x 659 | 127 | 4.93 deg | 201 | 1.58 |
| large | 1.3 | 1606 x 857 | 166 | 3.79 deg | 262 | 1.58 |
| huge | 1.8 | 2223 x 1186 | 229 | 2.74 deg | 362 | 1.58 |
| **giant** | **2.6** | **3211 x 1713** | **331** | **1.89 deg** | **523** | **1.58** |
| colossal | 5.2 | 6422 x 3427 | 662 | 0.95 deg | 1046 | 1.58 |

**Do not be alarmed by sigma.** A shorter range raises the ANGULAR spread, but
linear accuracy at max range is invariant by construction: G * sigma_rad =
w / Z = 14 / 1.2816 = **10.9 px at every row in that table** (stock included).
The gun behaves identically at its own max range whatever the override; only
how far that range reaches changes. This is exactly why the override is cheap.

**Pick the class by EPISODE LENGTH, since that is the one thing that is not
scale-invariant** — move speed is a fixed px/tick, so colossal takes 2x giant's
traverse time. Recommend **giant (2.6), G = 331**: half the traverse of
colossal, and it avoids colossal's known wire problems (8 of 20 colossal seeds
measured 65,555-73,549 bytes against the uint16 mapSpec ceiling, and map art
degrades on the largest boards). Gameplay shape is identical either way.

### 4.2 Spawns are a JITTERED GRID — and spawn areas are NOT kept empty
**(Maxwell's rulings, 2026-08-24, superseding the ring-spawn derivation that
stood here.)** Three rules:

1. **Spawns sit on a jittered grid across the WHOLE field** (16 groups ->
   a 4x4 grid, jittered within cells, minimum separation enforced), not on a
   perimeter ring. The ring was solving rotational fairness geometrically;
   fairness is measured per spawn (§3.1), so the geometry constraint buys
   nothing and starves the field edges of structure.
2. **No spawn keep-away. "We banned that."** Spawn points need to BE on
   walkable floor and nothing more; structures may stand immediately
   adjacent — a spawn in a compound's yard is a feature (a landing site),
   not a violation. The pocket carve is only the tiny floor a duo occupies
   (~70px, unscaled — a duo is 2 bodies), never a placement exclusion zone
   for terrain. Every prior round's mid-band clustering traced to
   keep-away radii; the rule itself was the bug.
3. **The exit rule (§4.5) still binds at spawns**: a spawn adjacent to
   structure must still have >=2 ways out. That is the fairness floor for
   spawn-adjacent terrain — not emptiness.

### 4.3 The zone is a RECTANGLE of the stock aspect, on a drawn center

The field keeps the stock 1.874:1 aspect so the replay pipeline is unchanged.
That makes a circular zone wrong: a circle inscribed in a 1.874:1 rectangle
abandons the long axis, so ~47% of the field could never host an endgame.

**The zone is a rectangle of the same 1.874:1 aspect, scaled uniformly about a
drawn center.** A single scalar z drives it, no axis is wasted, and the endgame
arena is geometrically similar to the field the policies trained on.

**Zone art ruling (Maxwell, 2026-08-24, FINAL — supersedes the tide/stormfront
and seepage-noise directives below): the dead region is rendered with the
game's OWN floor-splat paint decals (David's existing paint-on-ground style) —
overlapping splats drowning the floor deep in the dead area, discrete splats
creeping inward at the frontier. Reuse the existing splat rendering; invent no
custom frontier renderer. "We already have the design style, just do that."
The zone then reads as what it mechanically is: painted floor that hurts to
stand on. Honest boundary unchanged (damage = clamped rect; splat coverage ⊇
rect complement; safe rect clean).**

**Render the edge as a THING, not a line.** (Historical directive — see the
splat ruling above.) The advancing boundary is the
mode's protagonist-clock and deserves art: an advancing paint tide / spray
stormfront with body, animated (approach shimmer outside, a churning front at
the edge, dead paint behind). Build it on the cosmetic-FX-seq channel (copy
`damagePops`; HASH the sprite label so no text leaks into the policy
vocabulary). The POLICY-facing contract is separate and minimal: the zone
rect published per frame as a label — `labelEndzone`'s inclusive-corner rect
grammar is the ready template. Art may be as clever as it likes; the label
must stay boring.

**The center is DRAWN, not fixed at map center.** A fixed center makes a strong
middle decide every episode and hands central spawns a permanent edge. Drawing
it creates the BR analogue of "function-symmetric on the return leg", and it is
this document's central guarantee:

> **Every drawable zone center must yield a viable endgame arena.** For each
> candidate center, the enclosed rectangle must independently satisfy the place
> rule (§4.5), the rotation-cover rule (§2.3) and the exit rule (§4.5).

A map that is excellent in the middle and a bare pan in the north-west is not a
fair BR map; it is a map with a hidden 1-in-N coinflip.

**Final zone: z = 0.173**, sized so the last ~3 groups sit at territory radius
0.4G — well inside gun range, so the finish is forced but still has room for
cover play. That is 3.00% of field area (real BR final circles run 1-2%;
slightly generous is right for 16 groups in a short episode). On giant that is
a **556 x 297 px** arena.

**Phase schedule.** The invariant that matters is R/G = z * sqrt(16/n): a
group's territory radius in gun-ranges, which must fall MONOTONICALLY even as
eliminations push n down and R back up. Tune wait / shrink-duration / DPS per
phase ([BR practice](https://gamedesignskills.com/game-design/battle-royale/):
long waits + low damage early, short waits + high damage late), but keep this
column monotone or the map stops applying pressure mid-match:

| phase | z | n (expected) | R/G |
|---|---|---|---|
| 0 (drop) | 1.00 | 16 | 1.000 |
| 1 | 0.75 | 12 | 0.866 |
| 2 | 0.55 | 8 | 0.778 |
| 3 | 0.40 | 6 | 0.653 |
| 4 | 0.28 | 4 | 0.560 |
| 5 (final) | 0.17 | 3 | 0.393 |

### 4.4 Loot value must scale with exposure
The item-pull lever (§2.2), strengthened into a gradient: the richest kit sits
in the most exposed place. This is what makes the landing decision a decision
rather than a lottery, and it is the mechanism that keeps early game from
being uniform.

### 4.5 Every place must be leavable under fire
**No place has a single exit.** In CTF a dead end costs you a fight; in BR,
under a closing circle, a one-exit place is a death sentence and the map has
silently eliminated whoever landed there. This is a hard gate at triage,
checkable statically from the walk mask.

Corollary, inherited from BR level-design practice and consistent with the
weld test: no long corridors, no rooms with difficult exits, and no rotation
that forces every path through a single choke.

### 4.6 Cover that is good but never safe
A position that is both strong and unexposed is a camping attractor, and the
shrink exists precisely to punish camping. The `interiorFrac` lever
(subdivide the largest room) applies harder here than in CTF.

---

### 4.7 Density is UNIFORM across the field (Maxwell's ruling)
"For battle royale, the room and obstacle density needs to be roughly
uniform across the entire map, not focused in the center." No center-heavy
composition, no major-POI-dominates-the-middle grammar. Structures and
obstacles place by uniform sampling with minimum separation over the whole
field; archetype VARIETY provides the distinguishable places, not a density
hierarchy. Enforced, not aspired: a density-uniformity validator (structure+
obstacle area per cell of a fine grid within a band of the field mean) is a
hard gate, the same class as the distribution gate it supersedes.

### 4.8 Knobs become SWITCHES; buildings CONJOIN (Maxwell's rulings, 2026-08-24)
Two late rulings on the generator's shape:
- **Conjoined complexes by deterministic accretion**: buildings grow by a
  global process — each new unit hash-flips (hash(mapSeed, unitIndex), own
  lane per decision) between ATTACHING to an existing complex (welded shared
  walls, doors punched via the unit-adjacency spanning tree, grammars MIXED
  within a complex) or FOUNDING a new site. Complex sizes emerge (singles up
  to rare 12-16-unit fortresses); several complexes per map is the normal
  case. minSep applies between complexes only — it was the rule that kept
  every building solitary for ten rounds.
- **Top-level THEME SWITCHES over the knobs**: TERRAIN (cave | building |
  mixed) and THEME (interior | exterior) — named presets over existing
  parameters, declared in the spec, and MEASURED like keystones (a declared
  switch the detector cannot find fails the draw). Keystone families compose
  with switches; incoherent combos are reported, not forced.

## 5. Draw and triage discipline — port the PROCESS, not just the rules

The 2-team program's best asset is not any single gate, it is how it establishes
causality. Port this wholesale.

### 5.1 The single-lever rule — this is what makes a claim causal
Both banked levers are **the exact same geometry plus one change**. W1a-E2 is
W1a plus 8 cover pods, items untouched. W3d-v2 is W3d's exact geometry with
only the medkits moved. That is why "cover on the return leg is a proven causal
lever" is a claim and not a vibe.

**A BR balance change is a single-lever A/B on otherwise identical geometry, or
it is not evidence.** Two changes at once buys you a number you cannot
attribute, and on a 16-spawn corpus you will not have the episodes to
disentangle it afterwards.

### 5.2 The cell ladder
`open` -> `in flight` -> `GRADING` -> `banked` | `closed`. Each cell belongs to
a family (e.g. `open-field-e2pods`) and lands in a wave. A cell declares its
keystone at draw. Families carry certs; a cert holding is what lets a later
draw inherit the family's evidence instead of re-earning it.

### 5.3 Triage is two cheap tests before any episode is spent
The **weld test** and the **thumbnail test** run at triage. Both are static and
near-free, and they kill confetti before it consumes corpus budget. Keep them
first — the certification cost in §3.5 is the reason triage must be ruthless.

### 5.4 Renders are true engine art; heat composites ON the art
Never gray. Heat views are log-scale + percentile clip composited over the real
render, so a heat read and an art read are the same picture. A BR sheet needs a
third view the CTF sheet does not: **circle-center coverage**, showing which
drawn centers were sampled and how each scored (§4.3).

### 5.5 A human vote is part of the gate
good map / not it / suggestion-to-rework-queue. The metrics gate fairness; the
vote gates whether it is a *place* anyone wants to watch. BR raises the stakes
on the second — the mode's whole thesis is entertainment.

## 6. Known blockers — SCOPED (two scout reports, 2026-08-24)

Sources: a spawn-anchor scope run against `origin/main` @ bfd5e9c, and a
Team-widening census run against local main @ 686bbde (10 days stale — its
structural findings hold, its line numbers may drift, and its one
symmetry-dependent conclusion is superseded; noted below).

### 6.1 Spawn placement — #285 has a fix in flight; BR needs a subsystem
- **PR #287** (`spry-dingo/285-team-anchors`, ~76 lines, unmerged) adds
  `teamAnchors: seq[MapPoint]` to the spec — gated to `symNone` +
  `layoutSides` + exactly 2 points. Land it; it is the literal #285 fix and
  NOT the BR unlock.
- **The weld:** `flagHome` IS `teamAnchor` verbatim; the spawn pocket carves
  around it; compact endzones center on it; `spawnPosition(team, order)`
  staggers players off it. No spawn-point concept independent of a pedestal
  exists anywhere.
- **The template to imitate:** `TeamPickupPoints.barriers` — a validated,
  flattened `seq[MapPoint]` already round-tripped through the spec. BR spawn
  points should be that shape, spawn-typed.
- **Flagless is the easy part:** flag/endzone code paths simply are not
  called in a flagless mode; only the `teamAnchor`-keyed carve needs a
  spawn-only branch.
- Sized: types **M**, arena carve/validator/spec **L→S**, sim_state placement
  **M**. Tractable. The dominant piece is 6.2.

### 6.2 Group identity: WIDEN `Team` TO 16 (recommendation)
The alternative — a squad concept decoupled from `Team` — dodges nothing:
16 duos need 16 VISUAL identities (friend/foe legibility) and 16 score
ledgers regardless, so the art cost and the identity plumbing land either
way, plus a second parallel identity system. Widen the enum. The census
priced it:

- **Free (a third to half of team-aware code):** everything iterating
  `activeTeams`/`sim.teams()` generically — broadcast beat pipeline, scoring
  math, label builders (generic `color: string`), art-path loaders
  (string-built from `teamText`).
- **Mechanical (~30-40 sites):** three `[2,4]` gates that must move together
  (`activeTeams` doAssert / config validate / `generateMapAttempt`);
  ~13 exhaustive `case team` switches; ~9 color-word choke points each
  needing the full 12-word extension. The retro `Palette` is 16 entries —
  exactly 16 teams map 1:1, no palette resize.
- **GameVersion bump, NOT a safe append:** scalar `Team` fields append
  safely, but `array[Team, X]` fields inside the flatty-serialized
  `SimServer` (`flags`, `config.handicaps/perks`, `RewardAccount.wins/games`)
  are fixed-width runs with no length prefix — widening misaligns every
  subsequent field of an old keyframe, silently. Precedented (GV42/43
  re-records); old replays freeze as legacy.
- **The sleeper: sprite/object wire-ID pools hardcode literal 4-multipliers**
  (~15 sites — flag/aura/planted/carry-heart/selected/score/endzone-fade
  pools). Nothing catches an overflow at compile time; `ord(team)` walks past
  the declared width and corrupts a NEIGHBORING pool's art at runtime. This
  exact failure shipped once already (the 2026-08-02 4-team black-stripe).
  **Rule: derive every pool width from `Team.high`, never a literal, and
  assert non-overlap from the derived widths** — turning the hazard into a
  compile error. (Bonus: the IdentityBadge pool's declared width is already
  understated at 4 teams — fix in passing.)
- **Art: 12 new identities — build the TINT PIPELINE, do not hand-author.**
  4 authored sets exist (soldier/rig/heart/ped: ~180 new files if
  hand-painted). The engine has no tint step today, but the code loads by
  `teamText`-built path, so a bake-time tint-from-base-hue writes into the
  same contract. 12 hues x automated tint beats 180 commissioned images.
- **SUPERSEDED census conclusion:** "16 teams needs a new TeamLayout + a new
  16-fold symmetry group, authored from scratch." That was true of the old
  regime the stale branch shows. `origin/main` has **symNone full-board
  authoring merged (#280)** — BR maps carry NO symmetry group at all;
  fairness is the measured floor (§2.5, §3.1). What remains real from that
  finding: `generateMapAttempt`'s 2/4-team branches need a BR path, and BR
  play is 100% procedurally generated (all hand-authored + pool maps are
  2-team).

### 6.3 RESOLVED — the 1.874:1 aspect is kept deliberately
The aspect is kept so the replay pipeline is unchanged; the zone is a
rectangle of the same aspect (§4.3). No generator change needed for field
shape.

### 6.4 `colossal` is override-only — moot for v1
v1 targets giant, which the pool draws.

### 6.5 Sequencing
1. Land #287 (the literal #285 fix — small, in flight).
2. The `Team` widening + GV bump + pool-width derivation, as ONE change with
   the tint pipeline.
3. Flagless N-point spawn subsystem (6.1), on the widened enum.
4. The zone mechanic (new; §4.3) + its per-frame label.
5. First BR family draw under §3's ungated bootstrap.

### 6.6 Mode hardening from prior-art field evidence (2026-08-24)
Three findings from a study of hosted battle-royale replays, folded into the
mode:
- **Timeout is DRAW-FREE**: a strict total order (living > last-death tick >
  kills > damage > slot) — the reference eliminated draws because draws bred
  passive double-death play. Mid-match simultaneous-wipe draws remain.
- **Late-phase zone pricing must be lethal**: field evidence — weak rings
  (0.5 HP/s vs 20 HP) failed to force endgames; 2/8 reference matches hit the
  clock and were won by survival farming. Final phases kill in seconds.
- **Per-episode spawn-assignment rotation**: team→grid-point binding rotates
  by episode seed, so no team owns a position across episodes (composes with
  the measured per-spawn fairness floor, does not replace it).
Noted, not adopted: exposure-drain (our damage has no ramp to exploit);
their 62-key wire vocabulary (podium/assist/passivity — glory-port material).

## 7. Open questions

1. The BR corpus floor (§3.1) cannot be derived until a BR corpus exists.
   Bootstrapping order: draw a family, run it ungated, derive the floor, then
   gate retroactively.
2. Seats-per-policy. 16 duos implies 16 distinct policies per episode; if the
   platform seats fewer, one policy holds several duos and fights itself,
   which makes the scoring ambiguous.
3. Whether the shrink should damage or hard-kill, and whether glory prices
   circle-edge holding (it should — it is coup-counting in its purest form).
   **Glory-port constraint (from the same replay field evidence): any
   survival-derived scoring term must CAP or TAPER late — in clock-capped
   games observed in the field, survival points outscored fighting and farming beat the
   final fight. The timeout tiebreak's alive-count key is acceptable only
   because lethal late phases make clock-outs rare; a glory-scored BR must
   not reintroduce the farming vector through survival deeds.**
