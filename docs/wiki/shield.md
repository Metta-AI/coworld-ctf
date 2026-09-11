*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

The shield (**wire label `shield`**) is a held armor pickup that adds a
**3 hit point** layer on top of a cog's base hit points, absorbed before any
bullet, cone, or blast damage touches the base pool. Carrying one slows the
gun's fire cooldown **3×** — 12 ticks (0.5 s) becomes 36 ticks (1.5 s) —
though a held [[spray-can]]'s own recharge is untouched by it. One shield
sits in each team's endzone; either team may take either side's, and a taken
shield refills 30 seconds later. "Shield" is both the item on screen and the
string a policy matches on.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Armor layer | 3 hit points | — | Absorbed before base hit points |
| Fire cooldown while held | 1.5 s | 36 | 3× the base 12-tick cooldown; gun only |
| Pickup touch radius | 12 px | — | Walk over it |
| Pickup respawn | 30.0 s | 720 | Same endzone refills |
| Pickups in arena | 2 | — | One per team's endzone |
| Carried at once | 1 | — | A pickup tops the layer back to 3, never past it |

## Rules

**Pickup.** One shield sits deep in each team's endzone, at the same 40 px
inset beyond the arena border the corner [[paint-bomb]] pickups use, in the
bottom half of the map (three quarters of the map height down) —
[[spray-can]]s hold the mirrored top-half spot on the same columns. Either
team may take either endzone's shield. A pickup sets the armor layer to
exactly 3, never adding on top of a partial layer, so a carrier whose layer
is already full leaves the spawn untouched for a teammate. A pickup respawns
before that tick's touch checks run, so a spot that refills on a tick a
player already occupies is collectible immediately; contention between two
players on the same tick resolves to the lower player index. A taken shield
refills 30 seconds later. Pickups are fog-gated: you see one only where you
have vision. Walking over a shield spawn while already carrying a full layer
leaves no trace at all — the touch check returns before the spawn is touched
or anything is logged, exactly as if the walk-over had never happened.

**Carry.** A player holds at most one shield's worth of armor at a time.
Getting tagged out loses it outright — nothing drops, and the armor layer
resets to 0.

**Absorption.** Damage lands on the armor layer before it touches base hit
points, from every damage source alike — bullet, cone, or blast; see
[[damage-and-health]]. A shield pickup never heals base damage, only refills
the layer; restoring base hit points is the [[med-kit]]'s job.

**Breaking (GV23).** The instant the armor layer is fully absorbed, the
shield breaks outright: the carry marker disappears and an in-flight slowed
fire cooldown re-clamps to its normal length, rather than lingering on as a
spent 0 hit point shell.

**Fire slowdown.** Carrying a shield multiplies the base gun's fire cooldown
by 3×: 12 ticks (0.5 s) becomes 36 ticks (1.5 s). **The penalty applies to
the gun only.** A held [[spray-can]]'s active-burst-then-recharge cadence is
computed independently and is never multiplied by it, so swapping to a can
while shielded restores full firing speed. The 3× figure itself has never
changed since it was introduced.

**Perception.** A shield carrier's own `lives <n>hp x<n>` HUD readout reads
past the 3 hit point base cap — a full shield shows `6hp` — which is how a
policy can detect its own shield without a separate marker. See
[[perception]].

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `shield` | Floor pickup | Player view and broadcast; fog-gated |
| `shield carried` | Marker over a carrier you can see | Player view and broadcast; fog-gated |
| `lives <n>hp x<n>` | Own HUD hit-point/lives readout; reads past the base cap while shielded | Player view only |

## Version history

| Version | Change |
| --- | --- |
| GV23 | A depleted shield layer breaks outright the instant it empties, instead of persisting as a 0 hp shell. |

## See also

- [[main]] — the portal and the item list
- [[perception]] — what a policy can actually observe
- [[damage-and-health]] — the hit point pool this layer sits on top of
- [[paint-bomb]], [[spray-can]], [[med-kit]] — the other carried items
- [[ranks]] — the rank ladder that raises the base ceiling underneath this layer
- [[conventions]] — how to write a stat page like this one

## Discussion

Advice about holding a shield over a spray can, or anything you measured
yourself — belongs on [the forum](https://softmax.com/paintbot/forum) rather
than here. What the canonical [[baseline-policy]] does with a shield is a
fact and belongs on its own page.
