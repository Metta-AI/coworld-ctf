#!/usr/bin/env python3
"""Favela v2 — authored geometry -> raster masks + plan view + checks.

Canvas: 1228 x 1122, transform from 512-ref: canvas = (ref - (51,76)) * 3.0.
All geometry below is the SHIPPED plan (doc: docs/designs/favela-layout-v2.md).
"""
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

W, H = 1228, 1122
CX, CY = W // 2, H // 2          # 614, 561 engine-forced center
FLAG_RING = 70
RED_HOME = (150, 430)
BLUE_HOME = (1085, 222)
SPAWN_CLEAR = (70, 96)           # half extents of forced spawn pockets
RED_SPAWN = (60, 292, 110, 120)  # x,y,w,h respawn zones
BLUE_SPAWN = (1090, 160, 64, 130)
MEDKITS = [(580, 600), (920, 480)]
TRENCHES = [(180, 640, 48, 80), (466, 731, 140, 24), (668, 880, 36, 60)]

# ---------------------------------------------------------------- boundary
# Playable outline, clockwise. Everything outside is perimeter (solid
# out-of-bounds favela hillside). [ADJ] points noted in the doc.
BOUNDARY = [
    (342, 106), (525, 106), (525, 32), (668, 32), (670, 120),   # top terrace notch
    (932, 150), (1000, 150), (1000, 120), (1160, 120),          # north edge, NE yard deepened [ADJ]
    (1217, 180), (1181, 269), (1181, 306), (1210, 310),         # NE corner
    (1208, 490), (1160, 660), (1160, 828),                      # east wall + SE diagonal
    (1060, 860), (1060, 985),                                   # SE yard
    (708, 985), (708, 1091), (664, 1091), (664, 783),           # south stairs + bottom landing
    (443, 783),                                                 # street south face (center-west)
    (443, 947), (266, 947),                                     # SW pocket (mouth staggered off the shop cut [ADJ])
    (223, 893), (189, 869), (167, 857),                         # SW pocket west mouth
    (27, 838), (29, 776), (73, 777), (79, 736),                 # west nook
    (161, 734), (177, 607),                                     # stepped street east side
    (120, 530), (80, 530), (54, 488),                           # yard south extension [ADJ]
    (54, 260), (247, 258), (247, 282), (342, 282),              # west yard + NW upper yard
]
# Interior floor holes in the perimeter? none; but the south fabric between
# street and pocket etc. is encoded as perimeter INLETS below.
# Regions that must stay SOLID inside the outline (out-of-bounds masses that
# the outline wraps around as concavities are already handled by the polygon;
# the two literal interior solids: the south block and the SE corner block).
PERIM_SOLIDS = [
    # south terrace block between the main street and the lower pocket
    [(708, 815), (908, 815), (908, 905), (708, 905)],
    # ...west part between stairs/apron handled by boundary (street face y783
    #    for x 459..614). Apron x 664..700 y 783..815 stays floor:
    # SE corner block between the east street reach and the SE yard
    [(1021, 716), (1160, 716), (1160, 828), (1021, 828)],
    # north-edge spur east of the top terrace notch: bends the upper back
    # alley (dogleg south through the Yellow-gap, x 628..664) [ADJ]
    [(664, 120), (694, 120), (694, 220), (664, 220)],
    # buttress at the measured boundary jog (932,151)-(944,172): caps the
    # Bar-front alley; upper lane exits to the NE yard via (946..1000,150..221)
    [(932, 150), (946, 150), (946, 218), (932, 218)],
]
# floor CUTS back out of PERIM_SOLIDS (none needed; ramp is west of SE block)

