#!/usr/bin/env python3
"""Builds a pack map from a HAND-AUTHORED structure list, then makes it playable.

Why both this and mw2_trace.py: tracing recovers where things are but not what
they are. It reads a building's lit roof and its shadow as two shapes, splits a
concourse into fragments, and cannot know that one blob is the 747 and the next
is Burger Town. Naming the structures fixes identity — but hand-authored geometry
still has to earn the pack invariants, and that machinery already exists.

So the split is: this module owns WHAT and WHERE (named structures, measured off
the grid plates in docs/designs/mw2-reference/prepped/<map>-grid.png, whose axes
are the game's own pixel coordinates), and mw2_trace.py owns MAKING IT PLAYABLE
(carve the protected regions, connect sealed rooms with doorways, equalize the
walk to midfield, close open firing rows, decompose to ArenaShape rects, and
verify all of it on the rasterized shape list that actually ships).

Each structure is a rect with a NAME, so the emitted Nim carries the callout as a
comment and a reviewer can check the map against the reference by reading it.
Walls are authored as thin rects with explicit door GAPS, which is how the real
maps are built and what makes the result read as architecture.

Usage: python3 tools/mw2_author.py [map ...]
Writes /tmp/mw2map_<name>.nim + /tmp/mw2trace_<name>.png, same contract as
mw2_trace.py, so tools/mw2_integrate.py and the gallery consume either one.
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mw2_trace import (  # noqa: E402
    BLURB, CX, CY, MAP_H, MAP_W, MATERIALS, MID_TOL, emit, label_components,
    occupiable, parity, preview, protected_mask, rasterize, verify,
    merge_rects, decompose, repair, pickets_for,
)

# Layouts are declared as (name, x, y, w, h) in GAME pixels, read off the grid
# plates. A `name` beginning with "wall" is structural; everything else is a
# solid prop. Door gaps are expressed by simply not covering that span.
LAYOUTS = {}


def hbar(name, x0, x1, y, t=16, gaps=()):
    """A horizontal wall from x0 to x1 at y, thickness t, minus door gaps.

    Real MW2 buildings are enterable, so a wall is authored as the spans BETWEEN
    its doors. Doors are what keep the layout from sealing rooms the invariant
    forbids, and cutting them here (rather than letting the repair pass discover
    them) puts them where the real map has them.
    """
    out = []
    cuts = sorted(gaps)
    x = x0
    for gx0, gx1 in cuts:
        if gx0 > x:
            out.append((name, x, y, gx0 - x, t))
        x = max(x, gx1)
    if x < x1:
        out.append((name, x, y, x1 - x, t))
    return out


def vbar(name, y0, y1, x, t=16, gaps=()):
    """A vertical wall from y0 to y1 at x, thickness t, minus door gaps."""
    out = []
    y = y0
    for gy0, gy1 in sorted(gaps):
        if gy0 > y:
            out.append((name, x, y, t, gy0 - y))
        y = max(y, gy1)
    if y < y1:
        out.append((name, x, y, t, y1 - y))
    return out


def room(name, x, y, w, h, t=16, doors=()):
    """A hollow room: four walls with door gaps, interior left playable.

    doors is a list of (side, start, length) with side in NSEW, measured from
    the room's own origin — the notation a level designer actually thinks in.
    """
    n_gaps, s_gaps, e_gaps, w_gaps = [], [], [], []
    for side, start, length in doors:
        if side == "N":
            n_gaps.append((x + start, x + start + length))
        elif side == "S":
            s_gaps.append((x + start, x + start + length))
        elif side == "W":
            w_gaps.append((y + start, y + start + length))
        elif side == "E":
            e_gaps.append((y + start, y + start + length))
    out = []
    out += hbar(name, x, x + w, y, t, n_gaps)
    out += hbar(name, x, x + w, y + h - t, t, s_gaps)
    out += vbar(name, y, y + h, x, t, w_gaps)
    out += vbar(name, y, y + h, x + w - t, t, e_gaps)
    return out


def plane(name, cx, cy, length, span, nose="W", engines=2, fin=True):
    """An aircraft silhouette in rects: fuselage, swept wings, tail, engines.

    Three of the six maps are built around a recognizable airframe (Terminal's
    747 at the gate, Afghan's crashed C-130, Scrapyard's boneyard row), and a
    plain rectangle reads as a shipping container instead. Sweeping the wing
    BACKWARD in steps is what makes it read as an aircraft at board scale; a
    perpendicular bar reads as a cross. Port and starboard are built from the
    same loop so the airframe is symmetric about its own axis.

    length runs along x, span across y, `nose` is the heading ("W" or "E").
    """
    out = []
    tail_dir = 1 if nose == "W" else -1        # +x is aft when the nose is west
    bw = max(26, int(length * 0.11))           # fuselage width
    x0 = int(cx - length / 2)
    out.append((name + " fuselage", x0, int(cy - bw / 2), int(length), bw))
    # Nose taper: two progressively smaller blocks ahead of the barrel section.
    for i in (1, 2):
        w = int(length * 0.045)
        h = int(bw * (0.74 - 0.24 * i))
        px = (x0 - i * w) if nose == "W" else (x0 + int(length) + (i - 1) * w)
        out.append((name + " nose", px, int(cy - h / 2), w, h))
    # Wings: root just forward of mid, swept aft as they reach outboard.
    steps = 4
    seg = max(10, int((span / 2 - bw / 2) / steps))
    seg_x = int(length * 0.105)
    root_x = cx - tail_dir * int(length * 0.06)
    root_w = int(length * 0.34)
    for i in range(steps):
        w = max(20, int(root_w * (1 - i * 0.19)))
        bx = int(root_x + tail_dir * i * seg_x - w / 2)
        for side in (-1, 1):
            y = (int(cy - bw / 2) - (i + 1) * seg if side < 0
                 else int(cy + bw / 2) + i * seg)
            out.append((name + " wing", bx, y, w, seg))
    # Engine nacelles hung under the wings, symmetric about the axis.
    for k in range(engines):
        off = int(bw / 2 + seg * (1.1 + 1.7 * k))
        ex = int(root_x + tail_dir * int(seg_x * (0.6 + 1.5 * k))
                 - length * 0.055)
        for side in (-1, 1):
            y = int(cy - off - 14) if side < 0 else int(cy + off)
            out.append((name + " engine", ex, y, int(length * 0.11), 14))
    # Tail: horizontal stabilizer plus the fin, right at the aft end.
    tspan = max(40, int(span * 0.34))
    tw = int(length * 0.075)
    tx = (x0 + int(length) - tw) if nose == "W" else x0
    out.append((name + " tailplane", tx, int(cy - tspan / 2), tw, tspan))
    if fin:
        fx = tx - tail_dir * int(length * 0.05)
        out.append((name + " tail fin", int(fx), int(cy - bw * 0.6),
                    int(length * 0.08), int(bw * 1.2)))
    return out


def blocks(name, specs):
    """Shorthand for a run of solid props: [(x, y, w, h), ...]."""
    return [(name, x, y, w, h) for x, y, w, h in specs]


def mask_from(shapes):
    """Rasterizes an authored structure list into a wall mask."""
    m = np.zeros((MAP_H, MAP_W), bool)
    for _, x, y, w, h in shapes:
        x0, y0 = max(0, int(x)), max(0, int(y))
        m[y0:int(y + h), x0:int(x + w)] = True
    return m


# ---------------------------------------------------------------------------
# The six layouts. Structures are named for their real callouts so the emitted
# Nim carries them as comments and a reviewer can check the map against the
# reference plate by reading it. Coordinates are GAME pixels on the 1235x659
# board; the red pedestal sits at (185, 329) and the blue at (1049, 329), each
# inside a 70px clear ring, so nothing is authored on top of them.

def _terminal():
    """Airport concourse. The 747 is parked on the north apron at ONE end (the
    asymmetry that IS the map), the terminal building fills the south."""
    s = []
    # --- the hero: the 747 at the gate, nose west, on the open apron ---
    s += plane("747", 505, 132, 470, 268, nose="W", engines=2)
    # Jet bridge from the terminal's north wall out to the forward fuselage.
    s += blocks("jet bridge", [(556, 168, 30, 92)])
    # --- terminal building: one long enclosed hall, both bases inside it ---
    # North face (apron side) with the gate doors; south face with street doors.
    s += hbar("wall terminal north", 96, 1140, 246, 18,
              gaps=((300, 344), (556, 586), (836, 880)))
    s += hbar("wall terminal south", 96, 1140, 596, 18,
              gaps=((330, 374), (700, 744), (960, 1004)))
    s += vbar("wall terminal west", 246, 614, 96, 18, gaps=((300, 360),))
    s += vbar("wall terminal east", 246, 614, 1122, 18, gaps=((300, 360),))
    # The concourse itself: a clear east-west hall down the middle, defined by
    # the pillar row to its north and the shop fronts to its south.
    s += blocks("concourse pillar", [(x, 300, 22, 22) for x in
                                     range(300, 960, 82)])
    # --- ticket / check-in counters, the long north-side run ---
    s += blocks("ticket counter", [(360, 268, 150, 20), (560, 268, 150, 20),
                                   (760, 268, 130, 20)])
    # --- security scanner comb: the mid chokepoint ---
    s += blocks("security scanner", [(600, 372, 20, 54), (600, 452, 20, 54),
                                     (668, 372, 20, 54), (668, 452, 20, 54)])
    s += blocks("security desk", [(620, 340, 68, 18)])
    # --- retail: glass-fronted shops along the south wall ---
    s += room("duty free", 300, 470, 132, 108, 16, doors=(("N", 46, 40),))
    s += room("bookshop", 470, 470, 116, 108, 16, doors=(("N", 40, 38),))
    # --- Burger Town, the corner landmark ---
    s += room("burger town", 800, 452, 180, 126, 16,
              doors=(("N", 62, 44), ("W", 40, 40)))
    s += blocks("burger town counter", [(838, 512, 104, 20)])
    # --- gate seating, north-east lounge ---
    s += blocks("gate seating", [(920, 300, 118, 18), (920, 342, 118, 18)])
    s += blocks("gate seating", [(214, 300, 96, 18), (214, 342, 96, 18)])
    # --- escalators down to baggage, west end ---
    s += blocks("escalator", [(180, 470, 96, 24), (180, 512, 96, 24)])
    # --- baggage carousel, east end ---
    s += blocks("baggage carousel", [(1010, 452, 96, 20), (1010, 520, 96, 20),
                                     (1010, 472, 20, 48), (1086, 472, 20, 48)])
    # --- apron clutter beside the aircraft ---
    s += blocks("baggage cart", [(760, 96, 54, 26), (846, 140, 54, 26),
                                 (240, 40, 48, 24)])
    s += blocks("service truck", [(980, 110, 66, 30)])
    return s


def _rust():
    """Oil-yard duel map. The derrick tower is the pivot at dead center and the
    pad UNDER it stays walkable, which is the map's signature fight."""
    s = []
    # --- the hero: the derrick tower, four legs braced around an open pad ---
    for lx in (536, 676):
        for ly in (248, 388):
            s += blocks("tower leg", [(lx, ly, 26, 26)])
    # Bracing steps, angling between the legs (kept off the clear center pad).
    s += blocks("tower brace", [(566, 238, 34, 14), (612, 232, 34, 14),
                                (566, 408, 34, 14), (612, 414, 34, 14),
                                (524, 288, 14, 34), (524, 336, 14, 34),
                                (686, 288, 14, 34), (686, 336, 14, 34)])
    s += blocks("tower stair", [(700, 300, 58, 18), (700, 348, 58, 18)])
    # --- the two big fuel tanks ---
    s += blocks("fuel tank", [(300, 470, 130, 130), (868, 60, 120, 120)])
    # --- pipe runs crossing the yard ---
    s += hbar("pipe run", 210, 520, 200, 18, gaps=((360, 396),))
    s += hbar("pipe run", 720, 1030, 470, 18, gaps=((860, 896),))
    s += vbar("pipe riser", 200, 300, 470, 18)
    # --- shacks / huts at the corners ---
    s += room("sniper hut", 150, 76, 132, 104, 16, doors=(("E", 36, 40),))
    s += room("sniper hut", 950, 480, 132, 104, 16, doors=(("W", 34, 40),))
    s += room("pump house", 430, 76, 118, 96, 16, doors=(("S", 40, 38),))
    # --- shipping containers and the dumpster ---
    s += blocks("container", [(700, 120, 150, 46), (330, 300, 46, 128),
                              (880, 300, 128, 46), (560, 540, 150, 44)])
    s += blocks("dumpster", [(246, 380, 62, 40), (960, 210, 62, 40)])
    # --- barrel clusters ---
    s += blocks("barrels", [(x, y, 26, 26) for x, y in
                            ((470, 250), (508, 214), (764, 400), (802, 438),
                             (392, 560), (860, 560), (300, 210), (1000, 120))])
    # --- perimeter scrap fence stubs ---
    s += blocks("yard fence", [(600, 40, 160, 16), (470, 610, 200, 16),
                               (140, 300, 16, 120), (1080, 300, 16, 120)])
    return s


