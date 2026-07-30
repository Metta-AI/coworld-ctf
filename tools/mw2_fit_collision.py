#!/usr/bin/env python3
"""Fit shapeDisc collision to a prop render's alpha silhouette.

WHY collision follows art
-------------------------
Map props are Blender renders (RGBA PNGs in data/props/, rendered at 4x
their map-pixel footprint) composited over hand-authored collision
shapes.  For boxy props (containers, crates) authoring the collider
first and rendering art to match works fine.  For ORGANIC terrain --
sculpted rocks, mesas, cave mouths -- that workflow is backwards: a
hand-placed disc never matches the sculpted silhouette, and the art
then lies about where the walls are.  Players get snagged on invisible
rock or walk through visible rock, and both failures are unlearnable
because they do not follow the picture.  This tool inverts the
workflow: the render's alpha channel IS the ground truth, and the
collision is fitted TO it automatically, so the picture can never lie.

Algorithm
---------
1. Load the PNG alpha, threshold > 128 -> silhouette mask at render
   resolution.
2. Scale the mask to the map-px footprint W x H (box filter, >= 50%
   coverage keeps a pixel), rotate by `rot` degrees clockwise about the
   center, and place at (cx, cy) -- exactly the semantics of
   PropSprite / blitPropSprites in src/ctf/sim.nim (resize THEN rotate
   about center, screen coords, y-down).
3. Greedy medial-axis disc covering via scipy's distance transform:
   repeatedly center a disc on the uncovered silhouette pixel with the
   largest inscribed radius (distance_transform_edt of the mask),
   inflate it slightly so collision hugs the visible edge, then SHRINK
   it until no covered outside pixel lies more than OVERREACH_PX from
   the silhouette.  Stop when the uncovered residual is below
   RESIDUAL_FRAC of the silhouette or the best remaining inscribed
   radius drops under MIN_RADIUS.  Prefer fewer, larger discs; hard cap
   at MAX_DISCS with a warning if the cap forces coverage below target.
4. Because the overreach test measures against ALL non-silhouette
   pixels -- including interior holes -- a passage THROUGH a mass (a
   cave canyon rendered as transparent floor inside the rock) is never
   bridged: no disc may cover any hole pixel beyond the tolerance.

Verification (always runs)
--------------------------
The emitted discs are re-rasterized on the map-px grid with the exact
engine test from sim.nim's inShape (dx*dx + dy*dy <= r*r on integer
pixel indices) and diffed against the placed silhouette.  The report
gives silhouette area, covered %, max overreach in px, and disc count.
The tool exits 1 (loudly) if covered < 95% or overreach > 4 px.

Usage
-----
Single placement (same semantics as PropSprite: x,y is the CENTER,
w/h the map-px footprint, rot degrees clockwise):

    python3 tools/mw2_fit_collision.py \\
        --png data/props/fuel_tank.png --x 300 --y 300 --w 116 --h 116 \\
        [--rot 15] [--label "west fuel tank"]

Multiple placements from a JSON spec (a list of objects with keys
png, x, y, w, h and optional rot, label):

    python3 tools/mw2_fit_collision.py --spec placements.json

    [
      {"png": "data/props/mesa.png", "x": 300, "y": 300,
       "w": 116, "h": 116, "rot": 15, "label": "west mesa"},
      ...
    ]

Ready-to-paste Nim source goes to STDOUT (a comment + ArenaShape lines
per placement, then a clearly marked PropSprite block).  The
verification report goes to STDERR so stdout stays paste-clean.
Output is fully deterministic (no RNG; argmax ties break in C order).
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

# Fitting constants (map px unless noted).
ALPHA_THRESHOLD = 128    # alpha > this at render res -> silhouette.
RESIDUAL_FRAC = 0.03     # stop when uncovered residual < 3% of area.
MIN_RADIUS = 5           # stop when best inscribed radius < this.
MAX_DISCS = 80           # hard cap per placement.
OVERREACH_PX = 4.0       # no disc pixel > this far outside silhouette.
INFLATE_PX = 2           # try inflating each disc this much past its
                         # inscribed radius (then shrink to the
                         # overreach cap) so collision hugs the edge.
COVERAGE_MIN = 95.0      # verify: fail below this covered %.
CANVAS_MARGIN = 16       # zero padding around the placed silhouette.


def load_silhouette(png_path):
    """Alpha > ALPHA_THRESHOLD -> bool mask at render resolution."""
    img = Image.open(png_path)
    if img.mode != "RGBA":
        raise SystemExit(
            f"error: {png_path} is {img.mode}, need RGBA (alpha is the "
            "silhouette ground truth)")
    alpha = np.asarray(img)[:, :, 3]
    return alpha > ALPHA_THRESHOLD


def scale_mask(mask, w, h):
    """Box-filter the binary mask to w x h; >= 50% coverage keeps a px."""
    img = Image.fromarray((mask * 255).astype(np.uint8))
    scaled = img.resize((w, h), Image.Resampling.BOX)
    return np.asarray(scaled) >= 128


def place_mask(mask_wh, cx, cy, w, h, rot_deg):
    """Rasterize the scaled mask onto the map-px grid at its placement.

    Mirrors blitPropSprites: the w x h sprite is rotated `rot_deg`
    clockwise (screen coords, y-down) about its center, which lands on
    (cx, cy).  Returns (local bool canvas, (ox, oy) global offset of
    canvas pixel [0, 0]).
    """
    theta = np.deg2rad(rot_deg)
    cos_t, sin_t = np.cos(theta), np.sin(theta)
    # Rotated footprint bounds around the center.
    half_w, half_h = w / 2.0, h / 2.0
    corners = np.array([[-half_w, -half_h], [half_w, -half_h],
                        [-half_w, half_h], [half_w, half_h]])
    # Forward clockwise rotation in y-down screen coords.
    fwd = np.array([[cos_t, -sin_t], [sin_t, cos_t]])
    rotated = corners @ fwd.T
    x_lo = int(np.floor(cx + rotated[:, 0].min())) - CANVAS_MARGIN
    x_hi = int(np.ceil(cx + rotated[:, 0].max())) + CANVAS_MARGIN
    y_lo = int(np.floor(cy + rotated[:, 1].min())) - CANVAS_MARGIN
    y_hi = int(np.ceil(cy + rotated[:, 1].max())) + CANVAS_MARGIN

    ys, xs = np.mgrid[y_lo:y_hi, x_lo:x_hi]
    # Sample at pixel centers; inverse-rotate into the sprite frame.
    dx = xs + 0.5 - cx
    dy = ys + 0.5 - cy
    u = cos_t * dx + sin_t * dy + half_w
    v = -sin_t * dx + cos_t * dy + half_h
    ui = np.floor(u).astype(np.int64)
    vi = np.floor(v).astype(np.int64)
    inside = (ui >= 0) & (ui < w) & (vi >= 0) & (vi < h)
    canvas = np.zeros(xs.shape, dtype=bool)
    canvas[inside] = mask_wh[vi[inside], ui[inside]]
    return canvas, (x_lo, y_lo)


def disc_pixels(shape, cx, cy, radius):
    """Engine-exact disc raster: dx*dx + dy*dy <= r*r on pixel indices."""
    ys, xs = np.ogrid[: shape[0], : shape[1]]
    return (xs - cx) ** 2 + (ys - cy) ** 2 <= radius * radius


def fit_discs(mask):
    """Greedy maximal-inscribed-disc covering of a bool silhouette mask.

    Returns (discs, warnings) with discs as (col, row, radius) tuples in
    local canvas coordinates, all integers.
    """
    area = int(mask.sum())
    if area == 0:
        return [], ["silhouette is empty -- nothing to fit"]
    dist_in = ndimage.distance_transform_edt(mask)
    dist_out = ndimage.distance_transform_edt(~mask)
    covered = np.zeros_like(mask)
    discs = []
    warnings = []
    while len(discs) < MAX_DISCS:
        remaining = mask & ~covered
        if remaining.sum() < RESIDUAL_FRAC * area:
            break
        best = np.where(remaining, dist_in, -1.0)
        row, col = np.unravel_index(int(np.argmax(best)), best.shape)
        inscribed = dist_in[row, col]
        if inscribed < MIN_RADIUS:
            break
        # Inflate to hug the visible edge, then shrink until no covered
        # outside pixel (holes included) exceeds the overreach cap.
        radius = int(np.floor(inscribed)) + INFLATE_PX
        while radius > 0:
            disc = disc_pixels(mask.shape, col, row, radius)
            spill = disc & ~mask
            if not spill.any() or dist_out[spill].max() <= OVERREACH_PX:
                break
            radius -= 1
        if radius <= 0:
            break  # degenerate; cannot even fit a 1 px disc here.
        covered |= disc_pixels(mask.shape, col, row, radius)
        discs.append((int(col), int(row), int(radius)))
    uncovered = (mask & ~covered).sum()
    if len(discs) >= MAX_DISCS and uncovered >= RESIDUAL_FRAC * area:
        warnings.append(
            f"disc cap ({MAX_DISCS}) hit with {100 * uncovered / area:.1f}% "
            "of the silhouette still uncovered -- coverage below target")
    return discs, warnings


def verify(mask, discs):
    """Re-rasterize discs with engine semantics and diff vs silhouette.

    Returns (report dict, ok bool).  Overreach is measured against ALL
    non-silhouette pixels, so an interior hole (cave passage) bridged
    by a disc fails exactly like an exterior spill.
    """
    area = int(mask.sum())
    union = np.zeros_like(mask)
    for col, row, radius in discs:
        union |= disc_pixels(mask.shape, col, row, radius)
    covered_pct = 100.0 * (union & mask).sum() / max(area, 1)
    spill = union & ~mask
    if spill.any():
        dist_out = ndimage.distance_transform_edt(~mask)
        overreach = float(dist_out[spill].max())
    else:
        overreach = 0.0
    report = {
        "silhouette_area_px": area,
        "covered_pct": covered_pct,
        "max_overreach_px": overreach,
        "disc_count": len(discs),
    }
    ok = covered_pct >= COVERAGE_MIN and overreach <= OVERREACH_PX
    return report, ok


def nim_prop_line(placement):
    """One PropSprite(...) source line matching sim.nim's style."""
    png, x, y = placement["png"], placement["x"], placement["y"]
    w, h, rot = placement["w"], placement["h"], placement["rot"]
    base = f'    PropSprite(file: "{png}", x: {x}, y: {y}, w: {w}, h: {h}'
    if rot:
        rot_txt = f"{rot:g}"
        return base + f",\n               rot: {rot_txt}),"
    return base + "),"


