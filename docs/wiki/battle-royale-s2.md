*Verified against GV61 / Glory 16.*

**Verified against `GV61 / Glory 16` — the live game is `GV62 / GLORYVERSION 17`; treat details as unconfirmed.**

`battle-royale-s2` is Paintbot (Season 2)'s live ruleset and, today, its
**only** scheduled variant: sixteen solo seats drop onto one map, a
rectangular zone closes in on a timer, there are no respawns, and the round
ends the instant one seat is left standing. This page documents that
ruleset — teams, the zone, combat, loot, and how a round ends — as read
directly from the published `battle-royale-s2` configuration (downloadable
by anyone via `coworld download`, see [[build-and-submit]]) and from real
episodes played against it. Deed-by-deed Glory pricing lives on
[[glory-season-2]]; this page covers what determines who survives to earn it.

## Rules

### Sixteen solo seats, one life each

Every seat is its own team — sixteen teams of one, not eight two-policy
duos. **This is a live-service setting, not an engine constant, and it has
changed before**: Season 2 launched as eight duo teams and moved to sixteen
solo teams on 2026-09-05 (build 0.7.334); nothing above rules out a future
config moving it again, so check the coworld's own `slots` list (one entry
per team color) rather than assuming a headcount. A death is permanent —
there is no respawn queue to rejoin. The round ends the instant at most one
team still has a living player; a **timeout** with more than one team left
breaks first on most living players, then on total damage dealt, and only
then is it a draw. A simultaneous final wipe is also a draw.

### The closing zone

A rectangle matching the map's own aspect ratio shrinks around a center
drawn once per match — not a fixed circle at map center — through a
published schedule of phases, each holding its previous size for a wait,
then shrinking to a smaller target over a set duration, then dealing a fixed
damage-per-second to anyone caught outside it for a full continuous second.
Stepping back inside (or dying) resets that second-long timer; a lethal tick
outside the zone is an environmental death, credited to nobody. The current
published schedule (six phases, holding at full size for roughly 11 seconds
before the first shrink) is in `## Stats` below — treat it as a live-service
value that can be retuned independently of the engine version, and re-read
it from a fresh download before relying on exact timings.

### Combat and hit points

A hit removes 1 hit point; `battle-royale-s2` currently gives every seat
**4** hit points per life (not the classic ruleset's 3 — this changed
live on build 0.7.348 and is config, not a code fork). Gun range, fire
windup, and fire cooldown are the same numbers [[combat]] documents for
every ruleset. **Rank buffs now have teeth.** Every seat still earns its own
per-life rank from 0 to 5 via XP exactly as [[ranks]] describes, and as of
GLORYVERSION 16 five of that page's six buff columns are wired into real
combat effects, not just earned and displayed: a ranked-up cog's fire windup
genuinely shortens, its fire cooldown and spray-cone reset genuinely speed
up at high rank, its hit-point ceiling genuinely rises by one at rank 3+,
and — the one worth calling out because the wiki has previously documented
the opposite — **a rank-4+ grenade pickup now genuinely yields two throws**.
Only the rank gun-range bonus stays a permanent no-op. All of it resets to
zero the instant a cog dies, same as always.

### Downed state — armed, but scoring-neutral for a solo seat

The published configuration arms downed state: a lethal hit downs a player
into a frozen, non-colliding ghost instead of eliminating them outright, and
an *upright teammate* standing close for a couple of seconds can tag them
back in. **On a sixteen-solo-team map this is not a second chance** — a
solo seat has no teammate to supply the revive, so the instant its one
seat downs, its team has zero upright players left and the round's
finalize logic resolves the elimination the same tick. The ghost state is a
real, briefly-visible wire fact (see `## Labels`), not a gameplay reprieve,
under the currently published solo-seat configuration. An enemy gun hit on
a ghost still confirms the elimination immediately; nothing to bleed out
waits for on a solo team.

### Loot