def _highrise():
    """Rooftop of a tower under construction. Two glass office cores, the
    helipad deck south, the crane north."""
    s = []
    # --- the two office cores, one per end: real rooms with three exits ---
    s += room("office core", 120, 170, 240, 320, 18,
              doors=(("E", 34, 46), ("E", 200, 46), ("N", 90, 44)))
    s += room("office core", 876, 170, 240, 320, 18,
              doors=(("W", 34, 46), ("W", 200, 46), ("N", 90, 44)))
    s += blocks("office desk", [(180, 250, 90, 22), (180, 380, 90, 22),
                                (960, 250, 90, 22), (960, 380, 90, 22)])
    # --- the crane: base block and the jib reaching over midfield ---
    s += blocks("crane base", [(566, 40, 104, 76)])
    s += blocks("crane jib", [(600, 116, 30, 150)])
    s += blocks("crane counterweight", [(534, 54, 32, 48)])
    # --- helipad: an open deck ringed by a low parapet, south of center ---
    s += hbar("helipad parapet", 470, 770, 500, 16, gaps=((586, 654),))
    s += hbar("helipad parapet", 470, 770, 620, 16, gaps=((586, 654),))
    s += vbar("helipad parapet", 500, 636, 470, 16, gaps=((540, 580),))
    s += vbar("helipad parapet", 500, 636, 754, 16, gaps=((540, 580),))
    # --- AC plant and the duct runs across the mid roof ---
    s += blocks("ac unit", [(420, 130, 90, 62), (700, 130, 90, 62),
                            (420, 400, 76, 56), (740, 400, 76, 56)])
    s += hbar("duct run", 430, 800, 300, 20, gaps=((586, 640),))
    s += hbar("duct run", 380, 560, 220, 18)
    s += hbar("duct run", 690, 870, 220, 18)
    # --- scaffolding and plank bridges ---
    s += blocks("scaffold", [(390, 540, 120, 20), (740, 540, 120, 20),
                             (250, 540, 20, 76), (980, 540, 20, 76)])
    s += blocks("satellite dish", [(880, 90, 54, 54), (300, 90, 54, 54)])
    # --- parapet stubs at the roof edge ---
    s += blocks("parapet", [(150, 90, 150, 16), (940, 596, 150, 16)])
    return s


