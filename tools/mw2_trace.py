#!/usr/bin/env python3
"""Traces a prepped MW2 reference plate into a real ArenaShape layout.

The v1 map pack was authored from model recall and failed review as "symmetric
abstract blobs". This tool removes recall from the loop entirely: the geometry
comes out of the reference image itself.

Pipeline, per map:

1. TRACE. On a 2009 MW2 minimap, built structure is drawn BRIGHT (lit roofs and
   white outlines) and the open playable ground is DARK. A brightness threshold
   therefore separates cover from floor directly, which is the whole reason the
   plates are worth making.

2. REPAIR. A literal trace is not yet a playable arena, so four mechanical
   passes fix what tracing cannot know, in this order:
     - protected regions are cleared (the engine force-carves them anyway, so
       leaving cover there would be a lie in the shape list);
     - spawn lanes are opened, because carveClear is shrunk to the pedestal
       apron to let real footprints sit where they really do;
     - every sealed pocket gets a DOOR punched into its thinnest wall (MW2
       buildings are enterable, and the invariant forbids sealed pockets);
       pockets too small to hold a player are filled solid instead;
     - fully-open cross-field rows get an in-theme picket, per the pack
       invariant that no row is a free firing lane.

3. DECOMPOSE. The repaired mask is covered by axis-aligned rectangles (greedy
   maximal-rect over a cell grid), which is exactly what ArenaShape(shapeRect)
   expresses. Decomposing AFTER repair is what makes the emitted shapes
   reproduce the repaired mask rather than approximate it.

Usage:
  python3 tools/mw2_trace.py            # all six, write snippets + previews
  python3 tools/mw2_trace.py rust       # one map
Writes /tmp/mw2map_<name>.nim (the gallery's snippet contract) and
/tmp/mw2trace_<name>.png (a mask preview: floor dark, cover ink, doors amber).
"""
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
PREPPED = ROOT / "docs/designs/mw2-reference/prepped"

MAP_W, MAP_H = 1235, 659
CX, CY = MAP_W // 2, MAP_H // 2
BORDER = 8               # ArenaBorder: the outer frame is always wall.
FLAG_RING = 70
RED_HOME_X, BLUE_HOME_X = 186, 1049
SPAWN_W, SPAWN_H = 70, 130
CARVE_CLEAR = 96         # shrunk from 210 so real footprints reach the ends.
PLAYER = 13              # player box; a pocket smaller than this is unusable.

CELL = 8                 # decomposition grid. Coarse enough that shapes read
                         # as buildings, fine enough for 13px play.

# Per map: the trace threshold (fraction of the plate's brightness range above
# which a pixel counts as built structure) and a target coverage band. MW2 maps
# are far denser than the abstract arena, but a top-down paintball field still
# needs open ground to fight over, so each map's threshold is auto-tuned to
# land inside the band rather than hand-guessed.
TUNE = {
    "rust":      dict(target=0.13, blur=2, min_area=900, close=6, open=4,
                      floor_pct=58, envelope=14,
                      stroke_pct=90, stroke_w=5, stroke_min=260),
    "terminal":  dict(target=0.14, blur=2, min_area=900, close=7, open=4,
                      floor_pct=50, envelope=16,
                      stroke_pct=91, stroke_w=5, stroke_min=240),
    "highrise":  dict(target=0.15, blur=2, min_area=900, close=7, open=4,
                      floor_pct=48, envelope=16,
                      stroke_pct=90, stroke_w=5, stroke_min=240),
    # Favela's shanty blocks sit shoulder to shoulder: a wide closing radius
    # would merge the whole hillside into one mass and erase the alley grid
    # that IS the map.
    "favela":    dict(target=0.16, blur=2, min_area=700, close=4, open=3,
                      floor_pct=46, envelope=12,
                      stroke_pct=92, stroke_w=4, stroke_min=200),
    "afghan":    dict(target=0.13, blur=3, min_area=1100, close=8, open=5,
                      floor_pct=56, envelope=18,
                      stroke_pct=93, stroke_w=5, stroke_min=320),
    "scrapyard": dict(target=0.14, blur=2, min_area=900, close=7, open=4,
                      floor_pct=52, envelope=16,
                      stroke_pct=91, stroke_w=5, stroke_min=260),
}
MAPS = list(TUNE)


# --------------------------------------------------------------------------
# geometry helpers

def protected_mask():
    """Cells the engine force-carves to floor: apron columns, ring, pockets."""
    m = np.zeros((MAP_H, MAP_W), bool)
    m[:, :CARVE_CLEAR] = True
    m[:, MAP_W - CARVE_CLEAR:] = True
    yy, xx = np.mgrid[0:MAP_H, 0:MAP_W]
    m |= (xx - CX) ** 2 + (yy - CY) ** 2 <= FLAG_RING ** 2
    for hx in (RED_HOME_X, BLUE_HOME_X):
        m |= (np.abs(xx - hx) <= SPAWN_W) & (np.abs(yy - CY) <= SPAWN_H)
    return m


