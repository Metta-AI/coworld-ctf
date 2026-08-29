# The Battle Royale rung ladder for `stencil`

**Status: DESIGN, 2026-08-29.** Written for James Boggs, who owns the stencil
rework and the scoring hook. This document owns the **BR rung vocabulary** and
the **determinism/replay** side of it. It is a proposal to react to, not an
implementation plan — no policy code is written here, and nothing in
`player_labs-jboggsy/paintbot_lab/` was modified to produce it.

Ground truth read for this document:

- `paintbot_lab/docs/reports/stencil-policy-loop-2026-08-29.md` (v68 loop explainer)
- `paintbot_lab/docs/designs/nav-layer4-intent-contract-2026-08-13.md` (v66 Intent contract)
- `paintbot_lab/paintbot/stencil_nim/` at `origin/main` = `eac564f` — specifically
  `strategy.nim`, `types.nim`, `squads.nim`, `roles.nim`, `items.nim`,
  `policy.nim`, `belief_update.nim`, `worldmap.nim`, `fight.nim`.
- Battle Royale mechanics in `coworld-ctf` @ `b800d17` (branch
  `maxwell/br-restack-assembly`).

Every stencil citation below is `file:line` against `eac564f`. Where a claim is
a *judgement* rather than a citation it is marked **(judgement)**; where it is
unverified it is marked **(UNVERIFIED)**.

---

## 0. Executive summary

Three things, in descending order of how much they should change your plan.

**Stencil cannot currently take the field in BR at all, for reasons upstream of
the ladder.** Three hard blockers sit in `policy.nim` and `types.nim`, all of
them structural rather than behavioural: the `Team` enum has four values and BR
has sixteen teams (`types.nim:8-12`, `policy.nim:30`); the `WorldMap` — which is
*all* map knowledge — is built only once every endzone has been perceived
(`policy.nim:39-40`), and BR has no endzones, so `decideBaseObjective` returns
`hold("no_worldmap")` forever (`strategy.nim:303-305`); and the `seatsPerTeam`
heuristic returns 4 for a duo (`policy.nim:34-37`). None of these is a ladder
problem. All three must be closed before a single BR rung can be measured.
§7 lays them out.

**The ladder's kill list is bigger than the survivor list, but the salvage is in
the goal producers, not the rungs.** Nine of the fourteen rungs are heart,
pedestal or endzone shaped and die outright (§1). But `barrage_center`'s goal
producer — pick the most open, least dangerous room peak from the watershed
topology (`strategy.nim:85-111`) — is *exactly* what a zone-collapse rung wants,
and `clear_spray`'s 16-direction local scorer (`strategy.nim:194-282`) is
exactly what a "fall back" rung wants. The BR ladder is mostly a re-pointing of
existing producers at new named points, not new machinery.

**The authorable-rung goal is reachable, and it costs two specific
parameterisations.** §6 enumerates the goal-source vocabulary BR needs and works
James's own "fall back" example through it. It is expressible — but only if (a)
the local ring scorer takes a **weight vector as a parameter** instead of
reading module consts (`strategy.nim:248-249`), and (b) the **threat-track
filter** that supplies its anchor is parameterised instead of hardcoded to
`weapon == WeaponSpray` (`strategy.nim:168-170`). Those two refactors are what
turn "a new rung needs an engineer" into "a new rung needs a table row". They
are small, and they are on the rework path anyway.

---

## 1. The kill list — rungs that are meaningless in BR

The ladder is `strategy.nim:302-473`, first-match-wins. A rung dies in BR when
either its **trigger** can never be true, or its **goal producer** addresses a
map feature that does not exist. Both failure modes matter, and they are
different: a dead trigger is inert (harmless, wasted branch); a dead goal
producer is worse, because if the trigger *does* somehow fire the producer
resolves a garbage point or falls through unpredictably.

| rung | strategy.nim | dies because | failure mode |
| --- | --- | --- | --- |
| `carry_home` | 322-324 | trigger `iCarryHeartOf` needs a heart; goal `map.capturePoint(team)` needs an endzone (`worldmap.nim:1078`) | both dead |
| `intercept_thief` / `_heard` | 326-330 | trigger `ownHeartStolen` needs an own heart; `thiefFix` is set only by a `thief` shout (`belief_update.nim:262`) | both dead |
| `escort_carrier` / `_heard` | 377-393 | trigger walks `belief.hearts` for an ally-carried heart | both dead |
| `early_defense` | 358-365 | goal is `earlyDefensePostForSeat` — an atlas post *inside the team endzone* covering the home-room choke (`roles.nim:77-106`); release condition `everyEnemyTrailsLives` reads per-colour `teamScores.deaths` (`squads.nim:143-157`) | both dead |
| `steal` | 466-473 | goal is `stealGoal` → planted heart or `map.pedestal(target)` (`strategy.nim:284-292`) | both dead |
| squad order `M`/`W`/`H` | 413-451 | the *content* of every order is `advancePoint`, an interpolation from `map.homeCenter(team)` to `map.pedestal(opponent)` (`squads.nim:214-236`) | goal dead, trigger alive — **dangerous** |
| `to_post` / `hold_post` | 453-464 | `defensivePostForSeat` bands outward from `homeCenter` toward `mostDirectOpponent` (`roles.nim:31-75`) | goal dead |
| `to_hold` / `hold_line` | 453-464 | `holdPointForSeat` is `defenseGate(team)` offset perpendicular to the `center − home` axis (`roles.nim:12-29`) | goal dead |
| `hunt_fallback` | 466-471 | `convertHuntPoint`'s terminal fallback is `pedestal(weakestEnemyColor)` (`squads.nim:186-190`) | goal partly dead |
| `barrage_center` | 349-356 | trigger is `belief.barrage`, decoded from the CTF barrage marker; **(UNVERIFIED)** no barrage in BR | trigger dead, **goal is the best donor in the file** |

Two entries deserve emphasis.

**The squad-order rung is the dangerous one.** Its trigger — `belief.order` set
and fresh — is entirely alive in BR, because consensus runs on seats and shouts,
neither of which cares about hearts. Only its *payload* is dead. So a naive port
leaves a live rung, sitting above defender posture and the steal fallback,
navigating to a point interpolated between two coordinates that mean nothing.
It will validate through `nearestReachable` (it is a real pixel) and the agent
will walk there with conviction. This is the failure mode the kill list exists
to catch: an unreachable goal is a loud bug under the v66 contract
(`nav-layer4:109-115`), but a *meaningless reachable* goal is silent.

