# The Battle Royale rung ladder for `stencil`

**Status: DESIGN, 2026-08-29.** Written for James Boggs, who owns the stencil
rework and the scoring hook. This lane owns the **BR rung vocabulary** and the
**determinism/replay** side; this document is the thing to react to, not an
implementation plan. No policy code is written here, and nothing in
`player_labs-jboggsy/paintbot_lab/` was modified to produce it.

Ground truth:

- `paintbot_lab/docs/reports/stencil-policy-loop-2026-08-29.md` (the v68 loop explainer)
- `paintbot_lab/docs/designs/nav-layer4-intent-contract-2026-08-13.md` (the v66 Intent contract)
- `paintbot_lab/paintbot/stencil_nim/` at `origin/main` = `eac564f`
- Battle Royale mechanics read out of `coworld-ctf` @ `b800d17` with
  `git show`, not off disk (the working tree is on a later refactor where
  `sim.nim` is already split and `killPlayer` differs).

Citations are `file:line`. **(judgement)** marks an opinion; **(OPEN)** marks
something I could not settle.

---

## 0. Executive summary

**Stencil cannot take the BR field at all today, for three reasons upstream of
the ladder.** The `Team` enum has four values and BR has sixteen teams
(`types.nim:8-12`, `policy.nim:30` does `Team(index)` for `index in 0..<teams`).
The `WorldMap` — which is *all* map knowledge — is built only once every endzone
has been perceived (`policy.nim:39-40`), and a BR map emits none at all, so
`decideBaseObjective` returns `hold("no_worldmap")` for the entire episode
(`strategy.nim:303-305`). And `seatsPerTeam` resolves to 4 for a duo
(`policy.nim:34-37`). §7 has the detail. None of this is ladder work, and all of
it blocks measuring any ladder.

**The zone is a hard wall, not attrition — and it does nothing for the first
59% of the match.** Base HP is 3 (`sim_types.nim:421`); the zone deals its
phase's `dps` as a flat hit every 24 ticks outside (`sim.nim:3516-3570`), so from
the third phase (`dps = 4`) onward, stepping outside kills in about one second.
Meanwhile the reference schedule holds `dps = 0` until tick 3528 of 6000
(`tools/record_br_match.sh`). The consequence for the ladder is sharp: **zone
compliance must be a predictive rung, not a reactive one** — by the time you are
outside, you are usually dead — and **the first 147 seconds contain no
environmental pressure whatsoever**, so every early death is a death you chose.

**Two mechanics change the ladder more than the zone does.** First, placement is
by team and is decided by whichever duo member dies *second*
(`sim.nim:2841-2867`: `lastDeath[team] = max(...)`, ranked after living-cog
count) — so keeping the partner alive is directly placement equity, and this
resolves what was my largest open question. Second, the placement bonus is gated
on `attacksMade > 0 or damageDealt > 0` summed across the duo
(`sim.nim:2995-3016`) — **one attack in the whole match**, worth up to 5 points.
That is the cheapest point in the mode and the ladder must not miss it.

**The authorable-rung goal is reachable and costs two specific
parameterisations.** §6 enumerates the goal-source vocabulary, audits all twelve
BR rungs against it, and works James's "fall back" example through honestly. It
is expressible — but only after (a) the local ring scorer takes its **weight
vector as a parameter** instead of reading module consts
(`strategy.nim:248-249`), and (b) the **threat-track filter** that supplies its
anchor takes a predicate instead of hardcoding `weapon == WeaponSpray`
(`strategy.nim:168-170`). Those two refactors are what turn "a new rung needs an
engineer" into "a new rung needs a table row".

---

## 1. The Battle Royale facts the ladder is built on

Everything in this section is cited from `b800d17`. It is here because several
of these falsify the obvious design.

**The zone is an axis-aligned rectangle, not a circle.** `zone <x0>,<y0>
<x1>,<y1>` states inclusive map-pixel corners, board-clamped
(`labels.nim:238-244`, `sim.nim:3398-3421`). It stays geometrically similar to
the field at every phase — width and height scaled by the same permille.

**Its centre drifts; it is neither map-centre nor a fixed random point.** At
scale `z = 1.0` the effective centre is the board's true centre, and it slides
linearly toward a once-per-episode uniformly drawn point as `z` falls
(`sim.nim:3357-3388`, `resetZone` at `:317-345`). So the drop is always fully
safe and the destination is unknown at the drop. §3.10 argues this is
*inferable*, which is the single largest edge available to a policy here.

**Shrink is stepped phases, each a linear interpolation.** A `ZonePhase` is
`(zPermille, waitTicks, shrinkTicks, dps)` (`sim_types.nim:2070-2094`), walked
in order (`sim.nim:3446-3489`). The reference schedule
(`tools/record_br_match.sh`, `maxTicks = 6000`, 24 tps):

| phase | z | wait | shrink | dps | ticks |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.824 | 3000 | 528 | **0** | 0–3528 |
| 2 | 0.648 | 0 | 528 | 2 | 3528–4056 |
| 3 | 0.472 | 0 | 528 | 4 | 4056–4584 |
| 4 | 0.296 | 0 | 528 | 8 | 4584–5112 |
| 5 | 0.120 | 0 | 528 | 12 | 5112–5640 |
| 6 | 0.060 | 0 | 180 | 16 | 5640–5820 |
| 7 | 0.001 | 0 | 180 | 20 | 5820–6000 |

Note this is *authored config*, not an engine constant — `zonePhases` defaults
to empty (`sim_config.nim:60`). A policy must read the schedule off the wire,
never assume it.

**The lookahead is exactly one phase, and after tick 3528 it is short.**
`zonenext` is the rect the current one is interpolating *toward* — during a wait
it is genuinely future (3000 ticks of notice for phase 1), but during a shrink it
is that same phase's endpoint, not a preview of the phase after
(`sim.nim:3446-3454, 3480-3486`). With every subsequent `waitTicks` at zero, the
rotation budget from phase 2 onward is **the shrink duration itself: 528 ticks
(22 s), then 180 (7.5 s) for the last two.** There is never two-phase lookahead.

**Being outside is close to fatal, not attritional.** 24 ticks outside → a flat
`dps` hit through `absorbDamage` → `killPlayer(..., "caught outside the zone")`
on hp ≤ 0 (`sim.nim:3516-3570`, `ZoneDamageRollTicks = TargetFps = 24`,
`sim_types.nim:801`). Against 3 HP: `dps = 2` kills in 2 s, `dps = 4` in 1 s,
`dps ≥ 8` on the first roll. A shield adds 3 absorption (`sim_types.nim:736`),
roughly doubling that.

**Placement, and how a duo is ranked.** `BrPlacementBonus[2..16] =
[5,4,4,3,3,2,2,2,1,1,1,0,0,0,0]` (`sim_types.nim:526-529`), added to the loss
reward and clamped below the winner's (`sim.nim:3010-3016`). Rank is per team
(`brPlacements`, `sim.nim:2914-2928`), ordered by: most living cogs, then
**latest last-death tick where a team's last death is the `max` of its two
members'** (`sim.nim:2841-2867`), then kills, damage, seat index. Placement and
score are never visible mid-episode.

