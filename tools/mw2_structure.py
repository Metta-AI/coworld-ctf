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
    """Connected wall components, 8-connected so a diagonal corner is one wall.

    Returns (areas, extents) with the map's border frame dropped. Both are
    needed: AREA alone badly misjudges architecture, because a building is
    often a thin shell. Terminal's concourse wall is 268x22 — unmistakably
    building-scale, and only 5.9k px², which ranked it below a solid 80px
    blob. Judge footprint by bounding box and mass by area.
    """
    lab, n = ndimage.label(wall, structure=np.ones((3, 3), bool))
    if not n:
        return np.array([]), []
    sizes = np.bincount(lab.ravel())[1:]
    border = int(sizes.argmax())          # the map's own border frame

    # Footprints are reported from RAW components, with the caveat that a
    # shell pierced by doorways reads as several arcs — Favela's yellow
    # building (walls on four sides around a real room) scores as 46x40,
    # 58x61 and 164x53 rather than one 138x125 structure.
    #
    # Morphological closing to bridge the doors was tried and is worse: at the
    # 40px needed to span a doorway it also merges the abstract arena's picket
    # columns, which sit ~48px apart, into one 328x620 slab. That reported the
    # CONTROL as the most architectural map in the set, which is the usual
    # sign the metric has stopped measuring the thing. Doorway width and
    # picket spacing are too close to separate by morphology, so footprints
    # are a rough guide here and `interior` below is the number to trust.
    extents = []
    for i, sl in enumerate(ndimage.find_objects(lab)):
        if i == border or sl is None:
            continue
        extents.append((sl[1].stop - sl[1].start, sl[0].stop - sl[0].start,
                        int(sizes[i])))
    extents.sort(key=lambda e: max(e[0], e[1]), reverse=True)
    return np.delete(sizes, border), extents


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
    body, extents = structures(wall)
    body = np.sort(body)[::-1]
    score, open_ = enclosure(wall)
    floor = int(open_.sum())
    interior = float((score[open_] >= 6).mean())
    covered = float((score[open_] >= 3).mean())
    exposed = float((score[open_] <= 1).mean())
    total_wall = int(body.sum())
    top5 = float(body[:5].sum() / total_wall) if total_wall else 0.0
    top3 = " ".join(f"{e[0]}x{e[1]}" for e in extents[:3]) or "-"
    span = max((max(e[0], e[1]) for e in extents), default=0)
    print(f"{name:<11} structures {len(body):>3}  median "
          f"{int(np.median(body)) if len(body) else 0:>5}px²  "
          f"biggest footprints {top3:<24}"
          f"|  interior {interior:>5.1%}   wide open {exposed:>5.1%}")
    return dict(name=name, structures=len(body),
                median=int(np.median(body)) if len(body) else 0,
                span=span, top5=top5, interior=interior,
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
    print(f"\ninterior is the number to trust: the arena scores "
          f"{ctrl['interior']:.0%} and is deliberately scatter, so a "
          "recreation should sit clearly above it.")


if __name__ == "__main__":
    main()
