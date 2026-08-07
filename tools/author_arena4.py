#!/usr/bin/env python3
"""Authors `arena4` — the hand-built 4-team control — as a mapSpec JSON.

WHY A SCRIPT AND NOT A HAND-TYPED .json: the committed artefact is the .json
(that is what `map_eval` and the sim load). This file is the AUTHORING INTENT
behind it, kept so the board can be re-tuned rather than re-typed, and so the
one measurement that drove every placement stays attached to the placements.

=== THE MEASUREMENT THIS BOARD IS BUILT FROM ===
`docs/plans/2026-08-06-what-the-cover-is-made-of.md` bucketed every obstacle on
the hand-authored 2-team arena by its bounding box's long side:

    arena       35 shapes   cover 167pm   interiorFrac 0.342
      34-68px   31 shapes = 88.6% of shapes and 98.2% of FOOTPRINT
      >=120px    0 shapes

The generator's 4-team boards spend a NEARLY IDENTICAL cover budget (153pm)
across 3441 shapes per board and score 0.280. Enclosure is not bought with
mass — a 120px+ lump is mostly its own interior. It is bought by ARRANGEMENT
at body scale. So every shape here is 34-68px, there are ~20 of them in the
fundamental domain (the arena's shape DENSITY, scaled by area), and they are
arranged in five staggered ranks stepping out from each base toward the center.

=== WHAT rot90 COSTS AND GIVES ===
A 4-team board is `layoutCorners` + `symRot90`, and rot90 replicates ONE
QUADRANT: `leftObstacles` is a quarter of the board, so this authors ~21 shapes
and the sim expands them to ~84. The board must be SQUARE (validateMap raises
otherwise) and cannot carry trenches (`raiseAssert "trenches never place on
rot90 maps"`).

=== THE ONE DESIGN CHOICE WORTH ARGUING ABOUT: D4, NOT JUST rot90 ===
Every shape authored off the quadrant's main diagonal is emitted WITH ITS
TRANSPOSE. Transpose is a reflection about the board's main diagonal, and it
generates full D4 (dihedral, order 8) together with rot90's C4. The engine only
REQUIRES C4. Taking D4 buys a fairness property C4 does not:

  under C4 alone, a team's route to its clockwise neighbour and its route to
  its anticlockwise neighbour are DIFFERENT terrain. Under D4 they are mirror
  images. Since the baseline bot's raid target is chosen by largest horizontal
  offset (see `docs/plans/` writeup for this board), which of a team's two
  lateral neighbours it picks is decided by a TIE — so under C4 the tie-break
  would silently hand every team a different-quality approach.

The engine's spawn pockets are 70x130 — taller than wide, and rotated on odd
quarters — so the POCKETS are only C4-symmetric. The TERRAIN authored here is
D4. That asymmetry is the engine's, and is stated rather than papered over.

Usage:  python3 tools/author_arena4.py -o maps/arena4.json
        (base scalars come from `mapkit generate --seed 1007`, so this board's
         anchors, zones, ring and med-kits are IDENTICAL to the gen:1007
         reference point and the only difference measured is the TERRAIN.)
"""
import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

SIDE = 960                    # square, as rot90 requires
QUAD = SIDE // 2              # the fundamental domain is [0, 479]^2
CENTER = (SIDE - 1) / 2.0     # 479.5 — the TRUE rot90 axis, not width div 2
BORDER = 10                   # ArenaBorder
CORNER_CLEAR = 210            # captureClear: [0,210)^2 is protected floor
FLAG_RING = 70                # protected plaza around the board center
SPIN_BAND = 80                # a diamond within this of an axis becomes ANIMATED

# The size palette. Every entry's bounding-box long side is in [34, 68] — the
# arena's only populated bucket. 34px is one drawn cog body (below it a shape
# cannot hide anyone); 68px is two abreast (RecommendedCorridorWidthPx).
RECT = "rect"
DISC = "disc"
DIAM = "diamond"