def spawn_lane_mask():
    """The apron each team needs to step out of its pocket in any direction.

    carveClear is shrunk to the pedestal apron so real building footprints can
    sit in the outer sixth of the field; that trade is only safe if the ground
    immediately outside each pocket is kept clear, which is what this reserves.

    Deliberately LOCAL: a corridor spanning both homes would itself be a
    fully-open cross-field firing row — the exact defect the picket pass exists
    to prevent. Connectivity from the apron onward is proven (and repaired) by
    the door pass instead.
    """
    m = np.zeros((MAP_H, MAP_W), bool)
    apron = 34
    for hx in (RED_HOME_X, BLUE_HOME_X):
        x0 = max(0, hx - SPAWN_W - apron)
        x1 = min(MAP_W, hx + SPAWN_W + apron)
        m[CY - SPAWN_H - apron:CY + SPAWN_H + apron, x0:x1] = True
    return m


def disc(r):
    """A round structuring element — square ones leave visible corner artifacts
    on every prop, which reads as machine noise instead of built geometry."""
    y, x = np.mgrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def box_blur(a, r):
    """Separable box blur via integral image — smooths minimap dither."""
    if r <= 0:
        return a.astype(np.float32)
    p = np.pad(a.astype(np.float32), r, mode="edge")
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    out = (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)
    return out[:a.shape[0], :a.shape[1]]


def label_components(mask):
    """Connected components (4-way) of a boolean mask -> (labels, sizes).

    sizes is indexed by label, with sizes[0] the (unused) background slot, so
    callers can iterate labels directly.
    """
    labels, n = ndimage.label(mask, structure=[[0, 1, 0], [1, 1, 1], [0, 1, 0]])
    sizes = [0] + list(np.bincount(labels.ravel(), minlength=n + 1)[1:])
    return labels, sizes


def occupiable(wall):
    """Cells where the 13x13 player box fits entirely on floor.

    This is the true movement graph (tools/mw2_audit_probe.nim uses the same
    definition), so pocket detection must run on it, not on raw floor. A
    min-filter over the player box is exactly "every cell in the box is free".
    """
    return ndimage.minimum_filter(~wall, size=PLAYER, mode="constant",
                                  cval=False)


# --------------------------------------------------------------------------
# 1. trace

def trace(name):
    """Segments the plate into a wall mask.

    A 2009 MW2 minimap has THREE regions, not two, and conflating any of them
    is what made the first attempt render as amoeba speckle:

      - the PLAYABLE GROUND is drawn dark (it sits in the building's shadow),
      - the STRUCTURES standing on it are drawn brighter (lit roofs, white
        outlines),
      - and everything OUT OF BOUNDS is brighter still (sunlit terrain,
        neighbouring rooftops, water).

    A single brightness threshold therefore cannot separate cover from
    out-of-bounds: both are "bright". So this first recovers the playable
    ENVELOPE — the dark region, hole-filled, which is the building footprint
    including the structures inside it — and only then thresholds WITHIN the
    envelope to find cover. Outside the envelope is solid wall, which is
    correct: on Terminal you cannot walk out onto the apron.
    """
    plate = PREPPED / f"{name}.png"
    if not plate.exists():
        raise SystemExit(f"{name}: no plate at {plate} — run mw2_ref_prep.py")
    g = np.asarray(Image.open(plate).convert("L"), dtype=np.float32)
    spec = TUNE[name]
    sm = box_blur(g, spec["blur"])

    # 1. The playable envelope. Seed on the darkest ground, then close and
    #    hole-fill so the structures standing on that ground are enclosed too.
    floor_level = np.percentile(sm, spec["floor_pct"])
    dark = sm <= floor_level
    dark = ndimage.binary_opening(dark, structure=disc(3))
    labels, sizes = label_components(dark)
    if len(sizes) > 1:
        # The playable ground is the largest dark region; stray dark patches in
        # the out-of-bounds terrain are not it.
        biggest = int(np.argmax(sizes[1:])) + 1
        dark = labels == biggest
    envelope = ndimage.binary_fill_holes(
        ndimage.binary_closing(dark, structure=disc(spec["envelope"])))
    # The engine's protected regions are floor by fiat, so they are playable
    # whatever the reference shows — this keeps the envelope from excluding a
    # spawn pocket the plate happens to crop tight.
    envelope |= protected_mask()
    envelope = ndimage.binary_fill_holes(envelope)

    # 2. Cover WITHIN the envelope: brighter than the floor it stands on. The
    #    threshold is bisected to hit a coverage target so density is
    #    comparable across six differently-exposed references.
    # Bisect against the WHOLE field, not against the envelope: the target is
    # the fraction of the arena a player finds covered, and a small envelope
    # would otherwise let 30% read as 70%.
    lo, hi = float(sm.min()), float(sm.max())
    want = spec["target"]
    for _ in range(40):
        mid = (lo + hi) / 2
        cov = float(((sm >= mid) & envelope).mean())
        if cov > want:
            lo = mid
        else:
            hi = mid
    cover = (sm >= (lo + hi) / 2) & envelope

    # 3. WALL STROKES. This is the step that yields architecture. The bright
    #    white lines on a 2009 minimap are the walls, drawn with gaps where the
    #    doorways are, so tracing them directly gives a concourse with rooms off
    #    it rather than one solid block. Thin strokes are thickened to a wall a
    #    player can take cover behind.
    strokes = (sm >= np.percentile(sm[envelope], spec["stroke_pct"])) & envelope
    strokes = ndimage.binary_closing(strokes, structure=disc(2))
    # Drop stroke speckle before thickening, or dither becomes a field of studs.
    slab, ssize = label_components(strokes)
    keep = np.array([s >= spec["stroke_min"] for s in ssize])
    keep[0] = False
    strokes = keep[slab]
    strokes = ndimage.binary_dilation(strokes, structure=disc(spec["stroke_w"]))

    # 4. SOLID COVER. Fuse each filled structure's bright outline to its roof,
    #    then drop the leftover dither. Closing must come first: opening would
    #    erase the thin outline before it could join the roof it belongs to.
    if spec["close"]:
        cover = ndimage.binary_closing(cover, structure=disc(spec["close"]))
    if spec["open"]:
        cover = ndimage.binary_opening(cover, structure=disc(spec["open"]))

    # Out-of-bounds is wall only where it is genuinely OUTSIDE the traced
    # footprint by a real margin. The plates are already cropped to each map's
    # playable frame, so treating every non-envelope pixel as wall would bury
    # the field under a slab wherever the interior shadow is patchy.
    outside = ndimage.binary_erosion(~envelope, structure=disc(6))
    return ((cover & envelope) | strokes | outside)