**The engagement gate is one attack.** `if teamAttacks[t] == 0 and teamDealt[t]
== 0: continue` (`sim.nim:2995-3000`) — a single attack attempt *or* a single
point of damage, summed across both cogs, for the whole match. No kills, no
minimum. An unengaged losing team gets the flat floor. The same gate re-gates
Pacifist/Spotless in BR (`sim.nim:3098-3113`).

**No hearts, no pedestals, no endzones — "not even INERT ones"**
(`sim_types.nim:1309-1311`). `resetFlags` skips pedestal placement,
`tryPickupFlags` refuses unconditionally (`sim.nim:2355-2356`), and the endzone
emission loop is never entered on a flagless map (`global.nim:3799`). The wire
carries zero flag/pedestal sprites.

**Combat is unchanged from CTF.** Across all 51 `brMode` references in `src`,
none gates combat damage. Gun 1 hp/hit, grenade 2 open-field
(`sim_types.nim:673`), spray 3 per activation (`:724`), shield layer 3 (`:736`),
HP 3 (`:421`). Spray, grenades and shields all exist in BR with identical
numbers. There is no damage scaling over time except the zone's own schedule.

**Items: same four families, and the medkit is enormous.** Medkits heal **to
full**, not by an amount (`sim.nim:2122-2144`), respawn in 720 ticks / 30 s
(`sim_types.nim:683`), and the golden BR map authors 33 of them. Shields, spray
cans and grenades likewise respawn at 30 s. There is no ammo mechanic at all.
Everyone spawns with the same gun; everything else is ground loot.

**Dead players drop nothing** — `killPlayer` clears held items rather than
dropping them (`sim.nim:921-932`).

**Corpses are invisible to the living.** `global.nim:8635-8636` — corpses render
only for ghost viewers. A live bot can never see a body, its partner's included.
Partner death must be inferred from the badge disappearing.

**The map is ~6.9× the CTF area.** The golden BR fixture is 3211 × 1713 against
CTF's 1235 × 659 (`sim_types.nim:942-943`), same aspect ratio, generator-derived
per draw.

**Both duo members spawn on the same pixel.** With 16 spawn points and 16 teams,
`perTeam == 1` and `order mod 1 == 0`, so both seats resolve to the identical
coordinate (`sim_state.nim:361-403`, and `tests/test_br_team_bridge.nim:37-40`
states it outright). Which team gets which physical point is rotated per episode
by a seed hash (`sim_state.nim:346-359`).

---

## 2. The kill list — rungs that are meaningless in BR

The ladder is `strategy.nim:302-473`, first-match-wins. A rung dies when either
its **trigger** can never be true, or its **goal producer** addresses a map
feature that does not exist. The two failure modes are not equivalent: a dead
trigger is inert; a dead producer under a live trigger is silent nonsense.

| rung | strategy.nim | dies because | failure mode |
| --- | --- | --- | --- |
| `carry_home` | 322-324 | `iCarryHeartOf` needs a heart; `map.capturePoint` needs an endzone (`worldmap.nim:1078`) | both dead |
| `intercept_thief` / `_heard` | 326-330 | `ownHeartStolen` needs an own heart; `thiefFix` comes only from a `thief` shout (`belief_update.nim:262`) | both dead |
| `escort_carrier` / `_heard` | 377-393 | walks `belief.hearts` for an ally-carried heart | both dead |
| `early_defense` | 358-365 | goal is an atlas post *inside the team endzone* (`roles.nim:77-106`); release reads per-colour `teamScores.deaths` (`squads.nim:143-157`) | both dead |
| `steal` | 466-473 | goal is a planted heart or `map.pedestal` (`strategy.nim:284-292`) | both dead |
| squad order `M`/`W`/`H` | 413-451 | order *content* is `advancePoint`, interpolating `homeCenter` → `pedestal(opponent)` (`squads.nim:214-236`) | **goal dead, trigger ALIVE** |
| `to_post` / `hold_post` | 453-464 | `defensivePostForSeat` bands outward from `homeCenter` toward `mostDirectOpponent` (`roles.nim:31-75`) | goal dead |
| `to_hold` / `hold_line` | 453-464 | `holdPointForSeat` is `defenseGate` offset on the `center − home` axis (`roles.nim:12-29`) | goal dead |
| `hunt_fallback` | 466-471 | terminal fallback is `pedestal(weakestEnemyColor)` (`squads.nim:186-190`) | goal partly dead |
| `convert_hunt` | 404-411 | `wipeInReach` reads `teamScores` deaths against `seatsPerTeam × LivesPerPlayer` (`squads.nim:130-174`) | trigger unreadable, **and inverted** — see §3 |

**The squad-order rung is the dangerous one.** Its trigger — `belief.order` set
and fresh — is entirely alive in BR, because consensus runs on seats and shouts,
neither of which cares about hearts. Only its payload is dead. A naive port
leaves a live rung above defender posture and the steal fallback, navigating to a
point interpolated between two meaningless coordinates. It will validate through
`nearestReachable` — it is a real pixel — and the agent will walk there with
conviction. Under the v66 contract an *unroutable* goal is a loud bug
(`nav-layer4:109-115`); a **meaningless reachable** goal is silent. That is the
class of failure this kill list exists to catch.

**`barrage_center` does not make the kill list, and I had it wrong.** Barrage is
an independent config knob (`barrageMaxPerSec`, default 0, `sim_config.nim:56`)
that `brMode` does **not** disable — the reference match merely turns it off on
purpose. A policy that assumes "BR never has barrage" is relying on convention,
not on the engine. Keep the rung armed.

**Its producer is also the best salvage in the file.** `barrageGoal`
(`strategy.nim:85-111`) scores every watershed room peak in the agent's own
component by `openness − BarragePeakDangerWeight × normalised plan danger`,
falls back to `map.center`, and validates through `reachableGoal`. Restrict
"every room peak" to "every room peak inside `zonenext`", add a route-cost term,
and that is `zone_rotate` (§3.10) already written.

---

## 3. The survivor list and the new BR rungs

Presented in proposed ladder order. Each rung is factored the way §6 requires:
**trigger** (a predicate over named facts), **goal source** (a combinator from
the vocabulary, then `nearestReachable(point, selfXy)` — the single validator
every producer already routes through, `strategy.nim:80-83`,
`worldmap.nim:369-403`), and **Intent fields**. A rung whose goal fails to
validate is not a candidate.

### 3.0 `no_worldmap` → `Hold` — unchanged (`strategy.nim:303-305`)

### 3.1 `clear_grenade` — survives in form, near-dead in practice

Grenades exist in BR with unchanged damage (`sim_types.nim:673`). But
`belief.grenadeWarnings` is written at exactly one site,
`belief_update.nim:268`, inside the **inbound chat decode**. It is not a
perception of an enemy grenade — it is an ally saying "I am charging a grenade at
(x,y), clear the blast."

