#!/usr/bin/env python3
"""Replaces Afghan's propped-structure collision RECTS with silhouette fits.

Owner: "don't make collision rectangles on the ground. the object is the
collision mask." A rect under a sprite shows its carve-stone corners wherever
the organic render doesn't cover it, and the board reads as boxes with
pictures on top. For every structure that wears a prop, collision now comes
FROM the render's alpha silhouette via tools/mw2_fit_collision.py (maximal
inscribed discs, <= 4px overreach), so the visible object and the wall are
the same shape. Architecture with no prop art (the bunker's room divider)
keeps its rect — bevel stone IS its look.

Prints the replacement Nim lines; the integrator splices them over the
matching rect lines in AfghanObstacles.
"""
import sys

sys.path.insert(0, "tools")
import mw2_fit_collision as fit          # noqa: E402

# (sprite, cx, cy, w, h, rot, replaces-comment) — placements MATCH the
# PropSprite lines in afghanCtfMap(); the comment names the rect block in
# AfghanObstacles being replaced.
JOBS = [
    ("c130_nose", 713, 474, 69, 99, 0, "c130 nose section"),
    ("c130_mid", 635, 621, 111, 108, 0, "c130 mid fuselage + wing box"),
    ("c130_tail", 677, 770, 21, 87, 0, "c130 tail cone"),
    ("c130_fin", 594, 789, 81, 123, 0, "c130 tail fin fallen"),
    ("burnt_tank", 1049, 304, 42, 57, 90, "burnt tank"),
    ("crate", 882, 292, 54, 27, 0, "crates row"),
    ("crate", 675, 1096, 66, 45, 0, "sandbag V wadi"),
    ("crate", 799, 1035, 33, 48, 0, "sandbag T wadi"),
    ("crate", 772, 1120, 45, 21, 0, "sandbag rect wadi"),
    ("crate", 672, 1174, 54, 39, 0, "sandbag T south"),
    # the two forward-fragment / cargo crates of the wreck
    ("crate", 594, 469, 30, 51, 0, "c130 forward fragment"),
    ("crate", 616, 540, 27, 30, 0, "c130 cargo debris"),
]


def main():
    out = []
    for name, cx, cy, w, h, rot, label in JOBS:
        placement = dict(png=f"data/props/{name}.png", x=cx, y=cy,
                         w=w, h=h, rot=rot, label=label)
        discs, report = fit.process_placement(placement, ".")
        print(f"# {label}: {report}", file=sys.stderr)
        out.append(f"    # {label} (collision fitted to the sprite)")
        for dcx, dcy, r in discs:
            out.append(f"    ArenaShape(kind: shapeDisc, cx: {dcx}, "
                       f"cy: {dcy}, radius: {r}),")
    print("\n".join(out))


if __name__ == "__main__":
    main()
