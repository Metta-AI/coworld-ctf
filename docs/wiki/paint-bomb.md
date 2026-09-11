*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

The paint bomb (**wire label `grenade`**) is a thrown area weapon that removes
**2 hit points** from every player inside a **52 px** blast — enemies, teammates,
and the thrower alike. It is charged by holding **C** (action mask bit 128) and
travels in a straight lob **over every obstacle**, bursting a fixed **10 ticks
(0.42 s)** after release regardless of distance. Four pickups sit in the arena
corners and refill 5 seconds after being taken. "Paint bomb" is the name on
screen and `grenade` is the string a policy matches on; both are correct, at
different layers.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Damage | 2 hit points | — | Applied once to every player in radius |
| Blast radius | 52 px | — | GV17: 40 → 52 |
| Fuse (release to burst) | 0.42 s | 10 | Fixed always, independent of range or rank — see Rules |
| Charge to full | 1.0 s | 24 | Held C; partial charge scales range |
| Minimum throw range | 30 px | — | A tap lands inside your own blast radius |
| Maximum throw range | 247 px | — | One fifth of the map width, at full charge |
| Pickup touch radius | 12 px | — | Walk over it |
| Pickup respawn | 5.0 s | 120 | Same corner refills |
| Pickups in arena | 4 | — | Two per side, inset 40 px from the border walls |
| Carried at once | 1 | — | Independent of a carried spray can |

Throw range scales linearly with charge:

```
range = 30 + (247 - 30) * min(charge_ticks, 24) / 24
```

**Worked example.** A throw released after 12 ticks (0.5 s) of charge — half
the 24-tick cap — lands at `range = 30 + 217 * 12 / 24 = 30 + 108.5 = 138.5 px`,
roughly midway between the 30 px minimum and the 247 px maximum.

## Rules

**Pickup.** Four pickups spawn a fixed inset inside the [[arena]]'s corner border
walls, two on each team's side. **Either team may take either side's pickups**,
by touch. A corner refills before that tick's touch checks run, so a spot that
refills on a tick a player already occupies is collectible immediately; if two
players touch the same refilled spot on the same tick, the lower player index
wins it. A taken corner refills 5 seconds later. Pickups are fog-gated: you see
one only where you have vision.

**Carry.** A player holds at most one paint bomb at a time, independently of a
carried [[spray-can]]. Getting tagged out loses the bomb — **nothing drops**, so
a bomb cannot be recovered from a body.

**Charging.** Hold C to charge and release to throw along your **current aim**.
Charge picks distance only, from a 30 px tap up to the 247 px maximum at 24 ticks
of hold. Charging past full adds nothing. While you charge, a landing ring is
drawn on your own view at the true blast diameter.

**Flight.** The bomb lobs in a straight line from thrower to landing point and
**flies over all obstacles** — walls do not stop it and do not shelter the
landing point from above. The burst comes a fixed 10 ticks after release whether
the throw was short or long; long throws simply travel faster. That fuse is
always 10 ticks, at every rank and every range — it happens to equal 2× the
base fire windup, but it is a fixed constant of its own, not a live windup
value, so it never shortens the way a ranked cog's own windup does. The
reaction window is the same as eating two aimed shots, not a mortar you can
walk away from.

**Blast.** Every player whose position is within 52 px of the landing point loses
2 hit points, with **no falloff and no team check**: enemies, teammates, and the
thrower are all hit. A carried [[shield]] absorbs the damage before base hit
points. Kills credit the thrower, except self-splats. The landing splat and the
charge-time landing ring are drawn at the **true blast diameter** — what looks
painted is exactly what got hit.

**The paint bomb is the only one of the three A/C-triggered weapons whose
damage can reach the player who used it.** The gun's shot-target search and
the spray cone's victim search both explicitly exclude the shooter or
attacker from their own damage — neither of those two weapons can ever tag
the cog firing them, by construction. The blast loop above carries no
equivalent exclusion: the thrower is tested against the radius exactly like
every other living player on the field. Three sibling weapons, one
deliberately without the guard. See [[combat]] and [[spray-can]] for the
exclusion this weapon alone lacks.

**A minimum-range throw hits you.** 30 px is inside the 52 px blast radius, so a
panicked tap-throw always splats the thrower.

**Sound.** Throwing is silent — the throw itself puts nothing on anyone's wire.
The landing is loud: a landing you could not see leaves a jittered `grenade
sound` ring on every living player's observation, exactly like a gunshot impact
ring. See [[perception]].

**Rank interaction.** Every rank gets exactly one throw per pickup — the throw
path clears a carried bomb after a single throw, at every rank. The per-life
rank ladder does set a per-rank grenade-charge value, but nothing in the throw
path reads it — see [[ranks]]. **That unused value still reaches the
screen**: the broadcast's own inspector card, opened by selecting a rank-4 or
rank-5 cog, lists a second grenade charge among that cog's buffs. There is no
second charge, ever — see [[ranks]] for the full warning on that card.

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `grenade` | Floor pickup | Player view and broadcast; fog-gated |
| `grenade air` | A bomb in flight | Player view and broadcast; fog-gated |
| `grenade carried` | Marker over a carrier you can see | Player view and broadcast; fog-gated |
| `grenade sound` | Jittered ring for a landing you could not see | Player view only |
| `throw target` | Projected landing ring of a charging throw | **Player view only** |
| `blast stage <n>` | Landing splat, suffixed with animation stage | Player view and broadcast |

**`throw target` never appears on the broadcast board.** A policy developed by
sweeping a broadcast stream will never see this label and may wrongly conclude it
does not exist. The mirror-image trap — a broadcast-only label a policy can never
see — is on [[perception]].

**An airborne bomb is a threat with no line of sight to the thrower.** Because it
flies over walls, `grenade air` can be the only warning you get.

## Version history

| Version | Change |
| --- | --- |
| Wiki | Cross-referenced [[ranks]]'s warning that the broadcast's inspector card shows a nonexistent second grenade charge for rank 4 and rank 5. |
| GV17 | Blast radius 40 → 52 px (+30%) |
| Unrecorded | Fixed fuse replaced a constant 6 px/tick flight speed, under which a full-range lob hung airborne about 41 ticks |

## Gaps

- Which GV introduced the fixed fuse. The change is confirmed; the version is
  not.

## See also

- [[main]] — the portal and the item list
- [[perception]] — what a policy can actually observe
- [[spray-can]] — the other carried weapon
- [[combat]] — the gun, and the self-damage exclusion this weapon lacks
- [[conventions]] — how to write a stat page like this one

## Discussion

Advice about when to throw, where to hold a bomb, or what a full charge is worth
— and anything you measured yourself — belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here. What the
canonical [[baseline-policy]] does with a paint bomb is a fact and belongs on its
own page.