So in duos the source count drops from 7 to **1**, and when the partner dies the
rung is permanently dead — which, under one life, is most of the match for most
teams. It never protected you from enemy grenades and still doesn't. Keep it (it
is cheap and correct) but do not count it as BR coverage. The useful version is
perception-driven — an enemy track observed with `hasGrenade` (the field exists,
`types.nim:46`) inside throw range. That is new perception work, and I am
flagging it rather than proposing it.

### 3.2 `clear_spray` — survives verbatim, and gets more valuable

Trigger is `updateSprayFleeLatch` (`strategy.nim:159-192`): enemy tracks with
`weapon == WeaponSpray` inside `SprayFleeTriggerPx`, with release hysteresis.
Purely local perception. Goal is a 16-direction × 2-ring local scored flee
(`:194-282`). Spray exists in BR at 3 damage per activation
(`sim_types.nim:724`) against 3 HP — **a single spray activation is lethal from
full health.** This rung prevents the whole score.

One free upgrade: the scorer already carries a `centerTerm` pulling toward
`map.center` *during a barrage* (`strategy.nim:242-247`). That term is
structurally "pull toward safe ground during a shrinking hazard". Re-point it at
the zone rect and `clear_spray` becomes zone-aware for zero new machinery — and
stops competing with the zone rungs, which is why it sits above them.

### 3.3 `zone_escape` — an emergency that usually arrives too late

- **trigger** `not zone.contains(self)`.
- **goal source** `Nearest(inside: zone.rect, from: self, margin:
  ZoneSafeMarginPx)`. Because the zone is a **rectangle**, this is a clamp, not a
  projection: `(clamp(x, x0+m, x1-m), clamp(y, y0+m, y1-m))`. Cheaper and more
  robust than the circular version I first assumed.
- **Intent** `profile = ProfileHunter` (0.25× danger — cross contested ground;
  the zone kills with certainty), `movingGoal = true` (the rect moves nearly
  every tick during a shrink), `micro = {}`, `arriveRadius = ZoneSafeMarginPx`,
  `suppressFireFreeze = true`.
- **honest expectation** at `dps ≥ 4` you have about one second. Unless you are
  a stride from the boundary or carrying a shield, this rung is a formality. **It
  is not the zone answer; §3.6 is.** Keeping it high in the ladder is right
  anyway — it costs nothing when it never fires.

### 3.4 `fall_back` — James's example, promoted to a first-class rung

- **trigger** `hpPips <= FallBackHpPips and (underFire or firefightActive)`.
  All three facts exist today (`belief_state.nim:66, 72, 73`).
- **goal source** `ScoredLocal(dirs: 16, rings: 2, anchor: threat.centroid,
  weights: {threat: +1.0, cover: +0.6, zoneSafety: +0.8, clump: −0.4})` — i.e.
  `clear_spray`'s scorer with a different anchor and a different weight vector.
- **Intent** `profile = ProfileCarrier` (2.5× danger — evade),
  `movingGoal = true`, `suppressFireFreeze = true` (shoot while withdrawing —
  this is what the flag is for, `action.nim:438-442`), `micro = {}`,
  `arriveRadius ≈ 40`.
- **why a rung and not a modifier** the CTF ladder has no disengage. It has
  `clear_spray`, a specific weapon-avoidance behaviour, and nothing that says "I
  am losing this fight, my life *is* my score, leave." Against 3 HP with no
  respawn and a placement table that pays zero for a kill, that is the largest
  hole in the ladder. §6.4 uses this rung as the test of the vocabulary.

### 3.5 `fetch_medkit` — survives, and must be re-priced hard

Discovery is clean: `itemSpawns` are learned from `percept.visibleItems` with a
24 px match radius and an absence/respawn clock (`items.nim:39-67`); the BR
respawn is 30 s, which the stencil constant must be set to match.

The re-pricing is not a tweak, it is a different regime. A BR medkit **heals to
full** (`sim.nim:2122-2144`) and the golden map authors 33 of them. Under one
life a full heal restores your entire remaining placement equity. Two changes
follow (**judgement**):

- `medkitTarget` refuses unless `hpPips < 3` (`items.nim:155`, mirrored at
  `:102`). With three lives that is right; with one, any missing pip should
  qualify.
- `MedkitConvenientDetourPx` is a *convenience* budget. In BR the medkit is
  worth a large deliberate detour. I expect the right value to be several times
  the CTF one; I have no measurement and will not invent a number.

The pricing half also has one heart-shaped dependency: `evaluateFetch` prices
detour against an **anchor** (`items.nim:91-152`) drawn from `itemAnchor`
(`strategy.nim:294-300`) — squad order, else defender hold point, else
`stealGoal`, else `map.center`. Three of four are dead. The fix improves the
architecture: **pass the anchor in** — it should be the goal of whichever rung
would have won had the item not existed. That is also exactly what a scored
ladder wants (§6.5).

### 3.6 `zone_rotate` — the rung the mode is actually about

- **trigger** `zonenext` published, and my position is outside it (or within
  `RotateMarginPx` of its edge), **and** `routeTicks(goal) × RotateSafetyFactor
  >= ticksRemainingInPhase`. The route estimate is free — `map.routeDistance`
  (`worldmap.nim:919`) already exists and is what `evaluateFetch` uses for
  exactly this kind of pricing.
- **goal source** `ScoredRegion(candidates: room peaks ∩ zonenext, weights:
  {−routeCost, −planDanger, +openness, −distanceFromNextCentre})` — `barrageGoal`
  with a region filter and one extra term (§2).
- **Intent** `profile = ProfileDefault` early / `ProfileCarrier` late
  (**judgement**: once the field is small, routing around danger is worth the
  distance), `movingGoal = false` — the phase endpoint is static for the whole
  shrink, so the planner cache survives the entire rotation — `arriveRadius ≈
  64–80`, `micro = {MicroPeekDuck, MicroSeparation, MicroSprayPursuit}`.
- **the urgency is in the trigger, which is why its ladder position matters
  less.** Because the trigger is itself the deadline test, this rung fires only
  when the rotation is *becoming* forced. That is the right shape given the
  facts: the budget is 528 ticks per phase and 180 for the last two (§1), and
  missing it is death rather than damage.
- **it must sit above the partner and item rungs.** I originally had it lower.
  That was based on treating the zone as attrition; it is a wall. A rotation you
  skip to grab a medkit is a rotation you may not survive.

### 3.7 `partner_support`

- **trigger** partner track fresh, and (partner `underFire` — knowable only via
  their `under_fire` shout, `belief_update.nim:269-271` — or partner
  `hpSegments` low with an enemy track within `SupportRadiusPx`), and my own HP
  healthy.
- **goal source** `Track(selector: partner, lead: projected)` via
  `projectedTrackPos` (`belief_state.nim:156`).
- **Intent** `profile = ProfileDefault`, `movingGoal = true`, `micro =
  {MicroFormationBias, MicroSprayPursuit}`, `arriveRadius ≈ 56`.
- **this is now confirmed high-value, not conditional.** Rank orders on living-
  cog count first and on the **later** of the duo's two death ticks second
  (`sim.nim:2841-2867`). Both terms pay for keeping the partner alive. A 2v1 is
  also the only reliably asymmetric fight available, and asymmetry is the only
  fight shape the scoring table tolerates.