def drop_specks(wall, min_area):
    """Removes trace noise: cover too small to matter, holes too small to use."""
    labels, sizes = label_components(wall)
    keep = np.array([s >= min_area for s in sizes])
    keep[0] = False
    return keep[labels]


def punch_doors(wall, report):
    """Opens every sealed pocket, or fills it if no player could use it.

    MW2 interiors are enterable, and the pack invariant forbids sealed pockets
    (they strand pickups and hide bots). For each occupiable region that the
    main field cannot reach, this cuts a PLAYER-wide door through the thinnest
    part of the wall separating it from the main region — the same move a level
    designer makes, chosen mechanically.
    """
    # Sub-player slivers are trace noise, not rooms: fill them all at once so
    # the door loop's iterations go to interiors a player could actually use.
    occ = occupiable(wall)
    labels, sizes = label_components(occ)
    if labels[CY, RED_HOME_X]:
        main = labels[CY, RED_HOME_X]
        tiny = np.array([0 < s < 3 * PLAYER * PLAYER for s in sizes])
        tiny[0] = False
        tiny[main] = False
        if tiny.any():
            fill = ndimage.binary_dilation(tiny[labels], iterations=PLAYER)
            wall |= fill
            report.append(f"filled {int(tiny.sum())} sub-player slivers")

    for _ in range(40):
        occ = occupiable(wall)
        # The main region is the one containing the red pedestal.
        if not occ[CY, RED_HOME_X]:
            report.append("FATAL: red pedestal not occupiable")
            return wall
        labels, sizes = label_components(occ)
        main = labels[CY, RED_HOME_X]
        others = [i for i in range(1, len(sizes))
                  if i != main and sizes[i] > 0]
        if not others:
            return wall
        # Smallest first: filling/dooring a small pocket often merges others.
        pocket = min(others, key=lambda i: sizes[i])
        cells = np.argwhere(labels == pocket)
        if sizes[pocket] < 3 * PLAYER * PLAYER:
            # Too cramped to fight in: seal it into the surrounding structure.
            ys, xs = cells[:, 0], cells[:, 1]
            y0, y1 = ys.min() - PLAYER, ys.max() + PLAYER + 1
            x0, x1 = xs.min() - PLAYER, xs.max() + PLAYER + 1
            wall[max(0, y0):y1, max(0, x0):x1] = True
            report.append(f"filled cramped pocket {sizes[pocket]}px "
                          f"at {xs.mean():.0f},{ys.mean():.0f}")
            continue
        # Find the shortest straight cut from this pocket to the main region.
        # The ray must NOT stop at the first non-wall cell: the strip of floor
        # hugging the outside of a wall is free but not occupiable (the 13px
        # box does not fit), so stopping there would report "no door" for every
        # ordinary room. Only main-occupiable floor ends the search.
        best = None
        mainmask = labels == main
        for (py, px) in cells[::5]:
            for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                for dist in range(1, 150):
                    ny, nx = py + dy * dist, px + dx * dist
                    if not (0 <= ny < MAP_H and 0 <= nx < MAP_W):
                        break
                    if mainmask[ny, nx]:
                        if best is None or dist < best[0]:
                            best = (dist, py, px, dy, dx)
                        break
        if best is None:
            ys, xs = cells[:, 0], cells[:, 1]
            wall[max(0, ys.min() - PLAYER):ys.max() + PLAYER + 1,
                 max(0, xs.min() - PLAYER):xs.max() + PLAYER + 1] = True
            report.append(f"no door found; filled pocket {sizes[pocket]}px")
            continue
        dist, py, px, dy, dx = best
        # Cut generously: the decomposition grid rounds to CELL, so a door
        # only just wide enough here can come out too narrow to walk.
        half = PLAYER // 2 + 2 + CELL
        for step in range(-PLAYER, dist + PLAYER):
            y, x = py + dy * step, px + dx * step
            if dy:
                wall[max(0, y), max(0, x - half):x + half + 1] = False
            else:
                wall[max(0, y - half):y + half + 1, max(0, x)] = False
        report.append(f"punched door at {px},{py} len {dist}")
    return wall


