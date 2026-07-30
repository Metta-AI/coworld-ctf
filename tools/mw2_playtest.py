#!/usr/bin/env python3
"""Judges a pack map on HOW IT PLAYS, not on how it looks.

Both earlier passes at the MW2 pack put footprints in roughly the right places
and still played nothing like the real maps. Geometry in the correct place says
nothing about whether players use it, so this measures the things that actually
decide a match and reports where a map falls short.

Two kinds of evidence:

  STATIC, from the wall mask alone —
    * sightline lengths: how far an open shot runs. MW2 maps are built from
      short-to-medium lanes with cut angles; a field of long open shots plays
      like a shooting gallery no matter what the footprints look like.
    * route count: how many genuinely distinct paths connect the two bases. A
      map with one path is a corridor; MW2 maps famously offer three.
    * chokepoints: cells every route must cross. Some are good (they create the
      fights); too many means a map of doorways.

  DYNAMIC, from a re-simulated episode (tools/mw2_playtest.nim) —
    * dead space: open floor no player visited all match. This is the single
      clearest sign that geometry is decorative rather than played.
    * engagement spread: where players died, and whether the fights cluster in
      one blob or distribute across lanes the way a real map's do.

Usage:
  nim c -d:release -o:/tmp/mw2playtest tools/mw2_playtest.nim
  /tmp/mw2playtest mw2-rust-fixture.bitreplay --out /tmp/pt_rust.json
  python3 tools/mw2_playtest.py /tmp/pt_rust.json [...]
Writes a per-map heatmap PNG into /tmp/mw2-gallery/ and prints the gap report.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

GALLERY = Path("/tmp/mw2-gallery")

# The default arena is the control: it is the layout the game was tuned on, so
# "plays like the arena" is the floor, not the target. Numbers far from these
# are worth explaining; numbers matching them mean the map is at least sane.
ARENA_BASELINE = dict(medianSight=170, longSightPct=0.10, deadPct=0.20)


def sightlines(wall, samples=None):
    """Open-shot length along both axes, in cells, from every open cell.

    Guns are effectively map-wide here, so what governs a fight is how far you
    can see before geometry cuts the angle. Measured on the grid the heatmap
    uses so it lines up with the occupancy evidence.
    """
    gh, gw = wall.shape
    out = []
    for y in range(gh):
        run = 0
        for x in range(gw):
            if wall[y, x]:
                if run:
                    out.append(run)
                run = 0
            else:
                run += 1
        if run:
            out.append(run)
    for x in range(gw):
        run = 0
        for y in range(gh):
            if wall[y, x]:
                if run:
                    out.append(run)
                run = 0
            else:
                run += 1
        if run:
            out.append(run)
    return np.array(out) if out else np.array([0])


def lanes(wall, occ=None):
    """How many distinct LANES cross midfield — the '3-lane' property.

    Counted as the separate vertical gaps in the wall along the center column,
    which is the shape of the question: a lane is a way THROUGH the middle, and
    two routes that funnel into the same midfield gap are one lane.

    An earlier version tried "find a path, wall it off, find another". That is
    the intuitive framing and it is useless here: blocking a path at this cell
    scale severs the map, so it reported ONE route for every layout including
    the default arena, which is a known-good map. When a metric flags your
    control, the metric is wrong.

    Returns (lane_count, used_lane_count) — the second counts only lanes players
    actually walked through, which is what separates a real route from a gap
    that merely exists.
    """
    gh, gw = wall.shape
    col = gw // 2
    # Look at a narrow band around the center line so a one-cell notch does not
    # register as a lane.
    band = wall[:, max(0, col - 2):col + 3].any(axis=1)
    out, used, run, run_rows = 0, 0, 0, []
    for y in range(gh):
        if not band[y]:
            run += 1
            run_rows.append(y)
        else:
            if run >= 3:          # >= 30px: a player is 13px wide
                out += 1
                if occ is not None and any(
                        occ[r, max(0, col - 2):col + 3].sum() > 0
                        for r in run_rows):
                    used += 1
            run, run_rows = 0, []
    if run >= 3:
        out += 1
        if occ is not None and any(occ[r, max(0, col - 2):col + 3].sum() > 0
                                   for r in run_rows):
            used += 1
    return out, used


def bfs(free, start):
    dist = np.full(free.shape, -1, np.int32)
    if not free[start]:
        return dist
    frontier = np.zeros(free.shape, bool)
    frontier[start] = True
    dist[start] = 0
    cross = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], bool)
    n = 0
    while frontier.any():
        n += 1
        frontier = ndimage.binary_dilation(frontier, structure=cross) \
            & free & (dist < 0)
        dist[frontier] = n
    return dist


def heatmap(data, name):
    """Occupancy over the wall mask: where the match actually happened.

    Warm where players spent time, ink where the walls are, and PALE where open
    floor went unvisited — the dead space that says geometry is decorative.
    """
    gw, gh = data["gw"], data["gh"]
    wall = np.array(data["wall"], bool).reshape(gh, gw)
    occ = np.array(data["occupancy"], float).reshape(gh, gw)
    red = np.array(data["occRed"], float).reshape(gh, gw)
    blue = np.array(data["occBlue"], float).reshape(gh, gw)

    img = np.zeros((gh, gw, 3), np.float32)
    img[:] = (0.96, 0.94, 0.90)                 # paper: unvisited open floor
    hot = occ > 0
    if hot.any():
        # Rank-normalize: one camper should not flatten the rest of the map.
        r = np.zeros_like(occ)
        order = occ[hot].argsort().argsort().astype(float)
        r[hot] = order / max(len(order) - 1, 1)
        # Team tint by who held the ground, intensity by how much it was used.
        tot = np.maximum(red + blue, 1)
        redness = red / tot
        for c, (lo, hi) in enumerate(((0.96, 0.72), (0.94, 0.30), (0.90, 0.26))):
            img[..., c] = np.where(hot, lo + (hi - lo) * r, img[..., c])
        # Push warm toward red or cool toward blue.
        img[..., 0] = np.where(hot, img[..., 0] + 0.18 * (redness - 0.5),
                               img[..., 0])
        img[..., 2] = np.where(hot, img[..., 2] - 0.18 * (redness - 0.5),
                               img[..., 2])
    img[wall] = (0.22, 0.18, 0.14)              # ink: cover

    out = Image.fromarray(np.clip(img * 255, 0, 255).astype(np.uint8))
    out = out.resize((gw * 10, gh * 10), Image.NEAREST)
    # Deaths as rings: where the fights actually resolved.
    from PIL import ImageDraw
    d = ImageDraw.Draw(out, "RGBA")
    for dth in data["deaths"]:
        x, y = dth["x"], dth["y"]
        col = (176, 60, 40, 210) if dth["team"] == "red" else (40, 96, 176, 210)
        d.ellipse([x - 9, y - 9, x + 9, y + 9], outline=col, width=3)
    GALLERY.mkdir(exist_ok=True)
    out.save(GALLERY / f"heat-{name}.png")
    return wall, occ


def merge(paths):
    """Sums several episodes of the same map into one evidence set.

    Necessary because episode LENGTH dominates the dead-space number: a match
    that ends in a fast wipe leaves most of the field unvisited and would report
    the map as decorative when it is only the sample that was short. Merging
    several seeds measures the map instead of the match.
    """
    datas = [json.loads(Path(p).read_text()) for p in paths]
    base = datas[0]
    for d in datas[1:]:
        if d["map"] != base["map"]:
            raise SystemExit(f"merge: {d['map']} != {base['map']}")
        for key in ("occupancy", "occRed", "occBlue"):
            base[key] = [a + b for a, b in zip(base[key], d[key])]
        base["deaths"] = base["deaths"] + d["deaths"]
        base["ticks"] += d["ticks"]
    base["episodes"] = len(datas)
    return base


def report(paths):
    data = merge(paths if isinstance(paths, list) else [paths])
    name = data["map"]
    wall, occ = heatmap(data, name)
    gh, gw = wall.shape
    cell = data["cell"]

    sl = sightlines(wall)
    median_sight = float(np.median(sl)) * cell
    long_pct = float((sl * cell > 600).mean())

    # Count visited only WITHIN open cells. A player's body can sit in a cell
    # whose 10px center is not occupiable, so a raw (occ > 0) count can exceed
    # the open-cell count and report negative dead space.
    open_mask = ~wall
    open_cells = int(open_mask.sum())
    visited = int((open_mask & (occ > 0)).sum())
    dead_pct = 1.0 - visited / max(open_cells, 1)

    # Largest single unvisited open region — a big one is a whole wing of the
    # map nobody played, which no amount of correct footprints excuses.
    unvisited = open_mask & (occ == 0)
    lab, n = ndimage.label(unvisited)
    sizes = np.bincount(lab.ravel())[1:] if n else np.array([0])
    biggest_dead = int(sizes.max()) if len(sizes) else 0

    lane_count, lanes_used = lanes(wall, occ)

    deaths = data["deaths"]
    if deaths:
        dx = np.array([d["x"] for d in deaths], float)
        dy = np.array([d["y"] for d in deaths], float)
        spread = float(np.hypot(dx.std(), dy.std()))
    else:
        spread = 0.0

    flags = []
    if median_sight > 1.5 * ARENA_BASELINE["medianSight"]:
        flags.append(f"sightlines long (median {median_sight:.0f}px vs arena "
                     f"~{ARENA_BASELINE['medianSight']}px) — plays open, not "
                     "like MW2's cut angles")
    if long_pct > 0.18:
        flags.append(f"{long_pct:.0%} of open runs exceed 600px — too many "
                     "gallery shots")
    if lane_count < 2:
        flags.append(f"only {lane_count} lane crosses midfield — a corridor, "
                     "not a multi-lane map")
    elif lanes_used < 2:
        flags.append(f"{lane_count} midfield lanes exist but only "
                     f"{lanes_used} saw traffic — the others are decoration")
    if dead_pct > 0.35:
        flags.append(f"{dead_pct:.0%} of open floor never visited — most of "
                     "the geometry is decoration")
    if biggest_dead * cell * cell > 60000:
        flags.append(f"one unvisited region of ~{biggest_dead * cell * cell:,}"
                     "px² — a whole wing nobody played")

    print(f"\n=== {name}  ({data.get('episodes', 1)} episode(s), "
          f"{data['ticks']} ticks)")
    print(f"    sightline median {median_sight:.0f}px, "
          f"{long_pct:.0%} over 600px")
    print(f"    midfield lanes: {lane_count} ({lanes_used} actually used)")
    print(f"    dead space {dead_pct:.0%} of open floor "
          f"(largest unvisited region {biggest_dead * cell * cell:,}px²)")
    print(f"    {len(deaths)} deaths, spread {spread:.0f}px")
    for f in flags:
        print(f"    FLAG: {f}")
    if not flags:
        print("    no gameplay flags")
    return dict(map=name, medianSight=median_sight, longPct=long_pct,
                lanes=lane_count, lanesUsed=lanes_used,
                deadPct=dead_pct, biggestDead=biggest_dead,
                deaths=len(deaths), spread=spread, flags=flags)


def main():
    # Group the given files by map so several episodes of one map merge.
    groups = {}
    for p in sys.argv[1:]:
        m = json.loads(Path(p).read_text())["map"]
        groups.setdefault(m, []).append(p)
    out = {}
    for m, paths in groups.items():
        r = report(paths)
        r["episodes"] = len(paths)
        out[m] = r
    (GALLERY / "playtest.json").write_text(json.dumps(out, indent=1))
    print(f"\nwrote {GALLERY}/playtest.json + heat-<map>.png")


if __name__ == "__main__":
    main()
