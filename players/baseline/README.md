# baseline — Coworld CTF bot (8v8, fog-of-war)

> **Deprecated since 0.7.253.** This Sprite v1 policy is retained for deprecated
> modes, which run only with `allowDeprecatedModes: true`; it cannot drive a
> Season 2 play seat. Start at [`policies/starters/`](../../policies/starters/README.md).
> **The scoring section directly below is not deprecated** — the Season 2
> multiplier economy is engine-side, so it applies to whatever shell you write.

## What the server actually scores (Season 2 multiplier economy)

**Read this before you tune anything.** The scoring rule changed several times
in one week and everything below is checked against `src/ctf/glory.nim`,
`src/ctf/sim.nim`, `src/ctf/roster.nim` and `coworld_manifest_paintbot.json` on
`main`, not against an announcement. Every number carries a source line; a
number with no citation is not in this document on purpose. This section is
about the **engine's** economy, so it applies to any policy on any shell —
the deprecation notice above is about the Sprite v1 protocol client below it,
not about this.

### Losing no longer zeroes your score

This is the change that most needs a policy rewritten around it. The banked
league score used to be gated on winning. It is not any more: `playerWon` was
dropped from the score path in `src/ctf/roster.nim:1028-1048`, and every seat
now reports its own team's glory ledger — win, lose, or draw. The one gate left
is `sim.phase == GameOver`: an episode that never concludes still banks 0 for
everyone. That ledger is not a side channel; it **is** the `scores` field the
platform ranks you on (`src/ctf/roster.nim:920-941`, "GLORY-AS-LEAGUE-SCORE"),
and it can go negative.

Nothing gates this behind a config flag, so it is true on every variant.

What to do differently:

- **Stop treating a lost position as a scoreless one.** A duo that is going to
  die in ninety seconds still banks everything it earns in those ninety
  seconds. Play the ledger to the last tick.
- **Stop paying for win probability with certain score.** Winning is now a
  multiplier stacked on top of what you already banked, not the price of
  entry, so a trade that burns a banked factor for a small win-probability
  gain is a losing trade. Today the win pays as the `dVictory` deed at ×8
  (`glory.nim:2374`); under `winAsMultiplier` it becomes a flat ×4 fold
  instead (`glory.nim:2666`, `RecutWinFactorBR`) — see "What is armed today".
- **Survival is now instrumental, not terminal.** You stay alive because a
  dead cog mints nothing, not because placement is the score.

### Your score is a product, so deed *count* is the wrong objective

There are no base points. An episode's score is
`seed × Π(per-event factor) ÷ 2^(friendly-fire halvings)`, with the seed at 1
(`glory.nim:2330`) and every factor an integer (`glory.nim:2592-2613`,
`recutFactor`). Multiplying by 1 does nothing, so a deed priced ×1 moves your
score **exactly not at all** — `recutFactor` returns 1 for it before any
live-state multiplier can attach (`glory.nim:2606-2607`). It still mints, still
pops, still counts toward K/D and the achievement gates. It just is not worth
points.

The priced rungs, from `RecutClassTable` (`glory.nim:2335-2384`):

| factor | deeds | line |
| ---: | --- | --- |
| ×1 | plain gun kill, spray kill, grenade kill, point-blank kill, shield soak, level-up | `:2342-2345`, `:2363`, `:2365` |
| ×2 | first blood, revenge kill, run-down, escort kill, assist, rescue, duo-down, closing-time kill | `:2341`, `:2348-2349`, `:2359-2361`, `:2368-2369` |
| ×3 | longshot kill, splash multi-kill | `:2346-2347` |
| ×4 | ace tag, flag steal, carrier kill, last-light kill | `:2350`, `:2355`, `:2357`, `:2373` |
| ×6 | denial | `:2358` |
| ×8 | capture, wipeout, victory | `:2356`, `:2364`, `:2374` |

Achievement claims are priced by tier instead: ×1/×1/×2/×2/×4 for tiers I–V
(`glory.nim:2386`, `RecutTierClass`). The first-claim ×3 (`glory.nim:1658`)
fires on the **top tier only** — `sim.nim:520` gates it with
`tier == AchievementTiers - 1`, which `recutAchievementFactor` on its own does
not tell you.

