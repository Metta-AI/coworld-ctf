#!/usr/bin/env python3
"""Builds Rust v2 from the measured plan (docs/designs/rust-layout-v2.md).

Pipeline per tools/mw2_build_lib.py, with Rust's particulars:
  * terrain (dune band + yard walls) is disc-fitted at OVERREACH 2 — the plan
    deliberately keeps two real pinches at 27 and 33px against the east wall,
    and the default 4px overreach could take a 27px pinch under the 23px a
    13px player + fit tolerance needs;
  * structures (buildings, doors pre-carved in the mask) decompose to EXACT
    rects — rectilinear architecture, carve-stone is its look, zero fit
    error;
  * everything that will wear a prop sprite (containers, tanks, drum,
    barrels) is CARVED OUT of the structure mask first and its collision
    fitted from the sprite silhouette instead — "the object is the collision
    mask";
  * verification on the shipped raster, landmarks covering all nine
    interiors plus the two east-wall pinch courts.

Usage: python3 tools/mw2_rust_v2.py
Emits /tmp/rust_v2_shapes.nim + /tmp/rust_v2_props.nim + previews.
"""
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, "tools")
from mw2_build_lib import (MapSpec, PLAYER, load_masks, rect, fit_terrain,  # noqa: E402
                           fit_props, ship_verify, emit, seal_pockets)

SPEC = MapSpec(
    name="rust", w=1040, h=972,
    red_home=(452, 720), blue_home=(710, 296),
    spawn_w=55, spawn_h=90, carve_clear=-1,
    mask_dir="docs/designs/mw2-reference/rust-v2-masks",
    # Plan section 5, lever 1: if blue walks long, deepen red to (452, 770)
    # (the pocket stays clean there; adds ~50 to red's walk).
    nudge_home="red", nudge_to=(452, 770),
)

# Propped structures: (sprite, cx, cy, w, h, rot, label, carve-bbox).
# The carve-bbox removes the piece from the structure mask so its collision
# comes from the sprite silhouette, not the measured rect.
PROPPED = [
    ("container", 726, 148, 102, 30, 0, "long container",
     (672, 130, 108, 36)),
    ("crate", 762, 175, 24, 24, 0, "container annex", (747, 160, 30, 30)),
    ("container", 948, 583, 48, 30, 0, "small container",
     (921, 565, 54, 36)),
    ("container", 933, 828, 123, 33, 116, "big tank (diagonal)",
     (866, 762, 134, 132)),
    ("crate", 942, 771, 36, 30, 0, "big tank head skid", (939, 754, 42, 36)),
    ("container", 711, 868, 69, 24, 146, "south container",
     (674, 832, 74, 72)),
    ("fuel_tank", 567, 373, 34, 34, 0, "drum tank", (549, 355, 37, 37)),
    ("barrel", 795, 620, 28, 28, 0, "SE court barrel", (779, 604, 33, 33)),
    ("barrel", 817, 644, 28, 28, 0, "SE court barrel 2", (801, 628, 33, 33)),
    ("barrel", 822, 352, 28, 28, 0, "east avenue barrel", (806, 336, 33, 33)),
    ("barrel", 791, 325, 28, 28, 0, "east avenue barrel 2",
     (775, 309, 33, 33)),
]

# Vat battery art: the H-plinth stays measured masonry; four vat sprites sit
# ON it (decoration on architecture, silhouettes intentionally differ).
EXTRA_PROPS = [
    ("fuel_tank", 865, 193, 40, 40, 0),
    ("fuel_tank", 924, 193, 40, 40, 0),
    ("fuel_tank", 865, 277, 40, 40, 0),
    ("fuel_tank", 924, 277, 40, 40, 0),
]

