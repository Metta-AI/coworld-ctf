#!/usr/bin/env python3
"""mapgen_play_gate — the earn-the-switch meta-gate: does a STATIC score
predict how a map actually PLAYS, and do a BR map's spawns actually get a
fair game? Pure stdlib; consumes tools/br_outcome_probe.nim rows and any
static-score TSV.

WHY THIS EXISTS (technique ported from the dead mapgen epic's
score_play_corr.py; reimplemented clean, same statistical spine):

* RANK, NOT LINEAR. A static score is a bounded hand-weighted composite; only
  its ORDERING is meaningful. Spearman is the honest test of "higher score
  ranks better play".
* THE INTERVAL IS THE RESULT. A bare rho over a small n is indistinguishable
  from noise; every coefficient here carries n and a percentile bootstrap CI.
  The resampling unit is the INDEPENDENT unit (maps for score-vs-play,
  episodes for ring bias) — resampling the dependent unit understates the
  interval.
* TIE-AVERAGED RANKS. A bootstrap resample duplicates units by construction;
  argsort-of-argsort breaks those ties arbitrarily and inflates |rho|.
  rankdata averages them, which is what Spearman is defined on.
* SPLIT-HALF RELIABILITY separates "the score does not predict play" from
  "the play measurement is too noisy to tell": an observed correlation is
  bounded above by sqrt(reliability), so low reliability makes a null
  uninformative rather than a finding. Spearman-Brown steps the half-length
  reliability up to the full episode count.
* PAIRED EPISODE SEEDS. Play every map on the SAME episode-seed list so
  cross-map differences cannot be one map drawing luckier seeds. This gate
  checks and reports seed pairing when seeds are present in the input.
* THE PRECEDENT: two sibling branches of the dead epic ran this exact
  comparison and the shipped static score FAILED it (rho ~ +0.109, CI
  crossing zero) — "no weighting of these bands ranks play". Any static
  score must EARN authority over map selection here before it is trusted.

BR GATES (from br_outcome_probe.nim rows; all budget-parameterized):
* WIN-SHARE FLOOR: worst spawn group's win share vs uniform 1/16 = 0.0625.
  RE-DERIVED for 16 groups — the old 2-team 0.140 bar does not transfer.
  With no stored bar, the gate reports the exact one-sided binomial
  P(wins <= k | N, 1/16) per group; a group is FLAGGED when that p < 0.05.
  Detecting a never-winning group needs N >= 47 episodes ((15/16)^47 < .05);
  the gate prints DEMONSTRATION, NOT CERTIFICATION below that floor.
* CONTESTED-FINISH RATE: fraction of episodes whose FINAL elimination was a
  combat kill (vs zone attrition / timeout). No stored bar; report with a
  Wilson 95% interval.
* RING-BIAS GATE: does distance from the episode's drawn zone center predict
  a group's placement? Per-episode Spearman(distToZoneCenter, placement)
  across the 16 groups, mean rho with a bootstrap CI over EPISODES. A fair
  closing zone has a CI containing 0; placements converge ~16x faster than
  win bits because every episode yields a full ranking. Map-center distance
  is reported alongside to separate "zone bias" from "center bias".

Usage:
  mapgen_play_gate.py br   --rows rows.jsonl [--boot 4000]
  mapgen_play_gate.py corr --tsv data.tsv --unit map --score staticScore \
                           --outcome winRate [--per-episode outcomes]
  mapgen_play_gate.py --selftest
"""

import argparse
import json
import math
import random
import sys

# --------------------------------------------------------------------------
# stats spine (stdlib only)
# --------------------------------------------------------------------------

