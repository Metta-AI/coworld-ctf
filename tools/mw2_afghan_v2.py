#!/usr/bin/env python3
"""Builds Afghan v2 — the measured valley — and emits its Nim geometry.

Everything here is transcribed from docs/designs/afghan-layout-v2.md, which
was measured off the official 2009 overhead (rotated into game space,
thresholded, component-labelled, traced). This script turns that plan into
the exact artifacts sim.nim needs:

  1. rasterize the plan: all-mountain canvas, carve the 74-pt valley rim,
     fill the central massif + rock islands, carve the cave complex and the
     bunker, apply the plan's [ADJ] trims;
  2. enforce the CHOKEPOINT SCHEDULE mechanically: measure each scheduled gap
     on the raster and shave the specified face in 3 px steps until it meets
     spec. Hand-tuning polygon points does not converge (the disc-terrain
     pass proved it: fixing one 391-cell sliver created a 2043-cell one);
     measuring and correcting on the raster does.
  3. fit collision DISCS to the terrain mask (bbox-windowed variant of
     tools/mw2_fit_collision.py's greedy: maximal inscribed discs, inflate
     then shrink, <= 4 px overreach) — man-made structures stay crisp
     axis-aligned rects straight from the plan tables;
  4. VERIFY WHAT SHIPS: rasterize the emitted shapes (with the engine's
     forced-floor rules: flag ring, spawn pockets, carveClear = -1 so no
     forced home columns) and run the invariant checks on THAT raster —
     13 px-fit flood connectivity to every named room, no stranded floor,
     no open cross-field row, walk-to-midfield fairness with the plan's
     sanctioned blueHome nudge;
  5. emit the obstacle list + prop lines to /tmp/afghan_v2_shapes.nim and
     the mask previews to /tmp/afghan_v2_*.png.

Usage: python3 tools/mw2_afghan_v2.py
"""
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

W, H = 1460, 1400
CENTER = (730, 700)
FLAG_RING = 70
PLAYER = 13
CAPTURE_CLEAR = 210          # open-row scan span only; no forced columns.
SPAWN_W, SPAWN_H = 80, 96

RED_HOME = (210, 472)
BLUE_HOME = (1251, 598)      # may be nudged east up to 1290 by fairness.
MEDKITS = [(1025, 660), (805, 1150)]

# --- plan polygons (docs/designs/afghan-layout-v2.md section 3) -------------
# [ADJ] already applied: rim point (315,741) -> (270,741).
VALLEY_RIM = [
    (1185, 93), (1209, 156), (1251, 129), (1275, 210), (1170, 267),
    (1245, 495), (1380, 498), (1344, 555), (1398, 501), (1380, 720),
    (1362, 723), (1338, 675), (1302, 678), (1281, 714), (1197, 720),
    (1194, 984), (1101, 1017), (1095, 1059), (951, 1044), (915, 1086),
    (897, 1185), (717, 1260), (693, 1329), (642, 1347), (615, 1302),
    (615, 1170), (552, 1155), (483, 1185), (441, 1143), (363, 1137),
    (309, 1164), (291, 1020), (261, 993), (180, 984), (147, 948),
    (141, 855), (195, 828), (297, 831), (315, 741), (270, 741),
    (249, 732), (237, 702), (315, 636), (213, 609), (207, 624),
    (204, 558), (105, 540), (81, 507), (87, 447), (147, 342),
    (168, 339), (171, 381), (231, 378), (267, 402), (285, 387),
    (267, 342), (300, 291), (444, 303), (471, 330), (522, 297),
    (573, 297), (579, 321), (534, 366), (441, 372), (423, 393),
    (426, 489), (465, 507), (474, 588), (498, 600), (576, 393),
    (705, 375), (738, 294), (864, 210), (1065, 162), (1182, 96),
]
MASSIF = [
    (1080, 360), (1131, 369), (1194, 447), (1194, 510), (1152, 552),
    (1155, 639), (1125, 660), (1125, 630), (1152, 636), (1149, 552),
    (1191, 510), (1188, 468), (1176, 507), (1125, 555), (1107, 630),
    (1119, 681), (1176, 723), (1194, 888), (1125, 894), (1128, 918),
    (1176, 918), (1164, 966), (1086, 993), (1071, 1038), (975, 1038),
    (978, 1020), (1044, 1029), (1065, 987), (1161, 954), (1155, 921),
    (1122, 921), (1122, 885), (1170, 882), (1173, 741), (1140, 819),
    (1095, 798), (1047, 813), (1062, 876), (1044, 897), (1026, 897),
    (990, 756), (951, 744), (936, 807), (957, 873), (927, 933),
    (930, 1008), (915, 1026), (885, 1032), (816, 972), (753, 957),
    (678, 900), (648, 918), (603, 1011), (621, 1056), (603, 1110),
    (498, 1101), (501, 1065), (468, 1026), (546, 951), (666, 906),
    (765, 783), (870, 741), (900, 690), (903, 636), (879, 615),
    (876, 516), (810, 501), (837, 414), (903, 366), (981, 387),
    (1011, 417), (1026, 384), (1077, 363),
]
WEST_CENTRAL_ROCK = [
    (465, 615), (510, 630), (528, 657), (498, 819), (447, 861),
    (393, 861), (378, 849), (381, 816), (345, 789), (336, 762),
    (342, 735), (369, 723), (462, 618),
]
SW_ROCKS = [
    (396, 972), (447, 990), (435, 1011), (456, 1059), (423, 1083),
    (435, 1113), (357, 1119), (336, 1074), (348, 1050), (336, 1023),
    (345, 978), (393, 975),
]