def _favela():
    """Rio hillside slum: irregular stacked blocks, crooked alleys, and the
    open courtyard nobody holds for long."""
    s = []
    # Irregular shanty blocks, deliberately staggered so no alley runs straight.
    s += room("crackhouse", 128, 60, 190, 150, 16,
              doors=(("S", 60, 40), ("E", 50, 42)))
    s += room("yellow building", 360, 96, 170, 130, 16,
              doors=(("S", 54, 40), ("W", 44, 40)))
    s += room("laundromat", 128, 268, 150, 140, 16,
              doors=(("N", 48, 40), ("E", 52, 40)))
    s += room("barber shop", 320, 300, 140, 120, 16,
              doors=(("E", 40, 40), ("S", 46, 38)))
    s += room("brickhouse", 176, 470, 200, 140, 16,
              doors=(("N", 66, 42), ("E", 54, 40)))
    s += room("bar", 470, 452, 165, 158, 16,
              doors=(("N", 58, 42), ("W", 56, 40)))
    s += room("ice cream shop", 690, 470, 150, 140, 16,
              doors=(("N", 50, 40), ("E", 48, 40)))
    s += room("green house", 700, 80, 175, 145, 16,
              doors=(("S", 58, 42), ("W", 46, 40)))
    s += room("roof garden", 920, 96, 165, 140, 16,
              doors=(("S", 54, 40), ("W", 44, 40)))
    s += room("shacks", 900, 420, 180, 165, 16,
              doors=(("N", 60, 42), ("W", 52, 42)))
    # Market stalls lining the side street.
    s += blocks("fruit stand", [(560, 300, 62, 34), (640, 340, 62, 34),
                                (470, 250, 58, 32)])
    # Rooftop water tanks.
    s += blocks("water tank", [(250, 120, 42, 42), (760, 150, 42, 42),
                               (980, 160, 42, 42), (222, 520, 42, 42),
                               (520, 512, 42, 42)])
    # The playground / soccer field stays OPEN — the center killzone.
    s += blocks("cemetary wall", [(846, 268, 18, 120), (392, 240, 18, 96)])
    s += blocks("junkyard scrap", [(880, 300, 96, 22), (300, 224, 90, 20)])
    return s


