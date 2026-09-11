*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

The action mask is Paintbot's entire input surface today: an 8-bit bitmask a
policy sends once every tick, 24 times a second, in place of a controller.
Four bits drive movement, two bits rotate aim, and two bits fire the gun or
charge a throw — nothing else is settable. A browser seat maps the same
eight bits to keyboard keys; the bitmask is the mechanic layer a policy
writes, the keys are the chrome a human presses.

## Rules

### The eight bits

| Bit | Value | Button | Action |
| --- | --- | --- | --- |
| 0 | 1 | Up | Move up |
| 1 | 2 | Down | Move down |
| 2 | 4 | Left | Move left |
| 3 | 8 | Right | Move right |
| 4 | 16 | Select | Rotate aim clockwise |
| 5 | 32 | A | Fire the gun, or spray the cone while carrying a [[spray-can]] |
| 6 | 64 | B | Rotate aim counter-clockwise |
| 7 | 128 | C | Hold to charge a [[paint-bomb]] throw, release to throw |

The mask is a plain byte: OR together the values of every bit you want held
this tick and send the sum. All eight bits may be set at once — the engine
never rejects a combination, though some cancel each other out (below).

### Worked examples

| Combination | Arithmetic |
| --- | --- |
| Move left | Left 4 = 4 |
| Move left + fire | Left 4 + A 32 = 36 |
| Move up-right | Up 1 + Right 8 = 9 |
| Fire while stationary | A 32 = 32 |
| Item use — charge/throw a [[paint-bomb]] | C 128 = 128 |

### Sampling

A policy sends one mask per tick, sampled at the engine's 24 ticks/second
rate. There is no sub-tick resolution and no buffering: whatever mask is
current when a tick steps is the mask that tick acts on.

### Held versus edge-triggered

The eight bits do not all behave the same way when held:

- **Up, Down, Left, Right are level-triggered.** Movement is continuous
  acceleration, not a per-tick teleport: holding a direction accelerates
  toward max speed, releasing it lets friction decay the velocity to a
  stop. Opposing bits cancel exactly like opposing rotation does — Left and
  Right held together net zero horizontal input, the same as Up and Down.
- **Select and B are level-triggered.** Aim turns at 5 brads/tick toward
  whichever single one is held; holding both Select and B at once cancels
  to no turn at all, and holding neither also turns nothing. See [[combat]].
- **A is edge-triggered.** A shot — or, while carrying a spray can, a cone
  burst — arms on the tick the bit transitions from 0 to 1. Holding A down
  does nothing further: the next shot needs a fresh release-then-press. The
  same edge check governs both weapons, so carrying a spray can does not
  make A level-triggered.
- **C is both.** Holding C charges a throw, accumulating for up to 24 ticks
  (1.0 s); releasing it — a 1-to-0 transition with charge already banked —
  throws. Holding C while carrying no grenade does nothing and banks no
  charge.

**Firing has its own delay on top of the edge trigger, and the aim lock is
gun-only.** Pulling A while carrying the gun locks your aim immediately, but
the bullet does not leave until a 5-tick (0.21 s) windup finishes; a fixed
12-tick (0.5 s) cooldown then blocks the next pull. A pull during either
window is ignored, not queued. Carrying a [[spray-can]] instead, the same A
bit fires a cone burst with no aim lock at all — the cone tracks your live
aim every tick it is active, replacing the gun's windup/cooldown pair with
its own fixed 5-tick active burst and 20-tick recharge. Full shot-by-shot
timing is on [[combat]].

### Locomotion never touches aim

The d-pad and the aim-rotation bits are fully independent. Moving (bits 0–3)
never changes where you look, and rotating (bits 4 and 6) never moves you —
there is no turn-to-face-movement behaviour. A policy that wants to strafe
while holding a lane combines a locomotion bit with a rotation bit in the
same mask; neither overrides the other.

## Labels

The A bit's readiness and the C bit's in-progress charge are both surfaced
back to a policy as sprite labels, tying this page's control layer to the
observation layer:

| Label | Meaning | Stream |
| --- | --- | --- |
| `fire icon` | The gun (or spray can) is ready; gate an A press on this, not a timer | Player view |
| `fire icon cooldown` | The gun is recovering; an A press now is wasted | Player view |
| `throw target` | Landing ring of a charge already banked by holding C | Player view only |

**None of these read an actual button state off the wire.** They are the
engine's own readiness and preview signals — the mask itself carries no
readback of what you pressed last tick. A policy tracks its own held bits if
it needs to know what it is currently doing. Full label contract on
[[perception]].

## Gaps

- Whether sending multiple newly-rising bits in the same tick (A and C both
  going from 0 to 1, for instance) resolves in a guaranteed order.
- Whether any shipped mode changes the aim turn rate, the fire windup, or
  the fire cooldown away from their GV24 defaults — RULES.md calls these
  tuning parameters, not hard constants.

## See also

- [[main]] — the quick-reference control table
- [[perception]] — the label contract, including the readiness labels above
- [[combat]] — brads, turn rate, the aim-lock model, windup, cooldown, and
  the hitscan corridor
- [[paint-bomb]] — what C charges and throws
- [[spray-can]] — what A does while one is carried

## Discussion

Button-mashing patterns, input-buffering tricks, and any latency or
input-lag numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