# Carves applied to the mask AFTER fills (all become floor).
CAVE_CARVES = [
    (925, 590, 200, 140),    # main chamber
    (875, 620, 50, 40),      # west mouth -> crash site
    (1125, 650, 50, 50),     # east mouth -> bowl/ledge junction
    (975, 384, 45, 30),      # north-leg exit portal -> crates field
]
CAVE_NORTH_LEG = [(1000, 590), (975, 500), (990, 415)]   # 36 px corridor
CAVE_ROUTE = [(900, 640), (975, 660), (1065, 695), (1150, 675)]  # 40 px
BUNKER_CARVES = [
    (585, 261, 171, 102),    # interior
    # Doors widened from the plan's 18px: disc fitting may overreach up to
    # 4px per side, and 18 - 8 = 10px is under the 13px player box -- the
    # first build sealed the bunker on the shipped raster exactly this way.
    (561, 296, 24, 48),      # west door
    (630, 363, 60, 30),      # south embrasure ([CHOICE]: plain gap)
    (756, 311, 24, 48),      # east door
]
ADJ_CARVES = [
    (1155, 405, 90, 155),    # massif NE lobe trim (canyon)
    (1131, 700, 100, 130),   # massif east face trim (ledge corridor)
    (950, 1000, 150, 130),   # massif SE foot + stepped-wall drop (SE strait)
    (900, 1000, 200, 130),   # stepped-wall face north of y 1130
]

# --- man-made structures: crisp rects, straight from the plan tables --------
# (name, x, y, w, h) -> shapeRect. These are EMITTED as Nim rects and painted
# into the verification raster, but excluded from disc fitting.
STRUCTS = [
    ("bunker room divider", 660, 261, 12, 69),
    ("compound wall A west", 168, 330, 42, 12),
    ("compound wall A east", 240, 330, 39, 12),
    ("compound wall A west leg", 168, 330, 12, 42),
    ("compound wall A east leg", 267, 330, 12, 42),
    ("compound ruin B hut", 333, 366, 42, 36),
    ("compound thin wall W1", 294, 450, 18, 120),
    ("compound thin wall W2", 378, 450, 21, 93),
    ("plaza wall bit S", 150, 590, 50, 18),
    ("plaza wall bit E", 250, 585, 18, 40),
    ("west shack C1", 117, 575, 45, 30),
    ("west shack C2", 168, 573, 39, 72),
    ("south hut D", 168, 615, 57, 45),
    ("crates row", 855, 279, 54, 27),
    ("burnt tank", 1029, 276, 42, 57),
    ("wadi ledge wall", 243, 951, 153, 15),
    ("sandbag V wadi", 642, 1074, 66, 45),
    ("sandbag T wadi", 783, 1011, 33, 48),
    ("sandbag rect wadi", 750, 1110, 45, 21),
    ("sandbag T south", 645, 1155, 54, 39),
    ("sandbag arc BLUE west", 1180, 702, 70, 18),
    ("sandbag arc BLUE east", 1262, 702, 68, 18),
    # The C-130, heading 009 (nose NORTH) -- plan section 4.
    ("c130 nose section", 678, 432, 69, 99),
    ("c130 forward fragment", 579, 444, 30, 51),
    ("c130 cargo debris", 603, 525, 27, 30),
    ("c130 mid fuselage + wing box", 579, 567, 111, 108),
    ("c130 tail cone", 666, 723, 21, 87),
    ("c130 tail fin fallen", 561, 726, 81, 123),
]
STRUCT_DISCS = [
    ("c130 engine debris", 537, 588, 14),
    ("c130 engine debris", 513, 634, 14),
    ("c130 engine debris", 717, 600, 14),
    ("c130 engine debris", 741, 648, 14),
]

