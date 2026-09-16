*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

Firing is a three-stage act: pull the trigger, wait out a 5-tick (0.21 s)
windup with your aim already locked, then release a hitscan shot along that
locked angle, plus a small random deviation rolled at release. A 12-tick
(0.5 s) cooldown follows every release, and the gun reaches out to 1050 px —
fixed on every map since GameVersion 34, not scaled by arena size. Hit
resolution is **not** free of randomness: every released shot's true
direction is the locked aim angle plus a Gaussian draw, calibrated so a fully
exposed target standing at max range is hit about 80% of the time, not 100%.
Given the direction the shot actually flew, connecting is still deterministic
— it crosses the 8 px-wide bullet corridor with a clear line of sight to the
target's exposed silhouette, or it does not.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Fire windup | 0.21 s | 5 | Trigger pull to release; aim locks at the pull |
| Fire cooldown | 0.5 s | 12 | Starts at release, not at the pull; a pull is refused outright while it runs |
| Cooldown, shield carrier | 1.5 s | 36 | 3× normal, for as long as the shield layer holds — see [[shield]] |
| Gun range | 1050 px | — | Fixed on every map since GameVersion 34 — not scaled by arena size, unlike an earlier model; see [[arena]] |
| Aim jitter (real, hit-resolution) | ~0.6° sigma at 1050 px | — | Gaussian, rolled fresh per shot; ~80% hit chance at max range for a fully exposed target, ~99% at half range, ~100% inside a third — see Rules |
| Bullet corridor half-width | 8 px | — | The shot is a ray with width, not a zero-width line |
| Silhouette sample span | ±6 px | — | 5 samples, 3 px apart, across the target's 12 px-wide body |
| Damage per hit | 1 hp | — | Of 3 hp per life in the classic ruleset; 4 in the live `battle-royale-s2` ladder — see [[damage-and-health]] |
| Aim turn rate | 5 brads/tick | — | ≈7°/tick; a full turn takes ≈2.1 s |
| Full turn | 256 brads | — | 0 = east (+x), increasing counter-clockwise; Red spawns aimed at 0, Blue at 128 (west) |
| Render-angle fuzz | ±20° | — | Cosmetic only, re-rolled every 12 ticks (0.5 s), since GV24 — see [[perception]] |

## Rules

### Aim: a continuous angle, not a target

Every cog has a continuous aim angle in **brads** (256 units per full turn,
0 = east, increasing counter-clockwise), rotated by holding **B**
(counter-clockwise) or **Select** (clockwise) — two of the eight
[[action-mask]] bits — at 5 brads/tick. Holding both cancels
to no turn at all, the same cancellation the d-pad applies to opposing
directions. On spawn and every respawn your aim already points toward the
enemy side, so the first frame of a life is already looking down the lane.
Aim is fully decoupled from the d-pad: see [[movement]] for the locomotion
side of that split.

### Aim is not observable

**Nothing on the wire ever reports an exact aim angle** — not your own, not a
teammate's, not an enemy's. A policy knows its own aim only by tracking the
turn commands it has issued itself; there is no absolute readback. Since
GV24, every rendered gun in a player's own view — enemies, teammates,
corpses, and your own self marker alike — is drawn at the true aim plus a
deterministic pseudo-random offset of up to ±20°, re-rolled roughly twice a
second. This fuzz is purely cosmetic: it changes what an onlooker's screen
shows, never the locked angle actually used to resolve a shot. Full mechanic,
including the retired floating aim indicator, on [[perception]].

### The pull locks the shot

**This locked-aim model belongs to the gun only.** Fire (**A**, bit 32) is
edge-triggered: a shot arms only on the tick the button transitions from
released to held, and holding it down does nothing further. If the cooldown
has finished and no windup is already pending, the pull captures your
**current aim angle** and starts a 5-tick countdown. **Movement is completely
unrestricted during the windup** — you move at full speed while a shot is
queued, and the eventual bullet's position comes from wherever you end up. A
second pull during the windup, or any pull while the cooldown is still
running, is ignored outright rather than queued or buffered. **Carrying a
[[spray-can]] replaces this entire model with a live one**: the same A press
ignites the cone, but nothing about your aim is captured or frozen at that
moment — the cone re-samples your current aim on every tick of its active
window instead. See [[spray-can]] for that weapon's own timing.

