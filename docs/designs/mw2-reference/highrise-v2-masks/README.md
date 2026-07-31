# Highrise v2 raster masks

Canvas-scale (1400x700) single-channel PNGs, **white (255) = the named material,
black (0) = not it**. These rasters are the source of truth for the Highrise v2
rebuild — the polygon/rect tables in `docs/designs/highrise-layout-v2.md` were
used to *generate* them (via `gen_masks.py` in this directory), so the two are
consistent by construction, but where an integration question arises the raster
wins. Regenerate + re-verify all invariant metrics with:

```
python3 docs/designs/mw2-reference/highrise-v2-masks/gen_masks.py
```

(needs numpy/scipy/PIL; also emits `/tmp/hr2`-relative plan view + metrics).

| mask | semantics | white px |
|---|---|---|
| `boundary.png` | Out-of-bounds solid: the parapet/sky border ring, the north city-drop strips, the two sealed raised roofs on the east tower, the void strips flanking + under the rig bay and under the girder walk, and the west-border parapet tie-backs. Render as solid wall; never carve. | 166149 |
| `walls.png` | Structure walls (opaque, blocking): both tower interiors, the seam, gantry, penthouse shell + interior, parapet walls, rig bay, east-tower rooms, helipad parapet stubs. | 115501 |
| `glass.png` | `window: true` shapes (block movement, pass sight/shots): the tilted skylight, penthouse skylight, NE skylight box, and the east tower's sunken atrium well. | 26544 |
| `fixtures.png` | Freestanding cover: HVAC housings/vents, boilers, water tank, racks, crane pad + pallet, desk pieces, scaffold, hoist crate, planters, skylight housing. The crane mast + counterweight in this mask sit **on** boundary solid (art-anchored; no connectivity effect). | 40632 |

Walkable floor = NOT(boundary | walls | glass | fixtures). Verified: exactly
**one** floor component (no sealed pockets), flag ring at (700,350) r70 fully
clear (nearest solid 72 px), all doors >= 24 px.