def _afghan():
    """Desert crash site. The C-130 is the spine; the cave arc on one side and
    the bunker overlook on the other."""
    s = []
    # --- the hero: the crashed Hercules, broken-backed across the midfield.
    # High straight wing, four engines, the big slab tail — nose east.
    s += plane("c130", 600, 300, 470, 300, nose="E", engines=2)
    # The break: a scatter of hull plate aft of the wing box.
    s += blocks("hull plate", [(430, 400, 74, 30), (500, 436, 60, 26),
                               (388, 250, 54, 26)])
    # --- the cave: an arc of rock along the north ridge with two mouths ---
    s += hbar("ridge", 96, 560, 40, 60, gaps=((236, 288), (430, 476)))
    s += hbar("ridge", 700, 1140, 40, 60, gaps=((880, 932),))
    s += blocks("cave mouth", [(236, 100, 52, 22), (880, 100, 52, 22)])
    # --- the bunker overlook, south side ---
    s += room("bunker", 300, 470, 190, 130, 18,
              doors=(("N", 66, 44), ("E", 44, 42)))
    s += blocks("bunker slit", [(340, 452, 110, 16)])
    # --- rock outcrops forming the mid lanes ---
    s += blocks("rock", [(200, 220, 88, 78), (960, 200, 96, 84),
                         (820, 470, 104, 90), (150, 380, 76, 70),
                         (1060, 400, 84, 76)])
    # --- sandbag emplacements ---
    s += blocks("sandbags", [(470, 180, 100, 20), (700, 470, 100, 20),
                             (560, 560, 88, 20), (900, 330, 20, 88)])
    # --- burnt vehicle hulks ---
    s += blocks("tank hulk", [(760, 210, 110, 52)])
    s += blocks("truck hulk", [(250, 560, 96, 44)])
    return s


