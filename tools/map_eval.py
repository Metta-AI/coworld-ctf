#!/usr/bin/env python3
"""Judges a map on HOW IT PLAYS, and renders the evidence.

The companion to `tools/map_eval.nim`, which writes the artifacts this reads:

    nim c -d:release -o:/tmp/mapeval tools/map_eval.nim
    /tmp/mapeval --map arena --map pool:0 --map pool:3 --episodes 3
    python3 tools/map_eval.py /tmp/map-eval

Geometry in the correct place says nothing about whether players use it, so
this measures the things that actually decide a match:

  * DEAD SPACE — open floor no player visited all match. The clearest sign
    that geometry is decorative rather than played.
  * MIDFIELD LANES, and how many of them saw traffic. A map can offer three
    ways across and have every carry take the same one.
  * CARRY ROUTES — where the FLAG travelled, which is how the map is WON.
    Distinct from where players walked.
  * ENGAGEMENT SPREAD — where players died, and whether fights cluster in
    one blob or distribute across lanes.
  * BALANCE ENTROPY, pace and fight-time fraction, from the Nim side.

It also re-derives `enclosure` — the architecture-vs-scatter discriminator,
the highest-value single static metric — independently in numpy from the raw
wall mask, and cross-checks it against the Nim implementation. Two
implementations of the number everything else is ranked against is worth the
thirty lines.

The five meta-rules are enforced here as well as in the Nim side:
  1. The control (`arena`) is reported in every batch, and every flag is
     phrased against it. A metric that flags your control is wrong; a
     metric that SKIPS your control is worse.
  2. Never a count without its fraction.
  3. Merge >= 3 episodes before judging; fewer prints a warning.
  4. A capture ENDS the episode, so length is itself an outcome — every
     episode's ticks and result are printed, and a short sample is never
     called decorative.
  5. Thresholds come from the control, and near-miss values say so.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

CONTROL = "arena"


# ------------------------------------------------------------ enclosure ----

def enclosure(wall, reach=120):
    """How enclosed each piece of floor is: of 8 directions, how many are
    blocked by wall within `reach` px.

    Connectivity is the wrong tool for this and produced a number that
    flagged the control: floor inside a building is still perfectly
    REACHABLE through its door, and meanwhile the map's own border frame
    makes every open pixel unable to reach the image edge — so a flood-based
    "enclosed" measure reported one room covering the whole playfield on
    every map, arena included. What actually distinguishes a room is being
    surrounded at short range, which is a local property, not a topological
    one.

    Reading the score: 0-2 is open field, 3-5 is cover or a corridor, 6+
    means the floor is walled on nearly every side — a room, an alcove, an
    interior.
    """
    open_ = ~wall
    blocked = np.zeros(wall.shape, np.uint8)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0),
                   (1, 1), (1, -1), (-1, 1), (-1, -1)):
        hit = np.zeros(wall.shape, bool)
        cur = wall.copy()
        for _ in range(reach):
            cur = np.roll(cur, (dy, dx), axis=(0, 1))
            # Rolling wraps; clear the wrapped edge so one side of the map
            # cannot shadow the other.
            if dy > 0:
                cur[0, :] = False
            elif dy < 0:
                cur[-1, :] = False
            if dx > 0:
                cur[:, 0] = False
            elif dx < 0:
                cur[:, -1] = False
            hit |= cur
        blocked += hit.astype(np.uint8)
    return np.where(open_, blocked, 0), open_


def enclosure_report(static_path):
    """Re-derives interior/covered/exposed from the raw mask and compares.

    The Nim side sweeps a running "steps to the next wall" counter; this
    rolls the whole mask, exactly as the reference did. They are different
    code answering the same question, so a disagreement is a bug in one of
    them and is worth knowing about before anything is ranked on it.
    """
    static = json.loads(static_path.read_text())
    mask_path = static_path.parent / ("mask-" + static_path.stem[len("static-"):] + ".bin")
    if not mask_path.exists():
        return None
    raw = np.fromfile(mask_path, np.uint8)
    wall = (raw > 0).reshape(static["height"], static["width"])
    score, open_ = enclosure(wall)
    interior = float((score[open_] >= 6).mean())
    covered = float((score[open_] >= 3).mean())
    exposed = float((score[open_] <= 1).mean())
    return dict(source=static["source"], numpy=interior, nim=static["interiorFrac"],
                covered=covered, exposed=exposed)


# ------------------------------------------------------------- dynamics ----

def sightlines(wall):
    """Open-shot length along both axes, in cells, from every open cell.

    What governs a fight is how far you can see before geometry cuts the
    angle. Measured on the grid the heatmap uses so it lines up with the
    occupancy evidence.

    Fed the LINE-OF-SIGHT mask, not the footprint mask: a shot travels
    through the 6px band along every wall that a player's body cannot enter.
    Reading it off the footprint mask reported an 80px median for the
    control where the static side reported 112px for the same geometry.
    """
    gh, gw = wall.shape
    out = []
    for row in list(wall) + list(wall.T):
        run = 0
        for cell in row:
            if cell:
                if run:
                    out.append(run)
                run = 0
            else:
                run += 1
        if run:
            out.append(run)
    return np.array(out) if out else np.array([0])


def lanes(wall, occ=None):
    """How many distinct LANES cross midfield, and how many saw traffic.

    Counted as the separate gaps in the wall along the most divided line of
    the midfield BAND, which is the shape of the question: a lane is a way
    THROUGH the middle, and two routes that funnel into the same midfield
    gap are one lane.

    Two earlier framings were wrong in instructive ways. "Find a path, wall
    it off, find another" reported ONE route for every layout including the
    default arena, because at this cell scale blocking a path severs the
    map. Sampling the exact centre column reported ONE crossing for every
    layout including the arena too — the arena's centre sits inside a disc
    of protected floor the generator may not build in, so the centre column
    is open on every map by construction. When a metric flags your control,
    the metric is wrong.

    Returns (lane_count, used_lane_count, open_fraction) at the reported
    line. The count ALONE is degenerate in exactly the way the stand-ring
    metric was: one enormous opening scores the same "1" as one narrow
    doorway. Read the count against the fraction: low count plus low
    fraction is a corridor, low count plus high fraction is a field.
    """
    gh, gw = wall.shape
    best = (0, 0, 1.0, gw // 2)
    half = max(1, gw // 8)
    for col in range(max(0, gw // 2 - half), min(gw, gw // 2 + half + 1)):
        band = wall[:, max(0, col - 2):col + 3].any(axis=1)
        count, used, run, run_rows = 0, 0, 0, []
        for y in range(gh):
            if not band[y]:
                run += 1
                run_rows.append(y)
            else:
                if run >= 3:          # >= ~30px: a player is 13px wide
                    count += 1
                    if occ is not None and any(
                            occ[r, max(0, col - 2):col + 3].sum() > 0
                            for r in run_rows):
                        used += 1
                run, run_rows = 0, []
        if run >= 3:
            count += 1
            if occ is not None and any(occ[r, max(0, col - 2):col + 3].sum() > 0
                                       for r in run_rows):
                used += 1
        frac = float((~band).mean())
        if count > best[0] or (count == best[0] and frac < best[2]):
            best = (count, used, frac, col)
    return best[0], best[1], best[2]


def carry_lanes(carries, gw, gh, cell):
    """Which midfield lanes the FLAG actually travelled through.

    Distinct from the lane count: a map can offer three ways across and
    still have every successful carry take the same one, which plays as a
    one-lane map even though the geometry says otherwise.
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


