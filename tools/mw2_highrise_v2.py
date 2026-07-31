#!/usr/bin/env python3
"""Builds Highrise v2 from the measured plan (docs/designs/
highrise-layout-v2.md), pipeline per tools/mw2_build_lib.py.

Highrise's particulars:
  * there is NO organic terrain — everything is rooftop architecture, so all
    four masks decompose to EXACT rects (boundary parapet, interior walls,
    fixtures). The penthouse's chamfered faces staircase into small rects,
    which is correct: crisp concrete is the intended look;
  * glass.png becomes `window: true` shapes — solid to movement and fire,
    transparent to fog (the engine's glass; the atrium wells and curtain
    walls read through);
  * homes sit INSIDE real interiors (the plan preserves the current map's
    enclosure strength), spawns corner-locked as the real map plays.

Usage: python3 tools/mw2_highrise_v2.py
"""
import sys

sys.path.insert(0, "tools")
from mw2_build_lib import (MapSpec, load_masks, ship_verify, emit,  # noqa: E402
                           seal_pockets)
from mw2_rust_v2 import exact_rects  # noqa: E402

SPEC = MapSpec(
    name="highrise", w=1400, h=700,
    red_home=(244, 552), blue_home=(1205, 390),
    spawn_w=70, spawn_h=130, carve_clear=-1,
    mask_dir="docs/designs/mw2-reference/highrise-v2-masks",
    # Plan: slide blueHome within the south office if the gap exceeds 10%.
    nudge_home="blue", nudge_to=(1240, 390),
)

LANDMARKS = {
    "blueHome": (1205, 390),
    "medkit seam": (782, 200),
    "medkit rig bay": (770, 585),
    "NW spawn deck": (150, 120),
    "helipad": (1270, 575),
    "gantry bay": (770, 85),
    "west court": (600, 320),
    "girder walk": (900, 650),
    "seam south mouth": (784, 300),
    "NE deck": (1010, 330),
}


def main():
    print("loading measured masks...")
    solid = load_masks(SPEC, ["boundary", "walls", "fixtures"])
    glass = load_masks(SPEC, ["glass"])

    wall = solid | glass
    wall = seal_pockets(wall, SPEC)
    solid = wall & ~glass

    print("decomposing architecture to exact rects...")
    solid_rects = exact_rects(solid)
    glass_rects = exact_rects(glass)
    print(f"  {len(solid_rects)} solid rects, {len(glass_rects)} glass rects")
    rect_structs = [("wall", x, y, w, h) for x, y, w, h in solid_rects] + \
                   [("glass", x, y, w, h) for x, y, w, h in glass_rects]

    print("verifying the SHIPPED raster:")
    ship_verify(SPEC, [], rect_structs, [], LANDMARKS)

    emit(SPEC, [], [("wall", x, y, w, h) for x, y, w, h in solid_rects], [],
         "/tmp/highrise_v2_shapes.nim",
         "HIGHRISE v2: rooftop architecture, exact rects from the masks")
    with open("/tmp/highrise_v2_shapes.nim", "a") as f:
        f.write("    # glass: atrium wells + curtain walls, fog-transparent\n")
        for x, y, w, h in glass_rects:
            f.write(f"    ArenaShape(kind: shapeRect, window: true, "
                    f"rect: MapRect(x: {x}, y: {y}, w: {w}, h: {h})),\n")
    print("wrote /tmp/highrise_v2_shapes.nim")
    print(f"final homes: red {SPEC.red_home}, blue {SPEC.blue_home}")


if __name__ == "__main__":
    main()
