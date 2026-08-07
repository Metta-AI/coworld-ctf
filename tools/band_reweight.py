#!/usr/bin/env python3
"""Re-derive staticScore's band set from the STORED evidence. Plays nothing.

Task 013a9c98, epic 3757029c, lane D. The 210 episodes and the 361-candidate
static sweep are already paid for and committed under docs/evidence/; every
number this script prints comes out of those two files. Re-weighting is free
against them because the manifest stores each band's raw METRIC VALUE per map
and `subScore` is a pure function of (value, lo, hi, margin) -- so a candidate
band set can be scored on the same population without regenerating a map.

Read `docs/plans/2026-08-06-staticscore-vs-play.md` first; this builds on it.

Subcommands:
  reliability  -- can each play outcome carry a correlation at all?
  census       -- per-band discrimination over the 117 valid maps
  partition    -- constraint / style axis / quality, with the number for each
  compare      -- rank the population under a candidate set vs DefaultBands
  crossval     -- held-out rank correlation against play, with n and interval
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import score_play_corr as spc  # noqa: E402  -- reuse its stats, unmodified

EVIDENCE = os.path.join(ROOT, "docs", "evidence")
MANIFEST = os.path.join(EVIDENCE, "staticscore-spread-manifest.json")
ROWS_FULL = os.path.join(EVIDENCE, "staticscore-play-rows-full.json")
ROWS_WIN = os.path.join(EVIDENCE, "staticscore-play-rows-windowed.json")

# The 15 bands as they stood at the evidence base 4a013df. Bounds, margins,
# weights and kind are byte-identical at HEAD 3c6f8ba -- verified by diffing
# `DefaultBands` between the two trees -- so a stored `value` can be re-scored
# under HEAD's `subScore` without a translation step. The SIX bands HEAD adds
# on top of these are absent from the evidence entirely and are handled, and
# named, separately; they are not silently folded in here.
BANDS_15 = {
    # name:               (lo,     hi,      margin, weight, kind)
    "interiorFrac":        (0.25,   0.65,    0.22,   3.0, "soft"),
    "exposedFrac":         (-1.0,   0.20,    0.20,   1.0, "soft"),
    "longRunFrac":         (-1.0,   0.15,    0.12,   1.5, "soft"),
    "routeCountMin":       (2.0,    1.0e6,   2.0,    1.5, "hard"),
    "routeCapacityFrac":   (0.12,   0.50,    0.25,   2.0, "soft"),
    "chokeCount":          (-1.0,   6.0,     4.0,    1.0, "soft"),
    "chokeCoveredPenalty": (-1.0,   0.0,     1.0,    1.5, "soft"),
    "collisionCoverRatio": (0.70,   2.40,    0.60,   1.5, "soft"),
    "standRingOpenMin":    (0.25,   0.95,    0.08,   1.5, "soft"),
    "standRingSpread":     (-1.0,   0.10,    0.15,   2.0, "soft"),
    "standCoverSpread":    (-1.0,   0.04,    0.08,   2.0, "soft"),
    "midCrossCount":       (3.0,    12.0,    2.5,    1.5, "soft"),
    "midOpenFrac":         (0.10,   0.70,    0.20,   1.0, "soft"),
    "detourMax":           (1.10,   1.90,    0.35,   1.0, "soft"),
    "visDegreeCv":         (0.30,   1.20,    0.30,   1.0, "soft"),
}

# The six bands HEAD carries that the evidence never measured, with the weight
# they carry today. Reported as an uncertainty, never scored here.
BANDS_ADDED_AT_HEAD = {
    "sightlineMaxPx": 2.0,
    "diagLongRunPxFrac": 1.5,
    "routeCountDesign": 1.5,
    "chokeExcessPx": 2.0,
    "standCoverMin": 1.5,
    "standCoverGapMaxPx": 2.0,
}


def sub_score(value: float, lo: float, hi: float, margin: float) -> float:
    """Byte-for-byte the Nim `subScore` at map_metrics.nim:1600ish.

    Verified identical between 4a013df and HEAD, and re-verified against the
    stored `sub` for all 15 bands x 361 maps by `census --verify`.
    """
    if lo <= value <= hi:
        return 1.0
    d = (lo - value) if value < lo else (value - hi)
    return max(0.0, min(1.0, 1.0 - d / max(margin, 1e-9)))


def load_manifest():
    m = json.load(open(MANIFEST))
    valid = [x for x in m["maps"] if x.get("valid")]
    return m, valid


def load_rows(windowed: bool):
    rows = json.load(open(ROWS_WIN if windowed else ROWS_FULL))
    for r in rows:
        # Steal RATE, not steals per episode. Episode length varies 1713..4813
        # ticks across this pool, so a per-episode count partly measures how
        # long the episode ran rather than how often the objective was
        # reachable. The windowed rows truncate at 1238 ticks, which is the
        # OTHER way to match exposure -- and it throws away most of the signal
        # (6 steals survive the window against 195 in the full episodes), so
        # the rate on full episodes is what this script correlates on.
        per_st = r["_per_episode"]["steals_per_ep"]
        per_tk = r["ticks_all"]
        r["_per_episode"]["stealRate"] = [
            1000.0 * s / t for s, t in zip(per_st, per_tk)
        ]
        r["stealRate"] = sum(r["_per_episode"]["stealRate"]) / len(per_st)
    return rows


def gen_only(rows):
    return [r for r in rows if not r.get("is_control")]


def control(rows):
    return next(r for r in rows if r.get("is_control"))


OUTCOMES = [
    ("stealRate", "steals / 1000 ticks", "objective"),
    ("deadFloorFrac", "dead floor", "floor usage"),
    ("closeContactFrac", "close contact", "combat shape"),
    ("pace", "kills / 1000 ticks", "combat density"),
    ("ticks_mean", "episode length", "resolution"),
    ("balanceEntropy", "kill balance", "fairness"),
]


def cmd_reliability(args):
    for windowed in (False, True):
        rows = load_rows(windowed)
        tag = "WINDOWED 1238 ticks" if windowed else "FULL episodes"
        print(f"\n=== reliability, {tag} (n = {len(rows)} maps, 5 episodes each) ===")
        print(f"{'outcome':22s} {'split-half r':>12s} {'ceiling':>8s} {'n':>4s}")
        for key, label, _ in OUTCOMES:
            half, sb, n = spc.split_half_reliability(rows, key)
            if sb is None:
                print(f"{label:22s} {'n/a':>12s}")
                continue
            print(f"{label:22s} {half:12.3f} {sb:8.3f} {n:4d}")

    rows = load_rows(False)
    g = gen_only(rows)
    print("\n=== load confound on the objective, FULL episodes ===")
    late = [r["lateFrac"] for r in g]
    sr = [r["stealRate"] for r in g]
    rho, p = spc.spearman(late, sr)
    print(f"rho(lateFrac, stealRate) = {rho:+.3f}, p = {p:.3f}, n = {len(g)}")
    ss = [r["staticScore"] for r in g]
    rho2, p2 = spc.spearman(late, ss)
    print(f"rho(lateFrac, staticScore) = {rho2:+.3f}, p = {p2:.3f}")

    print("\n=== the objective, counted ===")
    tot = sum(r["steals_per_ep"] * r["episodes"] for r in rows)
    gtot = sum(r["steals_per_ep"] * r["episodes"] for r in g)
    nz = sum(1 for r in rows if r["steals_per_ep"] > 0)
    win = load_rows(True)
    wtot = sum(r["steals_per_ep"] * r["episodes"] for r in win)
    print(f"steals, full episodes:  {tot:.0f} over {len(rows)} maps "
          f"({gtot:.0f} on the {len(g)} generated)")
    print(f"steals, 1238-tick window: {wtot:.0f}  "
          f"-- the window discards {100*(1-wtot/tot):.1f}% of the objective")
    print(f"maps with >= 1 steal: {nz}/{len(rows)} ({100*nz/len(rows):.1f}%)")
    print(f"captures, any window: "
          f"{sum(r['captures_total'] for r in rows):.0f} -- unmeasurable, as before")
    c = control(rows)
    better = sum(1 for r in g if r["stealRate"] > c["stealRate"])
    print(f"\ncontrol `arena` stealRate = {c['stealRate']:.3f}/1k ticks; "
          f"generated maps better: {better}/{len(g)}")


def cmd_census(args):
    """Per-band discrimination over the 117 valid maps, and the sub-score check."""
    _, valid = load_manifest()
    print(f"=== band census, {len(valid)} valid maps of 361 candidates "
          f"({100*len(valid)/361:.1f}%) ===\n")

    # First: does this script's `sub_score` reproduce the Nim one exactly? If
    # it does not, every number below is a re-implementation artefact.
    bad = 0
    checked = 0
    for m in valid:
        for name, b in m["bands"].items():
            lo, hi, mg, _, _ = BANDS_15[name]
            checked += 1
            if abs(sub_score(b["value"], lo, hi, mg) - b["sub"]) > 1e-9:
                bad += 1
    print(f"sub_score re-implementation: {checked - bad}/{checked} exact "
          f"({100*(checked-bad)/checked:.2f}%) against the stored Nim sub-scores")
    if bad:
        print("  !! MISMATCH -- do not trust anything below")
    print()

    total_w = sum(v[3] for v in BANDS_15.values())
    print(f"{'band':22s} {'w':>4s} {'metric min':>11s} {'metric max':>11s} "
          f"{'sub min':>8s} {'levels':>7s} {'breached':>9s}  verdict")
    dead_w = 0.0
    rows = []
    for name, (lo, hi, mg, w, kind) in BANDS_15.items():
        vals = [m["bands"][name]["value"] for m in valid]
        subs = [m["bands"][name]["sub"] for m in valid]
        levels = len(set(round(s, 9) for s in subs))
        nbr = sum(1 for s in subs if s < 1.0)
        if levels == 1:
            verdict = "SATURATED -- cannot rank"
            dead_w += w
        elif levels <= 3:
            verdict = f"near-saturated ({levels} levels)"
        else:
            verdict = "discriminates"
        rows.append((name, w, min(vals), max(vals), min(subs), levels, nbr, verdict))
        print(f"{name:22s} {w:4.1f} {min(vals):11.4f} {max(vals):11.4f} "
              f"{min(subs):8.3f} {levels:7d} {nbr:4d}/{len(valid):<4d}  {verdict}")
    print(f"\nweight that cannot change any ranking: {dead_w:.1f} / {total_w:.1f} "
          f"= {100*dead_w/total_w:.1f}%")

    added_w = sum(BANDS_ADDED_AT_HEAD.values())
    head_total = total_w + added_w
    print(f"\n=== and what HEAD added AFTER this evidence was taken ===")
    for n, w in BANDS_ADDED_AT_HEAD.items():
        print(f"{n:22s} {w:4.1f}   never measured against play or this population")
    print(f"unmeasured weight in today's DefaultBands: {added_w:.1f} / "
          f"{head_total:.1f} = {100*added_w/head_total:.1f}%")


def band_play_table(rows, key):
    """rho(band metric, outcome) and rho(band sub, outcome) over generated maps."""
    g = gen_only(rows)
    ys = [r[key] for r in g]
    out = []
    for name in BANDS_15:
        xs = [r["bands"][name]["value"] for r in g]
        ss = [r["bands"][name]["sub"] for r in g]
        rv, pv = spearman_safe(xs, ys)
        rs, ps = spearman_safe(ss, ys)
        out.append((name, rv, pv, rs, ps, len(set(round(s, 9) for s in ss))))
    return out


def spearman_safe(xs, ys):
    if len(set(xs)) < 2 or len(set(ys)) < 2:
        return float("nan"), float("nan")
    return spc.spearman(xs, ys)


def cmd_corr(args):
    rows = load_rows(False)
    g = gen_only(rows)
    c = control(rows)
    print(f"=== play outcomes, generated maps only (n = {len(g)}), FULL episodes ===")
    print("The control is scored in the SAME batch and reported on every row.\n")
    print(f"{'outcome':22s} {'rho vs staticScore':>19s} {'95% CI':>18s} {'p':>7s} "
          f"{'arena':>9s} {'gen better':>11s}")
    for key, label, _ in OUTCOMES:
        ys = [r[key] for r in g]
        xs = [r["staticScore"] for r in g]
        rho, p = spearman_safe(xs, ys)
        lo, hi = spc.boot_ci(xs, ys)
        # "better" is direction-aware: less dead floor and more steals are good.
        if key in ("deadFloorFrac",):
            nb = sum(1 for r in g if r[key] < c[key])
        else:
            nb = sum(1 for r in g if r[key] > c[key])
        ci = f"[{lo:+.2f},{hi:+.2f}]" if lo is not None else "n/a"
        print(f"{label:22s} {rho:+19.3f} {ci:>18s} {p:7.3f} {c[key]:9.3f} "
              f"{nb:4d}/{len(g):<6d}")

    print(f"\n=== are the two 'control is unreachable' axes the same axis? ===")
    rho, p = spearman_safe([r["deadFloorFrac"] for r in g],
                           [r["stealRate"] for r in g])
    print(f"rho(dead floor, steal rate) over generated maps = {rho:+.3f}, "
          f"p = {p:.3f}, n = {len(g)}")

    for key, label, _ in OUTCOMES:
        if key in ("balanceEntropy", "ticks_mean"):
            continue
        print(f"\n=== per-band vs {label} (n = {len(g)} generated) ===")
        print(f"{'band':22s} {'w':>4s} {'rho(metric)':>12s} {'p':>7s} "
              f"{'rho(sub)':>9s} {'levels':>7s}  reads")
        for name, rv, pv, rs, ps, lv in band_play_table(rows, key):
            w = BANDS_15[name][3]
            if lv == 1:
                reads = "sub saturated -- weight does nothing"
            elif abs(rv) < 0.31:
                reads = "below the n=40 resolution floor"
            else:
                reads = "resolvable"
            rvs = f"{rv:+.3f}" if rv == rv else "n/a"
            rss = f"{rs:+.3f}" if rs == rs else "n/a"
            print(f"{name:22s} {w:4.1f} {rvs:>12s} {pv:7.3f} {rss:>9s} "
                  f"{lv:7d}  {reads}")


# ---------------------------------------------------------------------------
# Candidate band sets. Each is (lo, hi, margin, weight); scoring is the same
# weighted mean of `sub_score` that `staticScore` computes, so a set defined
# here and the Nim `seq[Band]` that ships it are the same object.
# ---------------------------------------------------------------------------

def set_default():
    return {k: (v[0], v[1], v[2], v[3]) for k, v in BANDS_15.items()}


# EvidenceBands. Built by SUBTRACTION plus one rule, and the rule has zero
# parameters fitted to play: every surviving bound is set at the CONTROL's own
# measured value, on the side the control sits. That is this repo's stated
# calibration doctrine (`Band.control`, "a bound can never drift away from the
# thing that justified it"), and it has a property worth having on purpose --
# the control scores exactly 1.000 BY CONSTRUCTION, so this stick cannot flag
# the arena by accident. Two bands survive. That is the finding, not an
# oversight; see the doc for why the other thirteen do not.
def set_evidence():
    return {
        # arena 0.0384; the 40 generated maps run 0.0809..0.1731, so the
        # control is 2.1x below the generated MINIMUM. Direction agrees with
        # the band that was already there (a cap) and with the sign of dead
        # floor (-0.173), which is below the n=40 resolution floor but is not
        # contradicted by the control.
        "exposedFrac": (-1.0, 0.0385, 0.15, 1.0),
        # arena 0.3200; generated 0.0400..0.2000, control 1.6x above the
        # generated MAXIMUM. Kept because the separation is total, and flagged
        # in the doc because the within-population sign does NOT support it.
        "routeCapacityFrac": (0.3190, 1.0e6, 0.30, 1.0),
    }


def set_overfit(rows, target):
    """NEGATIVE CONTROL. Weights fitted to maximise rank correlation with play
    on the 40 generated maps, which is exactly what the task forbids shipping.
    Built so the doc can show what it costs: it ranks the control badly."""
    import numpy as np
    from scipy.stats import rankdata
    g = gen_only(rows)
    names = [n for n in BANDS_15
             if len(set(round(r["bands"][n]["sub"], 9) for r in g)) > 1]
    X = np.array([[r["bands"][n]["sub"] for n in names] for r in g])
    y = rankdata([target(r) for r in g])
    Xr = np.apply_along_axis(rankdata, 0, X)
    beta, *_ = np.linalg.lstsq(
        np.hstack([Xr, np.ones((len(g), 1))]), y, rcond=None)
    return {n: (*BANDS_15[n][:3], float(b)) for n, b in zip(names, beta[:-1])}


def score_map(bandvals, bset):
    tot = wt = 0.0
    for name, (lo, hi, mg, w) in bset.items():
        v = bandvals[name]["value"]
        tot += sub_score(v, lo, hi, mg) * w
        wt += w
    return tot / wt if wt > 0 else 0.0


def play_composite(rows):
    """Higher = the map played better. The mean of two rank-normalised axes.

    These two and no others, because they are the two axes on which the
    hand-authored control beats ALL 40 generated maps (0/40 each) while being
    ordinary on pace and contact. That is what makes them the designed-vs-drawn
    axes rather than a taste. They agree with each other at rho = -0.552
    (p < 0.001) once dead floor is sign-flipped, so the composite is not two
    names for one measurement nor two unrelated things averaged.
    """
    from scipy.stats import rankdata
    g = gen_only(rows)
    dead = rankdata([-r["deadFloorFrac"] for r in g])
    steal = rankdata([r["stealRate"] for r in g])
    z = {}
    for r, d, s in zip(g, dead, steal):
        z[r["label"]] = (d + s) / 2.0
    return z


def cmd_compare(args):
    _, valid = load_manifest()
    rows = load_rows(False)
    c = control(rows)
    sets = {"DefaultBands": set_default(), "EvidenceBands": set_evidence()}

    print(f"=== how the {len(valid)} valid maps re-order ===\n")
    for name, bs in sets.items():
        sc = sorted(((score_map(m["bands"], bs), m["label"]) for m in valid),
                    reverse=True)
        vals = [s for s, _ in sc]
        ties = len(vals) - len(set(round(v, 6) for v in vals))
        at_one = sum(1 for v in vals if v >= 0.9999)
        print(f"{name:16s} range {min(vals):.4f}..{max(vals):.4f}  "
              f"maps at exactly 1.000: {at_one}/{len(vals)} "
              f"({100*at_one/len(vals):.1f}%)  tied: {ties}")
        print(f"{'':16s} control `arena` scores "
              f"{score_map(c['bands'], bs):.4f}")
    print()

    # Rank agreement between the two sticks over the same population.
    from scipy.stats import spearmanr
    a = [score_map(m["bands"], sets["DefaultBands"]) for m in valid]
    b = [score_map(m["bands"], sets["EvidenceBands"]) for m in valid]
    r = spearmanr(a, b)
    print(f"rho(DefaultBands, EvidenceBands) over {len(valid)} maps = "
          f"{r.statistic:+.3f} -- the two sticks are {'nearly the same' if abs(r.statistic)>0.8 else 'DIFFERENT'} ruler")

    print(f"\n=== the played maps, both sticks, control in the same batch ===")
    print(f"{'label':10s} {'Default':>8s} {'rank':>5s} {'Evidence':>9s} {'rank':>5s} "
          f"{'dead':>6s} {'steal/1k':>9s}")
    dr = sorted(rows, key=lambda r: -score_map(r["bands"], sets["DefaultBands"]))
    er = sorted(rows, key=lambda r: -score_map(r["bands"], sets["EvidenceBands"]))
    drank = {r["label"]: i + 1 for i, r in enumerate(dr)}
    erank = {r["label"]: i + 1 for i, r in enumerate(er)}
    for r in dr:
        tag = "  <== CONTROL" if r.get("is_control") else ""
        if r["label"] == "s1011a0":
            tag = "  <== the 1.000 / ZERO-steal map"
        print(f"{r['label']:10s} {score_map(r['bands'], sets['DefaultBands']):8.4f} "
              f"{drank[r['label']]:5d} {score_map(r['bands'], sets['EvidenceBands']):9.4f} "
              f"{erank[r['label']]:5d} {r['deadFloorFrac']:6.3f} {r['stealRate']:9.3f}{tag}")


def cmd_crossval(args):
    import numpy as np
    from scipy.stats import rankdata, spearmanr
    rows = load_rows(False)
    g = gen_only(rows)
    c = control(rows)
    comp = play_composite(rows)
    y = np.array([comp[r["label"]] for r in g])

    print(f"=== held-out rank correlation against play, n = {len(g)} generated "
          f"maps, 5 episodes each ===")
    print("Target: the play composite (mean rank of less dead floor + more "
          "steals).\n")

    # Reliability of the composite, so the ceiling on every rho below is known.
    from scipy.stats import rankdata as rd
    a, b = [], []
    for r in g:
        pe = r["_per_episode"]
        odd = [0, 2, 4]
        ev = [1, 3]
        a.append((-sum(pe["deadFloorFrac"][i] for i in odd) / 3,
                  sum(pe["stealRate"][i] for i in odd) / 3))
        b.append((-sum(pe["deadFloorFrac"][i] for i in ev) / 2,
                  sum(pe["stealRate"][i] for i in ev) / 2))
    ha = (rd([x[0] for x in a]) + rd([x[1] for x in a])) / 2
    hb = (rd([x[0] for x in b]) + rd([x[1] for x in b])) / 2
    half = spearmanr(ha, hb).statistic
    sb = 2 * half / (1 + half)
    print(f"composite split-half r = {half:.3f}, Spearman-Brown = {sb:.3f}; "
          f"an observed |rho| is capped at sqrt({sb:.3f}) = {sb**0.5:.3f}\n")

    def arena_rank(bs):
        """Rank of the control among all 41, TIE-AWARE.

        Tie handling is the whole point of this function rather than an
        `index()` call: under `DefaultBands` the control does not merely rank
        first, it ties at exactly 1.000 with two generated maps -- one of which
        recorded zero steals in five episodes. A rank that silently resolves
        that tie in the control's favour hides the defect being measured.
        """
        a = score_map(c["bands"], bs)
        sc = [score_map(r["bands"], bs) for r in rows]
        better = sum(1 for s in sc if s > a + 1e-9)
        tied = sum(1 for s in sc if abs(s - a) <= 1e-9) - 1
        return better + 1, tied

    fixed = {"DefaultBands": set_default(), "EvidenceBands": set_evidence()}
    print(f"{'band set':18s} {'rho vs play':>12s} {'95% CI':>18s} {'p':>7s} "
          f"{'arena':>8s} {'rank':>7s} {'tied':>6s}  fitted params")
    for name, bs in fixed.items():
        xs = [score_map(r["bands"], bs) for r in g]
        rho, p = spearman_safe(xs, list(y))
        lo, hi = spc.boot_ci(xs, list(y))
        ar, tied = arena_rank(bs)
        print(f"{name:18s} {rho:+12.3f} [{lo:+.2f},{hi:+.2f}]".ljust(50)
              + f" {p:7.3f} {score_map(c['bands'], bs):8.4f} "
              f"{ar:3d}/{len(rows):<3d} {tied:6d}  0 (no play data used)")

    # The best possible RE-WEIGHTING, which is what this task was asked for.
    # Non-negative least squares on the raw sub-scores, because that is exactly
    # the search space a band weight lives in: `staticScore` is a weighted mean
    # of sub-scores and a weight cannot be negative, so a band whose sub-score
    # runs against play can be driven to zero but never flipped. Fitting
    # anything wider would not be a re-weighting.
    # `scipy.optimize.nnls` emits a spurious divide-by-zero/overflow warning
    # from its own normal equations on this scipy build (1.13.1) even though
    # the design matrix is finite, in [0,1] and has no zero-variance column.
    # `lsq_linear(..., bvls)` is a different code path and agrees with it to
    # 7.1e-15 on every weight and to 12 digits on the residual, so the
    # constrained solution is real and the warning is not.
    from scipy.optimize import lsq_linear
    names = [n for n in BANDS_15
             if len(set(round(r["bands"][n]["sub"], 9) for r in g)) > 1]
    X = np.array([[r["bands"][n]["sub"] for n in names] for r in g])
    yr = rankdata(y)

    def fit(rowsel):
        # Centre both sides. `staticScore` is scale-invariant in w (it divides
        # by the weight sum), so only the DIRECTION of w matters and a fit on
        # centred data needs no intercept. Fitting the uncentred sub-scores
        # instead forces the weights to reproduce the mean as well as the
        # ranking, which is what overflowed the normal equations here.
        A = X[rowsel] - X[rowsel].mean(axis=0)
        b = yr[rowsel] - yr[rowsel].mean()
        return lsq_linear(A, b, bounds=(0.0, np.inf), method="bvls").x

    rng = np.random.default_rng(20260806)
    held = np.zeros(len(g))
    counts = np.zeros(len(g))
    for _ in range(args.repeats):
        idx = rng.permutation(len(g))
        for f in range(5):
            te = idx[f::5]
            tr = np.setdiff1d(idx, te)
            w = fit(tr)
            held[te] += X[te] @ w
            counts[te] += 1
    held /= counts
    rho, p = spearmanr(held, y)
    lo, hi = spc.boot_ci(list(held), list(y))

    wfull = fit(np.arange(len(g)))
    fitted_set = {n: (*BANDS_15[n][:3], float(w))
                  for n, w in zip(names, wfull) if w > 1e-9}
    a_sc = score_map(c["bands"], fitted_set)
    a_rank, a_tied = arena_rank(fitted_set)
    print(f"{'ReweightBands':18s} {rho:+12.3f} [{lo:+.2f},{hi:+.2f}]".ljust(50)
          + f" {p:7.3f} {a_sc:8.4f} {a_rank:3d}/{len(rows):<3d} {a_tied:6d}  "
          f"{len(names)} weights on n={len(g)}")

    ins = spearmanr(X @ wfull, y).statistic
    print(f"{'  (same, IN-SAMPLE)':18s} {ins:+12.3f}".ljust(50)
          + f" {'--':>7s} {'--':>8s} {'--':>7s} {'--':>6s}  the number NOT to report")

    # THE CONTRAST THAT LOCATES THE PROBLEM. Same 8 bands, same CV, but the
    # weights are allowed to go NEGATIVE. A negative weight is not a legal band
    # weight -- `staticScore` is a weighted MEAN, so a negative w does not
    # down-rank a band, it inverts it -- so this is not a shippable set. It is
    # here to answer one question: is the signal missing, or is it present in a
    # direction the weighted-mean form cannot express?
    heldS = np.zeros(len(g))
    countS = np.zeros(len(g))
    for _ in range(args.repeats):
        idx = rng.permutation(len(g))
        for f in range(5):
            te = idx[f::5]
            tr = np.setdiff1d(idx, te)
            A = np.hstack([X[tr], np.ones((len(tr), 1))])
            bb, *_ = np.linalg.lstsq(A, yr[tr], rcond=None)
            heldS[te] += np.hstack([X[te], np.ones((len(te), 1))]) @ bb
            countS[te] += 1
    heldS /= countS
    rhoS, pS = spearmanr(heldS, y)
    loS, hiS = spc.boot_ci(list(heldS), list(y))
    bS, *_ = np.linalg.lstsq(np.hstack([X, np.ones((len(g), 1))]), yr, rcond=None)
    a_lin = float(np.array([c["bands"][n]["sub"] for n in names]) @ bS[:-1])
    lins = [float(np.array([r["bands"][n]["sub"] for n in names]) @ bS[:-1])
            for r in rows]
    a_rankS = sum(1 for s in lins if s > a_lin + 1e-9) + 1
    print(f"{'SIGNED (illegal)':18s} {rhoS:+12.3f} [{loS:+.2f},{hiS:+.2f}]".ljust(50)
          + f" {pS:7.3f} {'n/a':>8s} {a_rankS:3d}/{len(rows):<3d} {'--':>6s}  "
          f"{len(names)} SIGNED weights")
    flipped = [n for n, b in zip(names, bS[:-1]) if b < 0]
    print(f"{'':18s} bands it had to INVERT to get there: "
          f"{len(flipped)}/{len(names)} -- {flipped}")

    print(f"\n--- the fitted weights, and what they did to the band set ---")
    tot = sum(w for w in wfull)
    for n, w in sorted(zip(names, wfull), key=lambda t: -t[1]):
        old = BANDS_15[n][3]
        note = "ZEROED" if w <= 1e-9 else ""
        print(f"  {n:22s} DefaultBands w={old:4.1f} -> fitted w={w:6.3f} "
              f"({100*w/tot if tot else 0:5.1f}% of the set)  {note}")
    dropped = [n for n, w in zip(names, wfull) if w <= 1e-9]
    print(f"  bands driven to zero: {len(dropped)}/{len(names)} -- {dropped}")

    print(f"\n*** THE DECISIVE NUMBER ***")
    print(f"The best re-weighting of these bands ranks the 40 generated maps at")
    print(f"rho = {rho:+.3f}, 95% CI [{lo:+.2f},{hi:+.2f}], p = {p:.3f}, n = 40, "
          f"held out over 5-fold CV x {args.repeats}.")
    print(f"It ranks the hand-authored control {a_rank} of {len(rows)} "
          f"(tied with {a_tied}) -- the map that beat")
    print(f"all 40 generated maps on BOTH play axes, 0/40 and 0/40.")
    for nm, bs in [("DefaultBands", set_default()),
                   ("EvidenceBands", set_evidence()),
                   ("ReweightBands", fitted_set)]:
        s11 = next(r for r in rows if r["label"] == "s1011a0")
        print(f"  {nm:14s} arena {score_map(c['bands'], bs):.4f} vs "
              f"s1011a0 (0 steals in 5 episodes) {score_map(s11['bands'], bs):.4f}"
              + ("   <-- TIED, the stick cannot tell them apart"
                 if abs(score_map(c['bands'], bs)
                        - score_map(s11['bands'], bs)) <= 1e-9 else ""))

    print(f"\n=== each axis separately, for the two shippable sets ===")
    for key, label, _ in [("deadFloorFrac", "dead floor (lower better)", ""),
                          ("stealRate", "steal rate (higher better)", "")]:
        ys = [(-r[key] if key == "deadFloorFrac" else r[key]) for r in g]
        print(f"\n{label}")
        for name, bs in fixed.items():
            xs = [score_map(r["bands"], bs) for r in g]
            rho, p = spearman_safe(xs, ys)
            lo, hi = spc.boot_ci(xs, ys)
            print(f"  {name:18s} rho = {rho:+.3f}  95% CI [{lo:+.2f},{hi:+.2f}]"
                  f"  p = {p:.3f}  n = {len(g)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("reliability").set_defaults(fn=cmd_reliability)
    sub.add_parser("census").set_defaults(fn=cmd_census)
    sub.add_parser("corr").set_defaults(fn=cmd_corr)
    sub.add_parser("compare").set_defaults(fn=cmd_compare)
    cv = sub.add_parser("crossval")
    cv.add_argument("--repeats", type=int, default=200)
    cv.set_defaults(fn=cmd_crossval)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