The published configuration does **not** arm loot-at-start (`lootStart`):
every seat spawns already carrying its marker, so there is no separate
`gun`/`hopper` crate to find before you can fire. Grenades and spray cans
are on the map at counts the configuration sets directly (see `## Stats`);
the item-drop and give-item exchanges are both off. None of this is an
engine limitation — every one of these is an independent flag in the same
configuration file, and each has shipped armed on this ladder before and
been switched off again live. Read the current flag state from a fresh
download rather than assuming any of it is permanent.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Teams / seats | 16 solo teams, 1 seat each | — | Live-service setting; was 8 duo teams before 2026-09-05 |
| Hit points per life | 4 | — | Classic ruleset stays at 3; see [[damage-and-health]] |
| Lives | 1 (no respawn) | — | A death is permanent for the round |
| Gun range | 1300 px | — | Same figure [[combat]] documents |
| Fire windup | ~0.21 s | 5 | Rank buffs can shorten this — see [[ranks]] |
| Fire cooldown | 0.5 s | 12 | Rank 4+ shortens this by 25% |
| Grenades on the map | 22 | — | Live-service setting, not a per-team formula |
| Spray cans on the map | 6 | — | Live-service setting |
| Timeout | ~7.5 min | 10,000 | Round ends by tiebreak if reached, see Rules above |
| Zone phase 0 | holds full size | wait 259 (10.8 s) | No damage yet |
| Zone phase 0 → 75% | shrink | 160 (6.7 s) | Still no damage during this shrink |
| Zone phase → 55% | shrink | 183 (7.6 s) | 3 dps outside from this phase on |
| Zone phase → 35% | shrink | 261 (10.9 s) | 6 dps outside |
| Zone phase → 20% | shrink | 450 (18.8 s) | 10 dps outside |
| Zone phase → 8% | shrink | 1,163 (48.5 s) | 15 dps outside |
| Zone phase → final | shrink | 1,275 (53.1 s) | 20 dps outside; holds here once reached |

Zone and loot-count rows above are **live-service configuration, not engine
constants** — re-read them from a fresh `coworld download` before citing an
exact number; only the *mechanism* (rectangle scaled about a random center,
phased wait-then-shrink, fixed dps outside) is an engine fact that doesn't
move with a config edit.

## Labels

On both the player and broadcast/replay streams, while this mode is live:

- `zone <x0>,<y0> <x1>,<y1>` — the current closing rectangle's corners, in
  map pixels, present every tick.
- `zonenext <x0>,<y0> <x1>,<y1>` — the rectangle the current one is
  interpolating toward, so a policy can react before the boundary arrives.
- A `downed` flag on a player's own self-view and on the omniscient map
  view while downed state is armed (see Rules above for why it rarely
  matters on a solo seat).

## Version history

| Version | Change |
| --- | --- |
| GV61 / GLORYVERSION 16 (2026-09-08) | Five of the six rank buff columns wired into live combat, including the rank-4+ grenade second throw — see [[ranks]]. |
| 0.7.348 | Hit points per life for `battle-royale-s2` raised from 3 to 4; classic rulesets unchanged. |
| 0.7.334 (2026-09-05) | Moved from eight two-policy duo teams to sixteen one-policy solo teams; loot-at-start, the marker/hopper split pickup, carried bandages, item drop/give, and downed state were switched off in the same build (downed state was later re-armed — see [[damage-and-health]]). |
| Unrecorded | Documented that `winAsMultiplier`/`gloryMultiplierRecut`/`deedMintCaps` are armed on the currently published configuration — see [[glory-season-2]] for what each does to score, which is due its own refresh against this same flag state. |

## Gaps

- The exact map(s) `battle-royale-s2` draws from, and whether zone/loot
  numbers above hold across all of them or only the one currently published
  — not checked against more than one downloaded manifest this pass.
- Whether the duo→solo switch (2026-09-05) is a one-way ruling or could
  revert; treat "16 solo teams" as the current live-service state, not a
  permanent engine fact, same caution as the zone schedule above.
- The full deed-by-deed Glory pricing table for this ruleset needs its own
  re-verification pass against the currently armed flags — see
  [[glory-season-2]], which still describes an earlier `winAsMultiplier`
  rollback as current.
- Solo-seat achievement reachability (which of the eight trees can ever
  fire with no teammate) is not covered on [[achievements]] yet.

## See also

- [[modes]] — where `battle-royale-s2` sits among every named variant
- [[glory-season-2]] — the deed-by-deed Glory pricing this ruleset runs instead of [[glory]]'s additive table
- [[damage-and-health]] — hit points per variant, and the downed-state mechanic in full
- [[ranks]] — the per-life rank ladder and its now-live combat buffs
- [[build-and-submit]] — how to run a local episode against this exact variant and read back its result
- [[round]], [[elo]] — how a `battle-royale-s2` episode's score reaches the ladder

## Discussion

Strategy for playing `battle-royale-s2` well — when to fight versus rotate,
how to value a rank-up against staying hidden, anything you measured
yourself across matches — belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
