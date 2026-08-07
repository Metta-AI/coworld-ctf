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
    instead of quietly comparing against a remembered number. Where no
    hand-authored map EXISTS — there is none at 4 teams — `--reference <map>`
    names a generated map as the yardstick instead, and everything it heads is
    stamped REFERENCE, never CONTROL. See `Baseline` for why that is enforced
    in code and not left to the writeup.
  * NO COUNT WITHOUT ITS FRACTION.
  * EVERY OBJECTIVE, SEPARATELY. `pedestal_reach` reports per pedestal, not
    summed: a board can leave two of its four objectives untouched for three
    whole episodes and score FAIR on every static symmetry metric there is.

Usage:
  tools/map_eval play arena --episodes 3 --out /tmp/ev
  for r in /tmp/ev/*.bitreplay; do
    /tmp/map_playtest "$r" --name arena --out "${r%.bitreplay}.json"; done
  python3 tools/map_playtest.py /tmp/ev/*.json
  python3 tools/map_playtest.py --reference gen:1020 /tmp/ev4/*.json
"""
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

GALLERY = Path(os.environ.get("CTF_MAP_GALLERY", "/tmp/ctf-map-gallery"))
# One fixed gallery silently CLOBBERS across batches, and the collision is not
# hypothetical: the same seed is a valid map at 2 and at 4 teams, so a 4-team
# run of gen:1024 overwrites the 2-team run's heatmap and playtest.json with a
# different board of the same name. Point CTF_MAP_GALLERY at a per-batch dir.

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
    base["episodeOutcomes"] = [d.get("outcome", "?") for d in datas]
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


def pedestal_reach(data):
    """PER-PEDESTAL enemy presence — was each objective ever even APPROACHED?

    "0 steals" has two completely different causes and the objective counters
    cannot separate them: either nobody ever got to the enemy pedestal, or they
    got there and kept dying on it. This walks the per-team occupancy grid over
    the ring around each home and asks, of every OTHER team separately, whether
    it ever stood there.

    PER PEDESTAL, not summed, because the summed form hid the finding it was
    built to catch. A rot90-symmetric board scores FAIR STATICALLY, and static
    fairness is a claim about GEOMETRY — it says nothing about whether the
    geometry is reachable in play. Two of four pedestals going untouched for
    three whole episodes is invisible in a total that the other two inflate,
    and at 4 teams even "reached" is too coarse: a pedestal one neighbour
    wandered into is not the same objective as one all three enemies contested.

    So three numbers per home, each answering a strictly harder question:
      approached  — did ANY enemy ever stand on it (a zero here needs no
                    control; zero is zero at any scale)
      attackers   — how many of the N-1 possible enemies ever did
      share       — enemy seat-ticks there as a fraction of alive time

    and across the board, `pressureBalance`: the entropy of enemy seat-ticks
    over the pedestals, base N, so 1.0 is pressure spread perfectly evenly over
    every objective and a board whose symmetry survived only on paper falls
    away from it. `attackPairs` is the same question at ordered-pair
    resolution: of the N*(N-1) (attacker, target) pairs the rules allow, how
    many actually happened.
    """
    gw, gh, cell = data["gw"], data["gh"], data["cell"]
    per_team = [np.array(t, float).reshape(gh, gw) for t in data["occTeam"]]
    radius = max(data.get("flagRing", 0) or data.get("captureRadius", 0), cell)
    ys, xs = np.mgrid[0:gh, 0:gw]
    homes = data.get("homes", [])
    alive = max(1, data.get("aliveTicks", 0))
    seats = []
    for t, home in enumerate(homes):
        ring = ((xs * cell + cell / 2 - home["x"]) ** 2 +
                (ys * cell + cell / 2 - home["y"]) ** 2) <= radius ** 2
        # Per ENEMY, kept apart. Summing here is what made a pedestal only one
        # neighbour ever touched read the same as a fully contested one.
        by_enemy = [int(per_team[o][ring].sum()) if o != t else 0
                    for o in range(len(per_team))]
        ticks = sum(by_enemy)
        seats.append(dict(
            team=t, ticks=ticks, approached=ticks > 0,
            attackers=sum(1 for v in by_enemy if v > 0),
            possibleAttackers=max(0, len(per_team) - 1),
            share=ticks / alive, byEnemy=by_enemy))
    ticks_each = [s["ticks"] for s in seats]
    pairs = sum(s["attackers"] for s in seats)
    possible_pairs = len(homes) * max(0, len(per_team) - 1)
    return dict(
        seats=seats, homes=len(homes),
        reached=sum(1 for s in seats if s["approached"]),
        neverApproached=[s["team"] for s in seats if not s["approached"]],
        ticks=sum(ticks_each), share=sum(ticks_each) / alive,
        ringPx=radius,
        # Balance over the OBJECTIVES, base = pedestal count, so a 4-team
        # board's spread is directly comparable to a 2-team board's — the same
        # normalisation `balanceEntropy` uses for kills.
        pressureBalance=balance_entropy(ticks_each, max(2, len(homes))),
        attackPairs=pairs, possibleAttackPairs=possible_pairs)


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


HAND_AUTHORED = ("arena", "arena-large", "arena4")
"""The maps a human placed every shape on, and therefore the only ones this
script will call a CONTROL. Read `Baseline` below for why the distinction is
carried in code.

This tuple is the entire basis for the word "control" in this file, so the one
change that would make every 4-team verdict dishonest is adding a `gen:` or
`pool:` name to it. A generated map belongs on the `--reference` flag, which
stamps REFERENCE on everything it heads precisely so it cannot be mistaken for
this. Membership here is a claim about PROVENANCE, not about quality: `arena4`
is listed because a person authored its 21 seed shapes in
`tools/author_arena4.py`, not because it measured well — at the time it was
added it had not been played at all.
"""


class Baseline:
    """The map every other map's numbers are stated against — and WHICH KIND.

    There are two, they are not interchangeable, and the difference is the
    whole reason this class exists rather than a bare dict:

      CONTROL — a HAND-AUTHORED map (`arena`). Known-good, designed by a human,
        and outside the population under test. A generated map that is 19pp
        deader than the control is worse than a board we know plays; that is a
        verdict, and it is the bar the epic asks for.

      REFERENCE POINT — one GENERATED map, drawn from the very population being
        judged, named as the yardstick because no hand-authored map exists at
        this team count. It can only ever say "worse than the best of its own
        kind". It CANNOT say a map is bad in absolute terms, because if the
        whole population is bad the reference is bad too and every delta from
        it reads zero. Calling one of these a control is the single mistake
        that would make a 4-team scorecard dishonest, so the word is carried in
        the data and printed on every line rather than left to a writeup.

    A reference point therefore SUPPRESSES the absolute-form verdicts (the
    dead-floor indictment) and keeps the comparative ones, and every table it
    heads is stamped REFERENCE.
    """

    def __init__(self, data, kind):
        assert kind in ("control", "reference")
        self.data = data
        self.kind = kind
        self.map = data["map"]

    @property
    def word(self):
        return "control" if self.kind == "control" else "reference point"

    @property
    def caveat(self):
        return ("" if self.kind == "control" else
                f" — and {self.map} is a GENERATED map from the same "
                "population, a reference point, NOT a hand-authored control: "
                "if the population is bad this delta reads zero")


def report(datas, baseline=None):
    """One map's verdict, stated against `baseline` — see `Baseline` above."""
    control = baseline.data if baseline else None
    kind = baseline.kind if baseline else None
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
    # The engine's own end state, not a guess from the tick count. Three ways
    # an episode can stop and they are three different results: somebody
    # scored, somebody was wiped out, or nobody did anything for the whole
    # clock. Only the first says the objective works on this map.
    outcomes = data.get("episodeOutcomes", ["?"] * episodes)
    decided = sum(1 for o in outcomes if o == "capture")
    by_elim = sum(1 for o in outcomes if o == "elimination")
    timed_out = sum(1 for o in outcomes if o == "timeLimit")

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
            f"{dead_pct:.0%} dead floor, but NO CONTROL AND NO REFERENCE in "
            "this batch — refusing the verdict. There is no absolute bar here: "
            "the arena itself reads 24% dead at one long episode and 51% at "
            "three short ones, so only a delta from a named baseline at "
            "comparable exposure means anything.")
    elif is_control:
        pass          # the baseline is the yardstick; it is never the verdict
    else:
        ctrl_open = int((~np.array(control["wall"], bool)).sum())
        ctrl_dead = 1.0 - int(
            (np.array(control["occupancy"], float) > 0)
            [~np.array(control["wall"], bool)].sum()) / max(1, ctrl_open)
        ctrl_exposure = control["aliveTicks"] / max(1, ctrl_open)
        ratio = exposure / max(1e-9, ctrl_exposure)
        if not 0.7 <= ratio <= 1.4:
            flags.append(
                f"{dead_pct:.0%} dead floor vs the {baseline.word}'s "
                f"{ctrl_dead:.0%}, but exposure differs {ratio:.2f}x "
                f"({exposure:.1f} vs {ctrl_exposure:.1f} alive seat-ticks per "
                "open cell) — NOT comparable, re-run both at the same seats "
                "and tick budget")
        elif dead_pct > ctrl_dead + 0.12:
            # The ABSOLUTE form of this verdict ("decoration in a way the
            # arena's is not") is licensed by the control being hand-authored
            # and outside the population. A reference point is inside it, so
            # the same delta only ever supports the comparative form.
            flags.append(
                f"{dead_pct:.0%} of open floor never visited against the "
                f"control's {ctrl_dead:.0%} at {ratio:.2f}x the same exposure "
                "— this map's geometry is decoration in a way the arena's is "
                "not"
                if kind == "control" else
                f"{dead_pct:.0%} of open floor never visited against "
                f"{baseline.map}'s {ctrl_dead:.0%} at {ratio:.2f}x the same "
                f"exposure — worse than the best board of its own kind, which "
                "is NOT the same finding as worse than a known-good board"
                f"{baseline.caveat}")
        if biggest_dead * cell * cell > 60000 and 0.7 <= ratio <= 1.4:
            flags.append(
                f"one unvisited region of ~{biggest_dead * cell * cell:,}px² "
                "— a whole wing nobody played")
    ped = pedestal_reach(data)
    reached, homes_n, reach_ticks = ped["reached"], ped["homes"], ped["ticks"]
    # As a SHARE of alive time, not a raw count. The ring radius is a map
    # property that varies 60..91px across the maps measured here, and episode
    # length varies 2.7x, so a bare seat-tick count compares three things at
    # once. The share removes the clock and the seat count and leaves the one
    # thing being asked about: how much of its life the enemy spent on the
    # objective rather than somewhere else.
    reach_share = ped["share"]
    # AN UNAPPROACHED OBJECTIVE IS AN ABSOLUTE FAILURE, so this flag fires
    # without a baseline. Every other verdict in this file is stated as a delta
    # because none of them have an absolute bar — but zero is zero at any
    # exposure, on any board size, at any team count. A map that seats N teams
    # and only ever puts an enemy on some of its N objectives has not been
    # measured as unfair, it has been measured as PARTLY UNPLAYED.
    if ped["neverApproached"]:
        names = ", ".join(f"team {t}" for t in ped["neverApproached"])
        flags.append(
            f"{len(ped['neverApproached'])}/{homes_n} = "
            f"{len(ped['neverApproached']) / max(1, homes_n):.0%} of the "
            f"objectives were NEVER APPROACHED ({names}) across "
            f"{episodes} episode(s). Not 'hard to take' — not once entered. "
            "Static symmetry is a claim about geometry and cannot see this")
    elif homes_n > 2 and ped["attackPairs"] < ped["possibleAttackPairs"]:
        flags.append(
            f"every objective was approached, but only "
            f"{ped['attackPairs']}/{ped['possibleAttackPairs']} = "
            f"{ped['attackPairs'] / max(1, ped['possibleAttackPairs']):.0%} of "
            "the (attacker, target) pairs the rules allow ever happened — some "
            "teams can reach the objective and some pairings never meet on it")
    if homes_n >= 2 and reach_ticks > 0 and ped["pressureBalance"] < 0.80:
        share_txt = " ".join(f"t{s['team']} {s['share']:.3%}"
                             for s in ped["seats"])
        flags.append(
            f"enemy pressure is spread {ped['pressureBalance']:.2f} evenly over "
            f"the objectives (1.0 is even): {share_txt}. A rot90/mirror board "
            "scores FAIR STATICALLY; this is the same board measured on whether "
            "that fairness is REACHABLE, and the two have come apart")
    if data["steals"] == 0:
        # ZERO STEALS SPLITS INTO TWO OPPOSITE FINDINGS with opposite remedies,
        # and the reach number is the only thing that tells them apart. The
        # flag used to assert the first one unconditionally — it read "near 0
        # the objective was never approached" over a board where enemies had
        # in fact stood on the pedestals for 18.6% of alive time, which is the
        # precise opposite diagnosis. The split is anchored on the
        # hand-authored arena's own measured 0.533%: at or under roughly twice
        # that the objective was barely touched; far above it the pedestal was
        # standing room and the steal STILL never happened, which is a rules or
        # bot question before it is a map question.
        seen = f"{reached}/{homes_n} = {reached / max(1, homes_n):.0%}"
        if reach_share <= 0.01:
            flags.append(
                f"ZERO steals in {episodes} episode(s), and the objective was "
                f"barely approached: an enemy stood inside {seen} of the "
                f"pedestal rings for only {reach_share:.3%} of alive time "
                f"({reach_ticks:,} seat-ticks), against the arena's 0.533%. "
                "No conversion number from this map means anything — nobody "
                "got far enough for the touch to be tested")
        else:
            flags.append(
                f"ZERO steals in {episodes} episode(s) DESPITE the objective "
                f"being reached constantly: an enemy stood inside {seen} of "
                f"the pedestal rings for {reach_share:.3%} of alive time "
                f"({reach_ticks:,} seat-ticks), {reach_share / 0.00533:.0f}x "
                "the arena's 0.533%. They got there and did not take it, so "
                "this is a RULES or BOT question before it is a map question")
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
                f"{baseline.word}'s {ctrl_close:.0%} (within "
                f"{data.get('closeRangePx', 0)}px) — the teams meet less here. "
                "GunRange contact is 100% on every map at these sizes and "
                "cannot see this")
    if control is not None and control["map"] != name:
        if data["ticks"] / episodes < 0.6 * control["ticks"] / control["episodes"]:
            flags.append(
                f"these games ran {data['ticks'] // episodes}t against the "
                f"{baseline.word}'s {control['ticks'] // control['episodes']}t "
                "— a capture ENDS an episode, so dead space here is not "
                f"comparable to {baseline.map}'s")

    print(f"\n=== {name}  ({episodes} episode(s), {data['ticks']} ticks total)")
    # Rule: each episode's length and result, individually. A mean hides that a
    # capture ended the episode.
    ends = {"capture": "WON ON THE OBJECTIVE", "elimination": "won by wipeout",
            "timeLimit": "ran out the clock, nobody won",
            "unfinished": "replay ends mid-game"}
    for i, (t, c, s, o) in enumerate(zip(data["episodeTicks"],
                                         data["episodeCaptures"],
                                         data["episodeSteals"], outcomes)):
        print(f"    ep{i}: {t:>5}t, {s} steal(s) -> {c} capture(s), "
              f"{ends.get(o, o)}")
    role = ""
    if is_control:
        role = ("  [CONTROL, hand-authored — the yardstick, never the verdict]"
                if kind == "control" else
                "  [REFERENCE POINT, generated — NOT a hand-authored control; "
                "it can only say 'worse than the best of its own kind']")
    print(f"    dead space {dead_pct:.0%} of open floor "
          f"({visited}/{open_cells} cells visited; largest unvisited region "
          f"{biggest_dead * cell * cell:,}px²){role}")
    print(f"    exposure {exposure:.1f} alive seat-ticks per open cell "
          f"({data['aliveTicks']:,} seat-ticks over {open_cells:,} cells)")
    print(f"    {len(deaths)} deaths, spread {spread:.0f}px")
    print(f"    kills {kills}  balance {balance:.2f}  "
          f"pace {pace:.1f} kills/1000t  contact {fight_frac:.0%} in gun range "
          f"/ {close_frac:.0%} within {data.get('closeRangePx', 0)}px")
    # PER PEDESTAL, one line, because the aggregate above averages away the
    # only thing this measure exists to show. `-` means never approached.
    print(f"    per objective (ring {ped['ringPx']}px), enemy seat-time and "
          f"how many of the {ped['seats'][0]['possibleAttackers'] if ped['seats'] else 0} "
          "possible enemies came:")
    for s in ped["seats"]:
        mark = "NEVER APPROACHED" if not s["approached"] else (
            f"{s['ticks']:>7,}t {s['share']:>7.3%}  "
            f"{s['attackers']}/{s['possibleAttackers']} enemies")
        print(f"      team {s['team']} pedestal  {mark}")
    print(f"    pressure balance {ped['pressureBalance']:.2f} over "
          f"{homes_n} objectives (1.0 = even), attack pairs "
          f"{ped['attackPairs']}/{ped['possibleAttackPairs']} "
          f"{ped['attackPairs'] / max(1, ped['possibleAttackPairs']):.0%}")
    print(f"    objective: {data['steals']} steals -> {data['captures']} "
          f"captures ({data['capturesInZone']} verified in zone) = "
          f"{pct(conversion)} conversion, carrier in zone "
          f"{data['carrierInZoneTicks']}t ({zone_rate:.1f} per 1000t)")
    print(f"    how they ended: {decided}/{episodes} "
          f"{decided / episodes:.0%} on the objective, {by_elim}/{episodes} "
          f"{by_elim / episodes:.0%} by wipeout, {timed_out}/{episodes} "
          f"{timed_out / episodes:.0%} out of clock")
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
                isControl=is_control, baselineKind=kind,
                baselineMap=baseline.map if baseline else None,
                deaths=len(deaths), spread=spread,
                kills=kills, balanceEntropy=balance, pace=pace,
                fightTimeFrac=fight_frac, closeContactFrac=close_frac,
                measuredTicks=ticks, tickCapped=capped,
                steals=data["steals"], captures=data["captures"],
                capturesInZone=data["capturesInZone"],
                conversion=conversion, decidedFrac=decided / episodes,
                pedestalsReached=reached, pedestals=homes_n,
                pedestalEnemyTicks=reach_ticks,
                pedestalEnemyShare=reach_share,
                pedestalRingPx=ped["ringPx"],
                # The per-objective detail, kept in the JSON as well as the
                # table: an aggregate that lost this is what let a board with
                # two untouched pedestals pass as merely hard to score on.
                pedestalSeats=ped["seats"],
                pedestalNeverApproached=ped["neverApproached"],
                pedestalPressureBalance=ped["pressureBalance"],
                pedestalAttackPairs=ped["attackPairs"],
                pedestalPossibleAttackPairs=ped["possibleAttackPairs"],
                episodeOutcomes=outcomes, wonByCapture=decided,
                wonByElimination=by_elim, timedOut=timed_out,
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
    kind = next((r["baselineKind"] for r in rows if r["baselineKind"]), None)
    stamp = "REFERENCE" if kind == "reference" else "CONTROL"
    w = max(13, max(len(n) for n in names) + 2)

    def frac(n, d):
        return f"{n}/{d} {n / max(1, d) * 100:.0f}%"

    # Built before it is printed so the column width can fit the widest cell.
    # The episode-lengths row is several times wider than a percentage and a
    # width guessed from the headers alone silently ran the columns together.
    body = [
        ("teams", lambda r: r["teams"]),
        ("episodes", lambda r: r["episodes"]),
        # Episode LENGTHS, all of them, never a mean: an episode stops when it
        # is decided, so the spread IS the result and the average is an
        # artefact of how many games ended early.
        ("episode lengths", lambda r: " ".join(f"{t}t" for t in r["episodeTicks"])),
        ("won on the objective", lambda r: frac(r["wonByCapture"], r["episodes"])),
        ("won by wipeout", lambda r: frac(r["wonByElimination"], r["episodes"])),
        ("out of clock, no winner", lambda r: frac(r["timedOut"], r["episodes"])),
        None,
        ("open floor (10px cells)", lambda r: f"{r['openCells']:,}"),
        ("visited", lambda r: frac(r["visitedCells"], r["openCells"])),
        ("DEAD SPACE", lambda r: f"{r['deadPct'] * 100:.0f}%"),
        ("largest dead region", lambda r: f"{r['biggestDeadPx2']:,}px²"),
        ("exposure (seat-t/cell)", lambda r: f"{r['exposure']:.1f}"),
        None,
        ("objectives approached", lambda r: frac(r["pedestalsReached"],
                                                 r["pedestals"])),
        # The per-objective row is the whole point of the block. A board can
        # show 4/4 approached and still be one team's private corner; a board
        # can show 2/4 and be scored FAIR by every static metric there is.
        ("  each, % of alive time", lambda r: " ".join(
            f"{s['share']:.2%}" if s["approached"] else "NONE"
            for s in r["pedestalSeats"])),
        ("  each, enemies that came", lambda r: " ".join(
            f"{s['attackers']}/{s['possibleAttackers']}"
            for s in r["pedestalSeats"])),
        ("attack pairs realized", lambda r: frac(
            r["pedestalAttackPairs"], r["pedestalPossibleAttackPairs"])),
        ("pressure balance", lambda r: f"{r['pedestalPressureBalance']:.2f}"),
        ("enemy time at pedestal", lambda r:
         f"{r['pedestalEnemyTicks']:,} {r['pedestalEnemyShare']:.3%}"),
        ("pedestal ring radius", lambda r: f"{r['pedestalRingPx']}px"),
        ("steals", lambda r: r["steals"]),
        ("captures", lambda r: r["captures"]),
        ("CONVERSION grab->cap", lambda r: pct(r["conversion"])),
        ("carrier in zone /1000t", lambda r: f"{r['carrierInZonePer1000t']:.1f}"),
        None,
        ("deaths", lambda r: r["deaths"]),
        ("kills/1000t", lambda r: f"{r['pace']:.1f}"),
        ("contact, gun range", lambda r: f"{r['fightTimeFrac'] * 100:.0f}%"),
        ("contact, close", lambda r: f"{r['closeContactFrac'] * 100:.0f}%"),
        ("balance entropy", lambda r: f"{r['balanceEntropy']:.2f}"),
    ]
    cells = [(lab, [str(fn(by[n])) for n in names]) for lab, fn in
             (b for b in body if b)]
    w = max([len(n) + 3 for n in names] +
            [len(v) + 2 for _, vs in cells for v in vs])

    print("\n" + "=" * (28 + w * len(names)))
    # The header names the baseline it actually ran against. It used to say
    # "vs arena" unconditionally, which is a lie on any batch with no arena in
    # it — exactly the batch where the distinction matters most.
    print("ONE-PAGE COMPARISON — " + (
        f"generated vs {ctrl['map']}, A GENERATED REFERENCE POINT (no "
        "hand-authored map exists at this team count)"
        if kind == "reference" else
        f"generated vs {ctrl['map']}, the hand-authored control"
        if ctrl is not None else
        "no baseline in this batch") + ", per metric")
    if any(r["tickCapped"] for r in rows):
        # The capped pass exists to make DEAD SPACE comparable, and truncation
        # makes the steal/capture COUNTS below wrong: a capture at 4153t inside
        # an 1890t window is real and invisible here. The three "how it ended"
        # rows are safe — they read the engine's end state over the whole
        # episode, not the windowed count.
        print("  MEASURED OVER A CAPPED WINDOW ("
              f"{max(r['measuredTicks'] // max(1, r['episodes']) for r in rows)}"
              "t per episode). Dead space, contact and pace are comparable\n"
              "  here and only here. Steals, captures and conversion are "
              "TRUNCATED to the window — read those off the uncapped run.")
    print(f"  {'':<26}" + "".join(
        f"{n + ('*' if by[n]['isControl'] else ''):>{w}}" for n in names))
    print(f"  {'':<26}" + "".join(
        f"{stamp if by[n]['isControl'] else '':>{w}}" for n in names))
    idx = 0
    for entry in body:
        if entry is None:
            print("")
            continue
        lab, vals = cells[idx]
        idx += 1
        print(f"  {lab:<26}" + "".join(f"{v:>{w}}" for v in vals))

    print("")
    if ctrl is None:
        print("  NO CONTROL AND NO REFERENCE COLUMN. There is no hand-authored "
              "map at this team count, so every number above is readable only "
              "against the other generated maps — not against a known-good "
              "board. Name one of them with --reference to at least get a "
              "labelled within-population yardstick.")
        return
    if kind == "reference":
        # Printed HERE, above the deltas, because this is the line a reader
        # skips when they lift the table into a scorecard. The distinction
        # between a control and a reference point is not a caveat about the
        # number; it changes which conclusions the number can carry.
        print(f"  DELTA FROM THE REFERENCE POINT  (map - {ctrl['map']}; "
              "pp = percentage points)")
        print(f"  {ctrl['map']} IS A GENERATED MAP, NOT A HAND-AUTHORED "
              "CONTROL. It is drawn from the same population as everything")
        print("  beside it, so these deltas can say 'worse than the best of "
              "its own kind' and CANNOT say 'worse than a board")
        print("  we know plays'. If the whole population is bad, every delta "
              "here reads zero and the table looks healthy.")
    else:
        print(f"  DELTA FROM THE CONTROL  (generated - {ctrl['map']}, the "
              "hand-authored board; pp = percentage points)")
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
    paths = []
    want_reference = None
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--reference="):
            want_reference = a.split("=", 1)[1]
        elif a == "--reference" and i + 1 < len(argv):
            want_reference = argv[i + 1]
            i += 1
        else:
            paths.append(a)
        i += 1
    if not paths:
        raise SystemExit(__doc__)
    groups = {}
    for p in paths:
        d = json.loads(Path(p).read_text())
        groups.setdefault(d["map"], []).append(d)

    # THE BASELINE, and WHICH KIND — see `Baseline`. A hand-authored map always
    # wins if it is in the batch: it is the only yardstick that is outside the
    # population under test, and every absolute-form verdict in `report` is
    # licensed by that and by nothing else.
    #
    # A hand-authored map from the WRONG TEAM COUNT is not a control either —
    # four objectives and three enemies is a different game — so when several
    # are present the one whose home count matches the batch wins.
    merged = {m: merge(ds) for m, ds in groups.items()}
    authored = [m for m in merged
                if any(m == n or m.endswith("/" + n) for n in HAND_AUTHORED)]
    baseline = None
    if authored:
        played = [len(d.get("homes", [])) for m, d in merged.items()
                  if m not in authored]
        want_homes = max(set(played), key=played.count) if played else None
        match = [m for m in authored
                 if len(merged[m].get("homes", [])) == want_homes]
        pick = (match or authored)[0]
        baseline = Baseline(merged[pick], "control")
    if baseline is None and want_reference:
        # No hand-authored map at this team count. A NAMED generated map is a
        # strictly better yardstick than none — a delta from something in the
        # batch beats a delta from a number somebody remembers — but it is a
        # different KIND of yardstick and is stamped as one everywhere.
        if want_reference not in groups:
            raise SystemExit(
                f"--reference {want_reference} is not in this batch "
                f"(have: {', '.join(sorted(groups))}). The reference point has "
                "to be MEASURED in the same invocation; naming a map that was "
                "not played is how a remembered number gets in.")
        baseline = Baseline(merge(groups[want_reference]), "reference")
        print(f"NO HAND-AUTHORED CONTROL AT THIS TEAM COUNT. Using "
              f"{want_reference} as a labelled REFERENCE POINT: a generated "
              "map from the\npopulation under test, named as the yardstick. "
              "It supports 'worse than the best of its own kind' and NOT\n"
              "'worse than a board we know plays'. Do not call it a control.")
    if baseline is None:
        print("NO CONTROL IN THIS BATCH. Run the arena through the same "
              "episode count ('tools/map_eval play arena --episodes 3') and "
              "pass its evidence here, or name a --reference from the batch. "
              "A dynamic number without a baseline beside it has no scale.")

    out = {m: report(ds, baseline) for m, ds in sorted(groups.items())}
    comparison(list(out.values()))
    GALLERY.mkdir(exist_ok=True, parents=True)
    (GALLERY / "playtest.json").write_text(json.dumps(out, indent=1))
    print(f"\nwrote {GALLERY}/playtest.json + heat-<map>.png")


if __name__ == "__main__":
    main()