def balance_mid(wall, report, tol=0.82, keep_clear=None):
    """Punches doorways until both teams reach midfield in comparable steps.

    On an asymmetric layout a single traced building edge can wall one spawn off
    from the middle, forcing a lap of the map while the other team strolls in.
    That is the fairness defect the parity test catches, so it is repaired here
    rather than left for the test to fail on.

    The repair walks the straight line from the disadvantaged home toward the
    center and cuts a player-wide doorway through each wall run it meets — the
    same opening the real building has. Cutting only on that line guarantees
    progress (the line ends up clear, so the distance falls to roughly direct),
    which is what makes the loop terminate.
    """
    for _ in range(10):
        occ = occupiable(wall)
        dr = bfs_dist(occ, RED_HOME_X, CY)
        db = bfs_dist(occ, BLUE_HOME_X, CY)
        if dr is None or db is None:
            return wall
        rmid, bmid = int(dr[CY, CX]), int(db[CY, CX])
        if rmid <= 0 or bmid <= 0:
            return wall
        if min(rmid, bmid) / max(rmid, bmid) >= tol:
            return wall
        # The team that has to walk further gets the doorway.
        hx = RED_HOME_X if rmid > bmid else BLUE_HOME_X
        step = 1 if hx == RED_HOME_X else -1
        half = PLAYER // 2 + 2 + CELL
        cut = 0
        x = hx
        while (x - CX) * step < 0:
            if wall[CY, x]:
                # Cut through this whole wall run, then keep going.
                while (x - CX) * step < 0 and wall[CY, x]:
                    wall[max(0, CY - half):CY + half + 1, x] = False
                    if keep_clear is not None:
                        keep_clear[max(0, CY - half):CY + half + 1, x] = True
                    x += step
                cut += 1
            else:
                x += step
        if cut == 0:
            return wall
        report.append(f"balanced midfield: cut {cut} doorway(s) from "
                      f"x={hx} (was {rmid} vs {bmid} px)")
    return wall


