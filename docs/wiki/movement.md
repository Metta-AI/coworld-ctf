*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

A cog moves with continuous acceleration and friction under d-pad input,
never a per-tick teleport — the engine calls the entity a **Player**,
`player <color> <side>` on the wire, while "cog" is the fiction name for the
same body. Movement is pure locomotion: the d-pad never changes where you aim
or look. At full tilt a cog covers 66 px/s (2.75 px/tick), reaches that top
speed after 10 ticks (0.42 s) of continuously held input, and decays back to
a stop several times faster once you let go.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Max speed | 66 px/s | — | 2.75 px/tick; raw engine value 704, in units of 1/256 px |
| Time to max speed | 0.42 s | 10 | From a standing start, input held continuously; raw accel step is 76/tick |
| Friction (no input) | ×0.5625 /tick | — | Multiplicative decay (raw ratio 144/256), not a constant deceleration |
| Stop threshold | 0.03 px/tick | — | Raw value 8; below this, velocity snaps to exactly 0 rather than crawling forever |
| Player footprint | 12×12 px | — | ±6 px half-extent, Chebyshev (box) distance — square, not circular |
| Player-player bounce | 40% | — | Restitution of a body-to-body collision; 0% = dead-stop shove, 100% = billiard-ball swap |
| Wall/body slide search | up to 3 px | — | Sideways offsets tried, biased toward your other-axis input, before a blocked step gives up |
| Carrier speed penalty | 70% | — | Both max speed and acceleration scale together while holding the enemy heart |
| Sub-pixel precision | 1/256 px | — | Motion is fixed-point; position carries a sub-pixel remainder between ticks |
| Aim turn rate | 5 brads/tick | — | Fully decoupled from the d-pad — see [[combat]] |

## Rules

### Acceleration and friction

Holding a d-pad direction adds a fixed step (76 raw units, ≈0.30 px) to your
velocity on that axis every tick, clamped at the max speed; opposing bits
(Left+Right, or Up+Down) cancel to zero net input, same as they do for aim
rotation. Releasing a direction does **not** subtract a constant — it
multiplies the existing velocity by 0.5625 every tick, an exponential decay
that roughly halves your speed every 1.2 ticks, until it drops under the
stop threshold and snaps to exactly zero. The two axes accelerate and decay
independently, so diagonal movement is not artificially slower or faster than
a cardinal direction. None of these three values — the acceleration step,
the friction ratio, or the max speed cap — has ever been tuned: all three
have held their current values since the game's first version.

### Walls slide, bodies bounce

Position is fixed-point: velocity accumulates a sub-pixel remainder each tick
and steps the body by whole pixels, one axis at a time, as that remainder
crosses a pixel boundary. When a step is blocked outright, the engine tries
nearby offsets on the *other* axis — biased toward whatever you're also
pressing, or your current drift if you're not — before giving up on that
tick's step; this is what reads as sliding along a wall instead of snagging
on it. **Player bodies are solid** — you cannot drive through another live
player, friend or foe — and **corpses never block**. A body-to-body collision
along the axis of contact is a slightly elastic bounce: at the default 40%
restitution, a head-on meeting knocks both players back at 40% of their
closing speed, while a glancing contact just shoves the slower body forward
and slides around it the same way a wall does.

### Movement never touches aim

The d-pad (four of the eight [[action-mask]] bits) drives
velocity only. Nothing about which way you're moving, or facing a moment ago,
changes your aim angle — turning is a deliberate B/Select input, never a
side-effect of travel. The soldier sprite's left/right flip follows the
**current aim** angle, not your direction of travel, so a cog can run
backward while still visibly facing — and shooting — the way it's aimed. See
[[combat]] for the rotation mechanic itself.

### Carrying the heart

While carrying the enemy heart, a cog's speed tax scales **both**
acceleration and top speed by 70%, not just a lowered cap — getting moving is
proportionally slower too, not only cruising. The tax is waived entirely
(100%) from rank 5 ("legend") of the per-life ladder. See [[ranks]] for the
rank ladder and [[arena]] for where the capture zone the carrier is
running toward actually sits.

## Version history

| Version | Change |
| --- | --- |
| GV63 / GLORYVERSION 18 (2026-09-11, wiki) | Re-traced against current source: acceleration (76/tick), friction (144/256 per tick), max speed (704 raw / 66 px/s), stop threshold (8 raw), player-player bounce (40%), wall-slide search (3 px), the 70% heart-carry speed tax and its rank-5 waiver, and the 5 brads/tick aim turn rate all re-checked and unchanged since this page's last stamp. |

## Gaps

- The browser client's d-pad key binding. The control table gives browser
  keys for B, Select, and C, but not for the d-pad (or for A).

## See also

- [[arena]] — the ground a cog moves across
- [[combat]] — the aim rotation and firing model, decoupled from movement
- [[action-mask]] — the full 8-bit input mask, d-pad included
- [[perception]] — the vision cone that rides on aim, not movement
- [[ranks]] — the rank that waives the heart-carry speed tax
- [[conventions]] — the mechanic-and-chrome layering rule

## Discussion

Strafing technique, corner-cutting lines through the arena's cover, and any
movement numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