**`barrage_center` should be killed by trigger and resurrected by producer.**
`barrageGoal` (`strategy.nim:85-111`) scores every watershed room peak in the
agent's own component by `openness − BarragePeakDangerWeight × normalised plan
danger`, falls back to `map.center`, and validates through `reachableGoal`. Swap
"every room peak" for "every room peak inside the next zone circle" and add a
route-cost term and that is `zone_rotate` (§3). It is the single highest-value
piece of salvage in the ladder.

---

## 2. The survivor list — checked, not assumed

### `clear_spray` — survives, and gets *more* valuable

Trigger is `updateSprayFleeLatch` (`strategy.nim:159-192`): enemy tracks whose
`weapon == WeaponSpray` within `SprayFleeTriggerPx`, with a release hysteresis.
Purely local perception, no map addressing. Goal is a 16-direction × 2-ring
local scored flee validated through `reachableGoal` (`strategy.nim:194-282`).

Carries over unchanged **provided the spray weapon exists in BR** (UNVERIFIED —
see §7). It gets more valuable, not less: under one life the thing it prevents
is the whole score.

One free upgrade: the scorer already has a `centerTerm` that pulls toward
`map.center` *during a barrage* (`strategy.nim:242-247`). That term is
structurally "pull toward safe ground during a shrinking hazard". Re-point it
from `map.center`/`barrage.depth` to `zone.center`/zone pressure and
`clear_spray` becomes zone-aware for zero new machinery — and stops fighting
`zone_escape` for control, which is why I rank it *above* `zone_escape` in §3.

### `clear_grenade` — survives in form, near-dead in practice

This one does not survive the check. `belief.grenadeWarnings` is written at
exactly one site — `belief_update.nim:268`, inside the inbound-chat decode, on a
`grenade` shout. It is **not** a perception of an enemy grenade. It is an ally
saying "I am charging a grenade at (x,y), clear the blast."

Consequences in BR duos:

- The number of possible sources drops from 7 (a CTF 8-seat team) to **1**.
- When the partner dies, the rung is permanently dead for the rest of the
  episode — which, in a one-life mode, is a large fraction of it.
- It never protected you from *enemy* grenades and still doesn't.

So: keep it (it is cheap and correct), but do not count it as BR coverage. If
grenades are a real BR threat, the useful version is perception-driven — an
enemy track observed with `hasGrenade` (the field already exists,
`types.nim:46`) inside throw range, or a grenade impact in `heardImpacts`. That
is new perception work, not a ladder change, and I am flagging it rather than
proposing it.

### `fetch_medkit` / `fetch_item` — survive, but must be re-priced

The discovery half is clean: `itemSpawns` are learned from
`percept.visibleItems` with a 24 px match radius and an absence/respawn clock
(`items.nim:39-67`). No map addressing at all.

The *pricing* half is heart-shaped in one place. `evaluateFetch` prices a
detour against an **anchor** (`items.nim:91-152`), and the anchor comes from
`itemAnchor` (`strategy.nim:294-300`): squad order position, else defender hold
point, else `stealGoal`, else `map.center`. Three of those four are dead in BR.

The fix is small and improves the architecture: **pass the anchor in.** The
anchor should be the goal point of whichever rung would have won had the item
not existed. That is a genuinely better contract than re-deriving it, and it is
the shape a scored ladder wants anyway (§6: the item rung prices its detour
against the current argmax).

Two re-pricings the scoring function demands (**judgement**):

- `medkitTarget` refuses to fire unless `hpPips < 3` (`items.nim:155`), and
  `evaluateFetch` skips medkits on the same gate (`items.nim:102`). Under three
  lives that is right. Under **one** life, health is placement equity and any
  missing pip should qualify.
- `MedkitConvenientDetourPx` is a *convenience* budget. In BR a medkit is worth
  a large, deliberate detour, not a convenient one. I would expect the BR value
  to be several times the CTF value; I have no measurement to name a number.

### `convert_hunt` — the trigger inverts; do not port it as-is

Trigger is `wipeInReach` = `enemyLivesLeft <= ConvertEnemyLives`
(`squads.nim:172-174`), computed from `teamScores` deaths against
`seatsPerTeam × LivesPerPlayer` (`squads.nim:130-141`, `config.nim:69`). In CTF
this is a real edge: a team on its last lives can be *wiped*, and a wipe
converts into a durable advantage.

In BR the arithmetic does not merely fail to compute, it points the wrong way.
The placement table pays nothing for kills; every enemy already has exactly one
life; and an even trade costs you your entire remaining placement equity to
remove 1/31st of the field. "The enemy is weak, go finish them" is a CTF theorem
that does not survive the change of scoring function.

What survives is narrower: **fight only from asymmetry**. That becomes
`third_party` (§3), which is a different rung with a different trigger, not a
re-pointed `convert_hunt`.

`convertHuntPoint` itself (`squads.nim:176-191`) is still a useful *producer* —
nearest visible enemy, else newest fresh track — as long as its terminal
`pedestal(weakestEnemyColor)` branch is replaced.

### `rejoin` — survives mechanically, breaks catastrophically. See §5.

### `arc_pursuit` — survives if the arc/spray weapon exists

The wrapper at `strategy.nim:475-488` overrides the base decision when the agent
holds the arc weapon and an enemy sits in the `(ArcIdealRangePx,
ArcPursuitRangePx]` band. No map addressing. Survives verbatim — but note it
*overrides every rung below it*, which in BR means it can override `zone_escape`
if `zone_escape` is placed below it. It must not be. **(judgement)**

### Local geometry from `squads.nim` — survives cleanly

`separationBias` and `formationBias` (`squads.nim:76-110`) are pure local vector
maths over teammate positions. They degrade to n=2 perfectly and are worth
keeping even if the consensus layer is switched off (§5).

---

## 3. The new BR rungs

Each rung is given in three parts, per the decomposition this document is
designed around:

- **trigger** — a predicate over named, perceivable facts;
- **goal source** — a combinator from the §6 vocabulary that produces a
  candidate point, then `nearestReachable(point, selfXy)` — the single validator
  every producer already routes through (`strategy.nim:80-83`,
  `worldmap.nim:369-403`). If it returns `none`, the rung is not a candidate.
- **Intent fields** — `profile`, `arriveRadius`, `movingGoal`, `micro`, and
  (per James's latest ruling) per-Intent firefight weights.

Proposed order, top rung first. Justification against the scoring function is
§4; this section is the specification.

### 3.0 `no_worldmap` → Hold — unchanged (`strategy.nim:303-305`)

### 3.1 `clear_grenade` — unchanged, see §2

### 3.2 `clear_spray` — unchanged trigger, `centerTerm` re-pointed at the zone

### 3.3 `zone_escape`

- **trigger** `not zone.contains(self)` — I am outside the live circle and
  taking zone damage.
- **goal source** `Nearest(inside: zone, from: self, margin: ZoneSafeMarginPx)`
  — the nearest point strictly inside the live circle by a margin. Validated
  through `nearestReachable`; if the nearest inside-point is in another
  component (a wall between me and safety) the ring search finds the nearest
  standable pixel in *my* component instead, which is the correct behaviour and
  is free.
- **Intent** `profile = ProfileHunter` (0.25× danger weighting — you must cross
  contested ground; the zone kills you with certainty, an enemy only might),
  `movingGoal = true` (the circle contracts under you), `micro = {}` (no peek,
  no duck, no separation — this is a sprint), `arriveRadius = ZoneSafeMarginPx`,
  firefight weights biased hard toward *not* stopping to fight.
- **note** placed *below* `clear_spray` deliberately: a point-blank sprayer
  kills in ~2 s, the zone in tens of seconds. With the zone term folded into
  `clear_spray`'s scorer (§2) the two rungs mostly agree anyway, so the ordering
  rarely binds.

### 3.4 `fall_back` — James's example, promoted to a first-class rung

- **trigger** `hpPips <= FallBackHpPips and (underFire or firefightActive)`. All
  three facts exist today: `belief.hpPips` (`belief_state.nim:66`),
  `belief.underFire` (:72), `belief.firefightActive` (:73).
- **goal source** `ScoredLocal(dirs: 16, rings: 2, anchor: threat.centroid,
  weights: {threat: +1.0, cover: +0.6, zoneSafety: +0.8, clump: −0.4})` — i.e.
  `clear_spray`'s scorer with a different anchor and a different weight vector.
- **Intent** `profile = ProfileCarrier` (2.5× danger — evade),
  `movingGoal = true`, `suppressFireFreeze = true` (shoot while withdrawing —
  this is what the flag is for, `action.nim:438-442`), `micro = {}`,
  `arriveRadius ≈ 40`.
- **why it is a rung and not a modifier** the CTF ladder has no disengage. It
  has `clear_spray`, which is a specific weapon-avoidance behaviour, and it has
  nothing that says "I am losing this fight, my life is my score, leave." Under
  three lives that omission is defensible. Under one it is the largest hole in
  the ladder.
- **see §6** — this rung is the test case for whether the vocabulary is real.

### 3.5 `fetch_medkit` — survivor, re-priced (§2)

### 3.6 `partner_support`

- **trigger** partner track is fresh, and (partner is `underFire` — knowable
  only via their `under_fire` shout, `belief_update.nim:269-271` — **or**
  partner's `hpSegments` is below threshold and an enemy track is within
  `SupportRadiusPx` of them), and my own HP is healthy.
- **goal source** `Track(selector: partner, lead: projected)` using
  `projectedTrackPos` (`belief_state.nim:156`).
- **Intent** `profile = ProfileDefault`, `movingGoal = true`,
  `micro = {MicroFormationBias, MicroSprayPursuit}`, `arriveRadius ≈ 56`.
- **rationale, and its dependency** in duos a 2v1 is the only *reliably*
  asymmetric fight available, and asymmetric fights are the only fights the
  scoring table likes. But the whole rung's value hinges on **which death
  determines the duo's placement** — last member out, or first? If placement is
  scored at the last member's death, keeping the partner alive is directly
  placement equity and this rung is high-value. If it is scored at the first,
  the rung's value collapses to "a live partner shoots for me." I do not know
  which, and it is my #1 uncertainty (§8).

### 3.7 `partner_regroup`

- **trigger** partner alive (`squadmatesAlive >= 1`, `squads.nim:193-198`) and
  separation > `RegroupPx` and no squad contact (`inSquadContact`,
  `squads.nim:515-522`).
- **goal source** `Track(selector: partner, lead: none)`.
- **Intent** `profile = ProfileDefault`, `movingGoal = true`,
  `micro = {MicroFormationBias}`, `arriveRadius ≈ 80`.
- **note** this is the honest replacement for the `rejoin` rung, which in BR
  degenerates into an infinite walk toward a nonexistent home (§5). Unlike
  `rejoin` it is *unarmed* when the partner is dead, which is the whole point.

### 3.8 `third_party`

- **trigger** two or more fresh enemy tracks **from different teams** within
  `FightRadiusPx` of each other; at least one showing `hpSegments` below full;
  recent `heardImpacts` near their centroid; my HP healthy; neither track aimed
  at me. This is the rung with the weakest perception story — see below.
- **goal source** `ScoredRegion(candidates: atlasNear(fightCentroid,
  ThirdPartySearchPx), weights: {sightline to centroid: +1, cover: +0.8,
  approach-avoidance: +0.6})` — i.e. `selectRankedPost` (`worldmap.nim:841`)
  over a region, which is the machinery `orderPost` already uses
  (`squads.nim:482-499`).
- **Intent** `profile = ProfileDefault`, `arriveRadius = HoldArrivePx`,
  `micro = {MicroPeekDuck, MicroSeparation}`, firefight weights biased toward
  **wounded** targets (raise `FirefightWoundWeight` for this Intent only).
- **the honest problem** stencil has no "these two are shooting each other"
  percept. The proxy above (two different-team fresh tracks, close, damaged,
  impacts nearby) is inference, and it will produce false positives on two
  enemies who merely happen to be near each other. I would ship this rung
  *disabled by default* and let a playbook page turn it on (§6), rather than
  claim it works. It is also the only rung in the ladder that deliberately seeks
  combat, which makes it the one most likely to be net-negative.

### 3.9 `fetch_item` — survivor, anchor re-pointed (§2)

### 3.10 `zone_rotate` — the workhorse

- **trigger** `zonenext` is published, and my projected position is outside the
  next circle (or within `RotateMarginPx` of its edge), and
  `estimatedTravelTicks(nextGoal) × RotateSafetyFactor >= ticksUntilShrink`.
  The travel estimate is free: `map.routeDistance` (`worldmap.nim:919`) already
  exists and is what `evaluateFetch` uses for exactly this kind of pricing.
- **goal source** `ScoredRegion(candidates: room peaks ∩ zonenext, weights:
  {−routeCost, −planDanger, +openness, −distanceFromNextCentre})`. This is
  `barrageGoal` (`strategy.nim:85-111`) with a region filter and one extra term
  — the salvage named in §1.
- **Intent** `profile = ProfileDefault` early / `ProfileCarrier` late
  (**judgement**: once the field is small, routing around danger is worth the
  extra distance), `movingGoal = false` (the next circle is static once
  published — this matters, it keeps the planner cache alive across the whole
  rotation), `arriveRadius ≈ 64–80`,
  `micro = {MicroPeekDuck, MicroSeparation, MicroSprayPursuit}`.
- **ordering caveat, and it is important** the correct priority of
  `zone_rotate` versus `hold_zone_ground` is *time-dependent*: early in a phase
  holding is right, late in a phase rotating is right. **No fixed ladder
  position is correct for this pair.** That is the strongest single argument in
  this document for the scored-ladder reframe (§6), and I would not want the
  MVP to ship a fixed order here without a time-pressure modifier.

### 3.11 `hold_zone_ground` — the default posture

- **trigger** inside the safe circle with margin, and nothing above fired. This
  is the terminal rung; it replaces both the defender-post family and the
  `steal` fallback.
- **goal source** `ScoredRegion(candidates: atlasNear(preferred band inside
  zone), weights: {cover: +1, sightline toward zone interior: +0.8,
  −planDanger, band preference})`. Uses `rankedAtlasPosts`
  (`worldmap.nim:792`) — the same post machinery defenders use, with the home-
  relative banding replaced by a zone-relative one.
- **Intent** `Hold` on arrival, `arriveRadius = HoldArrivePx`,
  `micro = {MicroPeekDuck, MicroSeparation}`, `profile = ProfileDefault`.
- **the band question, flagged as a hypothesis** I would prefer a post *some
  way inside the zone edge* over one at the centre: near the edge, threats can
  only come from a restricted arc, whereas the centre is exposed from every
  bearing. That reasoning is the same shape as the trench-lip result on the CTF
  side, and stencil's 16-sector directional cover masks
  (`stencil-policy-loop:59`) are exactly the instrument to price it. But it is
  a **hypothesis, not a finding** — the opposite (centre control, shorter
  next-rotation) is a defensible BR doctrine too. This is a knob a playbook page
  should own, not something to hardcode.

### 3.12 `seek_survivors` — terminal fallback

- **trigger** nothing else fired and holding is pointless (very few teams left,
  zone nearly collapsed).
- **goal source** `Track(nearest fresh enemy)` else `Fixed(zone.center)` —
  `convertHuntPoint` (`squads.nim:176-191`) minus its pedestal branch.
- **Intent** `profile = ProfileHunter`, `movingGoal = true`.
- **note** this exists so the ladder always terminates in a validated goal, the
  way `hunt_fallback` does today. It should almost never win.

### Rungs I considered and did not propose

- **`loot_death_box`** — depends entirely on whether dead players drop
  anything in BR (UNVERIFIED, §7). If they do, it is a `Fixed(deathSite)` rung
  sitting next to `fetch_item` and it is cheap. If they don't, it is nothing.
- **`break_los` / anti-exposure** — a rung that moves purely to reduce sightline
  count. I left it out because the planner already prices LOS danger
  (`planner.nim` edge cost, `stencil-policy-loop:206`), so this would be
  double-counting rather than new behaviour.
- **`disengage_on_third_party`** — "I am in a fight and a third party arrives,
  leave." This is `fall_back` with a different trigger, and it is a good
  illustration of why triggers should be authorable *separately* from goals
  (§6): one goal source, two rungs, zero new engine code.

---

## 4. Order justification against the scoring function

The placement table is `[2..16] = [5,4,4,3,3,2,2,2,1,1,1,0,0,0,0]` behind an
engagement gate. Reading the gradient:

- **13th through 16th pay zero.** The bottom quarter of the field is
  score-identical to being eliminated first. The first and largest job of the
  policy is simply *not to be in it* — outlive four teams.
- **12th → 10th is +1. 9th → 7th is +1. 6th → 2nd is +2.** Once you are in the
  paying region the gradient is shallow and roughly linear. There is no cliff
  worth a gamble.
- **A kill pays nothing directly.** It pays only through the placement it
  buys — and only if you survive the fight.
- **Therefore an even trade is strictly negative.** You spend your entire
  remaining placement equity (one life) to remove 1/31st of the field's. This is
  the single fact that reorders the whole ladder relative to CTF.

The ordering that falls out:

| # | rung | what the table pays for it | confidence |
| --- | --- | --- | --- |
| 1 | `clear_grenade` | avoids a self-inflicted zero | high (but rarely armed, §2) |
| 2 | `clear_spray` | the fastest way to lose the whole score | high |
| 3 | `zone_escape` | certain death, just slower | high |
| 4 | `fall_back` | converts a probable zero into a probable paying place | high |
| 5 | `fetch_medkit` | health *is* placement equity under one life | high |
| 6 | `partner_support` | 2v1 is the only reliably asymmetric fight | **depends on placement semantics (§8)** |
| 7 | `partner_regroup` | sets up 6; halves the odds of being caught alone | medium |
| 8 | `third_party` | the only positive-EV fight the table admits | **low — see §3.8** |
| 9 | `fetch_item` | cheap capability, priced by detour | medium |
| 10 | `zone_rotate` | the dominant survival action mid-game | high, **but the position is wrong by construction — see below** |
| 11 | `hold_zone_ground` | default; avoids contact, which the table rewards | medium |
| 12 | `seek_survivors` | terminal; should rarely win | high (that it should rarely win) |

**Rungs 1–4 are ordered by time-to-death, not by value.** Grenade impact is
~1 s, a point-blank sprayer ~2 s, zone attrition tens of seconds, and
`fall_back` is conditional on already being hurt. That is the only defensible
ordering principle for emergencies and it is the one the CTF ladder already
uses.

**The middle of the ladder is a bet.** Rungs 5–9 encode "survival compounds,
kills do not." The table supports it: four of fifteen placements pay literally
nothing, so the marginal value of *not dying in the first third* dominates
everything else. I am confident in the direction and not in the magnitudes.

**Where I am uncertain, plainly:**

1. **`zone_rotate` at #10 is wrong roughly half the time.** Its correct
   priority is a function of remaining phase time versus travel time. Placing it
   below `hold_zone_ground` makes a late rotator; above, an early one. A fixed
   ladder cannot express "hold until it is time." The MVP should ship it at #10
   *with* a hard time-pressure escalation (when
   `travelTicks × safety >= ticksUntilShrink`, it jumps above `fetch_item` and
   `third_party`), and the scored reframe should own it properly.
2. **`third_party` at #8 is a guess.** It is the only rung that seeks contact.
   Its perception basis is inference (§3.8). I would ship it off and measure.
3. **`partner_support` at #6 is conditional** on the placement-attribution
   question in §8.
4. **`hold_zone_ground`'s band preference** (edge versus centre) is a
   hypothesis, not a result.

---

## 5. Duos versus the squad layer — a verdict from the source

**Verdict: the consensus machinery is *safe* at n=2, *pointless* at n=2, and it
*hard-breaks* in the single most common BR state — the solo survivor. For the
BR MVP I would run with `SquadCommand=0` and replace it with the two direct
partner rungs (§3.6, §3.7), while keeping the local formation geometry.**

Three findings, in order of how much they should move the decision.

### (a) It lands on the duo correctly — by accident

`policy.nim:33-37` computes, on first sight of the `game teams` marker:

```nim
policy.belief.seat = min(policy.slot div teams, 7)
policy.belief.seatsPerTeam = if teams == 2:
  (if policy.belief.seat == 0: 1 else: 8)