# Chokepoint schedule: (label, (x0, y0, x1, y1) probe segment, min gap px).
# The probe crosses the gap; the measured value is open run length along it.
# Mask-space minimums carry +8 so the <=4 px disc overreach per side cannot
# take a shipped gap under spec.
CHOKES = [
    ("Canyon NE", (1130, 480, 1280, 480), 78),
    ("SE strait", (1020, 970, 1020, 1180), 90),
    ("Tongue tip vs west rock", (480, 560, 480, 680), 75),
    ("shack alley", (250, 780, 360, 780), 75),
    ("Ledge corridor", (1100, 780, 1230, 780), 80),
]

# --- helpers ----------------------------------------------------------------


def poly_mask(points, fill=1):
    """Polygon fill, taking the OUTER region.

    The measured polygons walk out and back along some faces and carry
    near-duplicate point pairs (Douglas-Peucker leftovers); PIL's even-odd
    rule turns those degenerate loops into interior holes, which fragmented
    the central massif into separate lumps on the first build. The outline is
    the measurement; holes inside it are artifacts, so fill them. Intended
    interior floor (the cave, the bunker) is carved explicitly afterwards.
    """
    im = Image.new("L", (W, H), 0)
    ImageDraw.Draw(im).polygon(points, fill=fill)
    return ndimage.binary_fill_holes(np.array(im, bool))