def process_placement(placement, repo_root):
    """Fit one placement.  Returns (shape_lines, prop_line, report, ok)."""
    png = placement["png"]
    path = png if os.path.isabs(png) else os.path.join(repo_root, png)
    if not os.path.exists(path):
        raise SystemExit(f"error: prop render not found: {path}")
    mask_render = load_silhouette(path)
    mask_wh = scale_mask(mask_render, placement["w"], placement["h"])
    canvas, (ox, oy) = place_mask(
        mask_wh, placement["x"], placement["y"],
        placement["w"], placement["h"], placement["rot"])
    discs, warnings = fit_discs(canvas)
    report, ok = verify(canvas, discs)
    report["warnings"] = warnings

    label = placement.get("label") or (
        f"{os.path.splitext(os.path.basename(png))[0]} at "
        f"({placement['x']}, {placement['y']})")
    lines = [f"    # {label} -- fitted collision "
             f"({report['disc_count']} discs, "
             f"{report['covered_pct']:.1f}% cover)"]
    for col, row, radius in discs:
        lines.append(
            f"    ArenaShape(kind: shapeDisc, cx: {ox + col}, "
            f"cy: {oy + row}, radius: {radius}),")
    return lines, nim_prop_line(placement), report, ok


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Fit shapeDisc collision to a prop render's alpha "
                    "silhouette (see module docstring).")
    parser.add_argument("--png", help="prop render, e.g. data/props/x.png")
    parser.add_argument("--x", type=int, help="footprint CENTER x (map px)")
    parser.add_argument("--y", type=int, help="footprint CENTER y (map px)")
    parser.add_argument("--w", type=int, help="footprint width (map px)")
    parser.add_argument("--h", type=int, help="footprint height (map px)")
    parser.add_argument("--rot", type=float, default=0.0,
                        help="clockwise degrees (default 0)")
    parser.add_argument("--label", help="comment for the Nim block")
    parser.add_argument("--spec",
                        help="JSON file: list of {png,x,y,w,h[,rot][,label]}")
    args = parser.parse_args(argv)

    if args.spec:
        if args.png:
            parser.error("--spec and --png are mutually exclusive")
        with open(args.spec) as fh:
            entries = json.load(fh)
        if not isinstance(entries, list):
            parser.error("--spec must contain a JSON list")
        placements = []
        for entry in entries:
            missing = [k for k in ("png", "x", "y", "w", "h")
                       if k not in entry]
            if missing:
                parser.error(f"spec entry missing {missing}: {entry}")
            entry.setdefault("rot", 0.0)
            placements.append(entry)
        return placements
    required = {"png": args.png, "x": args.x, "y": args.y,
                "w": args.w, "h": args.h}
    missing = [k for k, v in required.items() if v is None]
    if missing:
        parser.error(f"missing --{' --'.join(missing)} (or use --spec)")
    return [{"png": args.png, "x": args.x, "y": args.y, "w": args.w,
             "h": args.h, "rot": args.rot, "label": args.label}]


