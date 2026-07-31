# Favela v2 collision masks

Canvas-scale (1228 x 1122) single-channel PNGs, **wall = white (255), floor =
black (0)**. These are the SHIPPED collision truth of
`docs/designs/favela-layout-v2.md` — fit engine discs to these (<=4px
overreach, per the Afghan v2 recipe), do not re-trace the reference.
Regenerate with `tools/mw2_favela_v2_plan.py` (also re-runs every acceptance
check and renders `/tmp/favela_plan_view.jpg`).

| mask | semantics | white px |
|---|---|---|
| `perimeter.png` | out-of-bounds hillside mass: everything outside the playable boundary polygon, plus the four interior solids (south terrace block, SE corner block, north-edge spur, north-edge buttress). Blocks walk + shots. `carveClear = -1` territory: the canvas edge is solid on all sides. | 578251 |
| `blocks.png` | the named building masses (crackhouse, yellow building, green house, brickhouse, red house, shop row, the bar, ladder building, garage, hilltop shack, terrace walls...). Interior rooms and their 26-28px doors are already carved OUT of this mask. Blocks walk + shots. | 157227 |
| `windows.png` | `window: true` strips: shopfronts on the main street (incl. their street-counter lips), the crackhouse slit over the town square, the red-house square window, the bar's north window. Blocks WALK only — shots pass. | 9460 |
| `shanties.png` | small cover: market stalls, carts, huts, kiosk, sheds, low walls, drums, planter, boulder. Blocks walk + shots. | 23359 |

Full walk-blocking collision = `perimeter | blocks | shanties | windows`.
Shot-blocking collision = `perimeter | blocks | shanties` (windows excluded).

Verified on these exact rasters (see the layout doc, section 6): 0 forced-carve
collisions (flag ring r70 + both spawn pockets), exactly 5 midfield alleys on
the engine-center column, 13px-fit flood from redHome reaches every named room
and pocket with 0 stranded cells, 24px-corridor flood connects both homes, and
walk-to-midfield ratio is 0.921.
