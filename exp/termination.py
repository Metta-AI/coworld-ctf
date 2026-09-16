"""How do episodes TERMINATE? Capture vs elimination, and how far the attrition
race had run when they did.

The claim under test: "the capture is the finisher on an attrition race that is
~93% complete". Measured on the repo baseline. This script exists so the same
breakdown can be run against ANY battery -- in particular the champion-defines
build, which resolves 2.5x later and by capture more often, and is the build
the league actually runs. If the claim does not survive there, it was an
arena-and-baseline artifact and must not be generalised.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from analyze import clopper_pearson  # noqa: E402

FULL_WIPE = 24  # 3 lives x 8 seats


def load(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def loser_deaths(r: dict) -> int:
    return r["b_deaths"] if r["a_won"] else r["a_deaths"]


def winner_deaths(r: dict) -> int:
    return r["a_deaths"] if r["a_won"] else r["b_deaths"]


def report(name: str, rows: list[dict]) -> None:
    dec = [r for r in rows if not r["draw"]]
    cap = [r for r in dec if r["a_captures"] + r["b_captures"] > 0]
    eli = [r for r in dec if r["a_captures"] + r["b_captures"] == 0]
    lo, hi = clopper_pearson(len(cap), len(dec))
    print(f"\n=== {name}  ({len(dec)} decisive, {len(rows) - len(dec)} draws)")
    print(f"  capture-ending      {len(cap):>3} = {len(cap)/len(dec):.3f} "
          f"[{lo:.3f},{hi:.3f}]")
    print(f"  elimination-ending  {len(eli):>3} = {len(eli)/len(dec):.3f}")
    print(f"  frames/ep           {statistics.mean(r['frames'] for r in dec):.0f}")
    print(f"  combined captures/ep {statistics.mean(r['a_captures']+r['b_captures'] for r in dec):.3f}")
    for label, rs in (("capture-ending", cap), ("elimination-ending", eli)):
        if not rs:
            continue
        v = [loser_deaths(r) for r in rs]
        w = [winner_deaths(r) for r in rs]
        print(f"  loser deaths, {label:<19} mean {statistics.mean(v):5.1f}/{FULL_WIPE}"
              f"  median {statistics.median(v):4.1f}  min {min(v):2d}  max {max(v):2d}"
              f"   | winner mean {statistics.mean(w):5.1f}")
    if cap:
        v = [loser_deaths(r) for r in cap]
        for thr in (23, 22, 21, 20, 18, 15):
            k = sum(1 for x in v if x >= thr)
            print(f"    captures landing with the loser already at >= {thr}/24: "
                  f"{k:>3}/{len(v)} = {k/len(v):.3f}")
    allv = [loser_deaths(r) for r in dec]
    below = sum(1 for x in allv if x < 15)
    print(f"  episodes resolved with the loser BELOW 15/24 deaths: {below}/{len(dec)}")
    print(f"  loser deaths overall: min {min(allv)}  p10 {sorted(allv)[len(allv)//10]}"
          f"  median {statistics.median(allv)}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        p = Path(arg)
        report(p.parent.name if p.name == "episodes.jsonl" else p.name, load(p))
