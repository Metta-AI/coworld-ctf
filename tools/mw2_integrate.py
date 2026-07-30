#!/usr/bin/env python3
"""Splices the traced MW2 map snippets into src/ctf/sim.nim.

tools/mw2_trace.py authors each map as a standalone snippet at
/tmp/mw2map_<name>.nim (a `<Name>Obstacles` const block plus a `<name>CtfMap`
constructor). This replaces the v1 geometry in the real tree with those
snippets, in place, leaving no dead v1 layout behind.

Idempotent: run it after every re-trace. Verifies afterwards that no v1
`<Name>LeftObstacles` symbol survives, since a leftover const would compile
fine while silently being the abandoned layout.

Usage: python3 tools/mw2_integrate.py [map ...]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIM = ROOT / "src/ctf/sim.nim"
MAPS = ["rust", "terminal", "highrise", "favela", "afghan", "scrapyard"]


def splice(sim, name, snippet):
    cap = name.capitalize()
    const_m = re.search(r"(  ## " + cap + r" —.*?\n  " + cap +
                        r"Obstacles = \[\n.*?\n  \]\n)", snippet, re.S)
    proc_m = re.search(r"(proc " + name + r"CtfMap\(\): CtfMap =\n.*?\n"
                       r"  result\.validateMap\(\)\n)", snippet, re.S)
    if not const_m or not proc_m:
        raise SystemExit(f"{name}: snippet missing const block or ctor")

    # Replace the v1 const (comment lines + LeftObstacles list) in place.
    old_const = re.search(
        r"\n(?:  ## [^\n]*\n)*  " + cap + r"LeftObstacles = \[\n.*?\n  \]\n",
        sim, re.S)
    if old_const:
        sim = sim[:old_const.start()] + "\n" + const_m.group(1) + \
            sim[old_const.end():]
    else:
        # Already integrated once: swap the traced const for the new traced one.
        cur = re.search(
            r"\n(?:  ## [^\n]*\n)*  " + cap + r"Obstacles = \[\n.*?\n  \]\n",
            sim, re.S)
        if not cur:
            raise SystemExit(f"{name}: no const block found in sim.nim")
        sim = sim[:cur.start()] + "\n" + const_m.group(1) + sim[cur.end():]

    # Replace the constructor in place.
    old_proc = re.search(
        r"proc " + name + r"CtfMap\(\): CtfMap =\n.*?\n  result\.validateMap\(\)\n",
        sim, re.S)
    if not old_proc:
        raise SystemExit(f"{name}: no {name}CtfMap in sim.nim")
    sim = sim[:old_proc.start()] + proc_m.group(1) + sim[old_proc.end():]
    return sim


def main():
    names = sys.argv[1:] or MAPS
    sim = SIM.read_text()
    for name in names:
        snip = Path(f"/tmp/mw2map_{name}.nim")
        if not snip.exists():
            raise SystemExit(f"{name}: no snippet at {snip} — run mw2_trace.py")
        sim = splice(sim, name, snip.read_text())
        print(f"spliced {name}")
    SIM.write_text(sim)

    leftovers = [n for n in MAPS
                 if f"{n.capitalize()}LeftObstacles" in sim]
    if leftovers:
        raise SystemExit(f"v1 geometry still present: {leftovers}")
    print(f"integrated {len(names)} maps; no v1 LeftObstacles remain")


if __name__ == "__main__":
    main()
