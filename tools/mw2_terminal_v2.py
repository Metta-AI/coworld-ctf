#!/usr/bin/env python3
"""Builds Terminal v2 from the measured plan (docs/designs/
terminal-layout-v2.md), pipeline per tools/mw2_build_lib.py.

Terminal's particulars:
  * the masks ship a pre-composed collision truth (v2-composite.png) with
    the compose order documented in the masks README — the walkable 747
    (hull flanks, 26px cabin aisle, three doors), the bookstore splay, the
    belt wall and every carve already applied. The composite governs;
  * the concourse is architecture (exact rects), but the 747's hull, nose
    and nacelles are curved — the hero-747 mask is disc-fitted so the hull
    reads as an airframe, not a staircase. Everything else in the composite
    decomposes exactly;
  * landmark set covers the cabin aisle end-to-end (the owner's "narrow
    hallway units can navigate in") plus every named interior.

Usage: python3 tools/mw2_terminal_v2.py
"""
import sys

sys.path.insert(0, "tools")
from mw2_build_lib import (MapSpec, load_masks, fit_terrain, ship_verify,  # noqa: E402
                           emit, seal_pockets)
from mw2_rust_v2 import exact_rects  # noqa: E402

SPEC = MapSpec(
    name="terminal", w=1310, h=900,
    # blueHome stays at the MEASURED point. The plan's west-slide lever was
    # tried when the field data showed the Afghan-v1 signature (11 steals,
    # 0 captures, no carry reaching midfield; the office spawn centre sat
    # 47px from the stand, inside the r64 circle) -- but at 1150 the forced
    # spawn pocket punches 1404px of measured wall, and a scan shows the
    # antechamber has NO zero-carve home position with the spawn outside
    # the circle. The fix is the SPAWN ZONE: it moved to the clean pocket
    # 100px north of the stand (see the ctor), which the composite scan
    # verifies carves nothing.
    red_home=(131, 430), blue_home=(1180, 430),
    spawn_w=55, spawn_h=48, carve_clear=-1,
    mask_dir="docs/designs/mw2-reference/terminal-v2-masks",
    # Plan: nudge blueHome west along y=430 if a future edit shifts walk
    # parity; red is hall-locked.
    nudge_home="blue", nudge_to=(1150, 430),
)

LANDMARKS = {
    "blueHome": (1180, 430),
    "medkit apron": (398, 206),
    "medkit pre-security": (940, 430),
    "cabin fwd door": (102, 218),
    "cabin aisle mid": (184, 146),
    "cabin aft": (267, 74),
    "air-stairs": (330, 95),
    "Center Court": (655, 450),
    "Burger Town side": (200, 550),
    "security comb": (1000, 430),
    "carousel": (800, 300),
    "SE hall": (900, 560),
}


def main():
    print("loading the composite collision truth...")
    composite = load_masks(SPEC, ["v2-composite"])
    hero = load_masks(SPEC, ["hero-747"])

    wall = seal_pockets(composite.copy(), SPEC)
    hero_part = wall & hero
    rect_part = wall & ~hero

    print("fitting the 747 hull (curved airframe)...")
    discs = fit_terrain(hero_part, SPEC, max_discs=200, min_radius=3,
                        overreach=3)

    print("decomposing the concourse to exact rects...")
    srects = exact_rects(rect_part)
    print(f"  {len(srects)} exact rects")
    rect_structs = [("concourse", x, y, w, h) for x, y, w, h in srects]

    print("verifying the SHIPPED raster:")
    ship_verify(SPEC, discs, rect_structs, [], LANDMARKS)

    emit(SPEC, discs, rect_structs, [], "/tmp/terminal_v2_shapes.nim",
         "TERMINAL v2: 747 hull fitted, concourse exact from the composite")
    print(f"final homes: red {SPEC.red_home}, blue {SPEC.blue_home}")


if __name__ == "__main__":
    main()