What to do differently:

- **Stop optimising kill count.** Four plain gun kills are ×1×1×1×1 = no score.
  One ace tag on enemy ground is ×5. The kill *classifier* is the objective,
  not the kill.
- **Chase the composition, not the deed.** Two ×2 deeds and one ×4 are ×16;
  eight ×1 deeds are ×1. Ask what a deed composes *with*, not what it is worth.
- **On battle-royale maps the flag band is dead.** `dFlagSteal`/`dCapture` are
  inert without a heart to carry (`glory.nim:2492`), and the carry multiplier
  never lights either — `awardDeed`'s carrier scan never finds one on a
  flagless BR map, so `carrying` is always false (`sim.nim:368-373`). Do not
  budget for ×8 captures in Season 2 BR.

### Team context stacks on an accelerating curve — on kills only

`k` teammates-in-context multiplies the whole factor on a Fibonacci ladder:
×1, ×2, ×3, ×5, ×8, ×13 for k = 1…6, clamped at both ends
(`glory.nim:2393` `RecutStackLadder`, applied at `glory.nim:2564-2570`). Acting
alone is the k=1 column, which is neutral.

`k` is the number of distinct cogs participating in the victim's open damage
incident — the killer plus everyone with a qualifying hit on that victim inside
the last 120 ticks (`glory.nim:1520` `AssistWindowTicks`, counted in
`sim.nim:2564-2607` `recutContextK`). In CTF that means same-team players; in BR
it also counts cogs from **other duos** co-engaged on the same victim, so a
truce that focuses one target pays both duos. The victim's own duo never counts.

The trap: this is computed at the kill site and nowhere else. `awardDeed`
defaults `stackK` to 1 (`sim.nim:330`) and `sim.nim:2790-2792` is the only call
site that passes a real one. Captures, steals, wipes and achievement claims take
**no stack at all**, whatever your team is doing at the time.

What to do differently:

- **Converge damage onto one victim inside the 120-tick window** rather than
  spreading it. Going from solo to three participants is a ×3 on that entire
  kill's factor, on top of its class.
- **Do not detour to a teammate for a capture or a steal.** Objective deeds
  cannot take the stack. Bring the team to the *kill*, not to the objective.
- **In BR, co-engaging a neutral duo's target is worth real score** — it widens
  `k` without spending any of your own resources.

### Territory shifts the rung; it does not scale the score

A deed minted on enemy ground climbs **one integer rung** — ×2→×3, ×3→×4,
×4→×5, ×6→×7, ×8→×9 (`glory.nim:2572-2591`, `recutShiftedClass`). It is not a
percentage on the score any more. Two consequences that matter:

- A ×1 common **never** shifts, on any ground: `glory.nim:2589-2590` only
  shifts a class already at 2 or above, and `glory.nim:2606-2607` returns 1 for
  the rest before anything else can attach. Dragging plain gun kills onto enemy
  ground buys you nothing.
- The shift is worth proportionally the most on the *cheap* priced rungs: ×2→×3
  is +50%, ×8→×9 is +12.5%. Enemy ground is where your ×2 assists and rescues
  should happen, not where your ×8s should.

Ground is owned by nearest home pedestal, a Voronoi cell over the real pedestal
positions, never an x-midline (`sim.nim:239-242` `deedSitePct`,
`glory.nim:2276-2282` `siteMultPct`). "Neutral" ground is unreachable in this
engine — `deedSitePct` hardcodes `ownerIsNone = false`, so `SiteMultNeutralPct`
(`glory.nim:954`) can never fire. Every point on the map is home or enemy.

### Friendly fire divides, per mode, and is uncapped

A team kill is not a subtraction you can out-earn. It halves the whole episode
product, compounding, with no floor: BR halves once per incident, CTF once per
*two* incidents (`glory.nim:2629-2637`, `recutFfHalvings`; the fold is
`glory.nim:2654-2663`, `recutScore`, which floors the division). Three friendly
kills in a BR episode is ÷8 on everything you earn all game, including deeds
you have not minted yet.

What to do differently:

- **Treat the FF check as the highest-value gate in your fire discipline**, above
  target selection. There is no score you can earn that outruns a compounding
  halving, and the penalty is uncapped by owner ruling.