# ---------------------------------------------------------------- blocks
# name -> list of rect (x,y,w,h) or ("poly", pts). Solid building masses.
BLOCKS = {
    "hilltop shack": [(551, 63, 86, 95)],
    "yellow building": [(536, 196, 92, 105)],
    "crackhouse annex": [(472, 246, 64, 54)],
    "crackhouse body": [(467, 300, 73, 245)],
    "crackhouse east wing": [(540, 407, 124, 73)],
    "green house": [(327, 336, 140, 106)],
    "brickhouse": [(333, 471, 106, 112)],
    "west stair wall upper": [(254, 317, 28, 86)],
    "west stair wall parapet": [(270, 403, 12, 180)],
    "terrace lip wall": [(740, 383, 177, 25)],
    "red house": [(690, 450, 162, 156)],
    "laundromat": [(309, 611, 150, 125)],
    # west face at 485 staggers the shop cut (alley x 459..485) off the
    # laundromat/green-house column so no N-S sightline threads it [ADJ]
    "barber shop": [(485, 640, 143, 81)],
    "ice cream shop": [(656, 640, 219, 84)],
    "the bar hall": [(735, 218, 167, 50)],
    "bar west wing": [(735, 268, 52, 44)],
    "bar east wing": [(869, 268, 33, 44)],
    # bottom at 330 (measured west-face alcove notches y 301..331): opens the
    # x 930..970 dogleg from the yard-stair corridor into the terrace band
    "terrace houses arm": [(930, 221, 40, 109)],
    # strip top at the MEASURED y=358 (comp98 west face starts (970,358)):
    # the 44px corridor x 970..1014 above it is the yard->terrace stair,
    # blue's direct route to midfield; also keeps the blue spawn pocket
    # (1015..1155 x 126..318) carve-free
    "ladder building strip": [(970, 358, 44, 298), (1014, 358, 53, 298)],
    "ladder north arm": [(1014, 326, 131, 32)],
    "garage lobe a": [(1067, 494, 54, 147)],
    "garage lobe b": [(1121, 527, 35, 50)],
    # hillside house fused to the NE boundary: breaks the back-street
    # north-south sightline; sits just east of the blue spawn pocket [ADJ]
    "east edge house": [(1156, 230, 44, 36)],
    # fuses the ice-cream top edge to the red-house SW corner: breaks the
    # shop back alley into west/east halves (anti-sightline) [ADJ]
    "backalley bridge": [(690, 606, 34, 34)],
}
# Interior floor carved back OUT of blocks (enterable rooms) + door gaps.
# rect floors; doors are floor rects punched through 12px wall bands.
INTERIORS = {
    "crackhouse room": [(479, 392, 37, 141)],   # inside body (12px walls)
    "red house room": [(702, 462, 138, 132)],
    "laundromat room": [(321, 623, 126, 101)],
    # room stops at x=604 so the engine-center column (x=614) stays a wall
    # band here and the midfield alley count holds at five [ADJ]
    "barber room": [(497, 652, 107, 57)],
    "bar room": [(747, 230, 143, 26)],
    "ladder lobby": [(982, 470, 73, 90)],
}
DOORS = [
    (467, 440, 12, 26),    # crackhouse west door -> plaza alley
    (690, 516, 12, 28),    # red house west door -> town square
    (780, 594, 12, 28),    # red house south door -> shop alley
    (380, 611, 26, 12),    # laundromat back door (north)
    (520, 640, 28, 12),    # barber north door -> town square
    (806, 256, 28, 12),    # bar south door -> bar yard
    (970, 500, 12, 26),    # ladder lobby west door -> east court
    (1055, 448, 12, 26),   # ladder lobby east door -> garage yard
]
WINDOWS = [
    (528, 500, 12, 33),    # crackhouse slit over the town square (east face)
    (690, 468, 12, 28),    # red house window over the square (west face)
    (321, 724, 126, 12),   # laundromat shopfront (main street)
    (497, 709, 119, 20),   # barber shopfront + street counter lip
    (668, 712, 195, 16),   # ice cream shopfront + street counter lip
    (747, 218, 143, 12),   # bar north window over the upper alley
]