def main(argv=None):
    placements = parse_args(argv if argv is not None else sys.argv[1:])
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    shape_blocks = []
    prop_lines = []
    all_ok = True
    for placement in placements:
        lines, prop_line, report, ok = process_placement(placement,
                                                         repo_root)
        shape_blocks.append("\n".join(lines))
        prop_lines.append(prop_line)
        all_ok = all_ok and ok
        name = placement.get("label") or placement["png"]
        print(f"[{name}] silhouette area: "
              f"{report['silhouette_area_px']} px, covered: "
              f"{report['covered_pct']:.1f}%, max overreach: "
              f"{report['max_overreach_px']:.2f} px, discs: "
              f"{report['disc_count']}", file=sys.stderr)
        for warning in report["warnings"]:
            print(f"[{name}] WARNING: {warning}", file=sys.stderr)
        if not ok:
            print(f"[{name}] FAIL: needs covered >= {COVERAGE_MIN:.0f}% "
                  f"and overreach <= {OVERREACH_PX:.0f} px",
                  file=sys.stderr)

    print("    # --- fitted collision (tools/mw2_fit_collision.py) ---")
    for block in shape_blocks:
        print(block)
    print()
    print("    # --- matching prop placements ---")
    for line in prop_lines:
        print(line)

    if not all_ok:
        print("FAILED: fitted collision misses the verify gate; see "
              "per-placement lines above", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
