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

    Returns (lane_count, used_lane_count, open_fraction). The count ALONE is
    degenerate in exactly the way the stand-ring metric was: one enormous
    opening scores the same "1" as one narrow doorway. Favela reads as "1 lane
    crosses midfield — a corridor" when its midfield is 486px of continuous
    open ground, which is the opposite problem. Read the count against the
    fraction: low count plus low fraction is a corridor, low count plus high
    fraction is a field.
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
    return out, used, float((~band).mean())


def stand_exposure(wall, home, radius, cell):
    """How open the ground immediately around a flag stand is.

    The engine now scores a carrier within `captureRadius` of their own home
    point (the CoD model, capture AT the flag stand) rather than by crossing a
    full-height home column, so the ring around the stand is the decisive real
    estate: too sealed and an attacker cannot contest it, too open and a
    defender cannot hold it. Returns (open_fraction, distinct_arcs).

    Counting arcs ALONE is degenerate and briefly had me reporting the exact
    opposite of the truth: a stand sitting in open ground has one enormous
    unbroken open arc, which scored the same "1" as a stand behind a single
    doorway. Rust's red stand read as "1 approach, a turkey shoot" when its
    ring is in fact 81% open. The fraction is the honest primary number; the
    arc count only means something next to it.

    Measured for every map, including the ones still on the legacy column, so
    the default arena can serve as a control here too — the earlier version
    skipped legacy maps and therefore never scored the control, which is how
    the inverted reading survived.
    """
    gh, gw = wall.shape
    r = (radius or 64) / cell + 3.0
    ring = []
    steps = 180
    for i in range(steps):
        th = 2 * np.pi * i / steps
        x = int(round(home["x"] / cell + r * np.cos(th)))
        y = int(round(home["y"] / cell + r * np.sin(th)))
        inside = 0 <= x < gw and 0 <= y < gh
        ring.append(bool(inside and not wall[y, x]))
    frac = sum(ring) / steps
    if all(ring) or not any(ring):
        return frac, (1 if all(ring) else 0)
    # Rotate so an arc never straddles the seam, then count arcs wide enough
    # to walk through (a player is 13px; ~25px of arc is a real doorway).
    start = ring.index(False)
    rot = ring[start:] + ring[:start]
    min_steps = max(2, int(25 / (2 * np.pi * r * cell / steps)))
    arcs, run = 0, 0
    for v in rot:
        if v:
            run += 1
        else:
            if run >= min_steps:
                arcs += 1
            run = 0
    if run >= min_steps:
        arcs += 1
    return frac, arcs


