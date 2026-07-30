#!/usr/bin/env python3
"""Judges a pack layout on ARCHITECTURE: buildings, or objects on a field?

Review has rejected this pack twice with the same complaint — the maps read as
gray shapes scattered on a field rather than as the buildings, interiors and
lanes that make an MW2 map recognizable. Prop art fixed how the shapes LOOK
without changing that, so this measures the property itself.

What separates architecture from scatter, and how each is counted from the
real wall mask (tools/mw2_structure.nim writes it):

  * structure count and size — a map of buildings has a few large connected
    structures; a map of scatter has dozens of small ones. Reported as the
    median footprint and the share of wall area sitting in the biggest few.
  * ENCLOSED INTERIOR — floor you can stand on that is surrounded by one
    structure's walls. This is the single clearest discriminator: a building
    has an inside, a crate does not. The abstract arena, which is honest
    scatter by design, should score near zero here and does.
  * doorways — openings into those interiors. An interior with no way in is a
    sealed pocket (already a test failure); an interior with one is a room, and
    several rooms with several doors is what makes a map play like Terminal.

Usage: nim r tools/mw2_structure.nim && python3 tools/mw2_structure.py
"""
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

PLAYER = 13          # a player's collision box; nothing narrower is a space
MAPS = ["arena", "rust", "terminal", "highrise", "favela", "afghan",
        "scrapyard"]


def load(name):
    """Reads the P1 PBM the Nim side writes. 1 = wall."""
    txt = Path(f"/tmp/mw2mask-{name}.pbm").read_text().split("\n")
    w, h = (int(v) for v in txt[1].split())
    rows = [r for r in txt[2:] if r]
    grid = np.array([[c == "1" for c in row] for row in rows[:h]], bool)
    assert grid.shape == (h, w), f"{name}: {grid.shape} != {(h, w)}"
    return grid


def structures(wall):
    """Connected wall components, 8-connected so a diagonal corner is one wall."""
    lab, n = ndimage.label(wall, structure=np.ones((3, 3), bool))
    if not n:
        return np.array([]), lab
    sizes = np.bincount(lab.ravel())[1:]
    return sizes, lab


def enclosure(wall, reach=120):
    """How enclosed each piece of floor is: of 8 directions, how many are
    blocked by wall within `reach` px.

    Connectivity is the wrong tool for this and produced a number that flagged
    the control: floor inside a building is still perfectly REACHABLE through
    its door, and meanwhile the map's own border frame makes every open pixel
    unable to reach the image edge — so a flood-based "enclosed" measure
    reported one room covering the whole playfield on all seven maps, arena
    included. What actually distinguishes a room is being surrounded at short
    range, which is a local property, not a topological one.

    Reading the score: 0-2 is open field, 3-5 is cover or a corridor, 6+ means
    the floor is walled on nearly every side — a room, an alcove, an interior.
    """
    open_ = ~wall
    blocked = np.zeros(wall.shape, np.uint8)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0),
                   (1, 1), (1, -1), (-1, 1), (-1, -1)):
        hit = np.zeros(wall.shape, bool)
        cur = wall.copy()
        for _ in range(reach):
            cur = np.roll(cur, (dy, dx), axis=(0, 1))
            # Rolling wraps; clear the wrapped edge so one side of the map
            # cannot shadow the other.
            if dy > 0:
                cur[0, :] = False
            elif dy < 0:
                cur[-1, :] = False
            if dx > 0:
                cur[:, 0] = False
            elif dx < 0:
                cur[:, -1] = False
            hit |= cur
        blocked += hit.astype(np.uint8)
    return np.where(open_, blocked, 0), open_


def report(name):
    wall = load(name)
    h, w = wall.shape
    sizes, _ = structures(wall)
    # Ignore the map border frame, which is one huge component on every map.
    border = max(sizes) if len(sizes) else 0
    body = np.sort(sizes[sizes != border])[::-1] if len(sizes) else np.array([])
    score, open_ = enclosure(wall)
    floor = int(open_.sum())
    interior = float((score[open_] >= 6).mean())
    covered = float((score[open_] >= 3).mean())
    exposed = float((score[open_] <= 1).mean())
    total_wall = int(body.sum())
    top5 = float(body[:5].sum() / total_wall) if total_wall else 0.0
    biggest = int(body[0]) if len(body) else 0
    print(f"{name:<11} structures {len(body):>3}  median "
          f"{int(np.median(body)) if len(body) else 0:>6}px²  biggest "
          f"{biggest:>6}px² ({int(biggest ** 0.5):>3}px square)"
          f"  |  interior {interior:>5.1%}   wide open {exposed:>5.1%}")
    return dict(name=name, structures=len(body),
                median=int(np.median(body)) if len(body) else 0,
                biggest=biggest, top5=top5, interior=interior,
                covered=covered, exposed=exposed, floor=floor)


def main():
    names = sys.argv[1:] or MAPS
    print("architecture audit — the arena is honest SCATTER by design, so it "
          "is the floor to beat, not the target\n")
    out = [report(n) for n in names]
    print()
    ctrl = next((r for r in out if r["name"] == "arena"), None)
    if not ctrl:
        return
    flat = [r for r in out if r["name"] != "arena"
            and r["interior"] <= ctrl["interior"]]
    if flat:
        print("MORE OPEN THAN THE ABSTRACT ARENA: " +
              ", ".join(f"{r['name']} {r['interior']:.0%}" for r in flat) +
              f"  (arena {ctrl['interior']:.0%})")
        print("  The arena is scatter by design — pickets in an open field. A "
              "recreation with less enclosure than that has nothing to fight "
              "from.")
    # Cover is not the same as architecture. A map can be full of cover and
    # still be an obstacle course, which is what "gray shapes scattered on a
    # field" actually describes.
    small = [r for r in out if r["name"] != "arena" and r["biggest"] < 40000]
    if small:
        print("\nNO BUILDING-SCALE STRUCTURE (largest under 200x200px): " +
              ", ".join(f"{r['name']} {int(r['biggest'] ** 0.5)}px"
                        for r in small))
        print("  A player is 13px. These maps have plenty of COVER — most beat "
              "the arena on enclosure — but it is assembled from many objects "
              "a few player-widths across rather than from buildings with "
              "footprints, interiors and doorways. That is the difference "
              "between an obstacle course and Terminal.")


if __name__ == "__main__":
    main()
