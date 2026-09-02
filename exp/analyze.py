"""Summarise a battery: win rate with an exact CI, per-side split, per-episode rates."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from statistics import mean, stdev


def binom_ge(k: int, n: int, p: float) -> float:
    """P(X >= k) for X ~ Binomial(n, p), exact."""
    return sum(math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(k, n + 1))


def binom_le(k: int, n: int, p: float) -> float:
    """P(X <= k) for X ~ Binomial(n, p), exact."""
    return sum(math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(0, k + 1))


def _bisect(f, target: float, lo: float, hi: float) -> float:
    """Solve f(p) = target on [lo, hi] where f is monotone."""
    for _ in range(200):
        mid = (lo + hi) / 2
        if (f(mid) < target) == (f(lo) < target):
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def clopper_pearson(k: int, n: int, alpha: float = 0.05) -> tuple[float, float]:
    """Exact (Clopper-Pearson) binomial CI, by inverting the exact tails."""
    lo = 0.0 if k == 0 else _bisect(lambda p: binom_ge(k, n, p), alpha / 2, 0.0, 1.0)
    hi = 1.0 if k == n else _bisect(lambda p: binom_le(k, n, p), alpha / 2, 0.0, 1.0)
    return lo, hi


def binom_sf(k: int, n: int, p: float) -> float:
    """P(X >= k) for X ~ Binomial(n, p) -- exact, one-sided."""
    total = 0.0
    for i in range(k, n + 1):
        total += math.comb(n, i) * p**i * (1 - p) ** (n - i)
    return total


def rate(vals: list[float]) -> str:
    m = mean(vals)
    if len(vals) < 2:
        return f"{m:.3f}"
    se = stdev(vals) / math.sqrt(len(vals))
    return f"{m:.3f} +- {1.96 * se:.3f}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl", type=Path)
    ap.add_argument("--label-a", default="A")
    ap.add_argument("--label-b", default="B")
    args = ap.parse_args()

    rows = [json.loads(l) for l in args.jsonl.read_text().splitlines() if l.strip()]
    n = len(rows)
    a_wins = sum(1 for r in rows if r["a_won"])
    b_wins = sum(1 for r in rows if r["b_won"])
    draws = sum(1 for r in rows if r["draw"])
    lo, hi = clopper_pearson(a_wins, n)
    print(f"episodes            {n}   ({args.label_a} = A, {args.label_b} = B)")
    print(f"A wins              {a_wins}  ({a_wins / n:.3f}, 95% CI {lo:.3f}-{hi:.3f})")
    print(f"B wins / draws      {b_wins} / {draws}")
    print(f"one-sided P(X>={a_wins} | p=0.5)  {binom_sf(a_wins, n, 0.5):.4f}")
    for side in ("red", "blue"):
        sub = [r for r in rows if r["a_side"] == side]
        if not sub:
            continue
        w = sum(1 for r in sub if r["a_won"])
        slo, shi = clopper_pearson(w, len(sub))
        print(f"  A on {side:<4}          {w}/{len(sub)} = {w / len(sub):.3f} "
              f"(95% CI {slo:.3f}-{shi:.3f})")
    red_wins = sum(1 for r in rows
                   if (r["a_won"] and r["a_side"] == "red") or (r["b_won"] and r["a_side"] == "blue"))
    rlo, rhi = clopper_pearson(red_wins, n)
    print(f"red wins (side bias) {red_wins}/{n} = {red_wins / n:.3f} (95% CI {rlo:.3f}-{rhi:.3f})")
    print()
    for key, name in [("captures", "captures/ep"), ("kills", "kills/ep"),
                      ("teamkills", "teamkills/ep"), ("deaths", "deaths/ep")]:
        av = [r[f"a_{key}"] for r in rows]
        bv = [r[f"b_{key}"] for r in rows]
        dv = [a - b for a, b in zip(av, bv)]
        print(f"{name:<14} A {rate(av):<18} B {rate(bv):<18} A-B (paired) {rate(dv)}")
    fr = [r["frames"] for r in rows]
    sk = [r["skipped"] for r in rows]
    print(f"\nframes/ep      {rate(fr)}    skipped frames total {sum(sk)} "
          f"(episodes with any: {sum(1 for s in sk if s > 0)})")
    print(f"wall s/ep      {rate([r['wall_s'] for r in rows])}")


if __name__ == "__main__":
    main()