LANDMARKS = {
    "blueHome": (710, 296),
    "medkit slot": (654, 585),
    "medkit west": (380, 412),
    "gallery hall": (594, 660),
    "workshop": (706, 490),
    "garage hall": (940, 505),
    "NW shed": (390, 247),
    "warehouse": (315, 770),
    "south room": (555, 900),
    "SE shed": (688, 632),
    "canopy": (556, 136),
    "pump house": (615, 340),
    "SE court (tank pinch)": (980, 700),
    "east avenue": (800, 420),
    "north field": (540, 230),
}


def exact_rects(mask):
    """Greedy largest-rectangle decomposition; union EQUALS the mask."""
    work = mask.copy()
    H, W = work.shape
    rects = []
    while work.any():
        ys, xs = np.where(work)
        y0, x0 = ys[0], xs[0]
        # Grow width along the row, then height while the full row run holds.
        x1 = x0
        while x1 + 1 < W and work[y0, x1 + 1]:
            x1 += 1
        y1 = y0
        while y1 + 1 < H and work[y1 + 1, x0:x1 + 1].all():
            y1 += 1
        work[y0:y1 + 1, x0:x1 + 1] = False
        rects.append((int(x0), int(y0), int(x1 - x0 + 1), int(y1 - y0 + 1)))
    return rects


def main():
    print("loading measured masks...")
    terrain = load_masks(SPEC, ["terrain"])
    structures = load_masks(SPEC, ["structures"])

    print("carving propped pieces out of the structure mask...")
    for job in PROPPED:
        x, y, w, h = job[7]
        rect(structures, x, y, w, h, 0)

    wall = terrain | structures
    wall = seal_pockets(wall, SPEC)
    # Re-split after sealing (seal discs belong to terrain).
    terrain = wall & ~structures

    print("fitting terrain (overreach 2 for the kept east-wall pinches)...")
    discs = fit_terrain(terrain, SPEC, overreach=2, max_discs=700)

    print("decomposing structures to exact rects...")
    srects = exact_rects(structures)
    print(f"  {len(srects)} exact rects")
    rect_structs = [(f"structure", x, y, w, h) for x, y, w, h in srects]

    print("fitting prop silhouettes (the object is the collision mask)...")
    prop_lines, allok = fit_props(
        [(s, cx, cy, w, h, rot, lbl) for s, cx, cy, w, h, rot, lbl, _
         in PROPPED])
    if not allok:
        raise SystemExit("prop silhouette fit failed")
    # Parse the emitted disc lines back for the shipped raster.
    prop_discs = []
    for ln in prop_lines:
        if "ArenaShape" in ln:
            parts = ln.split("cx: ")[1]
            cx = int(parts.split(",")[0])
            cy = int(parts.split("cy: ")[1].split(",")[0])
            r = int(parts.split("radius: ")[1].split(")")[0])
            prop_discs.append(("prop", cx, cy, r))

    print("verifying the SHIPPED raster:")
    ship_verify(SPEC, discs, rect_structs, prop_discs, LANDMARKS)

    emit(SPEC, discs, rect_structs, [], "/tmp/rust_v2_shapes.nim",
         "RUST v2 terrain (fitted) + structures (exact rects from the mask)")
    with open("/tmp/rust_v2_shapes.nim", "a") as f:
        f.write("\n".join(prop_lines) + "\n")

    with open("/tmp/rust_v2_props.nim", "w") as f:
        for s, cx, cy, w, h, rot, lbl, _ in PROPPED:
            rot_part = f", rot: {rot}" if rot else ""
            f.write(f'    # {lbl}\n'
                    f'    PropSprite(file: "data/props/{s}.png", x: {cx}, '
                    f"y: {cy}, w: {w}, h: {h}{rot_part}),\n")
        for s, cx, cy, w, h, rot in EXTRA_PROPS:
            rot_part = f", rot: {rot}" if rot else ""
            f.write(f'    PropSprite(file: "data/props/{s}.png", x: {cx}, '
                    f"y: {cy}, w: {w}, h: {h}{rot_part}),\n")
    print("wrote /tmp/rust_v2_props.nim")
    print(f"final homes: red {SPEC.red_home}, blue {SPEC.blue_home}")


if __name__ == "__main__":
    main()
