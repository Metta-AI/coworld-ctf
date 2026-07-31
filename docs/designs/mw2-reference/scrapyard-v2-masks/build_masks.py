#!/usr/bin/env python3
"""Scrapyard v2: rasterize the measured layout into masks + plan view, verify."""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from pathlib import Path

W, H = 1235, 727
CX, CY = W // 2, H // 2          # engine-forced center (617, 363)
FLAG_RING = 70

RED_HOME = (257, 345)
BLUE_HOME = (978, 381)
SPAWN_W, SPAWN_H = 70, 85        # pocket half-extents
MEDKITS = [(580, 610), (455, 108)]
TRENCHES = [(600, 150, 150, 56), (560, 438, 128, 50), (866, 462, 104, 56),
            (352, 470, 56, 56)]
RED_SPAWN = (189, 262, 116, 166)
BLUE_SPAWN = (933, 300, 112, 162)

# Yard carve polygon (floor), clockwise.
YARD = [(142, 57), (460, 57), (460, 40), (1136, 40), (1136, 71), (1193, 71),
        (1193, 185), (1219, 185), (1219, 490), (1207, 490), (1207, 706),
        (125, 706), (125, 490), (21, 490), (21, 206), (142, 206)]

def R(x, y, w, h):  return ('rect', x, y, w, h)
def D(cx, cy, r):   return ('disc', cx, cy, r)
def DIA(x0, y0, x1, y1, t): return ('diag', x0, y0, x1, y1, t)
def DIAM(cx, cy, r): return ('diamond', cx, cy, r)

