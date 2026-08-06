#!/usr/bin/env python3
"""Judges a map on HOW IT PLAYS, from re-simulated episodes.

Consumes the evidence JSON `tools/map_playtest.nim` writes (one per episode)
and produces two things: a travel heatmap PNG per map, and a flat metric dict
ready to weight next to the STATIC score `src/ctf/map_metrics.nim` computes.

Four rules are enforced here rather than left to discipline, because each one
was learned by producing a confidently wrong number:

  * MERGE >= 3 EPISODES before judging. Episode length dominates dead space:
    one 1725-tick episode read a map as 53% dead floor; across three it was
    22%. `report()` refuses a dead-space verdict below three episodes.
  * A CAPTURE ENDS THE EPISODE, so episode length is itself an outcome, and
    dead space is not comparable between a map decided at half the tick limit
    and one that runs to it. Every episode's length and result print
    individually, never only their mean.
  * RUN THE CONTROL. Pass an `arena` evidence set in the same invocation and
    every flag is stated as a delta from it. Without one the report says so
    instead of quietly comparing against a remembered number.
  * NO COUNT WITHOUT ITS FRACTION.

Usage:
  tools/map_eval play arena --episodes 3 --out /tmp/ev
  for r in /tmp/ev/*.bitreplay; do
    /tmp/map_playtest "$r" --name arena --out "${r%.bitreplay}.json"; done
  python3 tools/map_playtest.py /tmp/ev/*.json
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

GALLERY = Path("/tmp/ctf-map-gallery")

# Team tints, in engine team order (Red, Blue, Green, Yellow).
TEAM_RGB = [(176, 60, 40), (40, 96, 176), (52, 150, 78), (198, 158, 44)]


def merge(datas):
    """Sums several episodes of the same map into one evidence set.

    Necessary because episode LENGTH dominates the dead-space number: a match
    that ends in a fast wipe leaves most of the field unvisited and would
    report the map as decorative when it is only the sample that was short.
    Merging several seeds measures the map instead of the match.
    """
    base = dict(datas[0])
    # Keep each episode's length and result separately. A capture calls
    # finishGame, so an episode that ENDS is itself the outcome signal.
    base["episodeTicks"] = [d["ticks"] for d in datas]
    base["episodeCaptures"] = [d.get("captures", 0) for d in datas]
    base["episodeSteals"] = [d.get("steals", 0) for d in datas]
    for d in datas[1:]:
        if d["map"] != base["map"]:
            raise SystemExit(f"merge: {d['map']} != {base['map']}")
        if (d["gw"], d["gh"]) != (base["gw"], base["gh"]):
            raise SystemExit(f"merge: {d['map']} grid changed between episodes")
        base["occupancy"] = [a + b for a, b in
                             zip(base["occupancy"], d["occupancy"])]
        base["occTeam"] = [[a + b for a, b in zip(x, y)]
                           for x, y in zip(base["occTeam"], d["occTeam"])]
        base["deaths"] = base["deaths"] + d["deaths"]
        base["carries"] = base["carries"] + d["carries"]
        base["kills"] = [a + b for a, b in zip(base["kills"], d["kills"])]
        for key in ("steals", "captures", "capturesInZone",
                    "carrierInZoneTicks", "ticks", "aliveTicks", "fightTicks",
                    "closeTicks", "measuredTicks"):
            base[key] = base.get(key, 0) + d.get(key, 0)
    base["episodes"] = len(datas)
    return base


def balance_entropy(counts, teams):
    """B = -sum (k_i/K) log_N (k_i/K), log base N = TEAM COUNT.

    The team-count base is what makes the number [0,1] for 2 / 3 / 4 / 6 teams
    alike, so a 4-team board's balance is directly comparable to a 2-team
    board's. Mirrors `balanceEntropy` in src/ctf/map_metrics.nim; the Nim side
    is the one under test.
    """
    total = sum(max(0, c) for c in counts)
    if total <= 0 or teams < 2:
        return 0.0
    ln_n = math.log(teams)
    return max(0.0, min(1.0, -sum(
        (c / total) * math.log(c / total) / ln_n for c in counts if c > 0)))


def heatmap(data, name):
    """Occupancy over the wall mask: where the match actually happened.

    Warm where players spent time, ink where the walls are, and PALE where open
    floor went unvisited — the dead space that says geometry is decorative.
    """
    gw, gh = data["gw"], data["gh"]
    wall = np.array(data["wall"], bool).reshape(gh, gw)
    occ = np.array(data["occupancy"], float).reshape(gh, gw)
    per_team = [np.array(t, float).reshape(gh, gw) for t in data["occTeam"]]

    img = np.zeros((gh, gw, 3), np.float32)
    img[:] = (0.96, 0.94, 0.90)                 # paper: unvisited open floor
    hot = occ > 0
    if hot.any():
        # Rank-normalize: one camper should not flatten the rest of the map.
        r = np.zeros_like(occ)
        order = occ[hot].argsort().argsort().astype(float)
        r[hot] = order / max(len(order) - 1, 1)
        # The intensity ramp is NEUTRAL — paper to warm graphite — so that
        # hue carries exactly one meaning: which team held the ground. mw2's
        # ramp was itself reddish (it only had to separate two teams by
        # nudging R and B), which made every hot cell red BEFORE any team tint
        # and left blue-held ground reading as dusty mauve while red-held
        # ground read as saturated red. Two halves of a mirrored board are then
        # not comparable by eye, which is the one comparison this image is for.
        for c, (lo, hi) in enumerate(((0.96, 0.34), (0.94, 0.32), (0.90, 0.30))):
            img[..., c] = np.where(hot, lo + (hi - lo) * r, img[..., c])
        # Tint by WHO held the ground: the team with the most time there,
        # weighted by how decisively they held it. With more than two teams a
        # single red/blue axis cannot carry this, so the winning team's own
        # colour is blended in by its share.
        #
        # The tint is ALSO scaled by `r`, the occupancy rank, and that is not
        # cosmetic. Blending a saturated team colour at full strength into a
        # barely-visited cell drags it ~70 luminance away from paper the moment
        # it is touched once, which collapses the whole ramp into a binary
        # visited/not-visited picture: the red half of the arena read as a
        # solid slab with no legible dead space inside it, which is the one
        # thing this image exists to show.
        stack = np.stack(per_team)
        total = np.maximum(stack.sum(axis=0), 1.0)
        top = stack.argmax(axis=0)
        share = stack.max(axis=0) / total
        for t in range(len(per_team)):
            mask = hot & (top == t)
            if not mask.any():
                continue
            tint = np.array(TEAM_RGB[t % len(TEAM_RGB)], np.float32) / 255.0
            # `share - 1/N` is zero on evenly contested ground, so contested
            # floor stays NEUTRAL GREY and only ground a team actually held
            # takes their colour. That removes the ambiguous purple mud where
            # both teams travelled, which a two-hue blend cannot avoid.
            pull = np.clip((share - 1.0 / len(per_team)) * 1.6, 0.0, 0.60) * r
            for c in range(3):
                img[..., c] = np.where(
                    mask, img[..., c] * (1 - pull) + tint[c] * pull,
                    img[..., c])
    img[wall] = (0.22, 0.18, 0.14)              # ink: cover

    out = Image.fromarray(np.clip(img * 255, 0, 255).astype(np.uint8))
    scale = 10
    out = out.resize((gw * scale, gh * scale), Image.NEAREST)
    d = ImageDraw.Draw(out, "RGBA")
    cell = data["cell"]
    px = scale / cell                            # map px -> image px

    def stroke(fn, box, col, width):
        """Draws an overlay with a dark halo under it.

        Every overlay here has to stay legible over BOTH paper and saturated
        team heat. A single thin coloured stroke does not: on the busy half of
        the board the capture circle and the spawn rectangle were invisible
        and the same-coloured death rings vanished into the ground they sat
        on. The halo costs one extra draw and makes contrast unconditional.
        """
        fn(box, outline=(20, 16, 12, 150), width=width + 2)
        fn(box, outline=col, width=width)

    # The carry routes first, UNDERNEATH everything: how the game was WON.
    #
    # Thinned to one dot per ~8px of travel. The evidence is one sample per
    # carrier per TICK, so at alpha 90 the samples overlap into an opaque bold
    # polyline that dominates the very heatmap it annotates.
    last = {}
    for c in data.get("carries", []):
        t = c["team"]
        prev = last.get(t)
        if prev is not None and (c["x"] - prev[0]) ** 2 + \
                (c["y"] - prev[1]) ** 2 < 64:
            continue
        last[t] = (c["x"], c["y"])
        col = TEAM_RGB[t % len(TEAM_RGB)] + (70,)
        x, y = c["x"] * px, c["y"] * px
        d.ellipse([x - 2, y - 2, x + 2, y + 2], fill=col)

    # The objective model, drawn so the evidence is read against the rules
    # actually in force: capture zone at the stand, and the real spawn areas.
    rad = data.get("captureRadius", 0) or data.get("flagRing", 0)
    for t, home in enumerate(data.get("homes", [])):
        col = TEAM_RGB[t % len(TEAM_RGB)] + (190,)
        x, y = home["x"] * px, home["y"] * px
        if rad:
            r = rad * px
            stroke(d.ellipse, [x - r, y - r, x + r, y + r], col, 3)
        d.line([x - 9, y, x + 9, y], fill=(20, 16, 12, 200), width=5)
        d.line([x, y - 9, x, y + 9], fill=(20, 16, 12, 200), width=5)
        d.line([x - 7, y, x + 7, y], fill=col, width=3)
        d.line([x, y - 7, x, y + 7], fill=col, width=3)
    for t, z in enumerate(data.get("spawns", [])):
        col = TEAM_RGB[t % len(TEAM_RGB)] + (170,)
        stroke(d.rectangle, [z["x"] * px, z["y"] * px,
                             (z["x"] + z["w"]) * px, (z["y"] + z["h"]) * px],
               col, 2)

    # Deaths as rings, on top: where the fights actually resolved.
    for dth in data["deaths"]:
        col = TEAM_RGB[dth["team"] % len(TEAM_RGB)] + (230,)
        x, y = dth["x"] * px, dth["y"] * px
        stroke(d.ellipse, [x - 9, y - 9, x + 9, y + 9], col, 2)

    GALLERY.mkdir(exist_ok=True, parents=True)
    path = GALLERY / f"heat-{name.replace(':', '-').replace('/', '_')}.png"
    out.save(path)
    return wall, occ, path


def pct(x, width=0):
    """A fraction as a percentage, or an explicit '-' when it has no denominator.

    `None` and `0.0` are DIFFERENT results here — 0 steals is not a 0%
    conversion — and printing both as "0%" is the exact conflation this
    harness exists to avoid.
    """
    return f"{'-' if x is None else f'{x * 100:.0f}%':>{width}}"


def _components(mask):
    """Sizes of 4-connected True regions. Kept dependency-free (no scipy)."""
    h, w = mask.shape
    seen = np.zeros_like(mask)
    sizes = []
    for sy in range(h):
        for sx in range(w):
            if not mask[sy, sx] or seen[sy, sx]:
                continue
            stack = [(sy, sx)]
            seen[sy, sx] = True
            n = 0
            while stack:
                y, x = stack.pop()
                n += 1
                for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] \
                            and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            sizes.append(n)
    return sizes


def report(datas, control=None):
    data = merge(datas)
    name = data["map"]
    wall, occ, heat_path = heatmap(data, name)
    cell = data["cell"]
    episodes = data["episodes"]

    # Count visited only WITHIN open cells. A player's body can sit in a cell
    # whose 10px center is not occupiable, so a raw (occ > 0) count can exceed
    # the open-cell count and report negative dead space.
    open_mask = ~wall
    open_cells = int(open_mask.sum())
    visited = int((open_mask & (occ > 0)).sum())
    dead_pct = 1.0 - visited / max(open_cells, 1)
    sizes = _components(open_mask & (occ == 0))
    biggest_dead = max(sizes) if sizes else 0

    deaths = data["deaths"]
    if deaths:
        dx = np.array([d["x"] for d in deaths], float)
        dy = np.array([d["y"] for d in deaths], float)
        spread = float(np.hypot(dx.std(), dy.std()))
    else:
        spread = 0.0

    teams = data["teams"]
    kills = data["kills"]
    balance = balance_entropy(kills, teams)
    # Rates divide by the window actually MEASURED. Under `--ticks` that is
    # shorter than the episode, and the episode length stays the outcome.
    ticks = max(1, data.get("measuredTicks") or data["ticks"])
    capped = bool(data.get("tickCap"))
    pace = 1000.0 * sum(kills) / ticks
    fight_frac = data["fightTicks"] / max(1, data["aliveTicks"])
    close_frac = data.get("closeTicks", 0) / max(1, data["aliveTicks"])

    # THE TOUCH, not the fight. The standing field finding is that combat sits
    # at parity and the objective TOUCH is where games are lost — 71.8% against
    # 94.9% conversion — so `captures / steals` is the number a map is judged
    # on, and it is meaningless as the bare count pair the line below used to
    # print. `conversion` is None (not 0.0) when nobody ever stole: no
    # denominator is a different result from a failed conversion, and averaging
    # the two together is how a map that is never even reached reads as a map
    # that is merely hard to score on.
    conversion = (data["captures"] / data["steals"]
                  if data["steals"] > 0 else None)
    zone_rate = 1000.0 * data["carrierInZoneTicks"] / ticks
    decided = sum(1 for c in data["episodeCaptures"] if c > 0)

    # EXPOSURE, not episode count, is what actually drives dead space: it is
    # alive seat-ticks spread over the floor there is to cover. The same arena
    # read 24% dead from one 6346-tick 16-seat episode and 51% from three
    # ~2000-tick 8-seat ones. So this is reported per open cell and every
    # verdict below is conditioned on it.
    exposure = data["aliveTicks"] / max(1, open_cells)

    flags = []
    is_control = control is not None and control["map"] == name
    # An ABSOLUTE dead-space threshold is the exact mistake this harness exists
    # to avoid: 0.35 fires on the hand-authored arena at three short episodes.
    # Dead space is only ever stated as an excess over the CONTROL measured at
    # comparable exposure, so the metric is structurally unable to flag its own
    # control.
    if episodes < 3:
        flags.append(
            f"{episodes} episode(s) only — REFUSING a dead-space verdict. "
            f"Episode length dominates this number (one 1725-tick sample once "
            f"read 53% dead floor where three read 22%).")
    elif control is None:
        flags.append(
            f"{dead_pct:.0%} dead floor, but NO CONTROL in this batch — "
            "refusing the verdict. There is no absolute bar here: the arena "
            "itself reads 24% dead at one long episode and 51% at three short "
            "ones, so only a delta from the control at comparable exposure "
            "means anything.")
    elif is_control:
        pass          # the control is the reference; it is never the verdict
    else:
        ctrl_open = int((~np.array(control["wall"], bool)).sum())
        ctrl_dead = 1.0 - int(
            (np.array(control["occupancy"], float) > 0)
            [~np.array(control["wall"], bool)].sum()) / max(1, ctrl_open)
        ctrl_exposure = control["aliveTicks"] / max(1, ctrl_open)
        ratio = exposure / max(1e-9, ctrl_exposure)
        if not 0.7 <= ratio <= 1.4:
            flags.append(
                f"{dead_pct:.0%} dead floor vs the control's {ctrl_dead:.0%}, "
                f"but exposure differs {ratio:.2f}x ({exposure:.1f} vs "
                f"{ctrl_exposure:.1f} alive seat-ticks per open cell) — NOT "
                "comparable, re-run both at the same seats and tick budget")
        elif dead_pct > ctrl_dead + 0.12:
            flags.append(
                f"{dead_pct:.0%} of open floor never visited against the "
                f"control's {ctrl_dead:.0%} at {ratio:.2f}x the same exposure "
                "— this map's geometry is decoration in a way the arena's is "
                "not")
        if biggest_dead * cell * cell > 60000 and 0.7 <= ratio <= 1.4:
            flags.append(
                f"one unvisited region of ~{biggest_dead * cell * cell:,}px² "
                "— a whole wing nobody played")
    if data["captures"] == 0 and data["steals"] > 0:
        flags.append(f"{data['steals']} steals converted to ZERO captures. "
                     f"The carrier stood in its own capture zone on "
                     f"{data['carrierInZoneTicks']} tick(s) — if that is also "
                     "0 the objective was never reached; if it is large the "
                     "carrier reached it and could not score, which is a "
                     "RULES or BOT question before it is a map question")
    if data["captures"] != data["capturesInZone"]:
        flags.append(f"HARNESS BUG: {data['captures']} engine captures but "
                     f"{data['capturesInZone']} verified inside the engine's "
                     "own capture zone — the geometry model disagrees with "
                     "the engine, so no map verdict here is trustworthy")
    if teams >= 2 and sum(kills) > 20 and balance < 0.90:
        flags.append(f"kills split {kills} = balance {balance:.2f} (1.0 is "
                     "even) — the map may favour a seat")
    if fight_frac < 0.15:
        flags.append(f"only {fight_frac:.0%} of alive time had an enemy in "
                     "gun range — the teams barely met")
    if control is not None and not is_control:
        ctrl_close = control.get("closeTicks", 0) / max(1, control["aliveTicks"])
        if close_frac < ctrl_close - 0.10:
            flags.append(
                f"close contact {close_frac:.0%} of alive time against the "
                f"control's {ctrl_close:.0%} (within "
                f"{data.get('closeRangePx', 0)}px) — the teams meet less here. "
                "GunRange contact is 100% on every map at these sizes and "
                "cannot see this")
    if control is not None and control["map"] != name:
        if data["ticks"] / episodes < 0.6 * control["ticks"] / control["episodes"]:
            flags.append(
                f"these games ran {data['ticks'] // episodes}t against the "
                f"control's {control['ticks'] // control['episodes']}t — a "
                "capture ENDS an episode, so dead space here is not "
                "comparable to the control's")

    print(f"\n=== {name}  ({episodes} episode(s), {data['ticks']} ticks total)")
    # Rule: each episode's length and result, individually. A mean hides that a
    # capture ended the episode.
    for i, (t, c, s) in enumerate(zip(data["episodeTicks"],
                                      data["episodeCaptures"],
                                      data["episodeSteals"])):
        outcome = f"{c} capture(s)" if c else "no capture"
        print(f"    ep{i}: {t}t, {s} steal(s) -> {outcome}")
    role = "  [CONTROL — the reference, never the verdict]" if is_control else ""
    print(f"    dead space {dead_pct:.0%} of open floor "
          f"({visited}/{open_cells} cells visited; largest unvisited region "
          f"{biggest_dead * cell * cell:,}px²){role}")
    print(f"    exposure {exposure:.1f} alive seat-ticks per open cell "
          f"({data['aliveTicks']:,} seat-ticks over {open_cells:,} cells)")
    print(f"    {len(deaths)} deaths, spread {spread:.0f}px")
    print(f"    kills {kills}  balance {balance:.2f}  "
          f"pace {pace:.1f} kills/1000t  contact {fight_frac:.0%} in gun range "
          f"/ {close_frac:.0%} within {data.get('closeRangePx', 0)}px")
    print(f"    objective: {data['steals']} steals -> {data['captures']} "
          f"captures ({data['capturesInZone']} verified in zone) = "
          f"{pct(conversion)} conversion, carrier in zone "
          f"{data['carrierInZoneTicks']}t ({zone_rate:.1f} per 1000t)")
    print(f"    decided by capture: {decided}/{episodes} episode(s) = "
          f"{decided / episodes:.0%}")
    print(f"    heatmap {heat_path}")
    for f in flags:
        print(f"    FLAG: {f}")
    if not flags:
        print("    no gameplay flags")
    return dict(map=name, episodes=episodes, ticks=data["ticks"],
                episodeTicks=data["episodeTicks"],
                episodeCaptures=data["episodeCaptures"],
                episodeSteals=data["episodeSteals"],
                deadPct=dead_pct, biggestDead=biggest_dead,
                biggestDeadPx2=biggest_dead * cell * cell,
                openCells=open_cells, visitedCells=visited,
                exposure=exposure,
                isControl=is_control,
                deaths=len(deaths), spread=spread,
                kills=kills, balanceEntropy=balance, pace=pace,
                fightTimeFrac=fight_frac, closeContactFrac=close_frac,
                measuredTicks=ticks, tickCapped=capped,
                steals=data["steals"], captures=data["captures"],
                capturesInZone=data["capturesInZone"],
                conversion=conversion, decidedFrac=decided / episodes,
                carrierInZoneTicks=data["carrierInZoneTicks"],
                carrierInZonePer1000t=zone_rate,
                teams=teams,
                heatmap=str(heat_path), flags=flags)


def comparison(rows):
    """The one-page table: every map as a column, the control's column first.

    Transposed on purpose. The question this answers is "generated vs arena,
    per metric", and a metric is only readable as a comparison when its values
    sit on ONE line — a map-per-row table makes the reader scan across 14
    columns to compare two numbers that differ by 24 points.

    The control's column is first and marked, and the delta block below states
    every headline number as an excess over it, because none of these have an
    absolute bar (see the dead-space note in `report`).
    """
    names = ([r["map"] for r in rows if r["isControl"]] +
             [r["map"] for r in rows if not r["isControl"]])
    by = {r["map"]: r for r in rows}
    ctrl = next((r for r in rows if r["isControl"]), None)
    w = max(13, max(len(n) for n in names) + 2)

    def line(label, fn):
        print(f"  {label:<26}" + "".join(f"{fn(by[n]):>{w}}" for n in names))

    print("\n" + "=" * (28 + w * len(names)))
    print("ONE-PAGE COMPARISON — generated vs arena, per metric")
    header = "".join(
        f"{n + ('*' if by[n]['isControl'] else ''):>{w}}" for n in names)
    print(f"  {'':<26}{header}")
    print(f"  {'':<26}" + "".join(f"{'CONTROL' if by[n]['isControl'] else '':>{w}}"
                                  for n in names))
    print("")
    line("teams", lambda r: r["teams"])
    line("episodes", lambda r: r["episodes"])
    line("median episode length", lambda r: f"{sorted(r['episodeTicks'])[len(r['episodeTicks']) // 2]}t")
    line("decided by a capture", lambda r:
         f"{sum(1 for c in r['episodeCaptures'] if c)}/{r['episodes']} "
         f"{r['decidedFrac'] * 100:.0f}%")
    print("")
    line("open floor (10px cells)", lambda r: f"{r['openCells']:,}")
    line("visited", lambda r:
         f"{r['visitedCells']:,} {r['visitedCells'] / max(1, r['openCells']) * 100:.0f}%")
    line("DEAD SPACE", lambda r: f"{r['deadPct'] * 100:.0f}%")
    line("largest dead region", lambda r: f"{r['biggestDeadPx2']:,}px²")
    line("exposure (seat-t/cell)", lambda r: f"{r['exposure']:.1f}")
    print("")
    line("steals", lambda r: r["steals"])
    line("captures", lambda r: r["captures"])
    line("CONVERSION grab->cap", lambda r: pct(r["conversion"]))
    line("carrier in zone /1000t", lambda r: f"{r['carrierInZonePer1000t']:.1f}")
    print("")
    line("deaths", lambda r: r["deaths"])
    line("kills/1000t", lambda r: f"{r['pace']:.1f}")
    line("contact, gun range", lambda r: f"{r['fightTimeFrac'] * 100:.0f}%")
    line("contact, close", lambda r: f"{r['closeContactFrac'] * 100:.0f}%")
    line("balance entropy", lambda r: f"{r['balanceEntropy']:.2f}")

    print("")
    if ctrl is None:
        print("  NO CONTROL COLUMN. There is no hand-authored map at this team "
              "count, so every number above is readable only against the other "
              "generated maps — not against a known-good board.")
        return
    print("  DELTA FROM THE CONTROL  (generated - arena; pp = percentage points)")
    for n in names:
        r = by[n]
        if r["isControl"]:
            continue
        conv = ("conversion n/a (no steals)" if r["conversion"] is None
                else "conversion " +
                ("n/a vs control (control never stole)"
                 if ctrl["conversion"] is None else
                 f"{(r['conversion'] - ctrl['conversion']) * 100:+.0f}pp"))
        print(f"    {n:<12} dead floor "
              f"{(r['deadPct'] - ctrl['deadPct']) * 100:+.0f}pp   {conv}   "
              f"decided {(r['decidedFrac'] - ctrl['decidedFrac']) * 100:+.0f}pp"
              f"   exposure {r['exposure'] / max(1e-9, ctrl['exposure']):.2f}x")
    print("  Exposure outside 0.70..1.40x makes the dead-space delta beside it "
          "NOT comparable — see the per-map FLAG lines above.")


def main():
    paths = sys.argv[1:]
    if not paths:
        raise SystemExit(__doc__)
    groups = {}
    for p in paths:
        d = json.loads(Path(p).read_text())
        groups.setdefault(d["map"], []).append(d)

    # THE CONTROL. Every flag below is a delta from the hand-authored arena;
    # without one in the batch the report says so rather than comparing
    # against a number somebody remembers.
    control = None
    for m, ds in groups.items():
        if m == "arena" or m.endswith("/arena"):
            control = merge(ds)
    if control is None:
        print("NO CONTROL IN THIS BATCH. Run the arena through the same "
              "episode count ('tools/map_eval play arena --episodes 3') and "
              "pass its evidence here. A dynamic number without the control "
              "beside it has no scale.")

    out = {m: report(ds, control) for m, ds in sorted(groups.items())}
    comparison(list(out.values()))
    GALLERY.mkdir(exist_ok=True, parents=True)
    (GALLERY / "playtest.json").write_text(json.dumps(out, indent=1))
    print(f"\nwrote {GALLERY}/playtest.json + heat-<map>.png")


if __name__ == "__main__":
    main()
