# Terminal v2 masks — the raster source of truth

Single-channel PNGs, all **1310x900 canvas scale, wall = white (255), floor =
black (0)**. Polygons in `docs/designs/terminal-layout-v2.md` are lossy
retraces of these rasters; where they disagree, **the masks govern**
(`tools/mw2_maskcheck.nim` is the arbiter pattern).

Provenance: measured from `docs/designs/mw2-reference/terminal.png` (512x512
official 2009 minimap). Classification on luminance: wall > 222, floor < 110,
out-of-bounds between (the distribution is cleanly trimodal). Frame
(0, 70, 512, 430) of the original, rotated 180 degrees into game space
(the shipped Terminal orientation, per docs/designs/mw2-parity-audit.md),
scaled uniformly 2.5x. Transform:

```
canvas.x = 1279 - 2.5 * orig.x
canvas.y =  899 - 2.5 * (orig.y - 70)
```

Canvas x 1280..1309 is a 30 px out-of-bounds art margin (chosen so
redHome.x + blueHome.x = width + 1).

| mask | semantics | white px |
|---|---|---|
| `shell.png` | MEASURED. Everything outside the playable floor: the out-of-bounds sea, the boundary wall band, the east art margin. | 467,830 |
| `structures.png` | MEASURED. Interior obstructions enclosed by floor: freestanding walls, counters, kiosk blocks, roofed shop units, the dotted conveyor pips. | 154,062 |
| `hero-747.png` | AUTHORED. The walkable 747: two hull flank walls with three door gaps, nose cone, tail cone, two engine nacelles, the air-stair block. Aisle and doors are black (floor). | 10,188 |
| `v2-authored.png` | AUTHORED. Non-plane v2 additions: bookstore splay storefront + shelves, relocated info kiosk, the solidified belt wall (three doors), the carousel loop (two gaps). | 11,155 |
| `v2-carve.png` | FORCED FLOOR. Every v2 carve: cabin aisle + doors, tail-apron wedge, jet bridge, Center Court r74, security-comb lanes + queue widening + capsule trim, bookstore interior + doors, belt door dot-clears, kiosk removal, newsstand tip trim. | 76,552 |
| `v2-composite.png` | The final collision truth. | 591,172 |

Compose order (must match exactly):

```
walls = (shell OR structures) AND NOT v2-carve
walls = walls OR hero-747 OR v2-authored
# == v2-composite.png
```

The engine then force-carves on top of this (isProtectedFloor): the r70 flag
ring at (655, 450) and the two spawn pockets (±55 x, ±48 y around each home).
The composite was audited WITH those forced regions applied: one floor
component, no sealed pockets, zero wall px inside either pocket.
