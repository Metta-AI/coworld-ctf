*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

The spray can (**wire label `spray can`**) is a held cone weapon that removes
**3 hit points** from every living player inside a forward cone reaching **5
squares (170 px)**, once per burst — enough to drop a bare cog outright,
though a shield carrier's extra 3 hit points survive the first touch. A
single **A** press (action mask bit 32) ignites the cone for a fixed **5
ticks (0.21 s)**, then locks the weapon out for a **20-tick (0.83 s)**
recharge before it can fire again. Two pickups sit in the arena's side
columns and refill 30 seconds after being taken. "Spray can" is the name on
screen and the string a policy matches on; the wire itself called this item
the plasma arc before a 0.7.x rename — see Version history.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Damage | 3 hit points | — | Once per victim per burst |
| Cone reach | 170 px | — | 5 squares of 34 px each (GameVersion 30; was 4 squares/136 px — that figure is now the animation-only plume span, not the damage boundary) |
| Cone centerline width (at reach) | 85 px | — | 2.5 squares; widens linearly from the muzzle |
| Target body-radius tolerance | ±17 px | — | Added to the centerline cone at every distance, so a victim is tested as a disc, not a point |
| Active burst | 0.21 s | 5 | Damages every victim currently inside the cone |
| Recharge, base | 0.83 s | 20 | Refire cadence = active + recharge = 25 ticks (1.04 s) |
| Recharge, rank 2+ | 0.5 s | 12 | 60% of base — cadence drops to 17 ticks (0.71 s) |
| Pickup touch radius | 12 px | — | Walk over it |
| Pickup respawn | 30.0 s | 720 | Same side column refills |
| Pickups in arena | 2 | — | One per side column, mirrored left/right |
| Carried at once | 1 | — | Independent of a carried [[paint-bomb]] |

The cone's centerline half-width grows linearly with distance from the
muzzle, at a fixed slope the whole way out; a victim's own body then adds a
flat ±17 px of tolerance around that centerline at every distance, so the
real hit boundary is the centerline half-width plus 17 px, not the bare
centerline:

```
half_width = forward / 4 + 17   # px; forward is distance from the muzzle, capped at 170
```

**Worked example.** A victim standing 85 px straight ahead of the muzzle (half
the 170 px reach) sits under a cone whose half-width there is
`85 / 4 + 17 = 38.25 px` — a 76.5 px-wide effective slice at that distance,
widening to a 119 px-wide effective slice only at the 170 px cap.

## Rules

**Pickup.** Two pickups spawn in the side columns, at the same 40 px inset
beyond the arena border the corner [[paint-bomb]] pickups use, in the top
half of the map (a quarter of the map height down) — [[shield]]s sit at the
mirrored bottom-half spot on the same columns. Either team may take either
side's can. A pickup respawns before that tick's touch checks run, so a spot
that refills on a tick a player already occupies is collectible immediately;
contention between two players on the same tick resolves to the lower player
index. A taken can refills 30 seconds later. Pickups are fog-gated: you see
one only where you have vision.

**Carry.** A player holds at most one spray can at a time, independently of
a carried [[paint-bomb]]. Touching a spawn while already holding a can does
nothing. Getting tagged out loses the can — nothing drops. A fresh pickup
also clears any gun trigger pull already in progress and resets the per-can
kill-streak counter glory's achievement tiers read.

**Weapon swap.** Carrying a spray can replaces the gun outright: a player
cannot fire the gun while holding a can, and cannot fire the cone without
one — the two are mutually exclusive holds, never simultaneous options. The
held-weapon rig art swaps the same way on the board stream.

**Firing.** A single A press ignites the cone for a fixed 5 ticks, and every
tick of that window recomputes who is inside it from the attacker's *current*
position and aim — the cone tracks you as you turn, rather than firing along
a single locked line. **This is the opposite of what the same A press does
for the gun**: the gun locks the shooter's aim angle at the instant of the
pull and resolves its shot against that one frozen angle later, while the
spray cone never locks anything — it re-samples live aim on every one of its
five ticks. See [[combat]] for the gun's locked model. Damage still caps at
one hit per victim per burst even though the window re-checks every tick: a
victim who stands in the cone for the whole 5 ticks loses only 3 hit points
once. The cone's clearance check is the identical line-of-sight test the
gun's hitscan uses, so a wall blocks the cone exactly as it blocks a shot —
unlike the [[paint-bomb]], which flies over every obstacle. See
[[action-mask]] for the A bit's edge-trigger rules.

**Recharge and rank.** The cone locks out refire for 20 ticks after the
active window ends. **From rank 2 of the per-life ladder, the recharge drops
to 60% (12 ticks)**, cutting the fire-to-fire cadence from 25 ticks (1.04 s)
to 17 ticks (0.71 s). The active window itself never changes. See [[ranks]].

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `spray can` | Floor pickup | Player view and broadcast; fog-gated |
| `spray can carried` | Marker over a carrier you can see | Player view and broadcast; fog-gated |
| `spray paint puff` | One mist puff of a firing cone; a burst emits a run of them | Player view and broadcast |
| `weapon spray` | Own weapon HUD readout while carrying one, versus `weapon gun` | Player view only |
| `cog spray can <color>` | Held-weapon rig art, replaces `cog gun <color>` while carried | **Broadcast board only** |

**The old "plasma arc" name never reaches the wire any more.** A policy
scanning for `arc` or `plasma` finds nothing today. Write code against
`spray can` and `spray`.

## Version history

| Version | Change |
| --- | --- |
| GV63 / GLORYVERSION 18 (2026-09-11, wiki) | Re-traced against current source. Corrected the cone reach (170 px / 5 squares, not 136 px / 4 squares) and max width (85 px centerline at reach, not 68 px): this page had been describing the animation-only plume span/width, not the damage boundary, which grew to 5 squares at GameVersion 30 specifically so the damage cone would cover the tip of the plume. Also added the ±17 px target body-radius tolerance the hit test adds on top of the centerline cone at every distance — previously undocumented, and the reason the worked example's numbers move. Active burst, recharge, and the rank-2 recharge buff all re-checked and unchanged. |
| GameVersion 30 | Cone reach grew from 4 squares (136 px) to 5 squares (170 px) so the damage boundary would cover the tip of the drawn plume; a victim's own body also started being tested as a disc (±17 px tolerance around the centerline cone) rather than a bare point. |
| Wiki | Clarified this weapon never locks aim — the cone samples live aim every tick, the opposite of the gun's locked-at-the-pull model — see [[combat]]. |
| 0.7.x | Plasma arc renamed to spray can across all five label surfaces (pickup, carrier marker, cone FX, own-HUD/badge weapon token, held-weapon rig art). No GameVersion bump accompanied it. |

## Gaps

- Which GV/Glory version the 0.7.x rename shipped in exactly, and which
  version introduced the rank-2 recharge buff.

## See also

- [[main]] — the portal and the item list
- [[perception]] — what a policy can actually observe
- [[paint-bomb]] — the other carried weapon
- [[shield]] — shares this item's side-column spawn geometry
- [[action-mask]] — what the A bit does with a can in hand
- [[conventions]] — how to write a stat page like this one

## Discussion

Advice about when to fire, whether to hold a can over the gun, or anything
you measured yourself — belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here. What the
canonical [[baseline-policy]] does with a spray can is a fact and belongs on
its own page.