# ---------------------------------------------------------------- shanties
# small cover: stalls, huts, kiosks, low walls, drums, planters.
# ("rect",x,y,w,h) ("diag",x0,y0,x1,y1,t) ("disc",cx,cy,r) ("diam",cx,cy,r)
SHANTIES = [
    ("diam", 952, 250, 20, "NE tin shack"),
    ("diam", 922, 592, 20, "east court kiosk"),
    ("rect", 300, 865, 46, 56, "junk row hut"),
    ("rect", 266, 776, 140, 16, "street stall row wall (SW)"),
    ("rect", 352, 765, 44, 18, "street stall W"),
    ("rect", 513, 756, 46, 27, "street stall mid"),
    ("diag", 660, 764, 696, 788, 12, "street stall (kink)"),
    ("rect", 852, 825, 47, 33, "apron stall A"),
    ("rect", 696, 843, 49, 36, "apron stall B"),
    ("rect", 807, 882, 49, 30, "apron stall C"),
    ("rect", 875, 890, 62, 26, "pocket stall"),
    ("diag", 96, 278, 132, 266, 12, "yard cart A"),
    ("diag", 180, 300, 214, 316, 14, "yard cart B"),
    ("rect", 228, 420, 26, 18, "yard cart C"),
    ("diag", 230, 500, 254, 524, 12, "yard cart D"),
    ("diam", 430, 745, 13, "main street planter"),
    ("disc", 760, 741, 14, "main street drum A"),
    ("rect", 906, 660, 64, 20, "east reach stall (court mouth)"),
    ("rect", 1130, 460, 28, 28, "back-street stall"),
    ("disc", 120, 800, 12, "west nook boulder"),
    # the SW slope is stepped ground: a low terrace wall breaks the
    # yard->street north-south sightline, gap 277..309 at the laundromat
    ("rect", 177, 616, 100, 14, "slope terrace wall"),
    ("diag", 262, 700, 296, 738, 14, "slope cart"),
    # shed fusing the brickhouse bottom to the laundromat top: splits the
    # shop back alley's west half off the slope (anti-sightline) [ADJ]
    ("rect", 352, 583, 26, 28, "back-alley shed"),
]


def rasterize():
    per = Image.new("1", (W, H), 1)          # start all-solid
    d = ImageDraw.Draw(per)
    d.polygon(BOUNDARY, fill=0)              # carve playable
    for pts in PERIM_SOLIDS:
        d.polygon(pts, fill=1)
    per = np.array(per, bool)

    blk = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(blk)
    for name, rects in BLOCKS.items():
        for r in rects:
            x, y, w, h = r
            d.rectangle([x, y, x + w - 1, y + h - 1], fill=1)
    for name, rects in INTERIORS.items():
        for x, y, w, h in rects:
            d.rectangle([x, y, x + w - 1, y + h - 1], fill=0)
    for x, y, w, h in DOORS:
        d.rectangle([x, y, x + w - 1, y + h - 1], fill=0)
    blk = np.array(blk, bool)

    win = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(win)
    for x, y, w, h in WINDOWS:
        d.rectangle([x, y, x + w - 1, y + h - 1], fill=1)
    win = np.array(win, bool)
    blk &= ~win

    sh = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(sh)
    for s in SHANTIES:
        if s[0] == "rect":
            _, x, y, w, h, _n = s
            d.rectangle([x, y, x + w - 1, y + h - 1], fill=1)
        elif s[0] == "diag":
            _, x0, y0, x1, y1, t, _n = s
            d.line([(x0, y0), (x1, y1)], fill=1, width=t)
        elif s[0] == "disc":
            _, cx, cy, r, _n = s
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=1)
        elif s[0] == "diam":
            _, cx, cy, r, _n = s
            d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=1)
    sh = np.array(sh, bool)
    return per, blk, win, sh


def forced_carves(wall):
    """Return wall pixels the engine force-carves (should be ~zero)."""
    yy, xx = np.mgrid[0:H, 0:W]
    ring = (xx - CX) ** 2 + (yy - CY) ** 2 <= FLAG_RING ** 2
    hits = {"flag ring": int((wall & ring).sum())}
    for nm, (hx, hy) in (("red pocket", RED_HOME), ("blue pocket", BLUE_HOME)):
        px = (np.abs(xx - hx) <= SPAWN_CLEAR[0]) & (np.abs(yy - hy) <= SPAWN_CLEAR[1])
        hits[nm] = int((wall & px).sum())
    return hits