BUILDINGS = [
    # Depot (RED end, boundary-welded, enterable)
    R(21, 206, 121, 12), R(21, 206, 12, 284), R(21, 478, 121, 12),
    R(130, 206, 12, 32), R(130, 262, 12, 68), R(130, 354, 12, 124),
    R(33, 336, 64, 10),                     # interior partition
    R(135, 432, 136, 67),                   # stair porch [ADJ +30y]
    R(189, 213, 35, 7), R(217, 219, 7, 39), # annex room walls [ADJ trim]
    R(162, 146, 30, 6), R(267, 143, 33, 7), # NW low walls
    # Workshop
    R(301, 68, 95, 12),
    R(301, 136, 29, 12), R(358, 136, 38, 12),  # S wall, door 28 @330
    R(301, 80, 12, 56),
    R(384, 80, 12, 44),                        # E wall, door 24 @124..148
    R(330, 80, 34, 20),                        # bench welded to N wall
    # North shed (open-front bay)
    R(500, 40, 12, 130), R(738, 40, 12, 108),
    R(560, 60, 40, 30), R(650, 52, 36, 26),    # stored crates
    # Fuselage rack (walls; cylinders live in airframes mask)
    R(750, 40, 12, 60), R(847, 40, 12, 60),
    # Engine pen back mass (welded to fence)
    R(968, 40, 61, 63),
    # L-building: narrow skylight wing [ADJ -65x]
    R(482, 305, 10, 95), R(482, 428, 10, 26),
    R(529, 305, 10, 55), R(529, 388, 10, 66),
    R(482, 305, 57, 10), R(482, 444, 57, 16),
    # L-building: long shed [ADJ west face cut 604->695]
    R(695, 393, 65, 10), R(788, 393, 42, 10), R(858, 393, 41, 10),
    R(695, 440, 204, 10),
    R(695, 393, 10, 14), R(695, 435, 10, 15),  # W wall around door y407-435
    R(889, 393, 10, 57),
    R(790, 403, 60, 12),                       # stored-wing rack welded to N wall
    # Cutting shed [ADJ west face 302->324]
    R(330, 358, 10, 81), R(425, 358, 10, 81),
    R(330, 358, 25, 10), R(383, 358, 52, 10),
    R(330, 429, 25, 10), R(383, 429, 52, 10),
    # Crane base / the Tower
    R(229, 535, 41, 12), R(298, 535, 50, 12),
    R(229, 535, 12, 118), R(229, 641, 119, 12),
    R(336, 535, 12, 35), R(336, 598, 12, 55),
    R(265, 575, 40, 40),                       # tower core
    # Warehouse (south-center, enterable, boundary-welded south)
    R(405, 528, 85, 12), R(518, 528, 122, 12), R(668, 528, 86, 12),
    R(405, 528, 12, 62), R(405, 618, 12, 88),
    R(742, 528, 12, 104), R(742, 660, 12, 46),
    R(405, 694, 349, 14),
    R(470, 580, 90, 24), R(560, 630, 120, 26), R(668, 540, 24, 60),  # racks
    # Long wall + baffle
    R(754, 525, 172, 18), R(535, 450, 19, 78),
    # Hangar (BLUE end, boundary-welded east)
    R(1051, 185, 69, 12), R(1148, 185, 71, 12),
    R(1207, 185, 12, 305),
    R(1051, 478, 31, 12), R(1110, 478, 109, 12),
    R(1051, 185, 18, 58), R(1051, 417, 18, 73),  # W piers, mouth y243..417
    R(1080, 290, 40, 26), R(1150, 330, 42, 32),  # rail-line debris
]
AIRFRAMES = [
    D(300, 232, 25), R(307, 207, 153, 50),        # F1 nose + hull [ADJ -36y]
    DIA(527, 259, 570, 206, 44),                  # F2 tilted section
    R(628, 241, 140, 52),                         # F3 gutted hull
    R(821, 238, 155, 50),                         # F4 hull [ADJ +30x, E face welds MG]
    R(695, 290, 111, 61),                         # wing slab (art rot ~20)
    R(762, 40, 85, 26), R(762, 66, 85, 26),       # rack cylinders
    D(872, 331, 16), D(876, 300, 13), D(884, 372, 21), D(386, 304, 11),  # fans
    D(998, 122, 20),                              # engine pen disc (art: 2 engines)
    DIA(905, 240, 985, 190, 30),                  # wing wreck [ADJ N]
    R(1020, 200, 34, 44),                         # tail wreck [ADJ NE]
]
SCRAP = [
    DIAM(895, 70, 36), D(920, 42, 18),            # scrap heap [ADJ welded W to rack]
    R(847, 40, 50, 44),                           # heap shoulder (welds rack->heap)
    DIA(770, 188, 843, 162, 34), R(760, 168, 30, 30),  # flatbed + container [ADJ +22y]
    R(1054, 104, 36, 15), R(1090, 101, 54, 20),   # NE crates
    R(600, 490, 91, 38),                          # truck trailer [ADJ]
    R(991, 578, 30, 88),                          # SE standing trailer
    R(778, 636, 64, 27),                          # container [ADJ +61y]
    R(1172, 490, 35, 43),                         # hangar-side crates
    DIAM(560, 185, 22),                           # parts pile at F2 nose
    DIA(812, 452, 852, 478, 22),                  # leaning scrap sheet on shed S
    DIAM(996, 264, 22),                           # MG nest [ADJ]
]

def raster(shapes):
    im = Image.new('L', (W, H), 0)
    d = ImageDraw.Draw(im)
    for s in shapes:
        if s[0] == 'rect':
            _, x, y, w, h = s
            if w > 0 and h > 0: d.rectangle([x, y, x + w - 1, y + h - 1], fill=255)
        elif s[0] == 'disc':
            _, cx, cy, r = s; d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
        elif s[0] == 'diamond':
            _, cx, cy, r = s
            d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=255)
        elif s[0] == 'diag':
            _, x0, y0, x1, y1, t = s
            d.line([(x0, y0), (x1, y1)], fill=255, width=t)
    return np.array(im) > 0

