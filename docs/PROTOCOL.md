# CTF wire protocol — Sprite v1 plus CTF extensions

Both the player endpoints (`/player`, POV observation streams) and the
global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything CTF adds or changes relative to that base
document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — mechanics, sprite labels, tuning defaults — live in
[`RULES.md`](RULES.md).

## Player input: bit 7 is the C button

Sprite v1 reserves player-input bit `7` ("must be sent as 0"). CTF assigns it:

| Bit | Value | Meaning |
| ---: | ---: | --- |
| `7` | `0x80` (128) | C button — hold to charge a grenade throw, release to throw |

Send it in the standard `0x84` Player Input bitmask alongside the Sprite v1
bits (d-pad, Select, A, B). A player that never sets bit 7 can still move,
shoot, and win — but cannot throw a carried grenade. See `RULES.md`, section
*Grenades*, for the charge/release mechanics. (The spray can is not thrown:
carrying one turns the normal trigger into the paint cone; C keeps throwing a
carried grenade.)

## Player Ready (`0x85`) is supported

The server understands the Sprite v1 Player Ready packet (`0x85`): after each
rendered frame a player client may send it to signal "done thinking", which
lets the server pace fast-mode games by readiness instead of the wall clock.
Sending it is optional; clients that never send it are paced by timeouts.

## Observation render scale

- **Player/POV streams are 1× map resolution.** Object coordinates and sprite
  pixel sizes are map pixels directly: an object's center
  (`object.x + sprite.width / 2`, same for y) IS its map point on the
  1235×659 map. No divisor is needed.
- **Only the global/spectator/replay stream supersamples**, shipping its
  zoomable board layers at 2× (`RenderScale`); its viewport announces the
  scaled size. The sim, the gameHash, and every value quoted in `RULES.md`
  stay in 1× map pixels.
- A 0.6.0-era build shipped observation coordinates at 3×; that is long gone.
  Any advice about dividing player-stream coordinates by 3 is stale.