def carry_lanes(carries, gw, gh, cell):
    """Which midfield lanes the FLAG actually travelled through.

    Distinct from the lane count: a map can offer three ways across and still
    have every successful carry take the same one, which plays as a one-lane
    map even though the geometry says otherwise. Buckets each midfield crossing
    by its y and counts clusters more than a player-width apart.
    """
    mid = gw * cell / 2
    band = 40
    ys = sorted(c["y"] for c in carries if abs(c["x"] - mid) < band)
    if not ys:
        return 0, []
    clusters, cur = [], [ys[0]]
    for y in ys[1:]:
        if y - cur[-1] > 60:        # a separate way through, not the same one
            clusters.append(cur)
            cur = [y]
        else:
            cur.append(y)
    clusters.append(cur)
    return len(clusters), [int(np.mean(c)) for c in clusters]


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
    from PIL import ImageDraw
    d = ImageDraw.Draw(out, "RGBA")

    # The carry routes first, underneath everything: how the game was WON.
    for c in data.get("carries", []):
        col = (176, 60, 40, 90) if c["flag"] == "red" else (40, 96, 176, 90)
        d.ellipse([c["x"] - 3, c["y"] - 3, c["x"] + 3, c["y"] + 3], fill=col)

    # The objective model, drawn so the evidence is read against the rules
    # actually in force: capture zone at the stand, and the real spawn areas.
    rad = data.get("captureRadius", 0)
    for team, key in (("red", "redHome"), ("blue", "blueHome")):
        home = data.get(key)
        if not home:
            continue
        col = (176, 60, 40, 190) if team == "red" else (40, 96, 176, 190)
        if rad:
            d.ellipse([home["x"] - rad, home["y"] - rad,
                       home["x"] + rad, home["y"] + rad], outline=col, width=2)
        d.line([home["x"] - 7, home["y"], home["x"] + 7, home["y"]], fill=col,
               width=3)
        d.line([home["x"], home["y"] - 7, home["x"], home["y"] + 7], fill=col,
               width=3)
    for team, key in (("red", "redSpawn"), ("blue", "blueSpawn")):
        z = data.get(key) or {}
        if z.get("w"):
            col = (176, 60, 40, 110) if team == "red" else (40, 96, 176, 110)
            d.rectangle([z["x"], z["y"], z["x"] + z["w"], z["y"] + z["h"]],
                        outline=col, width=2)

    # Deaths as rings: where the fights actually resolved.
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
    # Keep each episode's length and result. A capture calls finishGame, so an
    # episode that ENDS is itself the outcome signal, and dead space is not
    # comparable between a map whose games run to the tick limit and one whose
    # games are decided at half that.
    base["episodeTicks"] = [d["ticks"] for d in datas]
    base["episodeCaptures"] = [d.get("captures", 0) for d in datas]
    for d in datas[1:]:
        if d["map"] != base["map"]:
            raise SystemExit(f"merge: {d['map']} != {base['map']}")
        for key in ("occupancy", "occRed", "occBlue"):
            base[key] = [a + b for a, b in zip(base[key], d[key])]
        base["deaths"] = base["deaths"] + d["deaths"]
        base["carries"] = base.get("carries", []) + d.get("carries", [])
        base["steals"] = base.get("steals", 0) + d.get("steals", 0)
        base["captures"] = base.get("captures", 0) + d.get("captures", 0)
        base["ticks"] += d["ticks"]
    base["episodes"] = len(datas)
    return base


