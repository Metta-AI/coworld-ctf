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


def mask_from(shapes):
    """Rasterizes an authored structure list into a wall mask."""
    m = np.zeros((MAP_H, MAP_W), bool)
    for _, x, y, w, h in shapes:
        x0, y0 = max(0, int(x)), max(0, int(y))
        m[y0:int(y + h), x0:int(x + w)] = True
    return m


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
