# baseline — Coworld CTF bot

A minimal capture-the-flag bot that speaks the Bitworld Sprite v1 protocol. It
is intentionally simple: a correctness/liveness baseline, not a strategist.

## Decision logic

All of it lives in `decideMask` in `baseline.nim`:

1. Parse `?slot=N` from `COWORLD_PLAYER_WS_URL`. Even slot = Red (home = left
   edge), odd slot = Blue (home = right edge). The enemy is the other color.
2. If not carrying the flag, move toward the `"flag"` object (its screen-space
   center), or toward the `"flag arrow"` direction when the flag is off-screen.
3. If carrying the flag (the `"flag"` object sits on our screen-center), run for
   our home edge (left for Red, right for Blue).
4. Fire (the `A` bit) when an enemy-colored player object lies within a short
   range and roughly in our current heading; otherwise hold fire.

Object coordinates from the per-player view are **screen-space** (0..127); our
own avatar is at the screen center (~64, 64), so direction-to-target is just
`object_center - center`.

## Build & run

```bash
# From the repo root:
nim c --hints:off -o:players/baseline/baseline.out players/baseline/baseline.nim
COWORLD_PLAYER_WS_URL="ws://localhost:8080/player?slot=0&token=0xBADA55_0" \
  ./players/baseline/baseline.out
```

Container build uses `players/baseline/Dockerfile` (produces `/bin/baseline`).