### Release: hitscan from wherever you ended up

At the end of the windup the bullet resolves **instantly** along the
**locked** angle, from your **position at release** — not at the pull — so
strafing during the windup carries the shot's origin with you while its
direction stays exactly where you were looking when you pulled the trigger.
Every player's movement for the tick is applied first; every shot releasing
that same tick then resolves together against that one post-movement
snapshot, so no player's shot gets an input-processing-order advantage over
another's — a mutual quick-draw tags out both shooters at once. The cooldown
starts counting from this release, not from the original pull, so the
windup never eats into your sustained rate of fire.

### Hit resolution: a real aim roll, then a deterministic corridor test

**Whether a shot connects has a genuine accuracy roll in it, calibrated to
the gun's range.** At release, the locked aim angle is rotated by a Gaussian
draw before anything else happens: sigma is set so a fully exposed target
standing at the gun's full 1050 px range is hit about 80% of the time, tighter
the closer the target stands (roughly 99% at half range, roughly 100% inside
a third) — this is on the deterministic sim RNG, so a replay re-rolls it
identically every time. Given that rolled direction, the rest of the test is
deterministic: a shot is a ray cast from the shooter's position along the
rolled direction, and for every other living player the engine samples 5
points across that player's silhouette (perpendicular to the ray, at −6, −3,
0, +3, +6 px from their center), counting a sample as a hit only when
**both** conditions hold: the sample falls inside the shooter's 8 px-wide
bullet corridor, **and** the shooter has a clear, unobstructed line of sight
to that exact point. The closest player with any qualifying sample along the
ray is the target; a wall stops the ray outright before it reaches anyone
behind it. This makes cover **partial, not binary** — a shoulder poking past
a corner is exactly as hittable as the silhouette samples that clear the
wall, no more and no less, while a fully-hidden body cannot be tagged through
it. **Friendly fire is on**: the first valid body on the ray is hit
regardless of team, corpses are never candidates, and the shooter cannot hit
itself.

**The rolled direction is also what the tracer and any paint stain follow** —
onlookers see the shot's real, jittered path, not the pre-roll locked angle.
**The cosmetic render fuzz is a separate thing.** The ±20° fuzz described
above (re-rolled every 12 ticks) only changes what a *different-tick, idle*
gun looks like it's pointing at in someone else's view; it never touches
this per-shot aim roll or the tracer.

**Two further RNG sources exist in the same resolution path, both
config-gated and not confirmed armed on any currently scheduled ruleset**: an
occupant of a map's "trench" (a walkable dug pit, config field `trenches`)
ducks 70% of gun shots fired from outside their own trench, and a
per-team handicap (config field `handicaps`, 0 by default) can make a
fraction of that team's otherwise-connecting shots fly wide outright. Both
are read only when a map/league config arms them; neither is mentioned
anywhere else in this corpus, and this page does not claim either is live
today.

### Rank interaction

The per-life rank ladder shortens this model twice and speeds it up once,
while retiring one buff outright — see [[ranks]] for the full ladder:

- **Windup** drops by 1 tick (5→4) from rank 1 ("tagger"), and by a further
  tick (→3) at rank 5 ("legend").
- **Cooldown** drops 25% (12→9 ticks) from rank 4 ("quickdraw").
- **Gun range is not extended by rank.** An earlier +15% step at rank 2 was
  retired in Glory 6 to a flat 100% at every rank, reasoned against the
  1300 px gun range and ~1400 px arena diagonal live at the time: a buffed
  1495 px would have exceeded the whole diagonal, so it could never have
  gated a single shot at any rank, on any map. Gun range has since dropped to
  1050 px (GameVersion 34); at today's base, +15% (1207.5 px) would fit
  inside the same ~1400 px diagonal, but the multiplier table stays
  flattened to 100% regardless, so no rank gets a range buff today either —
  the original reasoning is stale, the outcome is not. The range calculation
  itself still runs on every shot, at every rank — only the per-rank
  multiplier table was flattened to neutral, not the code that reads it. See
  [[ranks]] for the code-versus-data distinction — and contrast the
  grenade-charges value on that same rank table, which as of GLORYVERSION 16
  is genuinely wired (a rank-4+ pickup now yields two throws), the opposite
  of gun range's permanent no-op. See [[paint-bomb]].