else:
  (if policy.belief.seat < 4: 4 else: 8)
```

With 16 teams and 32 slots, `seat = slot div 16 ∈ {0, 1}` — which is the correct
seat-within-duo **if and only if** the engine interleaves slots as
`team = slot mod teams`, matching `teamForSlot` (`types.nim:235-236`). That
assumption is untested against the BR seat allocator and belongs in §8.

`seatsPerTeam` then evaluates to **4**, which is wrong (a duo has 2). But the
wrong value routes `squadTable` (`squads.nim:17-18`) into the `seatsPerTeam <= 4`
branch, which returns `@[('A', @[0, 1]), ('B', @[2, 3])]`. Squad `A` is seats
{0, 1} — *exactly the duo*. So `squadOf` → `('A', [0,1])`, `squadSize` → 2, and
`consensusQuorum` → `2 div 2 + 1` = **2**.

I want to be precise about what this means: the squad layer will find the right
partner in BR, but it will do so through a `seatsPerTeam` value that is wrong,
and that same wrong value also feeds `defenderCount` (`roles.nim:6-7`) and
`enemyLivesLeft`'s `seatsPerTeam × LivesPerPlayer` total (`squads.nim:133`).
Fixing `seatsPerTeam` to the true value of 2 would *change* the squad table
lookup. It still lands on `[('A',[0,1]),('B',[2,3])]` (2 ≤ 4), so the fix is
safe — but it is a coupling worth knowing about before touching either.

### (b) Safety degrades gracefully; liveness and cost do not

Quorum 2 of 2 is **unanimity**. Concretely:

- `consensusChoice` returns `none` unless `consensusProposals.len >= 2`
  (`squads.nim:315-316`). Own proposal is always present
  (`squads.nim:307`, `:459`), so this requires the partner's proposal to have
  arrived *over chat*.
- Chat is one shout per 24 ticks (`chat.nim:172-173`), and proposals sit fifth
  in the outbound priority queue behind carrier, thief, commit and vote
  (`stencil-policy-loop:214`).
- `updateConsensus` then requires 2 *matching* votes (`squads.nim:474-480`).

The good news: with n=2 both members compute over the same two-element proposal
set, and the tie-break is fully deterministic — kind priority `H > W > M`
(`squads.nim:323-329`), then medoid by squared directive distance, then
lexicographic on `(opponent, x, y)` (`squads.nim:330-349`). Both derive the
same choice. `receiveCommit`'s first-vote lock (`squads.nim:416-422`) means no
pair of overlapping quorums can commit differently. **Nothing is unsafe.**

The bad news: at n=2 quorum equals n, so there is *no fault tolerance to buy*.
The protocol is a two-phase commit that stalls on any single dropped shout until
`ConsensusTimeoutTicks` (480, `stencil-policy-loop:230`), and it spends two of
the four highest priority slots on a scarce channel. Two identical policies
computing the same deterministic function over shared facts would agree without
sending anything. The votes exist to reconcile *belief divergence under fog*,
which is real — but at n=2 the reconciliation costs more channel than it is
worth. **Overkill, not broken.**

### (c) It hard-breaks when the partner dies — and in BR the partner stays dead

This is the finding that decides it. Trace `nextProposal`
(`squads.nim:245-250`):

```nim
if belief.squadmatesAlive < belief.squadSize - 1:
  let position = ... belief.worldmap.homeStep(belief.team, belief.selfXy.get, BackoffStepPx)
  return SquadDirective(kind: 'H', pos: position, opponent: current.opponent)