- **partner death is invisible.** Corpses render only for ghost viewers
  (`global.nim:8635-8636`), so "partner died" can only be inferred from the badge
  going stale. `belief.presence` and `PresenceStaleTicks` (`squads.nim:193-198`)
  already implement exactly that, which is convenient — but it means a partner
  who is merely out of sight is indistinguishable from a dead one for
  `PresenceStaleTicks`. §5 shows what the current code does with that ambiguity,
  and it is bad.

### 3.8 `partner_regroup`

- **trigger** partner presence fresh, separation > `RegroupPx`, no squad contact
  (`inSquadContact`, `squads.nim:515-522`).
- **goal source** `Track(selector: partner, lead: none)`.
- **Intent** `profile = ProfileDefault`, `movingGoal = true`,
  `micro = {MicroFormationBias}`, `arriveRadius ≈ 80`.
- **note** this is the honest replacement for `rejoin`, which in BR degenerates
  into an endless walk toward a nonexistent home (§5). Unlike `rejoin`, it is
  *unarmed* when the partner is gone — which is the entire point.
- **spawn interaction** both duo members land on the identical pixel
  (`sim_state.nim:361-403`), so this rung is satisfied at tick 0 and
  `separationBias` (`squads.nim:76-110`) will immediately push them apart. That
  is probably correct — two cogs on one pixel are one grenade — but it is worth
  knowing it happens.

### 3.9 `fetch_item` — survives, anchor passed in (§3.5)

Shields deserve a specific note: 3 points of absorption (`sim_types.nim:736`)
doubles effective HP *and* roughly doubles survivable time outside the zone. In a
mode where both the zone and a spray activation kill from full, a shield is worth
more than its CTF pricing implies. **(judgement)**

### 3.10 `zone_forecast` — the inference this mode rewards most

This is the one genuinely new idea in the document, and I want to flag its
confidence honestly before describing it.

The zone's effective centre is not fixed: it slides linearly from the board's
true centre at `z = 1.0` toward a single per-episode drawn point as `z` falls
(`sim.nim:3357-3388`). The rect's scale `z` is directly observable — it is
`zone` rect width over map width. The board centre is known. Therefore **two
observations of `zone` at two different scales determine the drawn final centre**
by extrapolating the drift line, and one observation plus an assumption about the
schedule's terminal `z` gives a noisier estimate of the same thing.

If that holds, a policy can know roughly where the final zone will be **during
phase 1's 3000-tick wait** — 125 seconds before the first damaging phase, while
every other team is still guessing.

- **trigger** at least two `zone` observations at distinct scales, and match
  time before the first damaging phase.
- **goal source** `ScoredRegion(candidates: room peaks near
  zone.projectedFinalCentre, weights: {+cover, −planDanger, −routeCost})`.
- **Intent** `profile = ProfileDefault`, `movingGoal = false`,
  `arriveRadius ≈ 80`, `micro` default.
- **confidence: medium on the mechanism, low on the exploit.** The mechanism is
  cited. What I have not verified is whether the drift is linear in `z` in the
  form I assume, what the terminal `z` is in an arbitrary (non-reference)
  schedule, and whether the estimate converges fast enough to be worth acting on
  before phase 1 finishes. It is cheap to test offline against a recorded match
  and I would test it before building it. If it does not hold, this rung
  degrades gracefully to "pre-position near the board centre", which is where
  the zone starts anyway.

### 3.11 `third_party`

- **trigger** two or more fresh enemy tracks **of different colours** within
  `FightRadiusPx` of each other, at least one below full `hpSegments`, recent
  `heardImpacts` near their centroid, my HP healthy, neither aimed at me.
- **goal source** `ScoredRegion(candidates: atlasNear(fightCentroid,
  ThirdPartySearchPx), weights: {+sightline to centroid, +cover,
  +approach-avoidance})` — `selectRankedPost` (`worldmap.nim:841`), the same
  machinery `orderPost` uses (`squads.nim:482-499`).
- **Intent** `profile = ProfileDefault`, `arriveRadius = HoldArrivePx`,
  `micro = {MicroPeekDuck, MicroSeparation}`, firefight weights biased toward
  wounded targets (raise `FirefightWoundWeight` for this Intent only).
- **the honest problem** stencil has no "these two are shooting each other"
  percept, and the proxy above is inference that will fire on two enemies who
  merely happen to be near each other. It is also the only rung that
  deliberately seeks contact, in a mode where an even trade is strictly negative.
  **Ship it disabled and let a playbook page turn it on** (§6.5) rather than
  claim it works.

### 3.12 `hold_zone_ground` — the default posture

- **trigger** inside the rect with margin and nothing above fired. Terminal
  rung; replaces the whole defender-post family and the `steal` fallback.
- **goal source** `ScoredRegion(candidates: atlasNear(preferred band inside
  zone), weights: {+cover, +sightline toward zone interior, −planDanger, band
  preference})` via `rankedAtlasPosts` (`worldmap.nim:792`) — defender post
  machinery with home-relative banding replaced by zone-relative.
- **Intent** `Hold` on arrival, `arriveRadius = HoldArrivePx`, `micro =
  {MicroPeekDuck, MicroSeparation}`, `profile = ProfileDefault`.
- **the band question is a hypothesis, not a finding.** Holding some way inside
  the boundary restricts the arc threats can arrive from; holding centre
  shortens every future rotation. Both are defensible BR doctrines. I lean edge-
  band because stencil's 16-sector directional cover masks make it cheap to
  price, but this is a knob a playbook page should own rather than something to
  hardcode.

### 3.13 `seek_survivors` — terminal fallback

`Track(nearest fresh enemy)` else `Fixed(zone.center)` —
`convertHuntPoint` (`squads.nim:176-191`) minus its pedestal branch.
`profile = ProfileHunter`, `movingGoal = true`. Exists so the ladder always
terminates in a validated goal, the way `hunt_fallback` does today. Should
almost never win.

### `convert_hunt` — do not port it; the trigger inverts

`wipeInReach` (`squads.nim:172-174`) is a real CTF edge: a team on its last lives
can be *wiped*, and a wipe converts. In BR the arithmetic does not merely fail to
compute — it points the wrong way. Kills pay nothing directly (they are only
tiebreak inputs, `sim.nim:2983-2985`); every enemy has exactly one life; and an
even trade spends your entire placement equity to remove 1/31st of the field's.
What survives is narrower — *fight only from asymmetry* — and that is
`third_party` and `partner_support`, different rungs with different triggers.

### Rungs I considered and did not propose

- **`loot_death_box`** — does not exist. `killPlayer` clears held items rather
  than dropping them (`sim.nim:921-932`), and there is no drop mechanic in the
  engine.
- **`break_los` / anti-exposure** — the planner already prices LOS danger into
  edge cost (`stencil-policy-loop:206`); a movement rung for it would double-
  count rather than add behaviour.