def rankdata(xs):
    """Average-tie ranks, 1-based (what Spearman is defined on)."""
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    sxx = sum((a - mx) ** 2 for a in xs)
    syy = sum((b - my) ** 2 for b in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def spearman(xs, ys):
    return pearson(rankdata(xs), rankdata(ys))


def boot_ci(xs, ys, iters=4000, seed=20260831, stat=spearman):
    """Percentile bootstrap CI over the rows of (xs, ys) — call it with the
    INDEPENDENT unit as the row. Tie handling comes free: stat re-ranks each
    resample, and rankdata averages the duplicates a resample creates."""
    n = len(xs)
    rng = random.Random(seed)
    vals = []
    for _ in range(iters):
        idx = [rng.randrange(n) for _ in range(n)]
        r = stat([xs[i] for i in idx], [ys[i] for i in idx])
        if r is not None:
            vals.append(r)
    if len(vals) < 100:
        return None, None
    vals.sort()
    lo = vals[int(0.025 * (len(vals) - 1))]
    hi = vals[int(0.975 * (len(vals) - 1))]
    return lo, hi


def boot_ci_scalar(rows, iters=4000, seed=20260831):
    """Percentile bootstrap CI of the MEAN of scalar rows."""
    n = len(rows)
    if n == 0:
        return None, None
    rng = random.Random(seed)
    vals = []
    for _ in range(iters):
        s = sum(rows[rng.randrange(n)] for _ in range(n))
        vals.append(s / n)
    vals.sort()
    return (vals[int(0.025 * (len(vals) - 1))],
            vals[int(0.975 * (len(vals) - 1))])


def split_half(per_unit_episodes):
    """Split-half reliability + Spearman-Brown step-up.

    per_unit_episodes: list (one per unit) of per-episode outcome lists.
    Splits each unit's episodes odd/even, correlates the halves ACROSS
    units, then steps the half-length reliability up to full length (k=2).
    """
    a, b = [], []
    for per in per_unit_episodes:
        if per is None or len(per) < 4:
            return None, None, 0
        h1 = per[0::2]
        h2 = per[1::2]
        a.append(sum(h1) / len(h1))
        b.append(sum(h2) / len(h2))
    if len(a) < 4 or len(set(a)) < 3 or len(set(b)) < 3:
        return None, None, 0
    rh = spearman(a, b)
    if rh is None or rh != rh:
        return None, None, 0
    full = (2 * rh) / (1 + rh) if rh > -1 else 0.0
    return rh, max(0.0, min(1.0, full)), len(a)


def binom_cdf(k, n, p):
    """P(X <= k) for X ~ Binomial(n, p). Exact, log-space stable."""
    total = 0.0
    for i in range(0, k + 1):
        logc = (math.lgamma(n + 1) - math.lgamma(i + 1)
                - math.lgamma(n - i + 1))
        total += math.exp(logc + i * math.log(p) + (n - i) * math.log(1 - p))
    return min(1.0, total)


def wilson(k, n, z=1.96):
    """Wilson 95% interval for a proportion."""
    if n == 0:
        return None, None
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return max(0.0, center - half), min(1.0, center + half)


# --------------------------------------------------------------------------
# br: the three BR gates
# --------------------------------------------------------------------------

def cmd_br(args):
    rows = []
    with open(args.rows) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if args.map:
        rows = [r for r in rows if r.get("map") == args.map]
    if not rows:
        sys.exit("no episode rows" + (f" for map {args.map}" if args.map else ""))
    maps = sorted({r.get("map", "?") for r in rows})
    n = len(rows)
    finished = [r for r in rows if r.get("finished")]
    seeds = [r.get("seed") for r in rows]
    print(f"BR PLAY GATES  map(s)={','.join(maps)}  episodes={n} "
          f"({len(finished)} finished, {n - len(finished)} not)")
    if len(set(seeds)) != len(seeds):
        print(f"  WARNING: duplicate episode seeds {sorted(seeds)} — paired-"
              "seed discipline expects distinct seeds per episode of one map")

    groups = sorted({g["group"] for r in rows for g in r["groups"]})
    ngroups = len(groups)
    uniform = 1.0 / ngroups if ngroups else 0.0

    # --- gate 1: win-share floor -----------------------------------------
    wins = {g: 0 for g in groups}
    decided = 0
    for r in finished:
        if r.get("isDraw") or r.get("winnerGroup", -1) < 0:
            continue
        decided += 1
        wins[r["winnerGroup"]] += 1
    print(f"\nWIN-SHARE FLOOR  ({decided} decided episodes, {ngroups} spawn "
          f"groups, uniform = {uniform:.4f})")
    print("  NOTE: bar RE-DERIVED for 16 groups from uniform 1/16; the old "
          "2-team 0.140 bar does not transfer.")
    if decided:
        worst = min(groups, key=lambda g: wins[g])
        flagged = []
        for g in groups:
            p = binom_cdf(wins[g], decided, uniform)
            if p < 0.05:
                flagged.append((g, wins[g], p))
        shares = ", ".join(
            f"g{g}:{wins[g]}/{decided}" for g in groups if wins[g] > 0)
        print(f"  wins by group: {shares or '(none decided)'}")
        print(f"  worst group g{worst}: {wins[worst]}/{decided} "
              f"(share {wins[worst] / decided:.3f}); exact one-sided "
              f"P(<= {wins[worst]} | uniform) = "
              f"{binom_cdf(wins[worst], decided, uniform):.3f}")
        for g, k, p in flagged:
            print(f"  FLAGGED g{g}: {k}/{decided} wins, p={p:.4f} < 0.05")
        if not flagged:
            print("  no group significantly below uniform at this budget")
    floor_n = math.ceil(math.log(0.05) / math.log(1 - uniform))
    if decided < floor_n:
        print(f"  DEMONSTRATION, NOT CERTIFICATION: {decided} episodes cannot "
              f"resolve even a never-winning group (needs N >= {floor_n}; "
              "a 2x-favored group needs low hundreds).")

    # --- gate 2: contested-finish rate -----------------------------------
    contested = sum(1 for r in finished if r.get("contested"))
    timeouts = sum(1 for r in finished if r.get("byTimeout"))
    lo, hi = wilson(contested, len(finished))
    print(f"\nCONTESTED-FINISH RATE  {contested}/{len(finished)} "
          f"({(contested / len(finished)):.2f}) Wilson95 "
          f"[{lo:.2f}, {hi:.2f}]" if finished else "\nCONTESTED-FINISH: n/a")
    if finished:
        print(f"  final elim by zone/attrition: "
              f"{len(finished) - contested - timeouts}/{len(finished)}; "
              f"timeouts: {timeouts}/{len(finished)}")

    # --- gate 3: ring bias -------------------------------------------------
    def dist(ax, ay, bx, by):
        return math.hypot(ax - bx, ay - by)

    rho_zone, rho_center = [], []
    for r in finished:
        ds_zone, ds_center, places = [], [], []
        for g in r["groups"]:
            if g["group"] < 0 or g["spawnX"] < 0:
                continue
            ds_zone.append(dist(g["spawnX"], g["spawnY"],
                                r["zoneCenterX"], r["zoneCenterY"]))
            ds_center.append(dist(g["spawnX"], g["spawnY"],
                                  r["mapCenterX"], r["mapCenterY"]))
            places.append(g["placement"])
        if len(places) >= 4:
            rz = spearman(ds_zone, places)
            rc = spearman(ds_center, places)
            if rz is not None:
                rho_zone.append(rz)
            if rc is not None:
                rho_center.append(rc)
    print(f"\nRING-BIAS GATE  (per-episode Spearman of spawn distance vs "
          f"placement rank; placement 1 = winner, so rho > 0 means far "
          f"spawns FINISH WORSE)")
    for name, rhos in [("zoneCenter", rho_zone), ("mapCenter", rho_center)]:
        if not rhos:
            print(f"  {name}: n/a")
            continue
        lo, hi = boot_ci_scalar(rhos, iters=args.boot)
        mean = sum(rhos) / len(rhos)
        if len(rhos) < 4:
            verdict = "n too small for any verdict"
        elif lo > 0 or hi < 0:
            verdict = "BIAS (CI excludes 0)"
        else:
            verdict = "no resolvable bias (CI spans 0)"
        print(f"  dist-to-{name:<11} mean rho {mean:+.3f}  "
              f"CI95 [{lo:+.3f}, {hi:+.3f}]  n={len(rhos)} episodes  "
              f"-> {verdict}")
    if len(rho_zone) < 8:
        print("  DEMONSTRATION, NOT CERTIFICATION: CI over "
              f"{len(rho_zone)} episodes is wide by construction.")


# --------------------------------------------------------------------------
# corr: static score vs played outcome (the meta-gate proper)
# --------------------------------------------------------------------------

def cmd_corr(args):
    units, scores, outcomes, per_ep = [], [], [], []
    with open(args.tsv) as f:
        header = f.readline().rstrip("\n").split("\t")
        col = {name: i for i, name in enumerate(header)}
        for want in (args.unit, args.score, args.outcome):
            if want not in col:
                sys.exit(f"column '{want}' not in {header}")
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < len(header):
                continue
            units.append(parts[col[args.unit]])
            scores.append(float(parts[col[args.score]]))
            outcomes.append(float(parts[col[args.outcome]]))
            if args.per_episode and args.per_episode in col:
                cell = parts[col[args.per_episode]]
                per_ep.append([float(v) for v in cell.split(";") if v]
                              if cell else None)
    n = len(units)
    if n < 4:
        sys.exit(f"need >= 4 units, got {n}")
    rho = spearman(scores, outcomes)
    lo, hi = boot_ci(scores, outcomes, iters=args.boot)
    print(f"META-GATE  {args.score} vs {args.outcome}  n={n} {args.unit}s")
    print(f"  Spearman rho {rho:+.3f}  bootstrap CI95 [{lo:+.3f}, {hi:+.3f}] "
          f"(resampling unit: the {args.unit})")
    if lo is not None and lo > 0:
        print("  -> the static score EARNS rank authority at this n "
              "(CI excludes 0, positive)")
    elif hi is not None and hi < 0:
        print("  -> the static score ranks play BACKWARDS at this n")
    else:
        print("  -> NOT EARNED: CI spans 0 — the score must not select maps "
              "on its own authority (the dead epic's stick-reweight verdict: "
              "rho +0.109, CI crossing zero, 'no weighting of these bands "
              "ranks play')")
    null_sd = 1.0 / math.sqrt(n - 1)
    print(f"  null SD of rho at n={n} is ~{null_sd:.2f}: |rho| below "
          f"~{2 * null_sd:.2f} is unresolvable — buy more UNITS, not more "
          "episodes (the resampling unit is what buys narrower intervals)")
    if per_ep and all(p is not None for p in per_ep):
        rh, full, k = split_half(per_ep)
        if rh is not None:
            print(f"  split-half reliability {rh:+.3f}; Spearman-Brown "
                  f"full-length {full:.3f} (n={k}); observed rho is bounded "
                  f"by ~sqrt(reliability) = {math.sqrt(full):.2f} — a null "
                  "under a low bound is uninformative, not a finding")


# --------------------------------------------------------------------------
# selftest
# --------------------------------------------------------------------------

def selftest():
    eps = 1e-9
    # rankdata: ties averaged, 1-based
    assert rankdata([10, 20, 20, 30]) == [1.0, 2.5, 2.5, 4.0]
    assert rankdata([3, 1, 2]) == [3.0, 1.0, 2.0]
    # spearman: perfect monotone = +1 / -1; ties handled
    assert abs(spearman([1, 2, 3, 4], [10, 20, 30, 40]) - 1.0) < eps
    assert abs(spearman([1, 2, 3, 4], [9, 7, 5, 1]) + 1.0) < eps
    r = spearman([1, 2, 3, 4, 5, 6], [2, 1, 4, 3, 6, 5])
    assert 0.7 < r < 1.0, r
    # constant input has no rank correlation
    assert spearman([1, 1, 1, 1], [1, 2, 3, 4]) is None
    # bootstrap CI: tight positive relation -> CI above 0; noise -> spans 0
    rng = random.Random(7)
    xs = list(range(24))
    ys = [x + rng.random() * 2 for x in xs]
    lo, hi = boot_ci(xs, ys, iters=800, seed=1)
    assert lo > 0.8, (lo, hi)
    ys_noise = [rng.random() for _ in xs]
    lo2, hi2 = boot_ci(xs, ys_noise, iters=800, seed=2)
    assert lo2 < 0 < hi2, (lo2, hi2)
    # binomial: never-winning group needs N >= 47 at 1/16
    assert binom_cdf(0, 46, 1 / 16) >= 0.05
    assert binom_cdf(0, 47, 1 / 16) < 0.05
    assert abs(binom_cdf(5, 10, 0.5) - 0.623046875) < 1e-9
    # wilson interval sanity
    lo3, hi3 = wilson(5, 10)
    assert 0.2 < lo3 < 0.5 < hi3 < 0.8
    # split-half: reproducible outcome -> high reliability
    per = [[v, v, v, v] for v in [1.0, 2.0, 3.0, 4.0, 5.0]]
    rh, full, k = split_half(per)
    assert k == 5 and rh > 0.99 and full > 0.99
    # ring bias construction: placements tracking distance -> rho = +1
    ds = [100.0, 200.0, 300.0, 400.0]
    places = [1, 2, 3, 4]
    assert abs(spearman(ds, places) - 1.0) < eps
    # ...and anti-tracking -> -1
    assert abs(spearman(ds, places[::-1]) + 1.0) < eps
    print("selftest OK (14 assertions)")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    br = sub.add_parser("br", help="BR play gates from br_outcome_probe rows")
    br.add_argument("--rows", required=True)
    br.add_argument("--map", default=None)
    br.add_argument("--boot", type=int, default=4000)
    br.set_defaults(fn=cmd_br)
    corr = sub.add_parser("corr", help="static score vs played outcome")
    corr.add_argument("--tsv", required=True)
    corr.add_argument("--unit", default="map")
    corr.add_argument("--score", required=True)
    corr.add_argument("--outcome", required=True)
    corr.add_argument("--per-episode", default=None)
    corr.add_argument("--boot", type=int, default=4000)
    corr.set_defaults(fn=cmd_corr)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
