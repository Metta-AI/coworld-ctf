#!/usr/bin/env python3
"""Emits ORGANIC rock terrain as ArenaShape lines for the MW2 pack.

Maxwell, on Afghan: *"this is the worst looking map but one of the coolest
with rock caves and stuff. we need to implement the coolness from afghan.
mountains, caves, etc...not blocky randomness"* — and the reference bears it
out. Real Afghan is a valley of irregular rock masses and cave mouths; ours
was rectangles, diamonds and discs sprinkled across sand.

The engine's shape vocabulary is rect / disc / diamond / diagonal, so an
organic silhouette has to be BUILT rather than declared: a chain of discs of
varying radius, walked along a spine with the centres jittered off it, unions
into a single lumpy mass whose outline never repeats. That is what a rock
massif is here, and the same routine walked as two near-parallel spines with
a gap between them is a cave.

Determinism matters — this emits source that gets committed, so the same call
must produce the same rock forever. Everything is seeded and no global RNG is
touched.

Usage: python3 tools/mw2_terrain.py > /tmp/afghan_terrain.nim
"""
import math
import random


def massif(spine, seed, r_lo=22, r_hi=40, step=26, jitter=10):
    """A lumpy rock mass along a polyline spine.

    Discs are spaced closer than their radii so the union is solid, and both
    radius and centre wobble so the edge reads as rock rather than as a row
    of circles.
    """
    rng = random.Random(seed)
    out, carry = [], 0.0
    for (x0, y0), (x1, y1) in zip(spine, spine[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg < 1e-6:
            continue
        ux, uy = (x1 - x0) / seg, (y1 - y0) / seg
        d = carry
        while d < seg:
            t = d / seg
            cx = x0 + (x1 - x0) * t + rng.uniform(-jitter, jitter)
            cy = y0 + (y1 - y0) * t + rng.uniform(-jitter, jitter)
            r = rng.randint(r_lo, r_hi)
            out.append((int(round(cx)), int(round(cy)), r))
            d += step * rng.uniform(0.8, 1.2)
        carry = d - seg
    return out


def nim(discs, comment):
    lines = [f"    # {comment}"]
    for cx, cy, r in discs:
        lines.append(f"    ArenaShape(kind: shapeDisc, cx: {cx}, cy: {cy}, "
                     f"radius: {r}),")
    return lines


# --- Afghan -----------------------------------------------------------------
# Laid out against the engine's forced-floor regions: x < 96 and x > 1139 are
# carved open, the flag ring is r70 at (617, 329), and each spawn pocket is
# |x - homeX| <= 70 / |y - homeY| <= 130 around (186, 329) and (1049, 329).
#
# THE CAVE. A corridor at y 58-100 running most of the map's width would be a
# clean cross-field firing row, which the invariant suite rejects outright, so
# the passage WINDS: fingers of rock reach down from the north mass and up
# from the south one, alternating, leaving an 18px walkable weave with no
# straight line down it. A player is 13px.
#
# The two walls have to be pushed properly apart or the massifs simply meet:
# the first attempt put the north spine at y 24-38 with radii to 44 (bottom
# edge ~82) and the south at y 124-138 with radii to 40 (top edge ~84), so the
# "corridor" was two rock masses touching and the invariant suite reported
# 9153 cells sealed into it. North bottom now lands ~54 and south top ~106.
CAVE_N = [(96, 22), (300, 18), (560, 26), (820, 16), (1139, 24)]
# Four segments, not one run: the gaps BETWEEN them are the cave mouths, and
# they have to be wide enough to survive the discs at each end reaching into
# them (~34px of radius a side), hence 140px of spine gap for a ~60px mouth.
CAVE_S = [
    [(150, 140), (290, 146)],
    [(430, 138), (560, 144)],
    [(700, 140), (840, 146)],
    [(980, 142), (1090, 138)],
]

# Fingers: alternating intrusions that break the sightline down the passage
# without closing it. Corridor runs y 54-106; a top finger bottoms out at 86
# and a bottom finger tops out at 74, so every crossing leaves 20px and a
# 13px player weaves through where a bullet cannot.
FINGERS = [(x, 60 if i % 2 == 0 else 100) for i, x in
           enumerate(range(230, 1020, 118))]

# The central massif — the big irregular plateau the reference has in the
# middle of the valley, kept clear of the flag ring.
CENTRE_N = [(452, 214), (556, 196), (668, 202), (772, 220)]
CENTRE_S = [(470, 452), (580, 470), (700, 464), (800, 444)]

# South wall of the valley, broken so the wadi still runs through it.
# Pulled well north of the border. At y 590-612 with radii to 38 these ran
# into the map frame and pinned 2700 cells of floor into slivers behind them.
SOUTH_W = [(150, 566), (300, 550), (398, 572)]
SOUTH_E = [(830, 566), (960, 548), (1090, 572)]


def afghan():
    out = []
    out += nim(massif(CAVE_N, 11, 20, 32, 26, 9),
               "cave system: the north rock wall along the ridge")
    for i, seg in enumerate(CAVE_S):
        out += nim(massif(seg, 12 + i, 22, 30, 26, 9),
                   f"cave system: south wall {i + 1} of 4 (the gaps between "
                   "these are the cave mouths)")
    fing = []
    for i, (x, y) in enumerate(FINGERS):
        rng = random.Random(400 + i)
        fing.append((x, y, 26))
        fing.append((x + rng.randint(-9, 9), y + (-18 if i % 2 == 0 else 18),
                     rng.randint(16, 22)))
    out += nim(fing, "cave fingers: the weave that stops it being a firing row")
    out += nim(massif(CENTRE_N, 21, 22, 34, 28, 10),
               "central massif, north face")
    out += nim(massif(CENTRE_S, 22, 22, 34, 28, 10),
               "central massif, south face")
    out += nim(massif(SOUTH_W, 31, 24, 38, 30, 11), "south valley wall, west")
    out += nim(massif(SOUTH_E, 32, 24, 38, 30, 11), "south valley wall, east")
    return out


if __name__ == "__main__":
    lines = afghan()
    print("\n".join(lines))
    print(f"# {sum(1 for l in lines if 'ArenaShape' in l)} shapes")


def seal_pass(mask_path, out_path):
    """Fills any pocket the terrain leaves too small to reach, with rock.

    Hand-tuning spine positions to avoid sealed pockets does not converge —
    lifting the cave's south wall to clear one sliver pushed its fingers into
    the wall and turned 391 stranded cells into 2043. The pockets are a
    rasterisation outcome, not a design decision, so they are solved on the
    raster: erode the free space by the player box, find every region that
    cannot reach the largest one, and cover it with discs. A gap too narrow
    for anyone to stand in is rock, and saying so explicitly is both honest
    and stable.

    Run AFTER splicing, against the mask tools/mw2_structure.nim writes.
    """
    import numpy as np
    from scipy import ndimage
    txt = open(mask_path).read().split("\n")
    w, h = (int(v) for v in txt[1].split())
    rows = [r for r in txt[2:] if r]
    wall = np.array([[c == "1" for c in r] for r in rows[:h]], bool)
    fits = ndimage.binary_erosion(~wall, np.ones((13, 13), bool))
    lab, n = ndimage.label(fits)
    if n <= 1:
        open(out_path, "w").write("")
        return 0
    sizes = np.bincount(lab.ravel())[1:]
    main = int(sizes.argmax()) + 1
    fills = []
    for i, sl in enumerate(ndimage.find_objects(lab), start=1):
        if i == main or sl is None:
            continue
        # Cover the pocket generously: it is measured on the eroded raster, so
        # the real floor it represents is a player-box wider on every side.
        y0, y1 = sl[0].start - 8, sl[0].stop + 8
        x0, x1 = sl[1].start - 8, sl[1].stop + 8
        step = 22
        for cy in range(y0, y1 + step, step):
            for cx in range(x0, x1 + step, step):
                fills.append((cx, cy, 18))
    open(out_path, "w").write("\n".join(nim(fills, "pockets the terrain left "
                                            "too small to stand in, filled")))
    return len(fills)