def main():
    yard = Image.new('L', (W, H), 0)
    ImageDraw.Draw(yard).polygon(YARD, fill=255)
    yard = np.array(yard) > 0
    boundary = ~yard

    b = raster(BUILDINGS); a = raster(AIRFRAMES); s = raster(SCRAP)
    walls = boundary | b | a | s

    # engine force-carves: flag ring + spawn pockets
    yy, xx = np.mgrid[0:H, 0:W]
    ring = (xx - CX) ** 2 + (yy - CY) ** 2 <= FLAG_RING ** 2
    carved = np.zeros((H, W), bool)
    for hx, hy in (RED_HOME, BLUE_HOME):
        carved |= (np.abs(xx - hx) <= SPAWN_W) & (np.abs(yy - hy) <= SPAWN_H)
    forced = ring | carved
    for nm, shapes in (('B', BUILDINGS), ('A', AIRFRAMES), ('S', SCRAP)):
        for i, sh in enumerate(shapes):
            m = raster([sh])
            n = int((m & forced).sum())
            if n: print('CHEW', nm, i, sh, n)
    chew = {}
    for name, m in (('boundary', boundary), ('buildings', b), ('airframes', a), ('scrap', s)):
        chew[name] = int((m & forced).sum())
    print('forced-carve chew (px per mask, want 0):', chew)

    floor = ~walls
    floor_after = floor | forced

    # 1px flood from red home
    lab, _ = ndimage.label(floor_after)
    rid = lab[RED_HOME[1], RED_HOME[0]]
    targets = {
        'blueHome': BLUE_HOME, 'medkit_warehouse': MEDKITS[0], 'medkit_north': MEDKITS[1],
        'depot_interior': (60, 300), 'workshop_interior': (320, 120),
        'wing_bay': (510, 370), 'long_shed_interior': (800, 428),
        'crane_interior': (250, 620), 'warehouse_interior': (500, 620),
        'hangar_interior': (1130, 330), 'NE_pocket': (1100, 140),
        'SE_yard': (950, 620), 'north_shed_bay': (620, 100),
        'annex_nook': (205, 240), 'cutting_shed': (375, 400),
    }
    ok = True
    for t, (tx, ty) in targets.items():
        good = lab[ty, tx] == rid
        ok &= good
        print(f'flood {t:22s} {"OK" if good else "FAIL (comp %d vs %d)" % (lab[ty, tx], rid)}')
    # sealed pockets: any floor component not reachable & bigger than 100 px?
    for i in range(1, lab.max() + 1):
        if i != rid:
            sz = int((lab == i).sum())
            if sz > 40:
                ys, xs = np.nonzero(lab == i)
                print(f'SEALED POCKET comp {i} size {sz} at ~({int(xs.mean())},{int(ys.mean())})')
                ok = False

    # open-row max run (inside yard)
    best = (0, 0, 0)
    for y in range(0, H):
        row = floor_after[y] & yard[y]
        if not row.any(): continue
        run, start, mx, ms = 0, 0, 0, 0
        for x in range(W):
            if row[x]:
                if run == 0: start = x
                run += 1
                if run > mx: mx, ms = run, start
            else: run = 0
        if mx > best[0]: best = (mx, ms, y)
    print(f'longest open row run: {best[0]} px at y={best[2]} x0={best[1]}')
    bestc = (0, 0, 0)
    for x in range(W):
        col = floor_after[:, x] & yard[:, x]
        run, mx, ms, start = 0, 0, 0, 0
        for y in range(H):
            if col[y]:
                if run == 0: start = y
                run += 1
                if run > mx: mx, ms = run, start
            else: run = 0
        if mx > bestc[0]: bestc = (mx, ms, x)
    print(f'longest open col run: {bestc[0]} px at x={bestc[2]} y0={bestc[1]}')

    # stand cover: structure-wall fraction of yard ground within r200 of each home
    struct = b | a | s
    for nm, (hx, hy) in (('red', RED_HOME), ('blue', BLUE_HOME)):
        m = (xx - hx) ** 2 + (yy - hy) ** 2 <= 200 ** 2
        ground = m & (yard | struct)
        cov = (m & struct).sum() / max(ground.sum(), 1)
        print(f'{nm} stand cover within 200px: {100 * cov:.1f}%  (target 10-25)')

    # emit masks
    out = Path('docs/designs/mw2-reference/scrapyard-v2-masks')
    out.mkdir(parents=True, exist_ok=True)
    counts = {}
    for name, m in (('boundary', boundary), ('buildings', b), ('airframes', a), ('scrap', s)):
        img = Image.fromarray((m * 255).astype(np.uint8))
        img.save(out / f'{name}.png')
        counts[name] = int(m.sum())
    print('mask white counts:', counts)

    # plan view
    view = np.zeros((H, W, 3), np.uint8)
    view[:, :] = (52, 50, 46)                 # boundary fill
    view[yard] = (108, 106, 100)              # yard floor
    view[carved & ~walls] = (118, 116, 108)
    for m, col in ((b, (168, 120, 84)), (a, (206, 208, 214)), (s, (180, 158, 96))):
        view[m] = col
    view[boundary] = (52, 50, 46)
    img = Image.fromarray(view)
    d = ImageDraw.Draw(img, 'RGBA')
    for x, y, w_, h_ in TRENCHES:
        d.rectangle([x, y, x + w_, y + h_], fill=(70, 82, 60, 255), outline=(40, 50, 30))
    d.ellipse([CX - FLAG_RING, CY - FLAG_RING, CX + FLAG_RING, CY + FLAG_RING],
              outline=(80, 200, 255), width=2)
    for (hx, hy), col in ((RED_HOME, (255, 80, 60)), (BLUE_HOME, (80, 140, 255))):
        d.ellipse([hx - 8, hy - 8, hx + 8, hy + 8], outline=col, width=3)
        d.rectangle([hx - SPAWN_W, hy - SPAWN_H, hx + SPAWN_W, hy + SPAWN_H],
                    outline=col + (150,), width=1)
    for r, col in ((RED_SPAWN, (255, 80, 60, 200)), (BLUE_SPAWN, (80, 140, 255, 200))):
        d.rectangle([r[0], r[1], r[0] + r[2], r[1] + r[3]], outline=col, width=2)
    for mx, my in MEDKITS:
        d.ellipse([mx - 6, my - 6, mx + 6, my + 6], outline=(90, 230, 120), width=3)
    for x in range(0, W, 100):
        d.line([(x, 0), (x, H)], fill=(255, 70, 50, 60))
        d.text((x + 2, 2), str(x), fill=(255, 120, 80))
    for y in range(0, H, 100):
        d.line([(0, y), (W, y)], fill=(255, 70, 50, 60))
        d.text((2, y + 2), str(y), fill=(255, 120, 80))
    lanes = {
        'N': [(250, 230), (350, 170), (470, 110), (620, 170), (870, 170), (1000, 170), (1100, 150), (1134, 220)],
        'M': [(250, 345), (400, 340), (470, 363), (617, 363), (740, 375), (860, 370), (985, 381), (1100, 330)],
        'S': [(250, 430), (330, 500), (400, 640), (480, 660), (590, 470), (700, 470), (860, 480), (960, 500), (1040, 560), (1100, 500)],
    }
    for nm, pts in lanes.items():
        d.line(pts, fill=(255, 235, 90, 190), width=3)
        d.text((pts[0][0] - 16, pts[0][1] - 6), nm, fill=(255, 235, 90))
    labels = [
        ('DEPOT', 40, 250), ('WORKSHOP', 305, 52), ('NORTH SHED', 560, 44),
        ('RACK', 755, 30), ('HEAP', 880, 60), ('ENGINE PEN', 950, 40),
        ('F1', 360, 255), ('F2', 530, 215), ('F3', 680, 253), ('F4', 880, 250),
        ('WING BAY', 470, 290), ('LONG SHED', 760, 418), ('WING SLAB', 700, 312),
        ('CUT SHED', 330, 345), ('CRANE', 240, 522), ('WAREHOUSE', 540, 560),
        ('HANGAR', 1090, 258), ('MG', 1000, 244), ('PORCH', 150, 445),
        ('TRAILER', 985, 560),
    ]
    for txt, x, y in labels:
        d.text((x, y), txt, fill=(255, 255, 255, 220))
    img.save('/tmp/scrapyard_plan_view.jpg', quality=92)
    img.resize((800, int(800 * H / W)), Image.LANCZOS).save('/tmp/scrap_plan_small.jpg', quality=90)
    print('plan view written. all-flood-ok:', ok)

if __name__ == '__main__':
    main()
