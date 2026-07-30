#!/usr/bin/env python3
"""Turns the MW2 reference minimaps into tracing plates in GAME coordinates.

Three problems stand between a 2009 minimap and an authorable layout, and this
solves all three so a feature measured on the plate converts to an ArenaShape by
reading the axes:

1. The minimaps are washed out (they render under a HUD tint), so wall outlines
   sit only a few levels above the background — fixed by a percentile stretch.
2. Most of the image is out-of-bounds terrain (sand, water, rooftops). Only the
   playable frame matters, so each map declares its frame as fractions of the
   reference; the rest is cropped away.
3. The field is 1235x659 landscape while most MW2 maps are square-ish, and CTF
   needs the two objectives at the LEFT and RIGHT ends. Each map therefore
   declares the rotation that puts its real spawn-to-spawn axis horizontal.

Outputs, per map, under docs/designs/mw2-reference/prepped/:
  <map>.png       the plate: playable frame, oriented, stretched, 1235x659
  <map>-grid.png  the same with a 100px grid labelled in MAP pixels, plus the
                  center line, the flag ring, and both spawn pockets drawn —
                  i.e. every engine-protected region an author must respect.

Usage: python3 tools/mw2_ref_prep.py [map ...]   (default: all six)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "docs/designs/mw2-reference"
OUT = REF / "prepped"

# The game field, and the regions the engine force-carves to floor. Mirrors
# sim.nim: center, flagRing 70, spawn pockets +-70x / +-130y about each home.
MAP_W, MAP_H = 1235, 659
CENTER = (MAP_W // 2, MAP_H // 2)
FLAG_RING = 70
RED_HOME_X, BLUE_HOME_X = 186, 1049
SPAWN_W, SPAWN_H = 70, 130

# Per map: the playable frame as (left, top, right, bottom) fractions of the
# reference image, and the rotation in degrees CCW applied BEFORE the frame is
# fitted to the field. Rotation is chosen so the real map's spawn-to-spawn axis
# runs left-right, because that is the axis CTF puts the two pedestals on.
PLATES = {
    # Rust: the derrick yard is a walled box in the desert; the yard wall is
    # the playable boundary. Square, so it stretches ~1.9x into the field —
    # relative positions are exact, footprints read wider than they really are.
    "rust": dict(frame=(0.275, 0.225, 0.845, 0.795), rot=0),
    # Terminal: already a long east-west concourse with the 747 at one end.
    "terminal": dict(frame=(0.020, 0.140, 0.980, 0.790), rot=0),
    # Highrise: twin office cores flank the roof NORTH-SOUTH with spawns at
    # either end -> rotate 90 so the cores face each other across the field.
    "highrise": dict(frame=(0.050, 0.270, 0.940, 0.710), rot=90),
    # Favela: the hillside block already runs east-west, spawns at either end.
    "favela": dict(frame=(0.100, 0.150, 0.900, 0.880), rot=0),
    # Afghan: TF141 spawns south, OpFor north -> rotate 90 to face off.
    "afghan": dict(frame=(0.070, 0.120, 0.920, 0.930), rot=90),
    # Scrapyard: a square yard whose hangars sit at opposite ends of the
    # north-south axis -> rotate 90 to put hangar against hangar.
    "scrapyard": dict(frame=(0.050, 0.270, 0.900, 0.770), rot=90),
}
MAPS = list(PLATES)


def stretch(gray, lo_pct=1.5, hi_pct=98.5, gamma=0.85):
    """Percentile contrast stretch — the step that makes walls visible."""
    g = gray.astype(np.float32)
    lo, hi = np.percentile(g, lo_pct), np.percentile(g, hi_pct)
    if hi - lo < 1e-3:
        return gray.astype(np.uint8)
    g = np.clip((g - lo) / (hi - lo), 0, 1) ** gamma
    return (g * 255).astype(np.uint8)


def plate(name):
    src = REF / f"{name}.png"
    if not src.exists():
        print(f"{name}: MISSING {src}")
        return
    spec = PLATES[name]
    img = Image.open(src).convert("RGB")
    if spec["rot"]:
        img = img.rotate(spec["rot"], expand=True)
    w, h = img.size
    l, t, r, b = spec["frame"]
    img = img.crop((int(l * w), int(t * h), int(r * w), int(b * h)))

    arr = np.asarray(img)
    # Structure lives in luminance and the HUD tint is a flat colour cast, so
    # plain luma is the cleanest signal to stretch.
    gray = (0.299 * arr[..., 0] + 0.587 * arr[..., 1] +
            0.114 * arr[..., 2])
    out = Image.fromarray(stretch(gray)).convert("RGB")
    # Fit the frame to the field: 1 plate pixel == 1 map pixel from here on.
    out = out.resize((MAP_W, MAP_H), Image.LANCZOS)
    OUT.mkdir(exist_ok=True)
    out.save(OUT / f"{name}.png")

    grid = out.copy()
    d = ImageDraw.Draw(grid, "RGBA")
    for x in range(0, MAP_W, 100):
        d.line([(x, 0), (x, MAP_H)], fill=(220, 60, 60, 60), width=1)
    for y in range(0, MAP_H, 100):
        d.line([(0, y), (MAP_W, y)], fill=(220, 60, 60, 60), width=1)
    for x in range(0, MAP_W, 200):
        d.line([(x, 0), (x, MAP_H)], fill=(230, 40, 40, 140), width=1)
        d.text((x + 3, 3), str(x), fill=(255, 70, 40, 255))
    for y in range(0, MAP_H, 200):
        d.line([(0, y), (MAP_W, y)], fill=(230, 40, 40, 140), width=1)
        d.text((3, y + 3), str(y), fill=(255, 70, 40, 255))
    # Engine-protected regions: cover placed inside these is silently carved.
    d.line([(CENTER[0], 0), (CENTER[0], MAP_H)],
           fill=(60, 140, 255, 170), width=1)
    d.ellipse([CENTER[0] - FLAG_RING, CENTER[1] - FLAG_RING,
               CENTER[0] + FLAG_RING, CENTER[1] + FLAG_RING],
              outline=(60, 200, 255, 220), width=2)
    for hx in (RED_HOME_X, BLUE_HOME_X):
        d.rectangle([hx - SPAWN_W, CENTER[1] - SPAWN_H,
                     hx + SPAWN_W, CENTER[1] + SPAWN_H],
                    outline=(70, 220, 120, 200), width=2)
        d.ellipse([hx - 9, CENTER[1] - 9, hx + 9, CENTER[1] + 9],
                  outline=(70, 220, 120, 230), width=2)
    grid.save(OUT / f"{name}-grid.png")
    print(f"{name}: rot={spec['rot']} frame={spec['frame']} -> plate + grid")


def main():
    for name in (sys.argv[1:] or MAPS):
        plate(name)


if __name__ == "__main__":
    main()
