# baseline — Coworld CTF bot

A readable capture-the-flag reference bot that speaks the Bitworld Sprite v1
protocol. It is intentionally simple — a legible policy, not a research agent —
but it plays visibly better than a naive "walk to flag and shoot ahead" bot:
it splits the team into roles, escorts its carrier, defends home, and picks its
shots.

All decision logic lives in `decideMask` in `baseline.nim`.

## View model

The per-player view is 128×128 **screen-space**; our own avatar is at the center
(~64, 64), so "direction to X" is just `objectCenter - center`. **Facing equals
movement direction** (you shoot where you walk), so to fire at a target we
briefly steer toward it. Object labels we read:

- `"player <color> right"` / `"player <color> left"` — a player; the suffix is
  their facing. Our color is a teammate, the other is an enemy.
- `"flag"` — the flag. A carried flag rides its carrier's sprite, so a flag
  near our center means **we** carry it; a flag overlapping a teammate/enemy
  sprite means **they** carry it; otherwise it is loose on the ground.
- `"flag arrow"` — off-screen direction hint to the flag.

## Roles (deterministic from slot)

Slot parity picks the team (even = Red, home = left edge; odd = Blue, home =
right). The per-team seat index (`slot div 2`, 0–3) picks the role so the team
is not a monolith:

- **Attackers** (lower two seats): chase the loose flag, grab it, and carry it
  home; escort a teammate carrier.
- **Defenders** (upper two seats): hang back toward home and face the incoming
  lane, intercepting enemies and enemy carriers.

## Per-frame decision

1. **Movement target**, in priority order:
   - Carrying the flag → beeline to our home edge.
   - A teammate is carrying → escort: sit just behind them toward home and cover.
   - An enemy is carrying → chase the carrier down.
   - Defender with no flag in view → hold near home, facing the nearest enemy.
   - Flag visible and loose → go grab it.
   - Otherwise → follow the flag arrow (or jitter to avoid deadlock).
2. **Aim bias**: if the nearest enemy is close and roughly ahead, briefly steer
   toward it — a one-shot kill is worth a short detour.
3. **Retreat / jink**: if a close enemy is facing us (a right-facer to our left,
   or a left-facer to our right) and we are not closing to shoot, strafe
   perpendicular instead of walking into its muzzle.
4. **Fire (A)**: shoot the nearest enemy that is in gun range and inside our
   firing cone (a looser cone at point-blank). A friendly-fire guard holds fire
   when a closer teammate sits tightly in the line.

Randomized jitter breaks ties and prevents deadlocks throughout.

## Build & run

```bash
# From the repo root:
nim c --hints:off -o:players/baseline/baseline.out players/baseline/baseline.nim
COWORLD_PLAYER_WS_URL="ws://localhost:8080/player?slot=0&token=0xBADA55_0" \
  ./players/baseline/baseline.out
```

Container build uses `players/baseline/Dockerfile` (produces `/bin/baseline`).