### Shield interaction

A carried [[shield]] triples the fire cooldown (12→36 ticks) for as long as
its 3 hp armor layer holds. The instant that layer is fully absorbed, the
shield breaks outright and the very next cooldown re-clamps to the normal
12 ticks — see [[damage-and-health]].

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `weapon gun` | Own weapon readout while the gun is the active weapon | Player view |
| `fire icon` | Trigger ready — gate a fire input on this, not a timer | Player view |
| `fire icon cooldown` | Gun recovering; the dimmed twin of the row above | Player view |
| `shot impact` | The only trace a shot leaves in a player's own view — a jittered ring near the landing, sound only | Player view |

**Carrying a [[spray-can]] disables the gun outright**, not just the label:
`weapon gun` becomes `weapon spray`, and firing is refused for as long as the
can is held — `fire icon` never appears, because the gun and the spray cone
are mutually exclusive weapons, not two labels racing for the same trigger.
See [[spray-can]] for what A does instead. Full label contract, including the
broadcast-only rig art (`cog gun <color>`), on [[perception]] and
[[action-mask]].

## Version history

| Version | Change |
| --- | --- |
| GV63 / GLORYVERSION 18 (2026-09-11, wiki) | Re-traced against current source. Corrected two stale claims: gun range is 1050 px, not 1300 px, and has been fixed (not map-scaled) since GameVersion 34; and hit resolution is **not** RNG-free — the same GameVersion introduced a real Gaussian aim roll on every released shot (~80% hit chance on a fully exposed target at max range), separate from the cosmetic GV24 render fuzz this page already documented. Also corrected the grenade-charges cross-reference, which as of GLORYVERSION 16 is wired, not dead — see [[paint-bomb]]. |
| GV34 | The gun's default range dropped from 1300 px to 1050 px and was fixed at that figure on every map (no longer scaled by arena size). The same version introduced a per-shot Gaussian aim roll calibrated against the live gun range, so hit resolution stopped being RNG-free. |
| Wiki | Reworded the retired rank-2 gun-range buff from "rung" to "step", matching [[ranks]]'s corpus-wide rename of the same word. |
| Wiki | Clarified the locked-aim model above is gun-only; the spray cone samples aim live every tick instead of locking it — see [[spray-can]]. |
| Glory 6 | The rank-2 +15% gun-range buff retired by flattening its per-rank multiplier table to 100%; the range calculation that reads that table remains live code, run on every shot. Previously misdocumented on [[ranks]] as dead code. |
| GV24 | Rendered gun angle in player views fuzzed ±~20°, re-rolled ~2×/s; cosmetic only — see [[perception]]. (Distinct from GV34's real per-shot aim roll, above.) |

## Gaps

- The browser client's key binding for the A (fire) button — the browser
  keys for B, Select, and C are documented, but A's is not recorded
  anywhere this page could confirm.

## See also

- [[action-mask]] — the full 8-bit input mask, A and the rotation bits included
- [[perception]] — the render-angle fuzz and the full label contract
- [[movement]] — locomotion, fully decoupled from aim
- [[arena]] — the map this model fires across, and the cover it fires through
- [[damage-and-health]] — hit points, damage, and the hitscan link
- [[ranks]] — the rank ladder that reshapes windup, cooldown, and range
- [[shield]], [[spray-can]] — the two items that change what A does
- [[conventions]] — the mechanic-and-chrome layering rule

## Discussion

Peek timing, when to trade a shot versus duck, and any accuracy or
time-to-kill numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