- **A blocked shot costs you one ×1 common; a friendly kill costs you half of
  everything.** When those trade off, they are not close.
- Note the mode asymmetry: the same FF discipline is literally twice as valuable
  in BR as in CTF.

### The live-state multipliers your factor composes with

Each applies only under its own gate, inside `recutFactor` (`glory.nim:2592-2613`):

- **Heat** — a streak multiplier of ×1/×2/×4/×8 by rung (`glory.nim:855`
  `HeatLadder`), reached at 2/5/10 cumulative embers (`glory.nim:866`
  `HeatThresholds`), capped at 11 embers (`:871`), shedding 2 per quiet window
  (`:875`) with a window closing after 45 quiet ticks (`:880`, ~1.9s at 24
  ticks/s). Only deeds with drama climb it, and achievements never do
  (`glory.nim:2135-2138`, `paysHeat`). **Cadence is a lever**: back-to-back
  drama inside 45-tick gaps is worth up to ×8 on every factor in the streak.
- **Carry** — ×2 on drama deeds while your team holds an enemy heart
  (`glory.nim:976` `CarrierHoldMultPct`). Dead on flagless BR maps, per above.

### Per-episode mint caps (armed on the Season 2 flagship)

Repeatable deeds have a per-episode, per-duo budget. Past it the deed folds
factor 1 and scores nothing, while still minting, popping, counting and
climbing heat (`glory.nim:2436-2539` `RecutMintCapTable`, applied at
`sim.nim:411-441`):

| deed | budget | line |
| --- | ---: | --- |
| `dTagBack` (revive a downed partner) | 3 | `glory.nim:2522` |
| `dJointAct` (cross-duo damage window, **alliance-only since GloryVersion 15** — see below) | 6 | `glory.nim:2530` |
| `dDuoDown` (finish an enemy duo) | 4 | `glory.nim:2510` |
| `dShieldSoak` | 3 | `glory.nim:2500` |

Everything else is uncapped (`0` rows). There is also a hard saturation bound
on the product at 2^26 = 67,108,864 while caps are armed (`glory.nim:2420`
`RecutProductCapArmed`) — it should never bind, and if your episode reports
exactly that number, it did.

What to do differently: **do not build a loop around a capped deed.** A revive
metronome pays three times and then pays nothing at all, forever, for the rest
of the episode.

### What is armed today

All three keys default to **off** (`sim_config.nim:130`, `:133`, `:137`).
Arming is a per-variant manifest publish, so "merged" and "armed" are different
things. On `main`, `coworld_manifest_paintbot.json` publishes:

| variant | `gloryMultiplierRecut` | `deedMintCaps` | `winAsMultiplier` |
| --- | --- | --- | --- |
| `battle-royale-s2` (the flagship you play) | **on** | **on** | off |
| every other variant | off | off | off |

With `gloryMultiplierRecut` off, the pre-v13 additive economy runs and none of
this section applies. With `winAsMultiplier` off — which is the state today —
the win pays as the `dVictory` ×8 deed rather than a flat ×4 fold, and
`dTagBack`/`dJointAct` are **not priced at all**: they mint nothing, because
those two rows only fire under that flag (`sim.nim:7790-7792`,
`glory.nim:2382-2383`). Their mint caps above are pre-armed for the day it
flips. Check the variant before you tune to any of it.

**`dJointAct` is alliance-only (GloryVersion 15, owner ruling 2026-09-08):** a
contributing seat mints it only if it shares an ACTIVE formal pact with at
least one other contributing team on the same damage incident
(`pactActive`, the mutual-pact registry the `pact` play feeds). Two or more
UNALLIED teams co-damaging the same victim now mints nothing for anyone —
before this ruling any ≥2-team co-fire minted regardless of alliance.
`dTagBack` needed no equivalent change: its cross-team revive already
requires an active pact as a precondition (a non-pact cross-team revive
cannot happen), so it could never mint off unallied co-fire in the first
place.

The economy version is `GloryVersion = 15` (`glory.nim:301`); it bumps on any
pricing change, and a score compared across versions is not a comparison.
This section's other line references predate later refactors and may drift —
check the cited symbol, not the exact line number.