def _scrapyard():
    """Aircraft boneyard: a row of gutted airframes between the two buildings."""
    s = []
    # --- the hero: the fuselage row. Three airframes, staggered, not a wall. ---
    s += plane("airframe", 430, 180, 300, 210, nose="W", engines=1, fin=True)
    s += plane("airframe", 800, 178, 290, 200, nose="E", engines=1, fin=True)
    s += plane("airframe", 610, 500, 320, 220, nose="W", engines=1, fin=False)
    # --- the two buildings at the ends: brick office vs the warehouse ---
    s += room("brick office", 120, 240, 180, 190, 18,
              doors=(("E", 60, 46), ("S", 56, 42)))
    s += room("warehouse", 940, 230, 200, 210, 18,
              doors=(("W", 66, 48), ("N", 70, 46)))
    s += blocks("office partition", [(170, 330, 80, 18)])
    s += blocks("warehouse rack", [(980, 300, 110, 20), (980, 370, 110, 20)])
    # --- control tower, north ---
    s += room("control tower", 560, 40, 110, 96, 18, doors=(("S", 38, 38),))
    # --- MG nest ---
    s += blocks("mg nest", [(300, 560, 96, 22), (300, 520, 22, 62)])
    # --- scrap piles, containers, stacked parts ---
    s += blocks("container", [(200, 96, 140, 44), (880, 560, 140, 44),
                              (140, 470, 44, 130), (1060, 96, 44, 130)])
    s += blocks("scrap pile", [(760, 380, 90, 40), (420, 380, 90, 40),
                               (930, 470, 76, 36)])
    s += blocks("engine stack", [(340, 300, 46, 46), (900, 130, 46, 46)])
    s += blocks("landing gear", [(520, 300, 34, 34), (690, 300, 34, 34)])
    # --- perimeter scrap fence ---
    s += blocks("scrap fence", [(430, 620, 200, 16), (620, 24, 200, 16)])
    return s