def report(paths, ref_ticks=0):
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

    lane_count, lanes_used, mid_open = lanes(wall, occ)

    # The objective model, as it is now: capture at the stand, not at the edge.
    rad = data.get("captureRadius", 0)
    exp_red, arcs_red = stand_exposure(
        wall, data.get("redHome", {"x": 0, "y": 0}), rad, cell)
    exp_blue, arcs_blue = stand_exposure(
        wall, data.get("blueHome", {"x": 0, "y": 0}), rad, cell)
    carries = data.get("carries", [])
    carry_lane_n, carry_ys = carry_lanes(carries, gw, gh, cell)

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
    # Deliberately NOT flagged on an absolute midfield-openness threshold.
    # The default arena — the layout this engine was tuned on — is itself 73%
    # open across midfield, so any fixed bar that means anything also fires on
    # the control. What is comparable is how many DISTINCT ways across that
    # openness is divided into: the arena splits its into 5, and a map with
    # one broad opening plays as a sprint rather than as lanes.
    if lane_count < 2:
        flags.append(f"midfield is {mid_open:.0%} open but arrives as ONE "
                     f"span — the arena divides a near-identical 73% into 5 "
                     "distinct ways across")
    elif lanes_used < 2:
        flags.append(f"{lane_count} midfield lanes exist but only "
                     f"{lanes_used} saw traffic — the others are decoration")
    # Dead space is only comparable between maps whose games ran about as
    # long. A capture ends the episode, so a map that converts fast leaves
    # more floor unvisited for a reason that is the opposite of a defect.
    short = ref_ticks and data["ticks"] < 0.6 * ref_ticks
    if dead_pct > 0.35 and not short:
        flags.append(f"{dead_pct:.0%} of open floor never visited — most of "
                     "the geometry is decoration")
    elif dead_pct > 0.35:
        flags.append(f"{dead_pct:.0%} unvisited, but these games ran "
                     f"{data['ticks']}t against {ref_ticks}t elsewhere — too "
                     "short a sample to call it decoration")
    if biggest_dead * cell * cell > 60000:
        flags.append(f"one unvisited region of ~{biggest_dead * cell * cell:,}"
                     "px² — a whole wing nobody played")
    for side, frac, arcs in (("red", exp_red, arcs_red),
                             ("blue", exp_blue, arcs_blue)):
        if frac < 0.25:
            flags.append(f"{side}'s flag stand ring is only {frac:.0%} open "
                         f"({arcs} way(s) in) — an attacker cannot contest it")
    if rad and abs(exp_red - exp_blue) > 0.25:
        flags.append(f"the two stands are not equally defensible: red ring "
                     f"{exp_red:.0%} open, blue {exp_blue:.0%} — with capture "
                     "AT the stand that is an objective-fairness gap")
    if carry_lane_n == 1 and len(carries) > 20:
        flags.append("every flag carry crossed midfield in the same lane — "
                     "the alternates exist but do not carry the objective")

    print(f"\n=== {name}  ({data.get('episodes', 1)} episode(s), "
          f"{data['ticks']} ticks)")
    print(f"    sightline median {median_sight:.0f}px, "
          f"{long_pct:.0%} over 600px")
    print(f"    midfield lanes: {lane_count} ({lanes_used} actually "
          f"used), {mid_open:.0%} of midfield open")
    print(f"    dead space {dead_pct:.0%} of open floor "
          f"(largest unvisited region {biggest_dead * cell * cell:,}px²)")
    print(f"    {len(deaths)} deaths, spread {spread:.0f}px")
    model = (f"capture r{rad} at the stand" if rad else "legacy home column")
    print(f"    objective: {model}; {data.get('steals', 0)} steals -> "
          f"{data.get('captures', 0)} captures")
    ep_ticks = data.get("episodeTicks", [])
    ep_caps = data.get("episodeCaptures", [])
    if ep_ticks:
        outcomes = ", ".join(
            f"{t}t {'capture' if c else 'no capture'}"
            for t, c in zip(ep_ticks, ep_caps or [0] * len(ep_ticks)))
        print(f"    episodes: {outcomes}")
    print(f"    stand ring: red {exp_red:.0%} open ({arcs_red} arc(s)), "
          f"blue {exp_blue:.0%} ({arcs_blue})")
    print(f"    carry routes crossed midfield in {carry_lane_n} lane(s) "
          f"{carry_ys}")
    for f in flags:
        print(f"    FLAG: {f}")
    if not flags:
        print("    no gameplay flags")
    return dict(map=name, medianSight=median_sight, longPct=long_pct,
                lanes=lane_count, lanesUsed=lanes_used,
                midOpen=mid_open,
                deadPct=dead_pct, biggestDead=biggest_dead,
                deaths=len(deaths), spread=spread,
                captureRadius=rad,
                standOpenRed=exp_red, standOpenBlue=exp_blue,
                standArcsRed=arcs_red, standArcsBlue=arcs_blue,
                steals=data.get("steals", 0),
                captures=data.get("captures", 0),
                carryLanes=carry_lane_n, carryYs=carry_ys,
                flags=flags)


def main():
    # Group the given files by map so several episodes of one map merge.
    groups = {}
    for p in sys.argv[1:]:
        m = json.loads(Path(p).read_text())["map"]
        groups.setdefault(m, []).append(p)
    # The longest-running map sets the yardstick for whether another map's
    # sample is long enough to judge its dead space against.
    ref = 0
    for paths in groups.values():
        ref = max(ref, sum(json.loads(Path(p).read_text())["ticks"]
                           for p in paths))
    out = {}
    for m, paths in groups.items():
        r = report(paths, ref_ticks=ref)
        r["episodes"] = len(paths)
        out[m] = r
    (GALLERY / "playtest.json").write_text(json.dumps(out, indent=1))
    print(f"\nwrote {GALLERY}/playtest.json + heat-<map>.png")


if __name__ == "__main__":
    main()
