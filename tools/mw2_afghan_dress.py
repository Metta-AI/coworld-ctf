#!/usr/bin/env python3
"""Dresses Afghan v2's terrain with the sculpted rock renders.

The collision layer is fitted discs over the measured masks (see
tools/mw2_afghan_v2.py); this pass decides where the Blender rock sprites
(scripts/art/blender_terrain.py families) sit on top of those masses so the
terrain reads as modeled rock rather than bevelled carve-stone. Props bake
into the BOARD image underneath players (blitPropSprites draws them into the
map render), so art overhanging a mass's edge cannot hide a player — it just
reads as rock overhang.

Placement rules, derived from the mask rather than hand coordinates so a
regenerated mask re-dresses itself:
  * the RING (the one component touching the canvas border) gets
    mountain_wall_{a,b,c} segments tiled along its inner boundary, each
    rotated to the local boundary tangent and pushed into the rock so the
    crest overhangs the face slightly;
  * field rock components get mesa_a/mesa_b if they are big and compact,
    or boulder_a/boulder_b if small;
  * the cave chamber's surroundings are left undressed so the canyon stays
    readable from above.

Prints PropSprite lines to paste into afghanCtfMap()'s props block.
"""
import numpy as np
from PIL import Image
from scipy import ndimage

W, H = 1460, 1400
CAVE_KEEPOUT = (860, 560, 1180, 770)     # x0, y0, x1, y1
WALLS = ["mountain_wall_a", "mountain_wall_b", "mountain_wall_c"]
MESAS = ["mesa_a", "mesa_b"]
BOULDERS = ["boulder_a", "boulder_b"]


def in_keepout(x, y):
    x0, y0, x1, y1 = CAVE_KEEPOUT
    return x0 <= x <= x1 and y0 <= y <= y1


def ring_segments(ring, step=200):
    """Sample points along the ring's inner boundary with local tangents."""
    inner = ring & ~ndimage.binary_erosion(ring, np.ones((3, 3), bool))
    # Drop boundary pixels on the canvas frame; only the valley-facing face.
    inner[:12, :] = inner[-12:, :] = False
    inner[:, :12] = inner[:, -12:] = False
    ys, xs = np.where(inner)
    pts = np.column_stack([xs, ys]).astype(float)
    # Greedy walk: repeatedly take the unvisited boundary point nearest the
    # last placement, spacing placements `step` apart along the face.
    placed = []
    used = np.zeros(len(pts), bool)
    cur = 0
    while True:
        p = pts[cur]
        near = np.hypot(pts[:, 0] - p[0], pts[:, 1] - p[1])
        # Local tangent from PCA of the boundary within 90 px.
        local = pts[near < 90] - p
        if len(local) >= 8:
            cov = np.cov(local.T)
            evals, evecs = np.linalg.eigh(cov)
            tangent = evecs[:, np.argmax(evals)]
            angle = float(np.degrees(np.arctan2(tangent[1], tangent[0])))
        else:
            angle = 0.0
        # Inward normal: toward the nearest floor, flipped to point INTO rock.
        placed.append((int(p[0]), int(p[1]), angle))
        used |= near < step
        if used.all():
            break
        remaining = np.where(~used)[0]
        cur = remaining[np.argmin(np.hypot(
            pts[remaining, 0] - p[0], pts[remaining, 1] - p[1]))]
    return placed


def main():
    mask_dir = "docs/designs/mw2-reference/afghan-v2-masks"
    ring = np.array(Image.open(f"{mask_dir}/ring.png").convert("L")) > 128
    massif = np.array(Image.open(f"{mask_dir}/massif.png").convert("L")) > 128
    islands = np.array(
        Image.open(f"{mask_dir}/islands.png").convert("L")) > 128

    dist_in_ring = ndimage.distance_transform_edt(ring)
    lines = ["    # --- terrain dressing: sculpted rock renders over the "
             "fitted masses ---"]

    # Ring: wall segments along the inner face, nudged into the rock.
    segs = ring_segments(ring)
    for i, (x, y, ang) in enumerate(segs):
        # Push the sprite centre ~45 px into the rock along the distance
        # gradient so the crest sits on the mass and only the talus edge
        # overhangs the face.
        y0, y1 = max(0, y - 60), min(H, y + 60)
        x0, x1 = max(0, x - 60), min(W, x + 60)
        win = dist_in_ring[y0:y1, x0:x1]
        gy, gx = np.gradient(win)
        py, px = y - y0, x - x0
        nx, ny = gx[py, px], gy[py, px]
        norm = np.hypot(nx, ny) or 1.0
        cx = int(x + 45 * nx / norm)
        cy = int(y + 45 * ny / norm)
        fam = WALLS[i % 3]
        rot = round(ang / 5) * 5 % 180
        lines.append(
            f'    PropSprite(file: "data/props/{fam}.png", x: {cx}, '
            f"y: {cy}, w: 330, h: 100, rot: {rot}),")

    # Field masses: mesas on the big lobes, boulders on the small rocks.
    field = massif | islands
    lab, n = ndimage.label(field, np.ones((3, 3), bool))
    mi, bi = 0, 0
    for i, sl in enumerate(ndimage.find_objects(lab), start=1):
        if sl is None:
            continue
        comp = lab[sl] == i
        area = int(comp.sum())
        if area < 900:
            continue
        cy = (sl[0].start + sl[0].stop) // 2
        cx = (sl[1].start + sl[1].stop) // 2
        bw = sl[1].stop - sl[1].start
        bh = sl[0].stop - sl[0].start
        if in_keepout(cx, cy):
            continue
        if area >= 12000:
            # A big lobe can carry several mesas: place one per local
            # maximum of the interior distance, spaced >= 170 px.
            dist = ndimage.distance_transform_edt(comp)
            spots = []
            work = dist.copy()
            while work.max() >= 28:
                r, c = np.unravel_index(int(work.argmax()), work.shape)
                spots.append((c + sl[1].start, r + sl[0].start,
                              float(dist[r, c])))
                rr = 170
                y0, y1 = max(0, r - rr), min(work.shape[0], r + rr)
                x0, x1 = max(0, c - rr), min(work.shape[1], c + rr)
                work[y0:y1, x0:x1] = 0
            for (sx, sy, srad) in spots:
                if in_keepout(sx, sy):
                    continue
                fam = MESAS[mi % 2]
                mi += 1
                side = int(min(3.4 * srad, 240))
                lines.append(
                    f'    PropSprite(file: "data/props/{fam}.png", '
                    f"x: {sx}, y: {sy}, w: {side}, "
                    f"h: {int(side * 0.8)}),")
        elif area >= 900:
            fam = BOULDERS[bi % 2]
            bi += 1
            side = int(min(max(bw, bh) * 1.0, 70))
            lines.append(
                f'    PropSprite(file: "data/props/{fam}.png", x: {cx}, '
                f"y: {cy}, w: {side}, h: {int(side * 0.85)}),")

    print("\n".join(lines))
    print(f"    # {len(segs)} ring segments, {mi} mesas, {bi} boulders")


if __name__ == "__main__":
    main()