# -------------------------------------------------------------- heatmap ----

def heatmap(data, path):
    """Occupancy over the wall mask: where the match actually happened.

    Warm where players spent time, ink where the walls are, and PALE where
    open floor went unvisited — the dead space that says geometry is
    decorative.
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
    d = ImageDraw.Draw(out, "RGBA")
    cell = data["cell"]
    scale = 10.0 / cell                          # map px -> image px

    def sx(v):
        return v * scale

    # Marker sizes ride the output, not a fixed pixel count. A 7px pedestal
    # cross is four screen pixels on the arena's 1550px canvas and is simply
    # not there on a giant map's 4000px one — the landmark a reader needs
    # most is the one that disappears first as maps grow. Deaths and carry
    # dots stay small on purpose: they are a density field, not landmarks.
    carry_r = max(3.0, 2.4 * scale)
    death_r = max(7.0, 7.5 * scale)
    landmark = max(18.0, 0.018 * max(out.width, out.height))
    arm = landmark
    stroke = max(3, int(landmark / 6))

    team_colors = {"red": (176, 60, 40), "blue": (40, 96, 176),
                   "green": (45, 155, 85), "yellow": (200, 160, 30)}

    # The carry routes first, underneath everything: how the game was WON.
    for c in data.get("carries", []):
        col = team_colors.get(c["flag"], (120, 120, 120)) + (110,)
        x, y = sx(c["x"]), sx(c["y"])
        d.ellipse([x - carry_r, y - carry_r, x + carry_r, y + carry_r],
                  fill=col)

    # The objective model, drawn so the evidence is read against the rules
    # actually in force: capture zone at the stand, and the real spawn areas.
    rad = data.get("captureRadius", 0)
    for zone in data.get("spawns", []):
        col = team_colors.get(zone["team"], (120, 120, 120)) + (110,)
        d.rectangle([sx(zone["x"]), sx(zone["y"]),
                     sx(zone["x"] + zone["w"]), sx(zone["y"] + zone["h"])],
                    outline=col, width=max(2, stroke - 1))
    for home in data.get("homes", []):
        col = team_colors.get(home["team"], (120, 120, 120)) + (255,)
        x, y = sx(home["x"]), sx(home["y"])
        if rad:
            r = sx(rad)
            d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=stroke)
        # A white disc under the pedestal, because the marker has to read
        # over ink, over a saturated warm wash, over a saturated cool one
        # and over paper — and a team-coloured cross drawn straight onto its
        # own team's half of the heat map reads over none of them.
        hub = landmark * 0.55
        d.ellipse([x - hub, y - hub, x + hub, y + hub],
                  fill=(255, 255, 255, 235), outline=col, width=stroke)
        d.line([x - arm, y, x + arm, y], fill=col, width=stroke)
        d.line([x, y - arm, x, y + arm], fill=col, width=stroke)

    # Deaths as rings, on top: where the fights actually resolved.
    for dth in data["deaths"]:
        col = team_colors.get(dth["team"], (120, 120, 120)) + (210,)
        x, y = sx(dth["x"]), sx(dth["y"])
        d.ellipse([x - death_r, y - death_r, x + death_r, y + death_r],
                  outline=col, width=3)
    out.save(path)
    return wall, occ


# ---------------------------------------------------------------- merge ----

def merge(paths):
    """Sums several episodes of the same map into one evidence set.

    Necessary because episode LENGTH dominates the dead-space number: a
    match that ends in a fast wipe leaves most of the field unvisited and
    would report the map as decorative when it is only the sample that was
    short. Merging several seeds measures the map instead of the match.
    """
    datas = [json.loads(Path(p).read_text()) for p in paths]
    base = datas[0]
    # Keep each episode's length and result. A capture ends the game, so an
    # episode that ENDS is itself the outcome signal, and dead space is not
    # comparable between a map whose games run to the tick limit and one
    # whose games are decided at half that.
    base["episodeTicks"] = [d["ticks"] for d in datas]
    base["episodeCaptures"] = [d.get("captures", 0) for d in datas]
    base["balanceEntropies"] = [d.get("balanceEntropy", 0.0) for d in datas]
    base["fightFracs"] = [d.get("fightTimeFrac", 0.0) for d in datas]
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


# --------------------------------------------------------------- report ----

def report(paths, gallery, control=None, ref_ticks=0):
    data = merge(paths if isinstance(paths, list) else [paths])
    name = data.get("source", data["map"])
    stem = "".join(c if c.isalnum() or c in "-_" else "-" for c in name)
    wall, occ = heatmap(data, gallery / f"heat-{stem}.png")
    gh, gw = wall.shape
    cell = data["cell"]

    los = np.array(data.get("wallLos", data["wall"]), bool).reshape(gh, gw)
    sl = sightlines(los)
    median_sight = float(np.median(sl)) * cell
    long_pct = float((sl * cell > 600).mean())

    # Count visited only WITHIN open cells. A player's body can sit in a
    # cell whose centre is not occupiable, so a raw (occ > 0) count can
    # exceed the open-cell count and report negative dead space.
    open_mask = ~wall
    open_cells = int(open_mask.sum())
    visited = int((open_mask & (occ > 0)).sum())
    dead_pct = 1.0 - visited / max(open_cells, 1)

    # Largest single unvisited open region — a big one is a whole wing of
    # the map nobody played, which no amount of correct footprints excuses.
    unvisited = open_mask & (occ == 0)
    lab, n = ndimage.label(unvisited)
    sizes = np.bincount(lab.ravel())[1:] if n else np.array([0])
    biggest_dead = int(sizes.max()) if len(sizes) else 0

    lane_count, lanes_used, mid_open = lanes(wall, occ)
    carries = data.get("carries", [])
    carry_lane_n, carry_ys = carry_lanes(carries, gw, gh, cell)

    deaths = data["deaths"]
    if deaths:
        dx = np.array([d["x"] for d in deaths], float)
        dy = np.array([d["y"] for d in deaths], float)
        spread = float(np.hypot(dx.std(), dy.std()))
    else:
        spread = 0.0

    episodes = data.get("episodes", 1)
    balance = float(np.mean(data.get("balanceEntropies", [0.0])))
    fight = float(np.mean(data.get("fightFracs", [0.0])))
    pace = len(deaths) * 1000.0 / max(data["ticks"], 1)

    result = dict(
        source=name, map=data["map"], episodes=episodes,
        ticks=data["ticks"], medianSight=median_sight, longPct=long_pct,
        lanes=lane_count, lanesUsed=lanes_used, midOpen=mid_open,
        deadPct=dead_pct, biggestDeadPx=biggest_dead * cell * cell,
        deaths=len(deaths), spread=spread,
        steals=data.get("steals", 0), captures=data.get("captures", 0),
        carryLanes=carry_lane_n, carryYs=carry_ys,
        balanceEntropy=balance, fightTimeFrac=fight, paceDeathsPer1000=pace,
        episodeTicks=data.get("episodeTicks", []),
        episodeCaptures=data.get("episodeCaptures", []),
    )

    flags = []
    # Every threshold below is stated against the control, which is the
    # layout the engine was tuned on. `control is None` means we are
    # reporting the control itself.
    if control:
        if median_sight > 1.5 * control["medianSight"]:
            flags.append(
                f"sightlines long (median {median_sight:.0f}px vs the "
                f"control's {control['medianSight']:.0f}px) — plays open")
        if long_pct > max(0.02, control["longPct"] * 1.6):
            flags.append(
                f"{long_pct:.0%} of open runs exceed 600px against the "
                f"control's {control['longPct']:.0%} — gallery shots")
        if lane_count < max(2, control["lanes"] // 2):
            flags.append(
                f"midfield is {mid_open:.0%} open but arrives as "
                f"{lane_count} span(s) — the control divides a comparable "
                f"{control['midOpen']:.0%} into {control['lanes']}")
        if dead_pct > control["deadPct"] + 0.15 and episodes >= 3:
            flags.append(
                f"{dead_pct:.0%} of open floor never visited against the "
                f"control's {control['deadPct']:.0%} — geometry is decoration")
        if balance < control["balanceEntropy"] - 0.15:
            flags.append(
                f"kill balance entropy {balance:.2f} vs the control's "
                f"{control['balanceEntropy']:.2f} — one team owns the map")
        if control["captures"] > 0 and result["captures"] == 0:
            flags.append(
                f"{result['steals']} steals converted 0 times, while the "
                f"control converted {control['captures']} — the objective "
                "does not close here")
    if lanes_used < 2 and lane_count >= 2:
        flags.append(f"{lane_count} midfield lanes exist but only "
                     f"{lanes_used} saw traffic — the others are decoration")
    if biggest_dead * cell * cell > 60000:
        flags.append(f"one unvisited region of ~{biggest_dead * cell * cell:,}"
                     "px² — a whole wing nobody played")
    if carry_lane_n == 1 and len(carries) > 20:
        flags.append("every flag carry crossed midfield in the same lane — "
                     "the alternates exist but do not carry the objective")
    if episodes < 3:
        flags.append(f"only {episodes} episode(s) merged — one 1725-tick "
                     "episode read a real map as 53% dead floor where three "
                     "read 22%. Do not judge this map off this sample.")
    result["flags"] = flags

    tag = "  <-- CONTROL" if control is None else ""
    print(f"\n=== {name}  ({data['map']}, {episodes} episode(s), "
          f"{data['ticks']} ticks){tag}")
    # META-RULE 4: a capture ends the episode, so length is an outcome.
    outcomes = ", ".join(
        f"{t}t {'capture' if c else 'no capture'}"
        for t, c in zip(result["episodeTicks"], result["episodeCaptures"]))
    print(f"    episodes: {outcomes}")
    print(f"    sightline median {median_sight:.0f}px, "
          f"{long_pct:.0%} over 600px")
    # META-RULE 2: never a count without its fraction.
    print(f"    midfield lanes: {lane_count} ({lanes_used} actually used), "
          f"{mid_open:.0%} of that line open")
    print(f"    dead space {dead_pct:.0%} of open floor "
          f"(largest unvisited region {biggest_dead * cell * cell:,}px²)")
    print(f"    {len(deaths)} deaths, spread {spread:.0f}px, "
          f"pace {pace:.1f} deaths/1000t, fight-time {fight:.0%}")
    print(f"    objective: {data.get('steals', 0)} steals -> "
          f"{data.get('captures', 0)} captures; carries crossed midfield in "
          f"{carry_lane_n} lane(s) {carry_ys}")
    print(f"    balance entropy {balance:.2f} "
          f"(1.00 = every team took an equal share of the kills)")
    for f in flags:
        print(f"    FLAG: {f}")
    if not flags:
        print("    no gameplay flags")
    return result


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/map-eval")
    if not root.is_dir():
        raise SystemExit(f"no artifact directory at {root}")

    print("architecture cross-check — the Nim sweep and this numpy roll are")
    print("two implementations of the same question; they must agree.\n")
    for static in sorted(root.glob("static-*.json")):
        row = enclosure_report(static)
        if not row:
            continue
        delta = abs(row["numpy"] - row["nim"])
        verdict = "agree" if delta < 0.005 else "DISAGREE"
        print(f"  {row['source']:<28} interior numpy {row['numpy']:6.1%} "
              f"nim {row['nim']:6.1%}  {verdict}    "
              f"covered {row['covered']:5.1%}  wide open {row['exposed']:5.1%}")

    groups = {}
    for path in sorted(root.glob("playtest-*.json")):
        source = json.loads(path.read_text()).get("source", path.stem)
        groups.setdefault(source, []).append(path)
    if not groups:
        print("\nno playtest-*.json found — run map_eval with --episodes 3.")
        return

    # META-RULE 1: the control is reported first and everything else is
    # phrased against it. Without it there is nothing to phrase against.
    if CONTROL not in groups:
        raise SystemExit(
            f"no episodes for the control ({CONTROL}). A metric that skips "
            "your control is worse than one that flags it — rerun the batch "
            "with the control simulated.")

    print("\ngameplay evidence — the control is the floor, not the target")
    control = report(groups.pop(CONTROL), root)
    out = {CONTROL: control}
    for source, paths in sorted(groups.items()):
        out[source] = report(paths, root, control=control)

    (root / "playtest.json").write_text(json.dumps(out, indent=1))
    print(f"\nwrote {root}/playtest.json + heat-<source>.png")


if __name__ == "__main__":
    main()
