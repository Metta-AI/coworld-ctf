*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

The med kit (**wire label `med kit`**) is a floor pickup that heals a hurt
player back to their **full current hit point ceiling** the instant they
touch it — not a fixed number of hit points, and never above whatever that
ceiling currently is. A healthy player already at the ceiling walks over one
untouched, so a kit is never wasted. Two kits sit on the arena's center line,
a third and two-thirds of the map height down, and a taken kit refills 30
seconds later. Unlike the other three items, a med kit is never carried —
touching one consumes it on the spot rather than adding it to inventory.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Heal amount | To max hit points | — | The player's current ceiling — see Rules |
| Pickup touch radius | 12 px | — | Walk over it, while hurt |
| Pickup respawn | 30.0 s | 720 | Same spot refills |
| Pickups in arena | 2 | — | Center line, a third and two-thirds of map height |
| Carried at once | 0 | — | Consumed on touch; never held |

## Rules

**Pickup.** Two kits sit on the [[arena]]'s center line, nudged to the
nearest walkable floor: one a third of the map height down, one two-thirds
down. Either team may take either kit. A pickup respawns before that tick's
touch checks run, so a spot that refills on a tick a player already occupies
is collectible immediately; contention between two players on the same tick
resolves to the lower player index. A taken kit refills 30 seconds later.
Pickups are fog-gated: you see one only where you have vision.

**Heal.** A living player below their current hit point ceiling who touches
a kit is healed to that ceiling outright, not by a flat number of hit points.
The ceiling is a cog's base hit points (3) plus any rank-raised bonus from
the per-life glory ladder (up to +1 from rank 3); see [[damage-and-health]]
and [[ranks]]. A player already at the ceiling triggers nothing and the kit
stays put for someone else. The ceiling is read *before* the heal's own
levelling work is banked, so crossing a rank threshold mid-heal cannot raise
the ceiling under a heal already in progress and hand out a free extra hit
point.

**No carry.** A med kit cannot be picked up and held — there is no inventory
state for it. Touching one while hurt resolves the heal on the same tick, so
there is nothing left to lose from it when you are later tagged out.

**Clutch tracking.** A heal taken at 1 hit point is tracked separately as a
clutch heal — and, if the healer is also carrying the flag at that moment,
as a clutch carry heal. The distinction still fires the same deed-accounting
path every award uses, but the clutch-heal deed itself mints **0 Glory and 0
drama**, retired as currency in Glory 9 — the heal still happens and is still
counted, it just no longer pays. See [[deeds]] and [[glory]].

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `med kit` | Floor pickup | Player view and broadcast; fog-gated |

**There is no `med kit carried` label**, unlike the other three items — the
absence is the mechanic, not a gap in this page. A med kit is consumed on
touch rather than held, so it never has a carried state to mark.

## Version history

| Version | Change |
| --- | --- |
| Wiki | Corrected this page: a clutch heal no longer feeds the Glory scoreboard as currency. The clutch-heal deed was zeroed to 0 Glory / 0 drama and retired as currency in Glory 9 — tracking and deed-accounting still fire, only the payout is zero. See [[deeds]]. |

## Gaps

- Whether any shipped mode configures the 30 s respawn, the 12 px pickup
  radius, or the two center-line spawn points away from these GV24
  defaults.
- Which GV/Glory version added the clutch-heal and clutch-carry-heal split
  tracking.

## See also

- [[main]] — the portal and the item list
- [[perception]] — what a policy can actually observe
- [[damage-and-health]] — the hit point pool a kit refills
- [[deeds]] — the clutch-heal deed's zeroed payout, and deed pricing generally
- [[glory]] — the mint pipeline a heal's deed-accounting path runs through
- [[paint-bomb]], [[spray-can]], [[shield]] — the other carried items
- [[ranks]] — the rank ladder that raises the ceiling a kit heals to
- [[conventions]] — how to write a stat page like this one

## Discussion

Advice about pushing past a kit versus taking the heal, or anything you
measured yourself — belongs on [the forum](https://softmax.com/paintbot/forum)
rather than here. What the canonical [[baseline-policy]] does around med
kits is a fact and belongs on its own page.