def corridor(points, width):
    im = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(im)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        d.line([x0, y0, x1, y1], fill=1, width=width)
        d.ellipse([x0 - width // 2, y0 - width // 2,
                   x0 + width // 2, y0 + width // 2], fill=1)
    x, y = points[-1]
    d.ellipse([x - width // 2, y - width // 2,
               x + width // 2, y + width // 2], fill=1)
    return np.array(im, bool)


def rect(mask, x, y, w, h, val):
    mask[max(0, y):min(H, y + h), max(0, x):min(W, x + w)] = val


def probe_gap(mask, seg):
    """Longest open run along the probe segment, in px."""
    x0, y0, x1, y1 = seg
    n = int(max(abs(x1 - x0), abs(y1 - y0)))
    best = run = 0
    for i in range(n + 1):
        x = int(round(x0 + (x1 - x0) * i / n))
        y = int(round(y0 + (y1 - y0) * i / n))
        if not mask[y, x]:
            run += 1
            best = max(best, run)
        else:
            run = 0
    return best


def forced_floor(mask):
    """Apply the engine's forced-floor rules (carveClear = -1: no columns)."""
    out = mask.copy()
    yy, xx = np.mgrid[0:H, 0:W]
    out[(xx - CENTER[0]) ** 2 + (yy - CENTER[1]) ** 2 <= FLAG_RING ** 2] = 0
    for hx, hy in (RED_HOME, blue_home()):
        out[(np.abs(xx - hx) <= SPAWN_W) & (np.abs(yy - hy) <= SPAWN_H)] = 0
    # Border ring is wall (ArenaBorder = 10 in the engine).
    out[:10, :] = 1
    out[-10:, :] = 1
    out[:, :10] = 1
    out[:, -10:] = 1
    return out


_blue_home = list(BLUE_HOME)


def blue_home():
    return tuple(_blue_home)


def fits_of(mask):
    return ndimage.binary_erosion(~mask, np.ones((PLAYER, PLAYER), bool))


def flood(mask_fits, seed):
    lab, _ = ndimage.label(mask_fits)
    return lab == lab[seed[1], seed[0]] if mask_fits[seed[1], seed[0]] \
        else np.zeros_like(mask_fits)


def bfs_dist(free, seed):
    dist = np.full(free.shape, -1, np.int32)
    if not free[seed[1], seed[0]]:
        return dist
    frontier = np.zeros(free.shape, bool)
    frontier[seed[1], seed[0]] = True
    dist[seed[1], seed[0]] = 0
    cross = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], bool)
    n = 0
    while frontier.any():
        n += 1
        frontier = ndimage.binary_dilation(frontier, structure=cross) \
            & free & (dist < 0)
        dist[frontier] = n
    return dist


def fit_terrain_discs(mask, max_discs=700, residual=0.02, min_radius=5,
                      overreach=4, inflate=3):
    """Bbox-windowed version of mw2_fit_collision.fit_discs (same semantics).

    The library version paints every candidate disc on the full canvas; at
    1460x1400 with ~600 discs that is minutes of numpy. Windowing each paint
    to the disc's bbox is identical math at a fraction of the cost.
    """
    area = int(mask.sum())
    dist_in = ndimage.distance_transform_edt(mask)
    dist_out = ndimage.distance_transform_edt(~mask)
    covered = np.zeros_like(mask)
    discs = []
    while len(discs) < max_discs:
        remaining = mask & ~covered
        if remaining.sum() < residual * area:
            break
        flat = np.where(remaining, dist_in, -1.0)
        row, col = np.unravel_index(int(np.argmax(flat)), flat.shape)
        inscribed = dist_in[row, col]
        if inscribed < min_radius:
            break
        radius = int(np.floor(inscribed)) + inflate
        while radius > 0:
            y0, y1 = max(0, row - radius), min(H, row + radius + 1)
            x0, x1 = max(0, col - radius), min(W, col + radius + 1)
            yy, xx = np.mgrid[y0:y1, x0:x1]
            disc = (xx - col) ** 2 + (yy - row) ** 2 <= radius * radius
            spill = disc & ~mask[y0:y1, x0:x1]
            if not spill.any() or dist_out[y0:y1, x0:x1][spill].max() \
                    <= overreach:
                covered[y0:y1, x0:x1] |= disc
                discs.append((int(col), int(row), int(radius)))
                break
            radius -= 1
        if radius <= 0:
            covered[row, col] = True   # give up on this pixel
    return discs


def raster_shapes(discs, structs, struct_discs):
    """The SHIPPED wall mask: exactly what the engine will rasterize."""
    wall = np.zeros((H, W), bool)
    for cx, cy, r in discs:
        y0, y1 = max(0, cy - r), min(H, cy + r + 1)
        x0, x1 = max(0, cx - r), min(W, cx + r + 1)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        wall[y0:y1, x0:x1] |= (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
    for _, x, y, w, h in structs:
        rect(wall, x, y, w, h, 1)
    for _, cx, cy, r in struct_discs:
        y0, y1 = max(0, cy - r), min(H, cy + r + 1)
        x0, x1 = max(0, cx - r), min(W, cx + r + 1)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        wall[y0:y1, x0:x1] |= (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
    return forced_floor(wall)


# --- build ------------------------------------------------------------------


MASK_DIR = "docs/designs/mw2-reference/afghan-v2-masks"


def build_mask():
    # The measured RASTER masks are the source of truth, not the polygon
    # lists above. The plan's polygons are Moore-trace + Douglas-Peucker
    # ENCODINGS of these masks, and they retrace their own faces in places —
    # no polygon fill rule reconstructs the mass (the first build's massif
    # came out as scattered lumps at a fraction of its measured area). The
    # layout pass re-emitted its actual component masks; the polygons stay
    # in this file as documentation of the measurement.
    wall = np.zeros((H, W), bool)
    for name in ("ring", "massif", "islands"):
        m = np.array(Image.open(f"{MASK_DIR}/{name}.png").convert("L")) > 128
        assert m.shape == (H, W), f"{name}: {m.shape}"
        wall |= m
    # SW merge: close the two <15 px micro-straits between SW_ROCKS and the
    # massif SW lobe so they are one rock group, not two sliver channels.
    zone = np.zeros((H, W), bool)
    zone[930:1140, 320:700] = True
    closed = ndimage.binary_closing(wall & zone, np.ones((17, 17), bool))
    wall[930:1140, 320:700] |= closed[930:1140, 320:700]
    for x, y, w, h in ADJ_CARVES + CAVE_CARVES + BUNKER_CARVES:
        rect(wall, x, y, w, h, 0)
    wall &= ~corridor(CAVE_NORTH_LEG, 36)
    wall &= ~corridor(CAVE_ROUTE, 40)
    return wall


def enforce_chokes(wall):
    """Measure each scheduled chokepoint; shave the rock until it meets spec
    (+8 px mask margin for disc overreach). Shaving erodes whichever wall the
    probe touches, 3 px per pass, logged."""
    for label, seg, want in CHOKES:
        want_mask = want + 8
        passes = 0
        while probe_gap(wall, seg) < want_mask and passes < 30:
            x0, y0, x1, y1 = seg
            n = int(max(abs(x1 - x0), abs(y1 - y0)))
            for i in range(n + 1):
                x = int(round(x0 + (x1 - x0) * i / n))
                y = int(round(y0 + (y1 - y0) * i / n))
                if wall[y, x]:
                    wall[max(0, y - 3):y + 4, max(0, x - 3):x + 4] = 0
            passes += 1
        got = probe_gap(wall, seg)
        status = "ok" if got >= want_mask else "STILL UNDER"
        print(f"  choke {label:<24} {got:>4}px (want >= {want_mask}) "
              f"[{passes} shaves] {status}")
        if got < want_mask:
            raise SystemExit(f"chokepoint {label} unresolvable")
    return wall


def main():
    print("building mask from the measured plan...")
    wall = build_mask()
    print("enforcing the chokepoint schedule (mask space, +8px margin):")
    wall = enforce_chokes(wall)

    # Fill pockets too small to stand in BEFORE fitting (seal pass).
    fits = fits_of(forced_floor(wall))
    lab, n = ndimage.label(fits)
    if n > 1:
        sizes = np.bincount(lab.ravel())[1:]
        main_lab = int(sizes.argmax()) + 1
        for i in range(1, n + 1):
            if i == main_lab:
                continue
            pocket = ndimage.binary_dilation(
                lab == i, np.ones((PLAYER + 4, PLAYER + 4), bool))
            wall |= pocket
            print(f"  sealed a {int((lab == i).sum())}-cell pocket as rock")

    # Terrain mask for fitting: mask minus explicit structures.
    terrain = wall.copy()
    for _, x, y, w, h in STRUCTS:
        rect(terrain, x, y, w, h, 0)
    print("fitting terrain discs (windowed greedy)...")
    discs = fit_terrain_discs(terrain)
    covered = np.zeros_like(terrain)
    for cx, cy, r in discs:
        y0, y1 = max(0, cy - r), min(H, cy + r + 1)
        x0, x1 = max(0, cx - r), min(W, cx + r + 1)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        covered[y0:y1, x0:x1] |= (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
    cov = (covered & terrain).sum() / max(terrain.sum(), 1)
    spill = covered & ~terrain
    over = ndimage.distance_transform_edt(~terrain)[spill].max() \
        if spill.any() else 0.0
    print(f"  {len(discs)} discs, coverage {cov:.1%}, max overreach "
          f"{over:.1f}px")
    if cov < 0.96 or over > 4.0:
        raise SystemExit("disc fit out of tolerance")

    # --- verify what ships --------------------------------------------------
    print("verifying the SHIPPED raster:")
    for attempt in range(2):
        shipped = raster_shapes(discs, STRUCTS, STRUCT_DISCS)
        # Written BEFORE the checks so a failed run leaves its evidence.
        Image.fromarray((~shipped * 255).astype(np.uint8)).save(
            "/tmp/afghan_v2_shipped.png")
        fits = fits_of(shipped)
        main_region = flood(fits, RED_HOME)
        landmarks = {
            "blueHome": blue_home(), "medkit cave": MEDKITS[0],
            "medkit wadi": MEDKITS[1],
            # East room of the bunker: the plan's (670,312) callout anchor
            # sits ON the room-divider wall (x 660-672), where the 13px-fit
            # erosion is False by construction -- a probe must be open floor.
            "bunker interior": (710, 300),
            "cave chamber": (1025, 660), "SW spur": (655, 1300),
        }
        ok = True
        for name, (x, y) in landmarks.items():
            reached = bool(main_region[y, x])
            print(f"  reach {name:<16} {'ok' if reached else 'FAIL'}")
            ok &= reached
        # Post-fit seal: disc overreach can pinch off a sliver that did not
        # exist on the pre-fit mask. Anything stranded on the SHIPPED raster
        # becomes rock -- a pocket too small to matter is a pocket a player
        # can be trapped in, and covering it is honest.
        stray = fits & ~main_region
        if stray.any():
            lab2, n2 = ndimage.label(stray)
            for i in range(1, n2 + 1):
                ys, xs = np.where(lab2 == i)
                cx, cy = int(xs.mean()), int(ys.mean())
                r = int(np.hypot(xs - cx, ys - cy).max()) + PLAYER + 2
                discs.append((cx, cy, r))
                print(f"  sealed a stranded {len(xs)}-cell sliver with rock "
                      f"disc ({cx},{cy}) r{r}")
            shipped = raster_shapes(discs, STRUCTS, STRUCT_DISCS)
            fits = fits_of(shipped)
            main_region = flood(fits, RED_HOME)
        stranded = int((fits & ~main_region).sum())
        print(f"  stranded 13px-fit cells: {stranded}")
        ok &= stranded == 0
        # Open cross-field rows, engine-test semantics.
        span = shipped[:, CAPTURE_CLEAR + 5:W - CAPTURE_CLEAR - 5]
        open_rows = int((~span).all(axis=1).sum())
        print(f"  fully-open cross-field rows: {open_rows}")
        ok &= open_rows == 0
        # Fairness: walk to midfield.
        free = ~shipped
        dr = bfs_dist(free, RED_HOME)
        db = bfs_dist(free, blue_home())
        col_r = dr[:, W // 2][dr[:, W // 2] >= 0]
        col_b = db[:, W // 2][db[:, W // 2] >= 0]
        rmid, bmid = int(col_r.min()), int(col_b.min())
        ratio = min(rmid, bmid) / max(rmid, bmid)
        print(f"  walk to midfield: red {rmid}, blue {bmid}, ratio "
              f"{ratio:.3f}")
        if ratio < 0.75 and attempt == 0 and bmid < rmid and \
                _blue_home[0] < 1290:
            _blue_home[0] = min(1290, _blue_home[0] + 39)
            print(f"  -> nudging blueHome east to {blue_home()} (plan-"
                  "sanctioned) and re-verifying")
            continue
        ok &= ratio >= 0.72
        if not ok:
            raise SystemExit("shipped-raster verification FAILED")
        break

    # --- emit ---------------------------------------------------------------
    out = ["    # === TERRAIN: measured valley (docs/designs/afghan-layout-"
           "v2.md), collision fitted to the mask ==="]
    for cx, cy, r in discs:
        out.append(f"    ArenaShape(kind: shapeDisc, cx: {cx}, cy: {cy}, "
                   f"radius: {r}),")
    out.append("    # === STRUCTURES: plan section 4, crisp rects ===")
    for name, x, y, w, h in STRUCTS:
        out.append(f"    # {name}")
        out.append(f"    ArenaShape(kind: shapeRect, rect: MapRect(x: {x}, "
                   f"y: {y}, w: {w}, h: {h})),")
    for name, cx, cy, r in STRUCT_DISCS:
        out.append(f"    # {name}")
        out.append(f"    ArenaShape(kind: shapeDisc, cx: {cx}, cy: {cy}, "
                   f"radius: {r}),")
    with open("/tmp/afghan_v2_shapes.nim", "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote /tmp/afghan_v2_shapes.nim ({len(discs)} terrain discs + "
          f"{len(STRUCTS)} rects + {len(STRUCT_DISCS)} discs)")
    print(f"final blueHome: {blue_home()}")

    Image.fromarray((~shipped * 255).astype(np.uint8)).save(
        "/tmp/afghan_v2_shipped.png")
    Image.fromarray((~wall * 255).astype(np.uint8)).save(
        "/tmp/afghan_v2_mask.png")
    print("previews: /tmp/afghan_v2_mask.png, /tmp/afghan_v2_shipped.png")


if __name__ == "__main__":
    sys.exit(main())