def shape(kind, x, y, a, b=None):
    """One shape centered on (x, y). `a` is the long side (rect w / 2r+1)."""
    if kind == RECT:
        w, h = a, (b if b is not None else a)
        return dict(kind=RECT, x=x - w // 2, y=y - h // 2, w=w, h=h)
    r = (a - 1) // 2
    return dict(kind=kind, cx=x, cy=y, r=r)


# === THE QUADRANT ===========================================================
# Authored in the fundamental domain [0,479]^2, which is RED's quadrant: its
# base anchor is (144,144) and its pedestal stands there. Entries with
# `pair=True` are emitted with their transpose too (see D4 above); entries on
# the diagonal are their own transpose and are emitted once.
#
# The ranks step OUT from the corner base toward the board center. They are
# staggered against each other — a shape in rank N sits over the GAP in rank
# N-1 — which is the arena's five-staggered-columns idea carried onto a
# quadrant. Gaps are one to two body widths, so a lane always exists but never
# a straight one.
# --- THE CHEVRON: what actually closes the sightline rule -------------------
# `collectMapDiagnostics` rejects any row between the capture columns with no
# always-wall pixel in it. On a MIRROR board the arena satisfies this for free:
# its five columns each span the full height, so one column blocks every row.
# A quadrant has no such column, and the first three drafts of this board each
# failed on a different single row (y=85, then y=102) — a whack-a-mole that
# `tools/arena4_rows.py` exists to end.
#
# The rule that ends it, derived rather than guessed. Take one quadrant entry
# centered at (a, b) with half-extent r. Its four rot90 images put wall into
# rows [b-r, b+r] at columns near a, and into rows [a-r, a+r] at columns near
# 959-b. The scan only looks at columns 215..745, so:
#
#   THE ENTRY CLOSES ROWS [a-r, a+r]  IFF  b + r >= 215
#   THE ENTRY CLOSES ROWS [b-r, b+r]  IFF  a + r >= 215
#
# and the transpose, emitted automatically, closes exactly the same two bands.
# The consequence that shapes the list below: an entry with BOTH coordinates
# past ~193 closes TWO bands for two shapes, while an entry hugging an edge
# closes only ONE — its own — because its images never reach the scan band.
# Cover is capped at 170pm, so which entries buy two bands and which buy one is
# the whole budget question.
#
# Eleven 45px bands tile rows 15..479; the rot180 images cover 480..944. Four
# edge entries take the low bands one apiece, three interior pairs and one
# diagonal entry take the remaining seven. Diamonds and discs are chosen on
# purpose over rects: they buy the widest extent per pixel of the cover ceiling.
# The corollary that decides WHERE the band-closing shapes go, and it is not
# where the first draft put them. An entry hugging an edge (partner < 193)
# closes the band at its SMALL coordinate only. So four entries out in the top
# strip at four different heights take the four low bands, and the interior
# entries — both coordinates past 193 — take two bands each. Putting them all
# on the anti-diagonal instead, as the first draft did, satisfied the rule and
# produced a sealed donut with four empty quadrants: see the render note in
# docs/plans. Bands are a CONSTRAINT here, not the layout.
# A DIAMOND TAPERS, and that cost two drafts. At row y a diamond centered on
# (a, b) only spans x = a +/- (r - |y - b|), so it reaches the scan band across
# its WHOLE band only when a >= 215 — at the band's edges it is a point. Same
# for a disc. A rect does not taper, but buys far fewer rows per pixel of
# cover. Cost per closed row, measured off this palette:
#
#     diamond pair, both coords past 215   21.5 px/row   <- use this
#     disc pair, same                      33.8 px/row   <- forced in the spin band
#     rect pair                            45.0 px/row
#
# so the board is diamonds wherever the spin band allows, discs where it does
# not, and the 170pm ceiling is what makes that difference matter.
CHEVRON = [
    # --- the four LOW bands. A band below 215 cannot be paired with another
    # band (its partner would have to reach the scan band and does not), so
    # each takes one entry. They are spread along the RAID LANE — the top strip
    # between two corner boxes, which is where the bot's target rule sends
    # everyone — at four increasing depths, and their transposes furnish the
    # left strip identically.
    ("chevron", shape(DIAM, 250, 37, 53), True),     # rows 11..63
    ("chevron", shape(DIAM, 300, 89, 53), True),     # rows 63..115
    ("chevron", shape(DIAM, 350, 141, 53), True),    # rows 115..167
    ("chevron", shape(DIAM, 390, 193, 53), True),    # rows 167..219
    # --- the interior entries. Both coordinates clear 215, so each closes the
    # band at BOTH of them. Coordinates inside 399.5..559.5 are the spin band
    # and must not be diamonds — a diamond there becomes an ANIMATED obstacle.
    #
    # These also stay CLEAR OF THE CENTER PLAZA. An earlier draft put the
    # near-center entries at x ~ 420, inside the 70px protected ring, which
    # carved most of each shape away and sealed the four mouths into the middle
    # — the board failed "no 26px route to the center". Keeping the low
    # coordinate under 385 puts every shape outside the plaza.
    ("chevron", shape(DISC, 225, 457, 45), True),    # rows 435..479 + 203..247
    ("chevron", shape(DIAM, 262, 397, 45), True),    # rows 375..419 + 240..284
    ("chevron", shape(DISC, 307, 437, 45), True),    # rows 415..459 + 285..329
    ("chevron", shape(DIAM, 352, 352, 45), False),   # rows 330..374, diagonal
]

# --- THE TERRAIN: the rest of the cover budget, spent on PLAY ---------------
# The chevron satisfies the rule; it does not by itself make a board.
TERRAIN = [
    # Far end of the raid lane, where the approach to the NEXT team's corner
    # box opens out. Disc, not diamond: 430 is inside the spin band.
    ("gatehouse", shape(DISC, 430, 100, 49), True),
    # Mid-quadrant. Red's pedestal sits at (144,144) inside a 210x210 protected
    # corner plaza that can hold no wall at all, so the nearest cover to any
    # pedestal is necessarily just outside that box — this is it.
    ("ward", shape(DIAM, 250, 300, 53), True),
]

QUADRANT = CHEVRON + TERRAIN


def transpose(s):
    """Reflection about the quadrant's main diagonal: (x, y) -> (y, x)."""
    t = dict(s)
    if s["kind"] == RECT:
        t["x"], t["y"] = s["y"], s["x"]
        t["w"], t["h"] = s["h"], s["w"]
    else:
        t["cx"], t["cy"] = s["cy"], s["cx"]
    return t


def bbox(s):
    if s["kind"] == RECT:
        return s["x"], s["y"], s["w"], s["h"]
    r = s["r"]
    return s["cx"] - r, s["cy"] - r, 2 * r + 1, 2 * r + 1


def audit(shapes):
    """Every rule this board claims to obey, checked rather than asserted."""
    bad = []
    for name, s in shapes:
        x, y, w, h = bbox(s)
        long_side = max(w, h)
        if not (34 <= long_side <= 68):
            bad.append(f"{name}: long side {long_side}px is outside 34-68")
        if x < BORDER or y < BORDER or x + w > QUAD + 1 or y + h > QUAD + 1:
            bad.append(f"{name}: bbox ({x},{y},{w},{h}) leaves the quadrant")
        cx, cy = x + w / 2, y + h / 2
        if s["kind"] == DIAM and (abs(cx - CENTER) < SPIN_BAND
                                  or abs(cy - CENTER) < SPIN_BAND):
            bad.append(f"{name}: diamond at ({cx},{cy}) would ANIMATE (spin band)")
        # Wholly inside protected floor = a shape that draws nothing.
        if x + w <= CORNER_CLEAR and y + h <= CORNER_CLEAR:
            bad.append(f"{name}: entirely inside the protected corner box")
        d = math.hypot(cx - CENTER, cy - CENTER)
        if d + max(w, h) / 2 <= FLAG_RING:
            bad.append(f"{name}: entirely inside the center flag ring")
    return bad


def build():
    out = []
    for name, s, paired in QUADRANT:
        out.append((name, s))
        if paired:
            out.append((name + "'", transpose(s)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--base", default="/tmp/ctf4ctl/base1007.json",
                    help="mapkit-generated spec supplying the scalar fields")
    args = ap.parse_args()

    shapes = build()
    problems = audit(shapes)
    if problems:
        for p in problems:
            print("AUDIT FAIL:", p, file=sys.stderr)
        raise SystemExit(1)

    spec = json.loads(Path(args.base).read_text())
    # Everything except the terrain is inherited from the gen:1007 base so the
    # play comparison against it is a pure TERRAIN comparison: same anchors,
    # same capture zones, same ring, same med-kits, same size.
    spec["name"] = "arena4"
    spec["genSeed"] = 0          # hand-authored: no seed reproduces this board
    spec["trenches"] = []        # rot90 boards never carry trenches
    spec["leftObstacles"] = [s for _, s in shapes]

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(spec, indent=1) + "\n")

    sides = sorted(max(bbox(s)[2], bbox(s)[3]) for _, s in shapes)
    area = sum(bbox(s)[2] * bbox(s)[3] for _, s in shapes)
    print(f"arena4: {len(shapes)} shapes in the quadrant "
          f"-> {len(shapes) * 4} on the board")
    print(f"  long side  min {sides[0]}  median {sides[len(sides)//2]}  "
          f"max {sides[-1]}   (arena's only bucket is 34-68)")
    print(f"  quadrant bbox footprint {area}px = "
          f"{1000 * area // (QUAD * QUAD)}pm of the quadrant (pre-carve)")
    print(f"  wrote {args.out}")


if __name__ == "__main__":
    main()