```

At `squadSize = 2` the guard is `squadmatesAlive < 1` — i.e. the partner is dead
or presence-stale. The proposal becomes a hold at a `homeStep` backoff toward a
**home that does not exist in BR** (`worldmap.nim:1140`). Then:

1. Quorum can never be met again — there is no one left to propose. So
   `consensusChoice` returns `none` permanently and `consensusState` pins at
   `"proposing"` (`squads.nim:467-469`).
2. After `ConsensusTimeoutTicks`, `updateConsensus` times out
   (`squads.nim:438-458`), and because `belief.alive` it sets
   `rejoinPoint = rejoinTarget()`.
3. `rejoinTarget` (`squads.nim:501-513`) finds no squadmate track and returns
   `homeStep(team, selfXy, BackoffStepPx * 2)` — the phantom home again.
4. That arms the **`rejoin` rung** (`strategy.nim:367-375`) for
   `RejoinTimeoutTicks`, and `rejoin` sits *above* items, `convert_hunt`, squad
   orders, defender posture and the steal fallback.
5. `rejoinUntil` expires or the agent arrives; consensus restarts; goto 1.

**A lone BR survivor would spend the endgame walking toward a phantom home, on a
loop, with a high-priority rung suppressing every useful behaviour below it.**
In CTF this path is benign — the dead squadmate respawns and `squadmatesAlive`
recovers. Under one life it never recovers, and the mode guarantees that all but
one team reaches this state.

### What I would do

- **BR MVP: `SquadCommand = 0`.** With n=2 there is nothing to reach consensus
  *about* that a shared deterministic function cannot produce, and the failure
  mode above is severe.
- **Replace with direct coupling:** `partner_support` and `partner_regroup`
  (§3.6–3.7), both of which are simply unarmed when the partner is dead. That is
  the property `rejoin` lacks.
- **Keep `separationBias` / `formationBias`** (`squads.nim:76-110`) — pure local
  geometry, degrades to n=2 perfectly, and `MicroFormationBias` already gates it
  per-Intent.
- **If consensus is kept anyway**, the minimum viable guard is to gate the whole
  block on `squadmatesAlive >= 1` and to give `rejoinTarget` a non-home fallback
  (zone centre). That closes the loop without touching the protocol.

---

## 6. The authorable rung: goal-source vocabulary and the playbook

This section is written to James's constraint: the BR ladder must ship as a
**fixed set**, but must not *foreclose* rungs authored from outside the game
later. The way to not foreclose it is to factor every rung into parts, and to
make the load-bearing part — the goal source — a **table, not a switch**.

### 6.1 Why the goal source is the load-bearing part

A trigger is cheap to author: it is an expression over named facts, and an
expression VM can already evaluate it. A rung whose *goal* can only come from
bespoke engine code is useless as an authorable unit, because every new rung
then needs an engineer and the whole idea is dead on arrival.

So the question is: **how many distinct goal shapes does the existing ladder
actually use?** Reading all fourteen producers, the answer is six.

| combinator | parameters | wraps | rungs using it today |
| --- | --- | --- | --- |
| `Fixed(name)` | a named point | — | `carry_home` (`capturePoint`), `steal` (`pedestal`), `early_defense` (post) |
| `Track(selector, lead)` | which tracked actor; optional velocity extrapolation | `enemyTracks`/`teammateTracks`, `projectedTrackPos` (`belief_state.nim:156`) | `intercept_thief`, `escort_carrier`, `convert_hunt`, `arc_pursuit` |
| `Radial(anchor, distance)` | flee/approach along a bearing from an anchor | vector maths + `segmentClear` (`worldmap.nim:279`) | `clear_grenade` (`strategy.nim:336-341`), `clear_spray` fallback (`:264-275`) |
| `ScoredLocal(dirs, rings, anchor, weights)` | local candidate ring, scored | `segmentClear` + coverage/danger sampling | `clear_spray` (`strategy.nim:206-262`) |
| `ScoredRegion(candidates, weights)` | best room peak / atlas post in a region | `map.rooms`, `atlasNear`, `rankedAtlasPosts` (`worldmap.nim:792`), `selectRankedPost` (`:841`) | `barrage_center` (rooms), `to_post`, squad `orderPost` (`squads.nim:482-499`) |
| `Interp(a, b, t)` | fraction along a line between two named points | — | `advancePoint` (`squads.nim:214-236`) |

Every one of them then passes through the **single validator**,
`nearestReachable(point, selfXy)` (`worldmap.nim:369-403`) — which is already
universal (`strategy.nim:80-83`) and already deterministic (squared distance,
then row-major index, explicitly documented as directionally unbiased at
`worldmap.nim:372-374`). That property is what makes the whole scheme safe to
open up: **an authored rung cannot produce an invalid goal, because it does not
get to choose the validator.**

### 6.2 The named-point namespace is what BR actually adds

The combinators are mode-independent. What is heart-shaped is the *namespace*
they draw from: today it is `home`, `pedestal(colour)`, `capturePoint`,
`defenseGate`, `map.center`, `room.peak`, `post`, and track positions.

BR needs these added. Each is a `name → proc(belief): Option[Point]` table row,
not a new code path:

| name | resolves to | source |
| --- | --- | --- |
| `zone.center`, `zone.radius` | the live circle | `zone ` label (**verify shape/units, §7**) |
| `zonenext.center`, `zonenext.radius` | the forecast circle | `zonenext ` label |
| `zone.nearestInside(p, margin)` | nearest point inside the live circle by margin | derived; the one that makes `zone_escape` a one-liner |
| `zone.edgeToward(p)` | the boundary point on the bearing to `p` | derived; supports edge-band holding (§3.11) |
| `partner.pos` | duo partner's freshest track | `teammateTracks` filtered by identity |
| `threat.centroid` | centroid of fresh enemy tracks | `freshEnemyPositions` (`belief_state.nim:167`) |
| `cover.nearest(p)` | nearest cover pixel | `map.nearestCover` (`worldmap.nim:1011`) |
| `danger.min(region)` | lowest-danger point in a region | `planDanger.sample` |
| `item.nearest(kind)` | nearest believed present spawn of a kind | `belief.itemSpawns` (`items.nim`) |

Adding a name is one table row and one small proc. Adding a **rung** that
composes existing names is zero engine code. That is the line this design is
trying to hold.

### 6.3 The whole BR ladder, audited against the vocabulary

The claim "these six combinators cover BR" is only worth anything if it is
checkable. Every rung from §3, with the combinator it uses and the names it
draws on:

| rung | combinator | named points it needs | new engine code? |
| --- | --- | --- | --- |
| `clear_grenade` | `Radial` | `grenadeWarning.pos` | none |
| `clear_spray` | `ScoredLocal` | `threat.centroid`, `zone.center` | weight param + zone name |
| `zone_escape` | `Fixed`-derived | `zone.nearestInside` | one name |
| `fall_back` | `ScoredLocal` | `threat.centroid`, `zone.center`, `cover.nearest` | **weight param + track filter param** |
| `fetch_medkit` | `Fixed` | `item.nearest(Medkit)` | none (re-pricing only) |
| `partner_support` | `Track` | `partner.pos` | one name |
| `partner_regroup` | `Track` | `partner.pos` | one name |
| `third_party` | `ScoredRegion` | `threat.centroid`, atlas | **track filter param** |
| `fetch_item` | `Fixed` | `item.nearest(kind)` | none (anchor passed in) |
| `zone_rotate` | `ScoredRegion` | `zonenext.center`, room peaks | one name |
| `hold_zone_ground` | `ScoredRegion` | `zone.center`, `zone.edgeToward`, atlas | two names |
| `seek_survivors` | `Track` → `Fixed` | fresh enemy track, `zone.center` | none |

Two readings of that table matter. First, **no rung in the proposed BR ladder
needs a seventh combinator** — the vocabulary as enumerated covers the mode,
which is the evidence that it is the right factoring rather than a convenient
one. Second, the "new engine code" column collapses to exactly the two
parameterisations named in §6.4 plus a handful of table rows. `Interp` goes
unused in BR (it existed for the home→pedestal advance), which is fine — an
unused combinator is not a cost.

### 6.4 The test case: can the vocabulary express "fall back"?

James's example, worked through honestly.

- **trigger** `hpPips <= 1 and (underFire or firefightActive)` — an expression
  over three named facts that all exist today (`belief_state.nim:66, 72, 73`).
  **Expressible, no new code.**
- **goal source** `ScoredLocal(dirs: 16, rings: 2, anchor: threat.centroid,
  weights: {threat: +1.0, cover: +0.6, zoneSafety: +0.8, clump: −0.4})`.
  **Not expressible today — two things block it:**
  1. **The weight vector is compiled in.** `strategy.nim:248-249` computes
     `SprayThreatWeight * threatGain + SprayCoverWeight * coverPath −
     SprayClumpWeight * clumpRisk + SprayCenterWeight * centerTerm`, reading four
     module consts. For `ScoredLocal` to be a vocabulary item rather than one
     bespoke behaviour, the scorer must take the weights as a **parameter**.
  2. **The threat anchor is hardcoded to spray.** `updateSprayFleeLatch`
     (`strategy.nim:168-170`) filters `track.weapon != WeaponSpray` and applies
     a spray-specific TTL. `fall_back` wants "all fresh enemy tracks", and
     `third_party` wants "different-team tracks near each other". The filter
     needs to be a **parameter**: `(weapon, freshness, radius, team-relation)`.
- **Intent fields** `profile = ProfileCarrier`, `movingGoal = true`,
  `suppressFireFreeze = true`, `micro = {}`, `arriveRadius ≈ 40`. All five are
  already typed fields on `Intent` (`types.nim:205-214`) set from a per-reason
  table (`strategy.nim:20-72`). **Expressible — this part is already a table.**

**Verdict: expressible after two parameterisations, both small, both of existing
code, both on the rework path anyway.** I would rather report that than a clean-
looking proposal, because the gap is the actionable part: *until the scorer takes
weights and the track filter takes a predicate, `ScoredLocal` is one behaviour
rather than a vocabulary item, and "authorable rung" stops at rungs whose goal is
`Fixed` or `Track`.*

Two smaller notes in the same spirit:

- **Per-Intent firefight weights have a precedent to copy.** `scoreTarget`
  already takes an injected `defensiveThreat` term as a parameter
  (`fight.nim:162-165`) rather than reading role state itself. The same seam
  generalises: pass the whole weight vector in from the Intent. That is the
  cleanest version of James's ruling and it does not require inventing anything.
- **`reason` must stay telemetry-only.** The v66 contract grep-gates it
  (`nav-layer4:47-48`). If rungs become authorable, `reason` becomes a rung
  *identity* — used for weight lookup and tie-breaking — and that is a real
  change to the contract's meaning. Worth deciding deliberately rather than
  drifting into it. My suggestion: add an explicit `rungId` field and leave
  `reason` alone.

### 6.5 What a playbook would price

Under the agreed reframe, a page **scores the validated rungs** rather than
taking the first, and default weights reproduce the ladder order exactly.

The mechanism: every rung whose trigger fires *and* whose goal validates
produces a candidate `(rungId, point, intentFields, baseWeight)`. Selection is
argmax over `baseWeight + Σ modifiers`. **If the default weights are strictly
descending in ladder order, argmax is identical to first-match-wins** — that is
the identity property, and it should be an actual test, not a claim.

A concrete page for one stance — the late rotator:

```yaml
stance: late_rotator
note: >
  Hold ground until the zone forces the move. Trade only from clear advantage.
  Bets that contact avoided early is worth more than position taken early.