---

A capture-the-flag reference bot that speaks the Bitworld Sprite v1 protocol.
Its WebSocket disables Nagle buffering so separate input and chat messages
arrive within the simulation tick that produced them.
It keeps a persistent world model on top of the fog-of-war full-map view and
plays a coordinated 8v8 team game on the dense-cover arena: cover-aware
pathfinding, a six-strong attack wave (mid quad plus wide flankers), an
overwatch sniper whose vision cone owns the longest lane (under fog the lane
watcher is also the radar), rotate-button vision sweeps at every hold point,
thief hunting without any global tracking, and a turret controller that
traverses the DECOUPLED aim angle onto targets and fires only when the bullet
corridor covers them.

All decision logic lives in `decide` in `baseline.nim`.

## View model (fog-of-war, full-map, map coordinates)

The observation is the **full 1235×659 map in map coordinates**: the map
object sits at `(0, 0)`, so object positions ARE map positions (no camera
math). Entities are **fogged**: every other player — **teammates included**,
and an enemy carrying our flag — is only streamed while inside OUR vision,
which is a **forward cone** (half-angle `visionConeDeg` ≈ 60° around our AIM
ANGLE, **unlimited range**, walls block it) plus an **omnidirectional bubble**
(`visionBubble` ≈ 90px).
**Aim carries vision**: the cone points where the turret points, never where
we walk, so sweeping it is an explicit rotate-button act. Always visible
regardless of fog: the map, **both flag pedestals**, and **ourselves** via the
distinct self marker. There is **no team radio** — a mate outside our cone and
bubble is as invisible to us as an enemy, so any notion of where our team is
has to be tracked and predicted, not read off the frame.
**Aim is decoupled from movement** (a continuous per-player angle in brads,
0 = east, counter-clockwise; B rotates CCW, Select CW at `AimRate` = 5
brads/tick) and
only a **fresh A press** fires — the pull locks the aim angle and the bullet
leaves after a ~5-tick windup. Labels we read:

- `"self <color> right|left"` — OUR OWN avatar (an outlined marker sprite);
  present exactly while we are alive, and how we locate ourselves in map
  coordinates. The suffix is the horizontal sprite flip (aim left/right-ish).
- `"player <color> right|left"` — another player; the suffix is the
  horizontal sprite flip. Teammates and enemies fog identically: another
  player is streamed only while inside our vision cone/bubble with line of
  sight, so a mate who steps out of the cone simply disappears from the frame.
- No label carries anyone's **aim angle**. The old `"aim dot <color>"` line was
  retired engine-side (see RULES.md label changes), so our own aim is pure dead
  reckoning and a mate's or enemy's facing is only the coarse left/right sprite
  flip above.
- `"<team> flag"` (`"red flag"` / `"blue flag"`) — a flag, on its pedestal or
  riding its carrier's exact position. Pedestal flags are never fogged; a
  carried flag is exactly as visible as its carrier — and since mates fog too,
  that includes a mate's carry. Consequences: the ENEMY flag (only our team can
  carry it) is visible on its pedestal and while *we* carry it, but once a MATE
  picks it up it is only visible while that mate is inside our vision, so the
  flag going ABSENT can equally mean a fogged mate is running it home. Our OWN
  flag on its pedestal means it is safe, visibly off-pedestal is a live thief
  fix, and ABSENT from the frame means a fogged enemy thief has it.
- `"walkability map"` — the full static walkability mask, sent once at init.
- `"fire icon"` / `"fire icon cooldown"` — whether our shot is ready (HUD).
- `"fog"` — the viewer-side fog overlay runs (cosmetic; we ignore them — the
  entity culling above IS the observation).
- Death splatters and shot tracers render under their own labels, culled by
  the same fog, and are ignored (cosmetic only).

There are **no flag arrows** — fog of war deleted all global tracking intel.
When we are dead the self marker disappears and the ghost view shows the whole
map (inputs are ignored); the bot returns to lobby behavior and ignores ghost
frames so corpses never poison memory.

## Nav grid, cost field & cover-aware movement

