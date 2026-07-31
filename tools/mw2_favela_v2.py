#!/usr/bin/env python3
"""Builds Favela v2 from the measured plan (docs/designs/favela-layout-v2.md),
pipeline per tools/mw2_build_lib.py.

Favela's particulars:
  * the map IS its alley grid: perimeter (hillside boundary) is organic,
    disc-fitted; blocks + shanties are the measured fabric — the blocks mask
    decomposes to EXACT rects (buildings), the shanties (carts, stalls, tin
    huts) are small organic clutter, disc-fitted;
  * windows.png marks the plan's shoot-through wall runs. The engine's
    nearest primitive is the `window: true` shape — solid to movement and
    fire, transparent to FOG only. That is a real semantic narrowing of the
    plan's intent, noted here and in the emitted comment;
  * acceptance criterion (board task fd4bf8ba): the engine-center column
    must cross >= 3 distinct alleys. Asserted below on the shipped raster.

Usage: python3 tools/mw2_favela_v2.py
"""
import sys

import numpy as np

sys.path.insert(0, "tools")
from mw2_build_lib import (MapSpec, load_masks, fit_terrain, ship_verify,  # noqa: E402
                           emit, seal_pockets)
from mw2_rust_v2 import exact_rects  # noqa: E402

SPEC = MapSpec(
    name="favela", w=1228, h=1122,
    red_home=(150, 430), blue_home=(1085, 222),
    spawn_w=70, spawn_h=96, carve_clear=-1,
    mask_dir="docs/designs/mw2-reference/favela-v2-masks",
    # Plan section 5: nudge blueHome west along the yard (to x 1060) if blue
    # measures slow; red is yard-locked.
    nudge_home="blue", nudge_to=(1060, 222),
)

LANDMARKS = {
    "blueHome": (1085, 222),
    "medkit square": (580, 600),
    "medkit east court": (920, 480),
    # Corrected in the reconciliation pass: the early trace invented an
    # "NW upper yard" in ground the reference keeps out-of-bounds; the real
    # terrace ground is the open column east of it.
    "NW terrace stairs": (390, 220),
    "top terrace": (594, 45),
    "the Bar yard": (818, 265),
    "town square": (614, 561),
    # Street reaches carry x-ranges now: west x 170-880 @ y 727-783, east
    # x 880-1160 @ y 660-716 (the street steps up at the measured bend).
    "main street west": (765, 765),
    "main street east": (1000, 690),
    "east court": (920, 500),
    "back street": (1160, 480),
    "south stairs": (686, 880),
    "SE yard": (1000, 920),
    "lower pocket": (800, 945),
    "junk row": (360, 865),
    "west nook": (100, 800),
}


def midfield_alleys(shipped, spec):
    """Distinct >= 24px open gaps crossing the engine-center column band."""
    col = spec.w // 2
    band = shipped[:, col - 2:col + 3].any(axis=1)
    gaps, run = [], 0
    for y in range(spec.h):
        if not band[y]:
            run += 1
        else:
            if run >= 24:
                gaps.append(run)
            run = 0
    if run >= 24:
        gaps.append(run)
    return gaps


def main():
    print("loading measured masks...")
    perimeter = load_masks(SPEC, ["perimeter"])
    blocks = load_masks(SPEC, ["blocks"])
    windows = load_masks(SPEC, ["windows"])
    shanties = load_masks(SPEC, ["shanties"])

    wall = perimeter | blocks | windows | shanties
    wall = seal_pockets(wall, SPEC)
    organic = (wall & ~blocks & ~windows)

    print("fitting organic masses (hillside + shanty clutter)...")
    discs = fit_terrain(organic, SPEC, max_discs=900)

    print("decomposing blocks to exact rects...")
    block_rects = exact_rects(blocks & ~windows)
    print(f"  {len(block_rects)} block rects")
    print("decomposing window runs (fog-transparent glass)...")
    window_rects = exact_rects(windows)
    print(f"  {len(window_rects)} window rects")
    rect_structs = [("block", x, y, w, h) for x, y, w, h in block_rects] + \
                   [("window", x, y, w, h) for x, y, w, h in window_rects]

    print("verifying the SHIPPED raster:")
    shipped = ship_verify(SPEC, discs, rect_structs, [], LANDMARKS)

    gaps = midfield_alleys(shipped, SPEC)
    print(f"  midfield alleys crossing the center column: {len(gaps)} "
          f"(widths {gaps})")
    if len(gaps) < 3:
        raise SystemExit("ACCEPTANCE FAIL: fewer than 3 midfield alleys")

    emit(SPEC, discs,
         [("block", x, y, w, h) for x, y, w, h in block_rects],
         [], "/tmp/favela_v2_shapes.nim",
         "FAVELA v2: hillside+shanties fitted, blocks exact from the mask")
    # Windows: the plan calls these shoot-through; the engine's window flag
    # is solid to movement/fire but transparent to FOG — the closest
    # primitive. Emitted separately so the narrowing is visible.
    with open("/tmp/favela_v2_shapes.nim", "a") as f:
        f.write("    # window runs: plan says shoot-through; engine glass "
                "is fog-transparent only\n")
        for x, y, w, h in window_rects:
            f.write(f"    ArenaShape(kind: shapeRect, window: true, "
                    f"rect: MapRect(x: {x}, y: {y}, w: {w}, h: {h})),\n")
    print("wrote /tmp/favela_v2_shapes.nim")
    print(f"final homes: red {SPEC.red_home}, blue {SPEC.blue_home}")


if __name__ == "__main__":
    main()