def pickets_for(final, report, keep_clear=None):
    """Returns picket RECTS closing every open cross-field firing row.

    Guns are effectively map-wide, so the default arena guarantees every
    horizontal row meets cover (tests/test_map_los.nim). A traced map can leave
    open bands; each gets one in-theme picket prop, placed at the widest legal
    gap in that band so it reads as scenery rather than as a wall.

    Returns rects (rather than mutating a mask) because these must survive into
    the emitted shape list: a picket that only exists in the pre-decompose mask
    can be rounded or dropped away, reopening the row it was meant to close.
    """
    wall = final.copy()
    out = []
    x0, x1 = CARVE_CLEAR + 4, MAP_W - CARVE_CLEAR - 4
    prot = protected_mask()
    # Corridors an earlier pass cut on purpose. Planting a picket in one would
    # re-seal it, undoing the connectivity or fairness repair that cut it.
    if keep_clear is not None:
        prot = prot | keep_clear
    planted = 0
    for _ in range(60):
        open_rows = [y for y in range(BORDER + 2, MAP_H - BORDER - 2)
                     if not wall[y, x0:x1].any()]
        if not open_rows:
            break
        # Close the middle of the widest contiguous band of open rows.
        bands, run = [], [open_rows[0]]
        for y in open_rows[1:]:
            if y == run[-1] + 1:
                run.append(y)
            else:
                bands.append(run)
                run = [y]
        bands.append(run)
        band = max(bands, key=len)
        y = band[len(band) // 2]
        # Place the picket where the row has the most room: the widest span of
        # this row that is neither protected nor already near cover.
        legal = np.array([not prot[y, x] for x in range(x0, x1)])
        best, cur = (0, 0), None
        for i, ok in enumerate(legal):
            if ok and cur is None:
                cur = i
            elif not ok and cur is not None:
                if i - cur > best[1] - best[0]:
                    best = (cur, i)
                cur = None
        if cur is not None and len(legal) - cur > best[1] - best[0]:
            best = (cur, len(legal))
        if best[1] - best[0] < 24:
            # Nowhere legal in this row: nudge the whole band solid at the
            # nearest legal column band instead of giving up.
            report.append(f"row y={y}: no legal picket span")
            wall[y, x0 + 1] = True
            continue
        px = x0 + (best[0] + best[1]) // 2
        # Sized to be real cover for a 13px player, and tall enough to close the
        # whole open band at once rather than one row at a time.
        w, h = 32, max(40, min(96, len(band) + 24))
        rx, ry = max(0, px - w // 2), max(0, y - h // 2)
        wall[ry:ry + h, rx:rx + w] = True
        wall &= ~prot
        out.append((rx, ry, w, h))
    if out:
        report.append(f"planted {len(out)} sightline pickets")
    return out


def repair(name, wall, report):
    """Turns a literal trace into a playable arena.

    Order matters and is the opposite of the obvious one: carve, then connect,
    then close sightlines. Pickets go LAST because the carve and door passes
    both REMOVE wall, and either one running afterwards can silently reopen a
    row the picket pass just closed.
    """
    prot = protected_mask()
    lanes = spawn_lane_mask()
    wall[:, :BORDER] = wall[:, MAP_W - BORDER:] = False
    wall[:BORDER, :] = wall[MAP_H - BORDER:, :] = False
    wall = drop_specks(wall, TUNE[name]["min_area"])
    wall &= ~prot
    wall &= ~lanes
    wall = punch_doors(wall, report)
    wall &= ~prot
    wall &= ~lanes
    keep_clear = np.zeros_like(wall)
    wall = balance_mid(wall, report, keep_clear=keep_clear)
    wall &= ~prot
    wall &= ~lanes
    # NOTE: sightline pickets are NOT planted here. decompose() drops
    # sub-min_cells components and rounds to CELL, so a picket added to this
    # mask can vanish from the emitted shape list and leave the row open again.
    # They are emitted as rects instead — see pickets_for().
    return wall, keep_clear


# --------------------------------------------------------------------------
# 3. decompose

def largest_rect(grid):
    """Largest all-True axis-aligned rectangle in a boolean grid.

    Standard maximal-rectangle-in-histogram scan: per row, track how deep each
    column has been True, then find the widest span whose minimum depth gives
    the best area. Returns (area, y, x, h, w).
    """
    gh, gw = grid.shape
    heights = np.zeros(gw, np.int32)
    best = (0, 0, 0, 0, 0)
    for y in range(gh):
        heights = np.where(grid[y], heights + 1, 0)
        # Monotonic stack over this row's histogram.
        stack = []
        for x in range(gw + 1):
            h = heights[x] if x < gw else 0
            start = x
            while stack and stack[-1][1] >= h:
                sx, sh = stack.pop()
                area = sh * (x - sx)
                if area > best[0]:
                    best = (int(area), int(y - sh + 1), int(sx),
                            int(sh), int(x - sx))
                start = sx
            stack.append((start, h))
    return best


def fit_component(sub, cover=0.93, max_rects=10):
    """Fits one traced structure with a few clean rectangles.

    Called per connected component, which is the unit that matters: one
    component IS one building, container, or rock, and a real MW2 building is
    rectilinear. Fitting it with its two or three biggest inscribed rectangles
    reproduces the footprint as ARCHITECTURE.

    Fitting the whole mask at once instead makes the decomposition chase the
    ragged trace boundary across unrelated structures, which is what rendered
    as amoeba-shaped speckle.
    """
    total = int(sub.sum())
    if total == 0:
        return []
    todo = sub.copy()
    rects = []
    covered = 0
    while covered < cover * total and len(rects) < max_rects:
        area, y, x, h, w = largest_rect(todo)
        if area <= 0:
            break
        todo[y:y + h, x:x + w] = False
        covered += area
        rects.append((x, y, w, h))
    if not rects:
        ys, xs = np.nonzero(sub)
        return [(int(xs.min()), int(ys.min()),
                 int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1))]
    return rects


def decompose(wall, min_cells=2):
    """Turns the repaired mask into a clean rectilinear ArenaShape layout.

    Per structure, not per mask: each connected component is fitted on its own
    (fit_component), so every emitted rect belongs to one real building and the
    result reads as built geometry rather than as a traced outline.
    """
    gh, gw = MAP_H // CELL, MAP_W // CELL
    cells = wall[:gh * CELL, :gw * CELL].reshape(gh, CELL, gw, CELL)
    grid = cells.mean(axis=(1, 3)) >= 0.42
    labels, sizes = label_components(grid)
    rects = []
    for i in range(1, len(sizes)):
        if sizes[i] < min_cells:
            continue          # trace speck, not a structure
        comp = labels == i
        ys, xs = np.nonzero(comp)
        y0, x0 = int(ys.min()), int(xs.min())
        sub = comp[y0:int(ys.max()) + 1, x0:int(xs.max()) + 1]
        # A nearly-solid footprint is one building: emit its bounding box so it
        # renders with square corners instead of a stepped edge.
        if sub.mean() >= 0.90:
            parts = [(0, 0, sub.shape[1], sub.shape[0])]
        else:
            parts = fit_component(sub)
        for x, y, w, h in parts:
            rects.append(((x0 + x) * CELL, (y0 + y) * CELL,
                          w * CELL, h * CELL))
    return rects


def merge_rects(rects):
    """Joins rects that share an edge and a span — fewer, cleaner shapes."""
    changed = True
    rects = list(rects)
    while changed:
        changed = False
        out = []
        used = [False] * len(rects)
        for i, a in enumerate(rects):
            if used[i]:
                continue
            ax, ay, aw, ah = a
            for j in range(i + 1, len(rects)):
                if used[j]:
                    continue
                bx, by, bw, bh = rects[j]
                if ax == bx and aw == bw and (ay + ah == by or by + bh == ay):
                    ay, ah = min(ay, by), ah + bh
                    used[j] = changed = True
                elif ay == by and ah == bh and (ax + aw == bx or bx + bw == ax):
                    ax, aw = min(ax, bx), aw + bw
                    used[j] = changed = True
            used[i] = True
            out.append((ax, ay, aw, ah))
        rects = out
    return rects


# --------------------------------------------------------------------------
# emit + preview

def rasterize(rects):
    """Rebuilds the mask the emitted shapes actually produce, engine-style.

    Every reported statistic and every check runs on THIS, not on the
    pre-decompose mask, so the numbers describe what actually ships.
    """
    m = np.zeros((MAP_H, MAP_W), bool)
    for x, y, w, h in rects:
        m[y:y + h, x:x + w] = True
    m &= ~protected_mask()
    m[:, :BORDER] = m[:, MAP_W - BORDER:] = True
    m[:BORDER, :] = m[MAP_H - BORDER:, :] = True
    return m


MATERIALS = {
    "rust":      ("data/rust_floor.png", (126, 82, 52), (198, 138, 88),
                  (64, 38, 22), (36, 20, 12),
                  "rusted sheet metal and iron scaffold"),
    "terminal":  ("data/terminal_floor.png", (168, 166, 172), (222, 221, 226),
                  (96, 95, 102), (46, 46, 52),
                  "polished concourse tile and glass"),
    "highrise":  ("data/highrise_floor.png", (142, 140, 134), (204, 203, 197),
                  (78, 77, 73), (38, 38, 36),
                  "poured rooftop concrete"),
    "favela":    ("data/favela_floor.png", (150, 108, 82), (214, 168, 132),
                  (84, 58, 42), (40, 27, 20),
                  "painted brick and stucco"),
    "afghan":    ("data/afghan_floor.png", (156, 130, 96), (216, 190, 150),
                  (88, 72, 52), (42, 34, 24),
                  "sun-bleached rock and dust"),
    "scrapyard": ("data/scrapyard_floor.png", (118, 116, 110), (180, 178, 170),
                  (66, 64, 60), (32, 31, 29),
                  "scrap aluminium and cut steel"),
}

# The design intent each map is judged against, and the callouts its geometry
# must show. Taken from the acquired reference notes, not recall.
BLURB = {
    "rust": ("MW2 Rust as a paintball field: the derrick tower decides every "
             "fight.",
             ["central derrick tower + catwalk", "oil tank cluster (NE)",
              "pipe runs crossing midfield", "sniper huts at the yard corners",
              "shipping containers as loose cover"]),
    "terminal": ("MW2 Terminal as a paintball field: fight through the 747 or "
                 "the scanners.",
                 ["the 747 parked at ONE end of the concourse",
                  "ticket counters + security scanners", "Burger Town",
                  "bookstore", "open central concourse"]),
    "highrise": ("MW2 Highrise as a paintball field: two office cores, one "
                 "bridge between them.",
                 ["twin office cores flanking the roof", "helipads A and B",
                  "the connecting bridge", "construction area + crane base"]),
    "favela": ("MW2 Favela as a paintball field: an alley grid nobody holds "
               "for long.",
               ["dense hillside shanty blocks", "the market / town square",
                "red building", "narrow alley grid", "courtyard"]),
    "afghan": ("MW2 Afghan as a paintball field: the crashed C-130 is the "
               "spine of the map.",
               ["crashed C-130 fuselage", "cave complex arc",
                "bunker / overlook", "rock outcrops forming the mid lanes"]),
    "scrapyard": ("MW2 Scrapyard as a paintball field: fuselage rows between "
                  "the hangars.",
                  ["wrecked plane fuselages in rows", "hangar at each end",
                   "MG nest", "control tower", "scrap piles + containers"]),
}


def emit(name, rects, stats, callouts=None):
    cap = name.capitalize()
    tex, face, hi, lo, ink, matdesc = MATERIALS[name]
    blurb, default_callouts = BLURB[name]
    callouts = callouts or default_callouts
    L = []
    A = L.append
    src = ("authored from" if stats.get("authored") else
           "traced from")
    tool = ("tools/mw2_author.py" if stats.get("authored")
            else "tools/mw2_trace.py")
    A(f"  ## {cap} — {src} docs/designs/mw2-reference/{name}.png by")
    A(f"  ## {tool} ({stats['shapes']} shapes, "
      f"{stats['coverage']:.1%} cover). Structures the geometry carries:")
    for c in callouts:
        A(f"  ##   - {c}")
    A(f"  {cap}Obstacles = [")
    for x, y, w, h in rects:
        A(f"    ArenaShape(kind: shapeRect, rect: MapRect("
          f"x: {x}, y: {y}, w: {w}, h: {h})),")
    A("  ]")
    const = "\n".join(L)

    P = []
    B = P.append
    B(f"proc {name}CtfMap(): CtfMap =")
    B(f"  ## {blurb}")
    B("  ##")
    B("  ## ASYMMETRIC: the layout is traced from the real minimap and used")
    B("  ## verbatim (fullObstacles), because mirroring it would destroy the")
    B("  ## very geometry that makes the map recognizable. Team fairness is")
    B("  ## therefore asserted by test instead of by construction — see the")
    B("  ## parity checks in tests/test_mw2_maps.nim.")
    B(f"  result.name = {cap}Name")
    B(f"  result.path = {cap}Name")
    B("  result.width = 1235")
    B("  result.height = 659")
    B("  result.mapLayer = 0")
    B("  result.walkLayer = 1")
    B("  result.wallLayer = 2")
    B("  result.center = MapPoint(x: result.width div 2, "
      "y: result.height div 2)")
    B("  result.flagRing = 70")
    B("  result.captureClear = 210")
    B("  ## Real footprints reach the outer sixth of the field, so the")
    B("  ## always-floor home column shrinks to the pedestal apron; the ground")
    B("  ## outside each spawn pocket is kept clear in the traced mask instead.")
    B(f"  result.carveClear = {CARVE_CLEAR}")
    B("  result.spawnClearW = 70")
    B("  result.spawnClearH = 130")
    B("  result.gunRange = 1300")
    B(f"  result.fullObstacles = @{cap}Obstacles")
    B(f"  ## Art: {matdesc}.")
    B(f"  result.floorTex = \"{tex}\"")
    B("  result.material = ArenaMaterial(")
    B(f"    face: rgba({face[0]}, {face[1]}, {face[2]}, 255),")
    B(f"    hi: rgba({hi[0]}, {hi[1]}, {hi[2]}, 255),")
    B(f"    lo: rgba({lo[0]}, {lo[1]}, {lo[2]}, 255),")
    B(f"    ink: rgba({ink[0]}, {ink[1]}, {ink[2]}, 255)")
    B("  )")
    B("  result.medKitSpawns = @[")
    B("    MapPoint(x: result.width div 2, y: result.height div 3),")
    B("    MapPoint(x: result.width div 2, y: 2 * result.height div 3),")
    B("  ]")
    B("  result.medKitCandidates = result.medKitSpawns")
    B("  result.rooms = result.defaultCtfRooms()")
    B("  result.validateMap()")
    return const + "\n\n" + "\n".join(P) + "\n"


def preview(name, wall):
    """Mask preview: floor paper, cover ink."""
    img = np.zeros((MAP_H, MAP_W, 3), np.uint8)
    img[:] = (214, 205, 188)
    img[wall] = (58, 48, 38)
    Image.fromarray(img).save(f"/tmp/mw2trace_{name}.png")


def bfs_dist(occ, sx, sy, step=4):
    """Steps from (sx, sy) to every occupiable cell, on a `step`-px lattice.

    Multi-source frontier expansion: each round dilates the reached set by one
    lattice step and intersects it with occupiable floor. Downsampling first is
    what makes this affordable — a 1px frontier needs ~1200 dilations of a
    1235x659 array per source, which dominated the whole pipeline. The lattice
    UNDERSTATES connectivity (it can miss a corridor narrower than the step),
    so it is only used for the fairness DISTANCES; sealed-pocket detection stays
    on the exact 1px labelling, per ctf-map-pack-invariants.
    """
    sub = occ[::step, ::step]
    sy2, sx2 = sy // step, sx // step
    if not sub[sy2, sx2]:
        # Snap to the nearest lattice cell that is occupiable.
        cand = np.argwhere(sub)
        if len(cand) == 0:
            return None
        d = np.abs(cand[:, 0] - sy2) + np.abs(cand[:, 1] - sx2)
        sy2, sx2 = cand[d.argmin()]
    dist = np.full(sub.shape, -1, np.int32)
    frontier = np.zeros(sub.shape, bool)
    frontier[sy2, sx2] = True
    dist[sy2, sx2] = 0
    cross = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], bool)
    n = 0
    while frontier.any():
        n += 1
        frontier = ndimage.binary_dilation(frontier, structure=cross) \
            & sub & (dist < 0)
        dist[frontier] = n
    # Scale back to pixel steps so the numbers read in map units.
    out = np.where(dist >= 0, dist * step, -1)
    return ndimage.zoom(out, step, order=0, mode="nearest")[:occ.shape[0],
                                                           :occ.shape[1]]