weights:                    # default (= ladder order) in comments
  clear_grenade:    100     # 100
  clear_spray:       95     # 95
  zone_escape:       90     # 90
  fall_back:         88     # 80   +8  one life; protect it harder than default
  fetch_medkit:      70     # 70
  partner_support:   60     # 60
  partner_regroup:   50     # 50
  third_party:       55     # 35   +20 this stance wants the free trades
  fetch_item:        45     # 45
  zone_rotate:       30     # 40   -10 rotate LATE
  hold_zone_ground:  35     # 30   +5  ... which is the whole stance: hold > rotate
  seek_survivors:     5     # 5

modifiers:                  # expressions over the SAME named facts as triggers
  - rung: zone_rotate
    add: +60
    when: zone.ticksUntilShrink < travelTicks(zone_rotate.goal) * 1.3
    note: hard safety override — a late rotator must not become a dead one
  - rung: hold_zone_ground
    add: -40
    when: teamsRemaining <= 4
  - rung: third_party
    add: -50
    when: hpPips < 3
  - rung: partner_support
    add: +25
    when: partner.hpSegments <= 1
```

Three things this example is meant to demonstrate:

1. **The stance is one inequality.** "Rotate late" is expressed entirely as
   `hold_zone_ground > zone_rotate`, with a hard modifier that restores rotation
   when it becomes forced. That is a legible knob an LLM can reason about and a
   human can audit — which a reordered `if` chain is not.
2. **It resolves the §3.10 ordering problem.** No fixed ladder position for
   `zone_rotate` is correct, because the right answer depends on remaining phase
   time. The modifier expresses exactly that dependency, in the same expression
   language as the triggers. One language, two uses.
3. **An early-rotator page is the same file with two numbers swapped.** That is
   the test of whether the vocabulary is actually a vocabulary.

### 6.6 Determinism and replay (our side of the split)

Since this lane owns determinism/replay, the constraints the scored ladder must
respect:

- **Selection must be a pure function of `(belief, page)`.** No wall-clock, no
  iteration order over hash tables. Note that `consensusChoice` already models
  this discipline well (`squads.nim:321-349`): it iterates a table but reduces
  through an order-independent tie-break.
- **Ties must break deterministically**, lexicographically by `rungId`. With
  authored weights, ties become *likely* rather than exotic.
- **Weights should be integers**, or fixed-point. Float weight sums compared for
  argmax across platforms is a determinism hazard for no benefit; the example
  above uses integers deliberately.
- **The page must be content-hashed into the replay.** A replay of a scored
  ladder is not reproducible without the exact page that scored it. This is the
  single most important requirement in this subsection and it should land with
  the first scored-ladder commit, not after.
- **`nearestReachable` is already deterministic and documented as such**
  (`worldmap.nim:372-374`) — validation does not need work.

---

## 7. Preconditions — what must be true before any BR rung can be measured

These are upstream of the ladder and belong to the port, not to this design. I
am listing them because they define the critical path and because two of them
change what the ladder should assume.

1. **The `Team` enum has four values; BR has sixteen teams.**
   `types.nim:8-12` defines `Team = enum Red, Blue, Green, Yellow`.
   `policy.nim:28-30` does `colors.setLen(teams)` then `colors[index] =
   Team(index)` for `index in 0 ..< teams`, and `teamForSlot`
   (`types.nim:235-236`) does `Team(slot mod teams)`. At `teams = 16` both are
   out-of-range enum conversions.
   **Recommendation:** do *not* widen `Team` to 16. In BR the only distinction
   that matters is partner / not-partner, so the colour model collapses to a
   boolean plus an identity. That is a smaller change than generalising, and it
   also fixes `belief_update.nim:260`, where chat-sourced enemy sightings are
   hardcoded to `color: Red`.

2. **No endzones means no `WorldMap` means no movement at all.**
   `policy.nim:39-40` gates the entire map build on
   `percept.endzones.len >= colors.len`, and `newWorldMap`
   (`worldmap.nim:173`) takes endzones as a construction argument. With no
   endzones the map is never built, and `decideBaseObjective`'s first line
   returns `hold("no_worldmap")` (`strategy.nim:303-305`) for the whole episode.
   **This is the hardest blocker: without it, stencil in BR stands still.** The
   build pipeline downstream of endzones (clearance → grid → components →
   watershed → cover → posts) does not otherwise need them; only the home
   Dijkstra fields and `capturePoint`/`pedestal`/`defenseGate` do.

3. **`seatsPerTeam` resolves to 4 for a duo** (`policy.nim:34-37`). See §5(a) for
   the coupling to the squad table, `defenderCount` and `enemyLivesLeft`.

4. **The zone must be perceived at all.** `perceive` (`perception.nim:308-390`)
   has no `zone `/`zonenext ` decode — every BR rung in §3 depends on adding it,
   and on `PaintState`/`Belief` gaining the fields. The label format must be
   read off the emitter, not assumed.

Unverified mechanics that change specific proposals (flagged where they appear):

- whether the **spray weapon, grenades and shields** exist in BR with the same
  numbers — decides whether `clear_spray` and `arc_pursuit` port verbatim;
- whether **items respawn** — `items.nim:19-24, 65-67` assumes they do;
- whether **dead players drop loot** — decides whether `loot_death_box` exists;
- whether the **barrage** exists in BR — decides whether `barrage_center`'s
  trigger is merely inert or needs deleting;
- the **`zone `/`zonenext ` label encoding**: shape, units, coordinate frame,
  refresh rate, and how far ahead `zonenext` is published;
- **placement attribution for a duo** — see §8.

---

## 8. Top uncertainties

1. **Which death determines a duo's placement — first or last?** This is the
   highest-leverage unknown in the document. If placement is scored at the
   *last* member's death, then `partner_support` (§3.6) is high-value, keeping
   the partner alive is directly placement equity, and a surviving solo still
   accrues. If it is scored at the *first*, then `partner_support` collapses to
   "a live partner shoots for me", solo play after a partner death is worth
   much less, and the ladder should shift toward mutual survival much harder
   than proposed. I could not settle it and did not want to guess.

2. **`third_party` (§3.8) rests on a percept stencil does not have.** There is
   no "these two are fighting each other" observation; the proposed trigger is
   inference from proximity, damage and impact sounds, and it will fire on two
   enemies who merely happen to be near each other. This rung is the only one
   that deliberately seeks contact, in a mode whose scoring function punishes
   contact — so a false positive is expensive. Ship it disabled; measure before
   trusting it.

3. **`hold_zone_ground`'s band preference is a hypothesis** (§3.11). Holding
   some way inside the zone edge restricts the arc threats can come from;
   holding centre shortens the next rotation. Both are defensible BR doctrines
   and I have no measurement. I have proposed the edge band because stencil's
   directional cover masks make it cheap to price, not because I know it wins.

4. **The slot→team mapping in BR is assumed, not verified** (§5a). Everything
   about seat and partner identification rests on `team = slot mod teams`
   matching the BR seat allocator. If BR blocks duos as adjacent slots
   (`slot div 2`) instead, `seat` and `squadOf` both land wrong and the partner
   rungs address the wrong agent.

5. **Every threshold in §3 is a placeholder.** `FallBackHpPips`,
   `RotateSafetyFactor`, `ZoneSafeMarginPx`, `SupportRadiusPx`,
   `FightRadiusPx`, the medkit detour multiplier — I have given shapes and
   directions, not values. They should be `STENCIL_*` knobs
   (`config.nim` already carries 152 of them) and tuned against real episodes,
   not chosen here.