- **`disengage_on_third_party`** — "I am in a fight and someone else arrives,
  leave." This is `fall_back` with a different trigger, and it is the cleanest
  illustration of why triggers should be authorable *separately* from goals
  (§6): one goal source, two rungs, zero new engine code.

### Not a rung, but the highest score-per-effort action in the mode

The placement bonus is gated on `attacksMade > 0 or damageDealt > 0` across the
duo for the entire match (`sim.nim:2995-3000`). **A team that never attacks
forfeits up to 5 points regardless of how well it places.** A pure-survival
policy — which is otherwise close to what this ladder recommends — walks
straight into that.

The fix is not a movement rung; it is a one-line fire-gate rider: *if the team
has not yet registered an attack, take the first safe shot opportunity.* Do it
early, do it at whatever is in front of you, never do it again for score
reasons.

**(OPEN)** I did not verify whether `attacksMade` increments on any shot fired
or only on a shot resolved against a target. If it is any shot, this is free and
should be unconditional at the first tick the gun is ready. That is one grep on
the counter's increment site and worth doing before anything else in this
document.

---

## 4. Order justification against the scoring function

`BrPlacementBonus[2..16] = [5,4,4,3,3,2,2,2,1,1,1,0,0,0,0]` behind the
engagement gate. Reading the gradient:

- **13th through 16th pay zero.** The bottom quarter is score-identical to
  being eliminated first. The first job of the policy is simply not to be in it —
  outlive four teams.
- **12th → 10th is +1; 9th → 7th is +1; 6th → 2nd is +2.** Once inside the
  paying region the gradient is shallow and roughly linear. No cliff is worth a
  gamble.
- **A kill pays nothing directly** — kills enter only as a rank tiebreak
  (`sim.nim:2983-2985`), behind living-cog count and last-death tick.
- **Therefore an even trade is strictly negative.** You spend your whole
  remaining placement equity to remove 1/31st of the field's.
- **And one attack, once, is worth the entire bonus.** See above.

Two structural facts amplify all of this. **There is no environmental pressure
until tick 3528 of 6000** — 59% of the match — so every death before then was
chosen, by you or by someone who found you. And **placement is decided by the
later of the duo's two deaths**, so a surviving partner keeps accruing rank after
you die.

| # | rung | what the table pays for it | confidence |
| --- | --- | --- | --- |
| 1 | `clear_grenade` | avoids a self-inflicted zero | high, but rarely armed (§3.1) |
| 2 | `clear_spray` | one activation kills from full HP | high |
| 3 | `zone_escape` | certain death, ~1 s to fix | high that it belongs; low that it saves you |
| 4 | `fall_back` | converts a probable zero into a paying place | high |
| 5 | `fetch_medkit` | a full heal restores all remaining equity | high |
| 6 | `zone_rotate` | missing a phase is death, not damage | high |
| 7 | `partner_support` | living-cog count *and* last-death both pay | high (was my top uncertainty; resolved) |
| 8 | `partner_regroup` | sets up 7; halves the odds of being caught alone | medium |
| 9 | `fetch_item` | shield ≈ doubles HP and zone survival time | medium |
| 10 | `zone_forecast` | free position before anyone else knows where to stand | **low — mechanism cited, exploit unverified (§3.10)** |
| 11 | `third_party` | the only positive-EV fight the table admits | **low — perception is inference (§3.11)** |
| 12 | `hold_zone_ground` | default; avoids contact, which the table rewards | medium |
| 13 | `seek_survivors` | terminal; should rarely win | high (that it should rarely win) |

**Rungs 1–4 are ordered by time-to-death, not by value** — grenade impact ~1 s, a
spray activation lethal from full, the zone ~1 s once outside, `fall_back`
conditional on already being hurt. That is the only defensible principle for
emergencies and it is the one the CTF ladder already uses.

**`zone_rotate` at #6 is a correction.** The draft of this document had it at
#10, below the partner and item rungs, on the theory that the zone was
attrition. It is not: `dps ≥ 4` kills in one second against 3 HP. A rotation
deferred for a medkit is a rotation you may not survive, so it outranks
everything that is merely valuable.

**The middle of the ladder is a bet** that survival compounds and kills do not.
The table supports the direction — four of fifteen placements pay literally
nothing — and I am not confident in the magnitudes.

