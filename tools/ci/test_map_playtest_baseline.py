#!/usr/bin/env python3
"""Which map `tools/map_playtest.py` calls the CONTROL, and at which team count.

Run from anywhere: python3 tools/ci/test_map_playtest_baseline.py

This is the one decision in that script that changes what its output is ALLOWED
TO CLAIM. A control licenses absolute verdicts ("deader than a board we know
plays"); a reference point licenses only comparative ones. Two ways to get it
wrong, both of which produce a confident, wrong scorecard rather than an error:

  * calling a GENERATED map a control — the failure the `Baseline` class exists
    to prevent, and the reason `HAND_AUTHORED` is a closed tuple;
  * calling a hand-authored map from the WRONG TEAM COUNT a control — four
    objectives and three enemies is a different game from two and one, so
    `arena` heading a 4-team batch is not a yardstick.

The selection lived as four lines inside `main()` with no coverage until a
4-team control existed to break it, so it is pinned here.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location(
    "map_playtest", ROOT / "tools" / "map_playtest.py")
mpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mpt)


def evidence(name, homes):
    """The smallest evidence dict the selection path reads."""
    return {"map": name, "ticks": 100, "homes": [{"x": 0, "y": 0}] * homes}


def pick(batch):
    """The selection block from `main()`, over one batch of (name, homes)."""
    groups = {n: [evidence(n, h)] for n, h in batch}
    merged = {m: mpt.merge(ds) for m, ds in groups.items()}
    authored = [m for m in merged
                if any(m == n or m.endswith("/" + n) for n in mpt.HAND_AUTHORED)]
    if not authored:
        return None
    played = [len(d.get("homes", []))
              for m, d in merged.items() if m not in authored]
    want = max(set(played), key=played.count) if played else None
    match = [m for m in authored
             if len(merged[m].get("homes", [])) == want]
    return (match or authored)[0]


CASES = [
    ("a 2-team batch picks arena",
     [("arena", 2), ("gen:1", 2), ("gen:2", 2)], "arena"),
    ("a 4-team batch picks arena4",
     [("arena4", 4), ("gen:1", 4), ("gen:2", 4)], "arena4"),
    ("both present, 4-team population -> arena4",
     [("arena", 2), ("arena4", 4), ("gen:1", 4)], "arena4"),
    ("both present, 2-team population -> arena",
     [("arena", 2), ("arena4", 4), ("gen:1", 2)], "arena"),
    ("arena-large alone is still hand-authored",
     [("arena-large", 2), ("gen:1", 2)], "arena-large"),
    ("a path-prefixed name still resolves",
     [("out/arena4", 4), ("gen:1", 4)], "out/arena4"),
    # THE important one: no hand-authored map means NO control, and the caller
    # falls through to --reference, which stamps REFERENCE on every table.
    ("generated maps alone never yield a control",
     [("gen:1", 4), ("gen:2", 4), ("pool:3", 4)], None),
]


def main():
    failures = 0
    for label, batch, want in CASES:
        got = pick(batch)
        ok = got == want
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {label}: "
              f"got {got!r}, want {want!r}")

    # A generated name must never be listed as hand-authored, whatever else
    # changes about this file.
    for name in mpt.HAND_AUTHORED:
        if name.startswith("gen:") or name.startswith("pool:"):
            print(f"FAIL  HAND_AUTHORED contains the generated name {name!r}")
            failures += 1

    print("ALL PASS" if not failures else f"{failures} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
