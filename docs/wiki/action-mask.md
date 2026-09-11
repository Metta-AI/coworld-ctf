*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

**This page documents the eight-bit action-mask byte and the mechanic it
always resolves to — not a claim that every seat's policy sends this literal
byte over the wire today.** The mask is the input every cog's movement, aim
and fire ultimately run on: produced directly by a `control: "input"` seat's
own wire message (see [[wire]]), or, for a `control: "play"` seat, derived by
the server itself from that seat's different kind of message before the mask
ever reaches the simulation. **Every seat in the platform's own published
`battle-royale-s2` variant — today's only live ladder — is configured
`control: "play"`**, so a policy submitted to it never sends this byte
directly; the byte still describes exactly what a human seat sends after
taking over a live cog's controls, what a browser seat's keyboard keys
translate to, and what any seat explicitly configured `control: "input"`
(today, only a deprecated classic-mode game — see [[modes]]) sends. Four bits
drive movement, two bits rotate aim, and two bits fire the gun or charge a
throw — nothing else is settable. A browser seat maps the same eight bits to
keyboard keys; the bitmask is the mechanic layer, the keys are the chrome a
human presses.

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

One mask is sampled per tick, at the engine's 24 ticks/second rate, however
that seat's mask was produced this tick (see the scope note above). There is
no sub-tick resolution and no buffering: whatever mask is current when a tick
steps is the mask that tick acts on.

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

### These three numbers are configurable per game, and none has moved

The aim turn rate, fire windup and fire cooldown above are per-game config
values, not hard engine constants — a game could in principle ship a faster
turn or a shorter windup. None does: every game variant defined in this
repo's own manifests sets all three to exactly the values stated above: 5
brads/tick, a 5-tick windup, a 12-tick cooldown.

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

## Version history

| Version | Change |
| --- | --- |
| 2026-09-11 (wiki, re-trace, GV63 / GLORYVERSION 18) | Added the lead's scope note: every seat on the live `battle-royale-s2` ladder is configured `control: "play"` and never sends this byte directly (see [[wire]]); this page previously read as if a submitted policy always sent this mask. Also resolved the old "does any shipped mode retune these" gap — every game variant in this repo's own manifests confirms the aim turn rate, fire windup and fire cooldown at their stated defaults — and removed a stale citation that no longer matches its source. |

## Gaps

- Whether sending multiple newly-rising bits in the same tick (A and C both
  going from 0 to 1, for instance) resolves in a guaranteed order.
- Whether this page's bit-level rules — edge-triggering, opposing-bit
  cancellation — apply identically to a mask the server's own play-interpreter
  derives for a `control: "play"` seat, or only to a mask a seat sends
  directly; not independently re-derived here.

## See also

- [[main]] — the quick-reference control table
- [[wire]] — the socket message this byte rides on a `control: "input"`
  seat, and the scope note explaining which seats send it directly
- [[perception]] — the label contract, including the readiness labels above
- [[combat]] — brads, turn rate, the aim-lock model, windup, cooldown, and
  the hitscan corridor
- [[paint-bomb]] — what C charges and throws
- [[spray-can]] — what A does while one is carried
- [[modes]] — which named variants boot `control: "input"` seats today

## Discussion

Button-mashing patterns, input-buffering tricks, and any latency or
input-lag numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