**Where I remain uncertain, plainly:** `zone_forecast` (#10) rests on an
unverified extrapolation; `third_party` (#11) rests on a percept that does not
exist; `hold_zone_ground`'s edge-versus-centre band (#12) is a hypothesis. All
three are called out where they appear and all three should be measured, not
argued.

---

## 5. Duos versus the squad layer — a verdict from the source

**Verdict: the consensus machinery is *safe* at n = 2, *pointless* at n = 2, and
it *hard-breaks* in the state BR guarantees for fifteen of sixteen teams — the
solo survivor. For the BR MVP, run `SquadCommand = 0` and replace it with the
two direct partner rungs (§3.7, §3.8), keeping the local formation geometry.**

### (a) It lands on the duo correctly — by accident

`policy.nim:33-37`, on first sight of the `game teams` marker:

```nim
policy.belief.seat = min(policy.slot div teams, 7)
policy.belief.seatsPerTeam = if teams == 2:
  (if policy.belief.seat == 0: 1 else: 8)
else:
  (if policy.belief.seat < 4: 4 else: 8)
```

With 16 teams and 32 slots, `seat = slot div 16 ∈ {0, 1}` — the correct
seat-within-duo **if** the engine interleaves slots as `team = slot mod teams`,
matching `teamForSlot` (`types.nim:235-236`). That assumption is still untested
against the BR seat allocator (§8).

`seatsPerTeam` then evaluates to **4**, which is wrong — a duo has 2. But the
wrong value routes `squadTable` (`squads.nim:17-18`) into the `seatsPerTeam <= 4`
branch returning `@[('A', @[0, 1]), ('B', @[2, 3])]`, and squad `A` is seats
{0, 1} — *exactly the duo*. So `squadOf` → `('A', [0,1])`, `squadSize` → 2,
`consensusQuorum` → `2 div 2 + 1` = **2**.

Worth knowing before touching either: correcting `seatsPerTeam` to 2 is safe for
the squad table (2 ≤ 4, same branch) but also feeds `defenderCount`
(`roles.nim:6-7`) and `enemyLivesLeft`'s `seatsPerTeam × LivesPerPlayer` total
(`squads.nim:133`).

### (b) Safety degrades gracefully; liveness and cost do not

Quorum 2 of 2 is **unanimity**:

- `consensusChoice` returns `none` unless `consensusProposals.len >= 2`
  (`squads.nim:315-316`). Own proposal is always present (`:307`, `:459`), so
  this requires the partner's proposal to have arrived **over chat**.
- Chat is one shout per 24 ticks (`chat.nim:172-173`) and proposals sit fifth in
  the outbound priority queue (`stencil-policy-loop:214`).
- `updateConsensus` then needs 2 *matching* votes (`:474-480`).

The good news: at n = 2 both members reduce over the same two-element proposal
set, and the tie-break is fully deterministic — kind priority `H > W > M`
(`:323-329`), then medoid by squared directive distance, then lexicographic on
`(opponent, x, y)` (`:330-349`). Both derive the same choice, and
`receiveCommit`'s first-vote lock (`:416-422`) prevents overlapping quorums from
committing differently. **Nothing is unsafe.**

The bad news: at n = 2, quorum equals n, so there is **no fault tolerance to
buy**. The protocol is a two-phase commit that stalls on any single dropped shout
until `ConsensusTimeoutTicks` (480, `stencil-policy-loop:230`) and spends two of
four high-priority slots on a scarce channel. Two identical policies computing
the same deterministic function of shared facts would agree without sending
anything. The votes exist to reconcile belief divergence under fog — real, but at
n = 2 costing more channel than it returns. **Overkill, not broken.**

### (c) It hard-breaks when the partner dies — and in BR the partner stays dead

`nextProposal`, `squads.nim:245-250`:

```nim
if belief.squadmatesAlive < belief.squadSize - 1:
  let position = ... belief.worldmap.homeStep(belief.team, belief.selfXy.get, BackoffStepPx)
  return SquadDirective(kind: 'H', pos: position, opponent: current.opponent)
```

At `squadSize = 2` the guard is `squadmatesAlive < 1` — the partner is dead *or
merely presence-stale*, and in BR the two are indistinguishable because corpses
are invisible to the living (`global.nim:8635-8636`). The proposal becomes a hold
at a `homeStep` backoff toward a **home that does not exist in BR**
(`worldmap.nim:1140`). Then:

1. Quorum can never be met again — nobody is left to propose. `consensusChoice`
   returns `none` permanently, `consensusState` pins at `"proposing"` (`:467-469`).
2. After `ConsensusTimeoutTicks`, `updateConsensus` times out (`:438-458`), and
   because `belief.alive`, sets `rejoinPoint = rejoinTarget()`.
3. `rejoinTarget` (`:501-513`) finds no squadmate track and returns
   `homeStep(team, selfXy, BackoffStepPx * 2)` — the phantom home again.
4. That arms the **`rejoin` rung** (`strategy.nim:367-375`) for
   `RejoinTimeoutTicks`, and `rejoin` sits *above* items, `convert_hunt`, squad
   orders, defender posture and the steal fallback.
5. `rejoinUntil` expires or the agent arrives; consensus restarts; goto 1.

**A lone BR survivor would spend the endgame walking toward a phantom home, on a
loop, with a high-priority rung suppressing everything useful below it — while
the zone closes.** In CTF this path is benign: the dead squadmate respawns and
`squadmatesAlive` recovers. Under one life it never recovers, and the mode
guarantees that fifteen of sixteen teams reach this state.

### What I would do

- **BR MVP: `SquadCommand = 0`.** At n = 2 there is nothing to reach consensus
  *about* that a shared deterministic function cannot produce, and the failure
  mode above is severe.
- **Replace with direct coupling** — `partner_support` and `partner_regroup`,
  both simply unarmed when the partner is gone. That is the property `rejoin`
  lacks.
- **Keep `separationBias` / `formationBias`** (`squads.nim:76-110`): pure local
  geometry, degrades to n = 2 perfectly, already gated per-Intent by
  `MicroFormationBias`. Note they fire immediately at spawn, since both duo seats
  land on one pixel (§1).
- **If consensus is kept anyway**, the minimum guard is to gate the block on
  `squadmatesAlive >= 1` and give `rejoinTarget` a non-home fallback (the zone
  rect). That closes the loop without touching the protocol.

---

## 6. The authorable rung: goal-source vocabulary and the playbook

Written to James's constraint: the BR ladder ships as a **fixed set**, but must
not *foreclose* rungs authored from outside the game later. The way not to
foreclose it is to factor every rung into parts and make the load-bearing part —
the goal source — a **table, not a switch**.

### 6.1 Why the goal source is the load-bearing part

A trigger is cheap to author: an expression over named facts, which an
expression VM can already evaluate. A rung whose *goal* can only come from
bespoke engine code is useless as an authorable unit, because every new rung
then needs an engineer.

So: how many distinct goal shapes does the existing ladder actually use? Reading
all fourteen producers, six.

| combinator | parameters | wraps | rungs using it today |
| --- | --- | --- | --- |
| `Fixed(name)` | a named point | — | `carry_home`, `steal`, `early_defense` |
| `Track(selector, lead)` | which tracked actor; optional extrapolation | `enemyTracks`/`teammateTracks`, `projectedTrackPos` (`belief_state.nim:156`) | `intercept_thief`, `escort_carrier`, `convert_hunt`, `arc_pursuit` |
| `Radial(anchor, distance)` | flee/approach along a bearing | vector maths + `segmentClear` (`worldmap.nim:279`) | `clear_grenade` (`strategy.nim:336-341`), `clear_spray` fallback (`:264-275`) |
| `ScoredLocal(dirs, rings, anchor, weights)` | local candidate ring, scored | `segmentClear` + coverage/danger sampling | `clear_spray` (`:206-262`) |
| `ScoredRegion(candidates, weights)` | best room peak / atlas post in a region | `map.rooms`, `atlasNear`, `rankedAtlasPosts` (`worldmap.nim:792`), `selectRankedPost` (`:841`) | `barrage_center`, `to_post`, `orderPost` (`squads.nim:482-499`) |
| `Interp(a, b, t)` | fraction along a line between named points | — | `advancePoint` (`squads.nim:214-236`) |

Every one passes through the **single validator**, `nearestReachable(point,
selfXy)` (`worldmap.nim:369-403`) — already universal (`strategy.nim:80-83`) and
already deterministic: squared distance then row-major index, explicitly
documented as directionally unbiased (`worldmap.nim:372-374`). That property is
what makes opening this up safe: **an authored rung cannot produce an invalid
goal, because it does not get to choose the validator.**

### 6.2 The named-point namespace is what BR actually adds

The combinators are mode-independent. What is heart-shaped is the *namespace*:
today `home`, `pedestal(colour)`, `capturePoint`, `defenseGate`, `map.center`,
`room.peak`, `post`, track positions.

BR needs these. Each is a `name → proc(belief): Option[Point]` table row, not a
new code path:

| name | resolves to | source |
| --- | --- | --- |
| `zone.rect`, `zone.center` | live rect corners / its centre | `zone x0,y0 x1,y1` (`labels.nim:238-244`) |
| `zonenext.rect`, `zonenext.center` | the rect being interpolated toward | `zonenext` (same emitter) |
| `zone.nearestInside(p, margin)` | axis-aligned **clamp** of `p` into the rect | derived; makes `zone_escape` a one-liner |
| `zone.scale` | rect width ÷ map width — the phase's `z` | derived; the input to `zone_forecast` |
| `zone.projectedFinalCenter` | extrapolated drift target (§3.10) | derived, **unverified** |
| `partner.pos` | the duo partner's freshest track | `teammateTracks`, same colour |
| `threat.centroid` | centroid of fresh enemy tracks | `freshEnemyPositions` (`belief_state.nim:167`) |
| `cover.nearest(p)` | nearest cover pixel | `map.nearestCover` (`worldmap.nim:1011`) |
| `item.nearest(kind)` | nearest believed-present spawn | `belief.itemSpawns` (`items.nim`) |

Adding a name is one row and one small proc. Adding a **rung** that composes
existing names is zero engine code. That is the line this design holds.

### 6.3 The whole BR ladder, audited against the vocabulary

A vocabulary claim is worth nothing unless it is checkable. All twelve rungs:

| rung | combinator | named points | new engine code? |
| --- | --- | --- | --- |
| `clear_grenade` | `Radial` | `grenadeWarning.pos` | none |
| `clear_spray` | `ScoredLocal` | `threat.centroid`, `zone.center` | weight param + zone names |
| `zone_escape` | `Fixed`-derived | `zone.nearestInside` | one name |
| `fall_back` | `ScoredLocal` | `threat.centroid`, `zone.center`, `cover.nearest` | **weight param + track-filter param** |
| `fetch_medkit` | `Fixed` | `item.nearest(Medkit)` | none (re-pricing only) |
| `zone_rotate` | `ScoredRegion` | `zonenext.rect`, room peaks | two names |
| `partner_support` | `Track` | `partner.pos` | one name |
| `partner_regroup` | `Track` | `partner.pos` | one name |
| `fetch_item` | `Fixed` | `item.nearest(kind)` | none (anchor passed in) |
| `zone_forecast` | `ScoredRegion` | `zone.projectedFinalCenter` | one name + the estimator |
| `third_party` | `ScoredRegion` | `threat.centroid`, atlas | **track-filter param** |
| `hold_zone_ground` | `ScoredRegion` | `zone.rect`, `zone.center`, atlas | none beyond the above |
| `seek_survivors` | `Track` → `Fixed` | fresh enemy track, `zone.center` | none |

Two readings matter. **No rung in the BR ladder needs a seventh combinator** —
which is the evidence the factoring is right rather than convenient. And the
"new engine code" column collapses to the two parameterisations named in §6.4,
a handful of table rows, and one estimator. `Interp` goes unused in BR (it
existed for the home→pedestal advance); an unused combinator is not a cost.

### 6.4 The test case: can the vocabulary express "fall back"?

James's example, worked honestly.

- **trigger** `hpPips <= 1 and (underFire or firefightActive)` — an expression
  over three facts that all exist today (`belief_state.nim:66, 72, 73`).
  **Expressible, no new code.**
- **goal source** `ScoredLocal(dirs: 16, rings: 2, anchor: threat.centroid,
  weights: {threat: +1.0, cover: +0.6, zoneSafety: +0.8, clump: −0.4})`.
  **Not expressible today. Two things block it:**
  1. **The weight vector is compiled in.** `strategy.nim:248-249` computes
     `SprayThreatWeight * threatGain + SprayCoverWeight * coverPath −
     SprayClumpWeight * clumpRisk + SprayCenterWeight * centerTerm` from four
     module consts. For `ScoredLocal` to be a vocabulary item rather than one
     bespoke behaviour, the scorer must take the weights as a **parameter**.
  2. **The threat anchor is hardcoded to spray.** `updateSprayFleeLatch`
     (`:168-170`) filters `track.weapon != WeaponSpray` with a spray-specific
     TTL. `fall_back` wants all fresh enemy tracks; `third_party` wants
     different-colour tracks near each other. The filter must become a
     **predicate parameter**: `(weapon, freshness, radius, colour-relation)`.
- **Intent fields** `profile = ProfileCarrier`, `movingGoal = true`,
  `suppressFireFreeze = true`, `micro = {}`, `arriveRadius ≈ 40`. All five are
  already typed fields on `Intent` (`types.nim:205-214`) set from a per-reason
  table (`strategy.nim:20-72`). **Already a table — expressible.**

**Verdict: expressible after two parameterisations, both small, both of
existing code, both on the rework path anyway.** I would rather report that than
a clean-looking proposal, because the gap is the actionable part: *until the
scorer takes weights and the track filter takes a predicate, `ScoredLocal` is
one behaviour rather than a vocabulary item, and authorable rungs stop at those
whose goal is `Fixed` or `Track`.*

Two notes in the same spirit:

- **Per-Intent firefight weights have a precedent to copy.** `scoreTarget`
  already takes an injected `defensiveThreat` term as a parameter
  (`fight.nim:162-165`) rather than reading role state itself. The same seam
  generalises to the whole weight vector, arriving from the Intent. That is the
  cleanest version of James's ruling and requires inventing nothing.
- **`reason` must stay telemetry-only.** The v66 contract grep-gates it
  (`nav-layer4:47-48`). If rungs become authorable, `reason` becomes a rung
  *identity* — used for weight lookup and tie-breaking — which is a real change
  to the contract's meaning. Better decided than drifted into: add an explicit
  `rungId` and leave `reason` alone.

### 6.5 What a playbook would price

Under the agreed reframe a page **scores the validated rungs** rather than
taking the first, and default weights reproduce the ladder order exactly.

Mechanism: every rung whose trigger fires *and* whose goal validates produces a
candidate `(rungId, point, intentFields, baseWeight)`. Selection is argmax over
`baseWeight + Σ modifiers`. **If defaults are strictly descending in ladder
order, argmax is identical to first-match-wins** — the identity property, which
should be an actual test rather than a claim.

A concrete page for one stance:

```yaml
stance: late_rotator
note: >
  Hold ground until the zone forces the move. Trade only from clear advantage.
  Bets that contact avoided early is worth more than position taken early.

weights:                    # default (= ladder order) in comments
  clear_grenade:    130     # 130
  clear_spray:      120     # 120
  zone_escape:      110     # 110
  fall_back:        105     # 100   +5   one life; protect it harder than default
  fetch_medkit:      90     # 90
  zone_rotate:       80     # 80    (its trigger is already the deadline test)
  partner_support:   70     # 70
  partner_regroup:   60     # 60
  fetch_item:        50     # 50
  zone_forecast:     45     # 40    +5   pre-position while it is still free
  third_party:       55     # 30    +25  this stance wants the free trades
  hold_zone_ground:  35     # 20    +15  ... which, with rotate's trigger, is the stance
  seek_survivors:     5     # 5

modifiers:                  # expressions over the SAME named facts as triggers
  - rung: zone_rotate
    add: +60
    when: zone.ticksRemainingInPhase < routeTicks(zone_rotate.goal) * 1.6
    note: hard safety override — a late rotator must not become a dead one
  - rung: third_party
    add: -70
    when: hpPips < 3
  - rung: partner_support
    add: +25
    when: partner.hpSegments <= 1
  - rung: hold_zone_ground
    add: -40
    when: teamsRemaining <= 4
  - rung: zone_forecast
    add: -100
    when: tick > zone.firstDamagingPhaseTick
    note: worthless once the schedule is already biting
```

Three things this is meant to show:

1. **The stance is a small set of inequalities**, not a reordered `if` chain —
   legible to an LLM and auditable by a human.
2. **It expresses time-dependence that no fixed ladder can.** `zone_forecast` is
   valuable only before the first damaging phase; `hold_zone_ground` only while
   the field is large. Modifiers say exactly that, in the same expression
   language as the triggers. One language, two uses.
3. **An early-rotator page is the same file with three numbers changed.** That
   is the test of whether the vocabulary is really a vocabulary.

### 6.6 Determinism and replay (our side of the split)

- **Selection must be a pure function of `(belief, page)`** — no wall-clock, no
  iteration order over hash tables. `consensusChoice` already models this well
  (`squads.nim:321-349`): it iterates a table but reduces through an
  order-independent tie-break.
- **Ties break lexicographically by `rungId`.** With authored weights, ties stop
  being exotic.
- **Weights should be integers or fixed-point.** Float sums compared for argmax
  across platforms is a determinism hazard for no benefit; the example uses
  integers deliberately.
- **The page must be content-hashed into the replay.** A replay of a scored
  ladder is not reproducible without the exact page that scored it. This should
  land with the first scored-ladder commit, not after.
- **`nearestReachable` is already deterministic and documented as such**
  (`worldmap.nim:372-374`) — validation needs no work.

---

## 7. Preconditions — what must be true before any BR rung can be measured

Upstream of the ladder, and on the critical path.

1. **The `Team` enum has four values; BR has sixteen teams.**
   `types.nim:8-12` is `Team = enum Red, Blue, Green, Yellow`.
   `policy.nim:28-30` does `colors.setLen(teams)` then `colors[index] =
   Team(index)` for `index in 0 ..< teams`; `teamForSlot` (`types.nim:235-236`)
   does `Team(slot mod teams)`. At 16 teams both are out-of-range conversions.
   The engine's own `Team` has 16 members (Red..Peach, `sim_types.nim:951-970`)
   and `teamCount()` only ever returns 2, 4 or 16 — never 8 (`:963-964`).
   **Recommendation: do not widen stencil's `Team` to 16.** In BR the only
   distinction that matters is partner / not-partner, so the colour model
   collapses to "same colour as me" plus an identity. Smaller than generalising,
   and it also fixes `belief_update.nim:260`, where chat-sourced enemy sightings
   are hardcoded to `color: Red`.

2. **No endzones means no `WorldMap` means no movement at all.**
   `policy.nim:39-40` gates the entire map build on `percept.endzones.len >=
   colors.len`, and `newWorldMap` (`worldmap.nim:173`) takes endzones as a
   construction argument. A flagless map never enters the endzone emission loop
   (`global.nim:3799`), so the map is never built and
   `decideBaseObjective`'s first line returns `hold("no_worldmap")`
   (`strategy.nim:303-305`) for the whole episode. **Without this, stencil in BR
   stands still.** Only the home Dijkstra fields and
   `capturePoint`/`pedestal`/`defenseGate` actually need endzones; the rest of
   the pipeline (clearance → grid → components → watershed → cover → posts) does
   not.

3. **`seatsPerTeam` resolves to 4 for a duo** (`policy.nim:34-37`) — see §5(a)
   for the coupling to the squad table, `defenderCount` and `enemyLivesLeft`.

4. **The zone is not perceived at all.** `perceive` (`perception.nim:308-390`)
   has no `zone `/`zonenext ` decode; `PaintState` and `Belief` need the fields.
   Every zone rung depends on this. The labels are world knowledge, not
   fog-gated, on both the POV and spectator streams (`global.nim:8688-8691`,
   `9618-9619`), so there is no visibility caveat to model.

5. **The `lives` label reads `x0` for a perfectly healthy BR cog.**
   `LabelPrefixLives` emits `$(hp+shieldHp) & "hp x" & $lives`
   (`global.nim:8793-8794`), and `seatLivesFor` seats every brMode cog with zero
   spare lives from the start (`sim_types.nim:2485-2501`). So a living, undamaged
   BR cog reads `"3hp x0"` all game. **Any liveness logic treating `lives == 0`
   as "eliminated" will misread every living cog in the mode.** Stencil's own
   liveness/respawn fold (`belief_update.nim:362-441`) should be checked against
   this before anything else is trusted.

6. **The map is ~6.9× the CTF area** (3211 × 1713 vs 1235 × 659). Stencil builds
   *all* map knowledge online, in the single tick the init snapshot completes
   (`policy.nim:39-50`, `worldmap.nim:173-209`) — clearance field, 8 px grid,
   components, watershed, 16-sector cover, Dijkstra fields, post atlas — over
   5.5 M pixels instead of 814 k. **(OPEN)** I did not measure whether that
   build fits inside the tick budget. It is the kind of thing that shows up as a
   mysterious first-frame stall rather than an error, and it is worth timing
   before anything else is diagnosed. `nearestReachable`'s default radius of
   `32 × NavCell` = 256 px is also proportionally much tighter on this map than
   on CTF's, which will change how often producers fall through.

---

## 8. Top uncertainties

1. **Does `attacksMade` increment on any shot, or only a resolved one?**
   (§3, last subsection.) The engagement gate is worth up to 5 points — the
   entire placement bonus — and is satisfied by one attack in the whole match. If
   any trigger-pull counts, a two-line rider captures it for free and the
   otherwise-correct pure-survival policy stops forfeiting the bonus. This is one
   grep and it is the highest value-per-effort item in the document.

2. **`zone_forecast` (§3.10) is an unverified exploit on a verified
   mechanism.** The drift from board centre to a drawn point is cited
   (`sim.nim:3357-3388`); that it is linear in `z` in the form I assume, that
   terminal `z` is knowable, and that the estimate converges fast enough to act
   on during phase 1 are not. It is cheap to test offline against a recorded
   match and I would test before building.

3. **`third_party` (§3.11) rests on a percept stencil does not have.** There is
   no "these two are fighting each other" observation; the trigger is inference
   from proximity, damage and impact sounds, and will fire on enemies who merely
   happen to be near each other. It is the only rung that seeks contact, in a
   mode that punishes contact, so a false positive is expensive. Ship disabled;
   measure before trusting.

4. **The slot→team mapping is assumed, not verified** (§5a). Seat and partner
   identification rest on `team = slot mod teams` matching the BR seat
   allocator. If BR blocks duos as adjacent slots (`slot div 2`), both `seat` and
   `squadOf` land wrong and the partner rungs address the wrong agent.

5. **Every threshold in §3 is a placeholder.** `FallBackHpPips`,
   `RotateSafetyFactor`, `ZoneSafeMarginPx`, `SupportRadiusPx`, `FightRadiusPx`,
   the medkit detour multiplier — shapes and directions, not values. They belong
   in `config.nim` (which already carries 152 `STENCIL_*` knobs) and should be
   tuned against real episodes, not chosen here.

6. **The zone schedule is authored config, not an engine constant**
   (`sim_config.nim:60` defaults `zonePhases` to empty). Every timing claim in
   this document — first damage at tick 3528, a 528-tick rotation budget, 59% of
   the match unpressured — is the *reference* schedule from
   `tools/record_br_match.sh`. A policy must read the schedule off the wire and
   must not hardcode any of it.
