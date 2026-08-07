#!/usr/bin/env python3
"""Authoring aid for `arena4`: which rows have an OPEN horizontal sightline.

`mapkit validate` stops at the FIRST failing row, so tuning against it is one
round trip per row. This rasterises the same rule over the whole board and
prints every open row at once, plus the widest open run in each, so a rank can
be placed where it actually closes something.

The rule, from `collectMapDiagnostics` in src/ctf/arena.nim: for every row
y in [ArenaBorder + MinCorridorWidth/2, h - that), at least one pixel in
x = [sightlineLoX, sightlineHiX] must be always-wall. Protected floor is NOT
wall — it carves any shape drawn over it.

Usage:  python3 tools/arena4_rows.py maps/arena4.json
"""
import json
import sys

import numpy as np

BORDER = 10
MIN_CORRIDOR = 26
SPAWN_W, SPAWN_H = 70, 130


def rot90_shape(s, side):
    """One quarter turn clockwise, matching arena.nim's rot90 exactly."""
    if s["kind"] == "rect":
        return dict(kind="rect", x=side - s["y"] - s["h"], y=s["x"],
                    w=s["h"], h=s["w"])
    return dict(kind=s["kind"], cx=side - 1 - s["cy"], cy=s["cx"], r=s["r"])


def main():
    spec = json.loads(open(sys.argv[1]).read())
    side = spec["width"]
    clear = spec["captureClear"]
    ring = spec["flagRing"]
    depth = spec["homeDepth"]
    c = side // 2
    lo, hi = clear + 5, side - clear - 5

    ys, xs = np.mgrid[0:side, 0:side]

    # --- walls: every seed shape and its three rot90 images -----------------
    wall = np.zeros((side, side), bool)
    n = 0
    for seed in spec["leftObstacles"]:
        s = dict(seed)
        for _ in range(4):
            if s["kind"] == "rect":
                wall[s["y"]:s["y"] + s["h"], s["x"]:s["x"] + s["w"]] = True
            elif s["kind"] == "disc":
                wall |= ((xs - s["cx"]) ** 2 + (ys - s["cy"]) ** 2
                         <= s["r"] ** 2)
            else:
                wall |= (np.abs(xs - s["cx"]) + np.abs(ys - s["cy"]) <= s["r"])
            n += 1
            s = rot90_shape(s, side)

    # --- protected floor carves walls (mapProtectedFloorAt, ezColumn) -------
    prot = np.zeros((side, side), bool)
    near_x = (xs < clear) | (xs >= side - clear)
    near_y = (ys < clear) | (ys >= side - clear)
    prot |= near_x & near_y                                  # corner approach
    dx2, dy2 = 2 * xs - (side - 1), 2 * ys - (side - 1)
    prot |= (dx2 ** 2 + dy2 ** 2) <= 4 * ring * ring          # center plaza
    a = c - (c * depth // 1000)                               # axisHomeLo
    b = side - a                                              # axisHomeHi
    for (ax, ay, q) in ((a, a, 0), (b, a, 1), (b, b, 2), (a, b, 3)):
        hw, hh = (SPAWN_W, SPAWN_H) if q % 2 == 0 else (SPAWN_H, SPAWN_W)
        prot |= (np.abs(xs - ax) <= hw) & (np.abs(ys - ay) <= hh)
    wall &= ~prot

    # `interiorPixels` for a corners board: inside the border, not protected.
    # This is arena.nim's own denominator, so the permille printed here is the
    # SAME number the validator bands at CoverPermilleMin/Max = 40/170.
    inside = ((xs >= BORDER) & (xs < side - BORDER)
              & (ys >= BORDER) & (ys < side - BORDER))
    interior = inside & ~prot
    cover_pm = int(wall[interior].sum()) * 1000 // max(1, int(interior.sum()))

    first = BORDER + MIN_CORRIDOR // 2
    band = wall[:, lo:hi + 1]
    open_rows = [y for y in range(first, side - first) if not band[y].any()]

    print(f"{sys.argv[1]}: {n} expanded shapes, band x={lo}..{hi}, "
          f"rows {first}..{side - first - 1}")
    print(f"COVER {cover_pm}pm of non-protected interior "
          f"(band 40..170; the hand-authored arena is 167)")
    if not open_rows:
        print("NO OPEN ROWS — every row is blocked inside the band.")
        return
    # Contiguous groups of open rows are what an author places against.
    groups, run = [], [open_rows[0]]
    for y in open_rows[1:]:
        (run if y == run[-1] + 1 else groups).append(y) if y == run[-1] + 1 \
            else (groups.append(run), run := [y])
    groups.append(run)
    print(f"{len(open_rows)} OPEN ROWS in {len(groups)} band(s):")
    for g in groups:
        row = band[g[len(g) // 2]]
        gap = (~row).astype(int)
        print(f"  y {g[0]}..{g[-1]}  ({len(g)} rows)  "
              f"widest open run {gap.sum()}px of {len(row)}px band")


if __name__ == "__main__":
    main()
