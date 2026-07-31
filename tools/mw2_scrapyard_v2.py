#!/usr/bin/env python3
"""Builds Scrapyard v2 from the measured plan (docs/designs/
scrapyard-layout-v2.md), pipeline per tools/mw2_build_lib.py.

Scrapyard's particulars:
  * boundary (fence band + rubble), airframes (the Row) and scrap piles are
    ORGANIC — disc-fitted. The airframe hulls will wear cut-fuselage sprites
    in the dressing pass; fitted discs already carry their measured
    silhouettes, so the no-rects rule holds from day one;
  * buildings (Depot, Workshop, sheds, Warehouse, Hangar — doors pre-carved
    in the mask) decompose to EXACT rects: rectilinear steel architecture,
    carve-stone base is its intended look until the dressing pass;
  * landmarks cover all thirteen interiors/courts from the plan's audit.

Usage: python3 tools/mw2_scrapyard_v2.py
Emits /tmp/scrapyard_v2_shapes.nim + preview.
"""
import sys

import numpy as np

sys.path.insert(0, "tools")
from mw2_build_lib import (MapSpec, load_masks, fit_terrain, ship_verify,  # noqa: E402
                           emit, seal_pockets)
from mw2_rust_v2 import exact_rects  # noqa: E402  (same greedy decomposition)

SPEC = MapSpec(
    name="scrapyard", w=1235, h=727,
    red_home=(257, 345), blue_home=(978, 381),
    spawn_w=70, spawn_h=85, carve_clear=-1,
    mask_dir="docs/designs/mw2-reference/scrapyard-v2-masks",
    # Plan section 5: if red measures long, nudge redHome to (262, 350);
    # never move blue -- its pocket sits 3px off the hangar piers.
    nudge_home="red", nudge_to=(262, 350),
)

LANDMARKS = {
    "blueHome": (978, 381),
    "medkit warehouse": (580, 610),
    "medkit G1 cut": (455, 108),
    "Depot interior": (75, 348),
    "Workshop": (348, 108),
    "North Shed mouth": (625, 150),
    "Crossroads": (617, 363),
    "Wing bay": (510, 380),
    "Long Shed": (800, 421),
    "Cutting Shed": (378, 398),
    "Warehouse": (580, 615),
    "Hangar": (1135, 337),
    "MG nest court": (996, 264),
    "SE container court": (778, 636),
}


def main():
    print("loading measured masks...")
    organic = load_masks(SPEC, ["boundary", "airframes", "scrap"])
    buildings = load_masks(SPEC, ["buildings"])

    wall = organic | buildings
    wall = seal_pockets(wall, SPEC)
    organic = wall & ~buildings

    print("fitting organic masses (fence, airframes, scrap)...")
    discs = fit_terrain(organic, SPEC, max_discs=900)

    print("decomposing buildings to exact rects...")
    srects = exact_rects(buildings)
    print(f"  {len(srects)} exact rects")
    rect_structs = [("building", x, y, w, h) for x, y, w, h in srects]

    print("verifying the SHIPPED raster:")
    ship_verify(SPEC, discs, rect_structs, [], LANDMARKS)

    emit(SPEC, discs, rect_structs, [], "/tmp/scrapyard_v2_shapes.nim",
         "SCRAPYARD v2: organic masses fitted, buildings exact from the mask")
    print(f"final homes: red {SPEC.red_home}, blue {SPEC.blue_home}")


if __name__ == "__main__":
    main()