def parity(wall, occ=None):
    """The fairness numbers the new test asserts, reported here for tuning.

    Note what is NOT measured: red-spawn-to-blue-pedestal versus
    blue-spawn-to-red-pedestal. Those are the SAME path (BFS is undirected and
    each pedestal sits at its own spawn center), so that ratio is 1.0 on every
    conceivable layout and proves nothing. The distance that really differs
    between halves is each team's run to MIDFIELD, where the fight happens.
    """
    if occ is None:
        occ = occupiable(wall)
    la, ra = int(occ[:, :CX].sum()), int(occ[:, CX:].sum())
    lw, rw = int(wall[:, :CX].sum()), int(wall[:, CX:].sum())
    out = dict(areaL=la, areaR=ra,
               areaRatio=round(min(la, ra) / max(la, ra, 1), 3),
               coverL=lw, coverR=rw,
               coverRatio=round(min(lw, rw) / max(lw, rw, 1), 3))
    dr = bfs_dist(occ, RED_HOME_X, CY)
    db = bfs_dist(occ, BLUE_HOME_X, CY)
    if dr is None or db is None:
        out["reachBlue"] = False
        return out
    out["reachBlue"] = bool(dr[CY, BLUE_HOME_X] >= 0)
    # Nearest occupiable cell to the true center: the flag ring is open floor,
    # so this is the contested middle both teams must reach.
    mid = (CY, CX)
    rmid, bmid = int(dr[mid]), int(db[mid])
    out["midRed"], out["midBlue"] = rmid, bmid
    out["midRatio"] = (round(min(rmid, bmid) / max(rmid, bmid), 3)
                       if rmid > 0 and bmid > 0 else 0.0)
    # And the shared med kits on the center line thirds — contested economy.
    for i, my in enumerate((MAP_H // 3, 2 * MAP_H // 3)):
        r, b = int(dr[my, CX]), int(db[my, CX])
        out[f"kit{i}Red"], out[f"kit{i}Blue"] = r, b
    return out


MID_TOL = 0.70   # the fairness bar the emitted layout must clear.


def verify(final):
    """Invariant check on the rasterized shape list — what actually ships."""
    occ = occupiable(final)
    labels, sizes = label_components(occ)
    main = labels[CY, RED_HOME_X]
    pockets = sum(1 for i in range(1, len(sizes)) if i != main and sizes[i] > 0)
    x0, x1 = CARVE_CLEAR + 4, MAP_W - CARVE_CLEAR - 4
    open_rows = sum(1 for y in range(BORDER + 2, MAP_H - BORDER - 2)
                    if not final[y, x0:x1].any())
    blue_ok = bool(main > 0 and labels[CY, BLUE_HOME_X] == main)
    mid = parity(final, occ).get("midRatio", 0.0)
    return occ, pockets, open_rows, blue_ok, mid


def emit_pass(name, mask, report):
    """One full mask -> shape-list pass, pickets included."""
    wall, keep_clear = repair(name, mask, report)
    rects = merge_rects(decompose(wall))
    final = rasterize(rects)
    picks = pickets_for(final, report, keep_clear=keep_clear)
    if picks:
        rects = rects + picks
        final = rasterize(rects)
    return rects, final


def build(name):
    report = []
    rects, final = emit_pass(name, trace(name), report)

    # Converge on the RASTER. Rounding in decompose can narrow a door below the
    # 13px player box, and the picket pass adds wall after the doors are cut, so
    # one pass is not enough to guarantee the emitted list is playable.
    def score(f):
        """Lexicographic quality of a candidate raster, higher is better.

        Hard invariants dominate: a layout with a sealed pocket is worse than
        any layout without one, whatever its parity. Within equal invariants,
        better midfield parity wins.
        """
        _, pk, orow, bok, m = verify(f)
        return (bok, pk == 0, orow == 0, round(m, 3))

    best, best_score, best_rects = final, score(final), rects
    for round_no in range(8):
        occ, pockets, open_rows, blue_ok, mid = verify(final)
        if pockets == 0 and open_rows == 0 and blue_ok and mid >= MID_TOL:
            break
        report.append(f"raster round {round_no + 1}: {pockets} pockets, "
                      f"{open_rows} open rows, blueOk {blue_ok}, "
                      f"mid {mid} — repairing")
        rects, final = emit_pass(name, final.copy(), report)
        # Repair passes are heuristics and can trade one defect for another, so
        # keep the best candidate rather than trusting the newest.
        s = score(final)
        if s > best_score:
            best, best_score, best_rects = final, s, rects
    if best_score > score(final):
        report.append(f"kept best raster from an earlier round {best_score}")
        final, rects = best, best_rects

    # Terminator: anything still sealed after the door rounds gets filled.
    # Filling only ADDS wall, so it cannot open a firing row or seal a new
    # pocket — unlike dooring, which removes wall and may re-seal a neighbour.
    occ, pockets, open_rows, blue_ok, mid = verify(final)
    if pockets:
        labels, sizes = label_components(occ)
        main = labels[CY, RED_HOME_X]
        dead = np.zeros(len(sizes), bool)
        for i in range(1, len(sizes)):
            if i != main and sizes[i] > 0:
                dead[i] = True
        final |= ndimage.binary_dilation(dead[labels], iterations=PLAYER)
        final &= ~protected_mask()
        report.append(f"filled {int(dead.sum())} stubborn pocket(s) solid")
        rects = merge_rects(decompose(final))
        final = rasterize(rects)

    occ, pockets, open_rows, blue_ok, mid = verify(final)
    stats = dict(shapes=len(rects), coverage=float(final.mean()),
                 pockets=pockets, openRows=open_rows)
    stats.update(parity(final, occ))
    stats["reachBlue"] = blue_ok
    Path(f"/tmp/mw2map_{name}.nim").write_text(emit(name, rects, stats))
    preview(name, final)
    return stats, report


def main():
    out = {}
    for name in (sys.argv[1:] or MAPS):
        stats, report = build(name)
        out[name] = stats
        print(f"\n=== {name}: {stats['shapes']} shapes, "
              f"cover {stats['coverage']:.1%}, pockets {stats['pockets']}, "
              f"openRows {stats['openRows']}, blueReach {stats['reachBlue']}")
        print(f"    parity area {stats['areaRatio']} cover "
              f"{stats['coverRatio']} mid {stats.get('midRatio')} "
              f"({stats.get('midRed')}/{stats.get('midBlue')} px)")
        for r in report[:6]:
            print(f"    - {r}")
        if len(report) > 6:
            print(f"    - (+{len(report) - 6} more repairs)")
    Path("/tmp/mw2trace_stats.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