def check(per, blk, win, sh):
    wall = per | blk | sh          # walk-blocking, shot-blocking
    solid = wall | win             # walk-blocking
    floor = ~solid

    print("== forced-carve collisions (want 0) ==")
    for k, v in forced_carves(solid).items():
        print(f"  {k}: {v}")

    # center column alleys
    col = floor[:, CX]
    runs, y = [], 0
    while y < H:
        if col[y]:
            y0 = y
            while y < H and col[y]:
                y += 1
            runs.append((y0, y - y0))
        else:
            y += 1
    runs = [r for r in runs if r[1] >= 20]
    print(f"== center column x={CX}: {len(runs)} floor gaps ==")
    for y0, ln in runs:
        print(f"  y {y0}..{y0+ln} ({ln}px)")

    # 13px-player connectivity (erode by r=6 disc)
    r = 6
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    disc = (xx * xx + yy * yy) <= r * r
    open6 = ndimage.binary_erosion(floor, disc)
    lbl, _n = ndimage.label(open6)
    hid = lbl[RED_HOME[1], RED_HOME[0]]
    print("== 13px-fit connectivity from redHome ==")
    ok = True
    targets = {"blueHome": BLUE_HOME, "medkit A": MEDKITS[0], "medkit B": MEDKITS[1],
               "bottom landing": (686, 1050), "SW pocket": (400, 880),
               "NE yard": (1080, 240), "top terrace": (600, 45),
               "lower pocket": (800, 945), "SE yard": (1000, 920)}
    for nm, rects in INTERIORS.items():
        x, y, w, h = rects[0]
        targets[nm] = (x + w // 2, y + h // 2)
    for nm, (x, y) in targets.items():
        t = lbl[y, x]
        good = t == hid and t != 0
        ok &= good
        print(f"  {nm} ({x},{y}): {'OK' if good else 'FAIL id=' + str(t)}")
    # stranded open floor
    sizes = ndimage.sum(open6, lbl, range(1, lbl.max() + 1))
    stray = [(i + 1, int(s)) for i, s in enumerate(sizes) if s > 40 and i + 1 != hid]
    print(f"  stranded open-floor comps >40px: {stray}")

    # 24px corridor connectivity (erode by r=12)
    r = 12
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    disc = (xx * xx + yy * yy) <= r * r
    open12 = ndimage.binary_erosion(floor, disc)
    l2, _ = ndimage.label(open12)
    h2 = l2[RED_HOME[1], RED_HOME[0]]
    bad = []
    for nm, (x, y) in targets.items():
        if nm in INTERIORS:  # rooms are entered through 26-28px doors; eroded
            continue         # centers can pinch, checked at 13px fit above
        if l2[y, x] != h2:
            bad.append(nm)
    print(f"== 24px-corridor connectivity: {'OK' if not bad else 'FAIL ' + str(bad)} ==")

    # longest open runs
    best = (0, 0, 0)
    for y in range(H):
        row = floor[y]
        x = 0
        while x < W:
            if row[x]:
                x0 = x
                while x < W and row[x]:
                    x += 1
                if x - x0 > best[0]:
                    best = (x - x0, x0, y)
            else:
                x += 1
    print(f"== longest open row segment: {best[0]}px at y={best[2]} x={best[1]}..{best[1]+best[0]} ==")
    bestv = (0, 0, 0)
    for x in range(W):
        colf = floor[:, x]
        y = 0
        while y < H:
            if colf[y]:
                y0 = y
                while y < H and colf[y]:
                    y += 1
                if y - y0 > bestv[0]:
                    bestv = (y - y0, x, y0)
            else:
                y += 1
    print(f"== longest open column segment: {bestv[0]}px at x={bestv[1]} y={bestv[2]}.. ==")

    # wall cover fraction inside playable frame
    play = ~per
    print(f"== cover: blocks+shanties = {(blk|sh).sum()/play.sum():.1%} of playable; "
          f"playable = {play.sum()/(W*H):.1%} of canvas ==")
    return ok


def masks_out(per, blk, win, sh):
    import os
    out = "/Users/maxwellstarr/projects/coworld-ctf-mw2/docs/designs/mw2-reference/favela-v2-masks"
    os.makedirs(out, exist_ok=True)
    for nm, m in (("perimeter", per), ("blocks", blk), ("windows", win), ("shanties", sh)):
        Image.fromarray((m * 255).astype(np.uint8), "L").save(f"{out}/{nm}.png")
        print(f"{nm}.png white px = {int(m.sum())}")


def plan_view(per, blk, win, sh):
    img = Image.new("RGB", (W, H), (52, 46, 42))          # perimeter dark
    px = np.array(img)
    px[~per] = (168, 158, 148)                            # floor
    px[blk] = (196, 148, 96)                              # blocks tan
    px[sh] = (222, 120, 60)                               # shanties orange
    px[win] = (90, 170, 230)                              # windows blue
    img = Image.fromarray(px)
    d = ImageDraw.Draw(img, "RGBA")
    for x, y, w, h in TRENCHES:
        d.rectangle([x, y, x + w, y + h], outline=(70, 110, 60), width=3)
    d.ellipse([CX - FLAG_RING, CY - FLAG_RING, CX + FLAG_RING, CY + FLAG_RING],
              outline=(40, 170, 220), width=3)
    for nm, (hx, hy), col in (("RED", RED_HOME, (200, 40, 40)),
                              ("BLUE", BLUE_HOME, (40, 60, 220))):
        d.ellipse([hx - 9, hy - 9, hx + 9, hy + 9], outline=col, width=4)
        d.ellipse([hx - 64, hy - 64, hx + 64, hy + 64], outline=col + (120,), width=2)
    for (x, y, w, h), col in ((RED_SPAWN, (200, 40, 40)), (BLUE_SPAWN, (40, 60, 220))):
        d.rectangle([x, y, x + w, y + h], outline=col, width=3)
    for mx, my in MEDKITS:
        d.rectangle([mx - 7, my - 7, mx + 7, my + 7], fill=(240, 240, 240))
        d.line([(mx - 4, my), (mx + 4, my)], fill=(200, 30, 30), width=3)
        d.line([(mx, my - 4), (mx, my + 4)], fill=(200, 30, 30), width=3)
    lanes = {
        # lane 1 NORTH: yard slot -> NW terrace column -> upper back alley
        # (dogleg under the spur) -> bar-front -> bar-arm gap descent ->
        # terrace band -> yard stair -> NE yard
        (250, 220, 60): [(150, 430), (264, 300), (310, 300), (350, 298), (365, 270),
                         (365, 180), (450, 170), (600, 178), (640, 188), (645, 215),
                         (680, 240), (715, 205), (880, 190), (916, 205), (916, 290),
                         (916, 335), (940, 355), (985, 345), (990, 250), (1015, 235),
                         (1085, 222)],
        # lane 2 CENTER: plaza street -> under-green band -> crackhouse alley ->
        # back alley -> town square -> red house north alley -> lip gap ->
        # terrace band -> yard stair -> NE yard
        (60, 220, 120): [(150, 430), (264, 300), (307, 340), (307, 450), (410, 456),
                         (448, 466), (453, 510), (453, 555), (470, 595), (545, 595),
                         (614, 561), (677, 520), (677, 435), (700, 430), (880, 425),
                         (920, 418), (931, 396), (940, 370), (985, 350), (990, 250),
                         (1015, 235), (1085, 222)],
        # lane 3 MAIN STREET: yard ext -> slope east of the diagonal -> west
        # reach (threading south of planter/drum) -> bend -> east reach ->
        # back street north to the NE yard
        (230, 90, 200): [(150, 470), (150, 505), (190, 560), (250, 595), (292, 622),
                         (260, 660), (230, 720), (250, 756), (340, 748), (400, 758),
                         (430, 770), (460, 765), (490, 748), (575, 740), (600, 745),
                         (700, 748), (740, 765), (790, 765), (870, 748), (910, 700),
                         (1000, 690), (1140, 680), (1170, 600), (1190, 480),
                         (1195, 330), (1160, 290), (1120, 245), (1085, 222)],
        # lane 4 SOUTH LOOP: street -> stairs -> lower pocket -> SE yard -> ramp
        (255, 255, 255): [(640, 760), (686, 800), (686, 900), (720, 945), (800, 945),
                          (920, 945), (1000, 900), (1000, 840), (975, 760), (960, 700)],
    }
    for col, pts in lanes.items():
        d.line(pts, fill=col + (200,), width=4)
    img.save("/tmp/favela_plan_view_full.png")
    img.convert("RGB").resize((780, int(780 * H / W)), Image.LANCZOS).save(
        "/tmp/favela_plan_view.jpg", quality=80)
    print("plan view -> /tmp/favela_plan_view.jpg")


if __name__ == "__main__":
    per, blk, win, sh = rasterize()
    check(per, blk, win, sh)
    masks_out(per, blk, win, sh)
    plan_view(per, blk, win, sh)