LAYOUTS.update({
    "rust": _rust(),
    "terminal": _terminal(),
    "highrise": _highrise(),
    "favela": _favela(),
    "afghan": _afghan(),
    "scrapyard": _scrapyard(),
})


def build(name):
    """Authored structures -> repaired, verified, emitted shape list."""
    shapes = LAYOUTS[name]
    report = [f"authored {len(shapes)} structures"]
    mask = mask_from(shapes)

    # Same playability machinery the traced path uses: the authored geometry is
    # the intent, and these passes make it a legal arena.
    rects, final = _emit_pass(name, mask, report)
    best, best_score, best_rects = final, _score(final), rects
    for round_no in range(6):
        _, pockets, open_rows, blue_ok, mid = verify(final)
        if pockets == 0 and open_rows == 0 and blue_ok and mid >= MID_TOL:
            break
        report.append(f"round {round_no + 1}: {pockets} pockets, "
                      f"{open_rows} open rows, blueOk {blue_ok}, mid {mid}")
        rects, final = _emit_pass(name, final.copy(), report)
        s = _score(final)
        if s > best_score:
            best, best_score, best_rects = final, s, rects
    if best_score > _score(final):
        final, rects = best, best_rects
        report.append("kept best raster from an earlier round")

    occ, pockets, open_rows, blue_ok, mid = verify(final)
    if pockets:
        labels, sizes = label_components(occ)
        main = labels[CY, 186]
        dead = np.zeros(len(sizes), bool)
        for i in range(1, len(sizes)):
            if i != main and sizes[i] > 0:
                dead[i] = True
        from scipy import ndimage
        final |= ndimage.binary_dilation(dead[labels], iterations=13)
        final &= ~protected_mask()
        rects = merge_rects(decompose(final))
        final = rasterize(rects)
        report.append(f"filled {int(dead.sum())} stubborn pocket(s)")

    occ, pockets, open_rows, blue_ok, mid = verify(final)
    stats = dict(shapes=len(rects), coverage=float(final.mean()),
                 pockets=pockets, openRows=open_rows)
    stats.update(parity(final, occ))
    stats["reachBlue"] = blue_ok
    stats["authored"] = len(shapes)
    Path(f"/tmp/mw2map_{name}.nim").write_text(
        emit(name, rects, stats, callouts=_callouts(shapes)))
    preview(name, final)
    return stats, report


def _emit_pass(name, mask, report):
    wall, keep_clear = repair(name, mask, report)
    rects = merge_rects(decompose(wall))
    final = rasterize(rects)
    picks = pickets_for(final, report, keep_clear=keep_clear)
    if picks:
        rects = rects + picks
        final = rasterize(rects)
    return rects, final


def _score(f):
    _, pk, orow, bok, m = verify(f)
    return (bok, pk == 0, orow == 0, round(m, 3))


def _callouts(shapes):
    """The distinct named structures, in authoring order — the review checklist."""
    seen, out = set(), []
    for n, *_ in shapes:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def main():
    stats_path = Path("/tmp/mw2trace_stats.json")
    allstats = json.loads(stats_path.read_text()) if stats_path.exists() else {}
    for name in (sys.argv[1:] or list(LAYOUTS)):
        if name not in LAYOUTS:
            print(f"{name}: no authored layout yet — skipping")
            continue
        stats, report = build(name)
        allstats[name] = stats
        print(f"\n=== {name}: {stats['shapes']} shapes from "
              f"{stats['authored']} authored structures, "
              f"cover {stats['coverage']:.1%}, pockets {stats['pockets']}, "
              f"openRows {stats['openRows']}")
        print(f"    parity area {stats['areaRatio']} cover "
              f"{stats['coverRatio']} mid {stats.get('midRatio')}")
        for r in report[:8]:
            print(f"    - {r}")
    stats_path.write_text(json.dumps(allstats, indent=1))


if __name__ == "__main__":
    main()
