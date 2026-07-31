# Scrapyard v2 raster masks

Canvas-scale collision truth for `docs/designs/scrapyard-layout-v2.md`. All four
files are single-channel (mode `L`) PNGs at **1235x727** — the v2 canvas — with
**wall = white (255)**, floor = black (0). The union of the four masks is the
complete v2 collision set; they are disjoint by construction except for
deliberate welds (a weld overlap is still wall, so union is safe). Polygons in
the layout doc are the *authoring* form; these masks are the *ground truth* the
doc was verified against — if a transcription into Nim disagrees with a mask,
the mask wins.

Rebuilt by `build_masks.py` in this directory (run it from the repo root; it
also re-runs the verification suite and re-renders
`/tmp/scrapyard_plan_view.jpg`); regenerate whenever a shape in the doc
changes and update the counts below from its output.

| file | semantics | white px |
|---|---|---|
| `boundary.png` | Everything outside the yard-fence carve polygon (16-pt `YARD` in the doc): out-of-bounds rubble fill, the fence line itself, the NE notch, and the canvas edge band. Solid on all four canvas edges (this is what makes `carveClear = -1` legal). | 154197 |
| `buildings.png` | Man-made walls and interior furniture: Depot walls/partition/porch/annex-room, Workshop, north shed walls + stored crates, fuselage-rack and engine-pen walls, wing bay, long shed + stored-wing rack, cutting shed, crane base + tower core, warehouse walls + pallet racks, the long wall + the N-S baffle wall, hangar walls/piers + rail-line debris. | 83663 |
| `airframes.png` | The boneyard itself: F1 nose+hull, F2 tilted section, F3 gutted hull, F4 hull, the wing slab, the two rack cylinders, four engine fans, the engine-pen display disc, the wing and tail wrecks in the hangar forecourt. | 46599 |
| `scrap.png` | Yard clutter: scrap heap + shoulder, tilted flatbed + container, NE crates, truck trailer, SE standing trailer, SE container, hangar-side crates, parts pile at F2's nose, leaning scrap sheet on the long shed, MG-nest sandbag diamond. | 21547 |

Not in any mask (floor features / art only): trenches, spawn rects, medkits,
the crane boom lattice + hook, the landing-gear pair at (640,418), the rail
streak through the hangar, and the painted roof numbers.

Verification state at these counts: forced-carve chew (flag ring r70 at
(617,363) + both 140x170 spawn pockets) = **0 px** in every mask; 1-px flood
from redHome reaches all 15 interior/court probes with **no sealed pocket**
over 40 px; longest open floor row-run 497 px (y=488), longest column-run
488 px (x=460, the G1 cut); stand cover within 200 px: red 18.9%, blue 21.0%.