At init the full-map walkability mask is eroded by the player's solid
footprint (`PlayerHalf` = 6px, matching the sim's `canOccupy`) into an
8px-cell grid (`NavCell`). Movement goals run a **cost field (Dijkstra)** over
that grid: orthogonal steps cost `StepCost`, diagonals `DiagCost` (no corner
cuts), and entering a cell **exposed to a remembered enemy** adds
`ExposedCost`. Exposure is recomputed per repath from the freshest few enemy
tracks (`ExposureThreats`, age ≤ `ExposureTrackTtl`): a cell is exposed when
it is inside gun range (`ExposureRange`) of the track with a coarsely-clear
line. The soft cost makes every unit — attackers and carriers alike — advance
cover-to-cover and keep obstacles between themselves and known threats
without hard-blocking any route. Steering follows the cost gradient with a
waypoint lookahead (`LookaheadCells`) plus a grid raycast; the field refreshes
when the goal cell changes or every `RepathTicks`. A stuck detector (no
movement for ~1s, and not deliberately holding behind cover) bursts in a
random direction and forces a repath.

## Cover model

From the eroded grid we precompute **cover cells** — walkable cells adjacent
to an obstacle (`coverCell`). They feed three behaviors:

- **Duck**: during the 12-tick fire cooldown with a remembered threat nearby,
  move to the nearest directly-reachable cell whose center the threat cannot
  see (exact pixel raycast, the sim's LOS rule) and hold there until the gun
  is back up (`findDuckCell`).
- **Peek**: with the gun up and the nearest fresh track wall-blocked, PRE-LAY
  the aim on the blocked target's line while stepping sideways to the nearest
  cell that opens the firing line (`findPeekCell`); the traverse happens
  during the step, so the engage logic fires the moment the ray clears, and
  the next cooldown ducks us back. This aim → peek → fire → duck cycle is the
  default combat mode for every non-carrier, non-rushing unit and the big
  payoff of decoupled aim: the shot is already laid before we expose.
- **Overwatch posts**: at nav-build each overwatch seat scans for a cover
  cell just on our side of the flag ring (`pickPost`) whose obstacle blocks
  the line toward the enemy half (`CoverShieldDist`) and which has a sideways
  peek cell with an open firing line toward the enemy half (≥`PeekLineDist`,
  scored by the longest line — sniper posts). The bot holds the post,
  sidesteps to the peek cell when a remembered enemy is in reach with the gun
  up, fires, and ducks back on cooldown.

## Memory (fog makes the entity stream partially observable)

- **Player tracks**: visible players are matched to remembered tracks
  (position, blended px/tick velocity, last-seen tick, sprite flip). Tracks expire
  after `TrackTtl` (~5s) and are capped at the **8** real opponents/teammates
  (`TrackCap`). Tracks are what persists through fog: an enemy that walks
  behind cover or out of the cone stays remembered until the TTL runs out.
- **Our own flag's state needs no memory**: its pedestal is never fogged, so
  stolen-ness is observable every frame. The enemy flag is *not* equally free —
  it is certain only on its pedestal or in our own hands; a mate's carry fogs
  with the mate, so an absent enemy flag is ambiguous (a mate is running it home
  vs. we simply cannot see the carry) and does need remembering.
- **Thief fix**: seeing our own flag off-pedestal is a live fix on the thief
  (position, plus velocity from the matching track). The fix guides pursuit
  for `ThiefFixTtl` (~1.7s); after that the hunt falls back to guarding the
  mid crossing on the lane nearest the last fix.

## Roles & lanes (deterministic from the seat)

Slot parity picks the team (even = Red/left, odd = Blue/right); the per-team
seat index (`slot div 2`) picks the role via `roleForSeat`:

- **Seats 2/3 — MidTop (rusher) + MidBottom**: both seats spawn at flag
  height, but the sim's un-mirrored ±6px spawn offset makes seat 3 the
  closest spawn for Red and seat 2 for Blue — the **rusher** takes whichever
  is closer for its team (still fully deterministic) and races the flag dead
  straight, winning the opening pickup race. The other trails offset low.
- **Seats 1/4 — MidGuard + second MidBottom**: the trailing attackers; the
  quad is spread so one enemy vision cone cannot kill two of them. The attack
  wave is deliberately six strong — under fog a carrier that slips the
  contest is hard to reacquire, so committed offense converts steals into
  captures.
- **Seats 0/6 — FlankBottom/FlankTop**: route wide via the extreme bottom/top
  lanes (`LaneBottom`/`LaneTop`) to `FlankDepth` past mid (sticky
  `behindLines` progress so they never oscillate), then turn straight in and
  hit the pocket together with the mid quad.
- **Seat 5 — Overwatch**: holds a shielded cover post flanking the flag ring
  (see cover model) and runs the peek-fire-duck cycle on anything crossing
  mid. Post selection is sniper-first: candidate peek cells are scored by
  the **length of their clear firing line** toward the enemy half
  (`openLineLen`, floor `PeekLineDist`), because under a map-wide gun AND
  map-wide vision cone a post is worth what its lane can reach — the watcher
  aiming down an open lane sees (and kills) intruders at any distance.
  Overwatch is the team's radar.
- **Seat 7 — HomeDefender**: holds the choke between the flag and our capture
  column, snapped to the nearest cover cell (`chokeHold`); chases intruders
  spotted on our half and hunts the thief when our flag leaves its pedestal.

Priorities override the defaults for everyone: carry → run home; enemy
carrier known → intercept (see below); teammate carries → escort (mids and
flankers take spread positions ahead toward home, the guard screens the
nearest threat, overwatch keeps its post covering the retreat, the defender
holds the choke). **Endgame push**: with our flag safe, deep into the game
(`PushOutMinGame`), and no enemy seen for `PushOutTicks` (~15s), even
Overwatch and the HomeDefender break their posts and push for the steal —
the late-game survivors are usually exactly the defensive seats, and holding
forever is a guaranteed tiebreak stalemate.

## Carrier play & interception

Our carrier picks the home lane (top/mid/bottom) that combines the fewest
remembered enemies with the best **cover continuity** (`safestLaneY` samples
the run home and charges stretches with no cover cell nearby — under map-wide
guns an open lane is a shooting gallery even when it looks empty) and paths
deep into the capture zone; the exposure cost keeps the run hugging cover
past remembered enemies. The **enemy spawn pocket is a standing virtual
threat** (fed into `enemyPosts`): every kill respawns an armed
enemy at the pedestal whose spawn aim points along the
east-west axis, so a fresh carrier first **bugs out of the pocket
vertically** (pure-vertical movement exits that cone fastest) and runs home
along a border lane. Carriers never peek, duck, or jink and only engage
enemies within `CarrierFireRange`.

Against a thief carrying OUR flag (defense without arrows): stolen-ness is
always observable — the own pedestal is empty — but the thief itself is
fogged like any enemy. With a **fresh fix** (own flag seen off-pedestal ≤
`ThiefFixTtl` ago) the back line (defender, and overwatch while the fix is
fresh) converges on the thief's predicted path toward ITS home edge. With a
**stale** fix the defender guards the **mid crossing** on the lane nearest
the last fix (the thief must cross toward its capture zone) and **sweeps its
vision** there; overwatch keeps its long lanes — reacquisition takes eyes on
the thief, and the moment any unit's cone touches the carrier, the flag
sprite itself is the new fix. Attackers keep pressing the enemy pedestal so
the capture race stays on.

## Fire discipline & combat micro

- **Target**: nearest track seen within `FreshShotTicks` (the turret needs
  traverse time, so tracks stay shootable ~1s), led by its velocity
  (`LeadTicks` covers the 5-tick windup), within `FireRange`, with a clear
  pixel raycast against the walkability mask (exactly the sim's LOS rule).
  Shoot first — first shot wins. Tracks form anywhere the vision cone
  reaches, so a lane watcher genuinely engages down its open lane.
- **Turret controller**: the bot tracks its own aim by **dead reckoning only**
  (spawn aim is toward the enemy side; every elapsed sim tick advances it by
  the rotation of the last sent mask) — no observation label reads the aim
  angle back, so drift is uncorrected. Each tick it outputs the rotate button
  (B = CCW, Select = CW) that closes the shortest arc to the desired aim and stops
  inside `CombatDeadband` (±2 brads; `AimRate` = 5 cannot settle tighter).
- **Fire gate**: fire only when the corridor covers the target at its range —
  the perpendicular miss of the current aim error, `range × sin(err)`, must
  be within `FireSlackPx` (11px of the ~14px corridor half-width). Closing
  distance scales the miss down linearly, so the engage branch keeps walking
  toward the target while the turret settles; far targets fire only on clean
  alignments. The pull tick never rotates: the shot locks the settled angle.
- **Scanning**: any unit holding a position (overwatch posts, the defender's
  choke or thief gate, cooldown ducks) sweeps the aim back and forth across
  `±ScanArc` brads around the watch heading with real rotate-button sweeps
  (`scanAim`), raking the 90°-wide cone over the arc while standing
  perfectly still — movement no longer leaks (or aims) our vision.
- **On the move**: when no target demands the turret, the aim leads the
  movement direction (`CruiseDeadband` hysteresis), so attackers watch
  down-lane while crossing and the cone points where trouble will appear.
- **Friendly fire guard**: the bullet corridor kills the **nearest** player
  inside it, friend or foe. `friendlyBlocked` checks remembered mates closer
  than the target against the corridor (`CorridorHalfWidth`, inflated with
  sighting age) around the exact angle the turret would fire. Mate-blocked
  targets are **skipped at selection**, so the bot retargets a clear enemy
  instead of holding fire.
- **Rushing**: the mid trio skips peek/duck while playing for the flag —
  pickup races and carrier chases are lost to positioning detours — and
  shoots on the move instead.
- **Jink**: when a visible enemy inside `ThreatRange` faces us and we have no
  shot lined up (and no duck cell breaks its line), strafe perpendicular.
- **Serpentine**: non-rushing, non-carrying units weave
  (`SerpentineNear`..`SerpentineFar`) while a fresh remembered enemy at mid
  distance has a clear pixel line to us — under map-wide guns a straight run
  across a watched lane is lethal.
- **Duck radius**: cooldown ducking reacts to remembered threats out to
  `DuckRange` (340px), beyond the old close-quarters radius, since threats
  outside the view can kill us the moment their line clears.
- **Spacing**: soft repulsion keeps teammates ~`MateSpacing` (40px) apart so
  one burst (or one of our own shots) cannot hit two of us.

## Tuning

Strategic levers can be overridden at compile time with `-d:NAME=VALUE`;
defaults preserve the current baseline behavior. `AimRate` must match the server's
`aimTurnRate` config (default 5). Role assignment is `roleForSeat`; lane
via-points, `chokeSpot`, and `homeDeepX` encode the map geometry.

| Name | Type | Default | What it does | Sane experimental range |
| --- | --- | ---: | --- | --- |
| `tuneRushEngageRange` | int | 230 | Rusher engagement distance | 150–350 |
| `tunePocketRushRange` | int | 210 | Distance from enemy pedestal to prioritize pickup | 150–300 |
| `tuneWeaveBand` | int | 280 | Midline x-band where rushers weave | 150–450 |
| `tuneWeaveGain` | int percent | 60 | Side-steer strength during weaving | 20–100 |
| `tuneCarrierFireRange` | int | 110 | Carrier engagement distance | 50–180 |
| `tuneEscortEngageRange` | int | 320 | Engagement distance while escorting | 200–500 |
| `tuneThiefFixTtl` | int ticks | 40 | Lifetime of a thief position fix | 20–80 |
| `tuneThiefLeadTicks` | int ticks | 18 | Prediction lead for thief interception | 0–36 |
| `tuneThiefFocusBonus` | int px | 400 | Target-priority bonus for the enemy flag thief | 0–800 |
| `tuneFlankDepth` | int px | 260 | How far flankers cross past mid | 150–400 |
| `tuneLatePushTick` | int ticks | 3400 | Tick after which defensive roles all-in for capture | 2500–4500 |
| `tuneCarrierLaneBiasDiv` | int px | 500 | Divisor for nearest-lane stickiness | 250–1000 |
| `tuneCarrierLaneThreatY` | int px | 120 | Enemy lane-threat y-window | 60–220 |
| `tuneExtraDefenders` | int seats | 0 | Promote seats 6, then 0, then 1 to HomeDefender | 0–3 |
| `stolenOverwatchGuards` | bool define | off | Make Overwatch guard stale own-flag steals | on/off |

## Build & run

```bash
# From the repo root:
nim c -d:release --opt:speed --out:players/baseline/baseline.out players/baseline/baseline.nim
COWORLD_PLAYER_WS_URL="ws://localhost:8080/player?slot=0&token=0xBADA55_0" \
  ./players/baseline/baseline.out
```

Container build uses `players/baseline/Dockerfile` (produces `/bin/baseline`):

```bash
docker build --platform=linux/amd64 \
  -f players/baseline/Dockerfile -t coworld-ctf-baseline:local .
```

`--platform=linux/amd64` is required, not advisory — the platform rejects any
other architecture, and the build is arch-native otherwise, so an Apple Silicon
machine silently produces an arm64 image without it.

Both stages sit on nix-built bases this repo defines (`caos/nim`,
`caos/player-runtime`) and CI publishes to GHCR. **Building the image does not
need nix** — the bases pull like any other `FROM`. They are tagged by the
nixpkgs pin they were built from, and the Dockerfile names that tag, because
nim bakes absolute `/nix/store` paths into the binary (its RUNPATH, and an
absolute `dlopen` path for libcurl, which the nim `libcurl` package loads at
run time rather than linking). Build base and runtime base must share one pin.
Getting it wrong fails at startup with `could not load: libcurl.so(|.4)`,
before the websocket — never silently.

`caos-cli run-tool build-player` compiles on `caos/nim` too, so its binary is
linked exactly like this one and can be dropped into the runtime stage as-is.
This Dockerfile does not do that — it is the standalone path and compiles from
source, with no ccache (a build stage is discarded, so a cache there would be
cold every time while looking like a cached build).

## Artifact telemetry (always on)

`baseline/artlog.nim` records structured decision telemetry every episode
and uploads it as the platform's per-seat **player artifact** (one zip per
slot per episode, PUT to the presigned `COWORLD_PLAYER_ARTIFACT_UPLOAD_URL`
the runner injects; `file://` URLs on local runs; silently skipped when the
variable is absent; a failed upload never fails the episode). It exists so
post-hoc analysis over large episode sets — "what was seat 3 doing between
the steal and the death" — reads a few JSON files instead of re-simulating
replays.

Zip contents:

- `meta.json` — slot, team, role, active compile defines, sample cadence.
- `events.jsonl` — tick-stamped edges: `steal`/`carry_end`,
  `mate_carry`/`mate_carry_end`, `death`/`respawn`,
  `own_flag_stolen`/`own_flag_returned`, `thief_fix`,
  `pickup_shield`/`shield_lost`, `pickup_spraypaint`/`spraypaint_spent`,
  `pickup_nade`/`nade_thrown`, `damage`/`heal`, `shot` (with aim + engage
  range), `objective` (movement-branch switches), `push_out`, `stuck_jink`,
  `nade_flee`, `shout_tx`, `game_start`/`game_end`.
- `ticks.jsonl` — a state row every 12 ticks (~0.5 s): position, hp, aim,
  objective + action branch, movement target, visible enemies, engage
  distance, input mask, and status flags (carry/shield/spraypaint/nade/pushOut).
- `summary.json` — event counters plus per-objective and per-action tick
  histograms; the first internal telemetry error, if any, is recorded here
  (telemetry disables itself rather than ever touching gameplay).

The `objective` tag names the movement-target branch in `decide` (`carry`,
`thief_hunt`, `thief_guard`, `escort`, `defend`, `overwatch`, `attack`,
`pocket_rush`, `shield_trip`, `spraypaint_grab`, `heal_detour`, `nade_grab`);
the `action` tag names the turret/act branch (`nade`, `spraypaint`, `fire`,
`duck`, `peek`, `evade`, `scan`, `navigate`, `nade_flee`).

Fetching after a league/xreq episode:

```bash
uv run coworld episode-logs <ereq_id> --agent <slot> --artifact --download-dir logs/
```

Local runs: set `CTF_ARTLOG_PATH=/tmp/artifact.zip` to write the bundle to
disk without a runner. Test builds can drop the libcurl dependency with
`-d:artlogNoCurl` (file delivery keeps working).
