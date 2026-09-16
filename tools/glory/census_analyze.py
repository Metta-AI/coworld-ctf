#!/usr/bin/env python3
"""GLORY GRADIENT step-1 CENSUS: aggregate seat-episode rows into the five
census answers (deed mint census, glory percentiles, cap-hit share,
recipe share, LONGSHOT/ACETAG/WIPE/TAGBACK + heat rung occupancy).

Usage:
  python3 census_analyze.py --rows seat_episode_rows.json
"""
import argparse
import json
import math
import os
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog_fold  # noqa: E402

CAP = 2 ** 24

# Full Deed enum, verbatim from src/ctf/glory.nim (order matches the enum
# declaration; dNone and dAchievement excluded -- dAchievement never mints
# as a glory_deed row, it rides the separate 'achievement' kind) -- the 31
# named deeds -- PLUS `survivalCredit`, which is NOT a member of that enum
# and so was silently missing from this census entirely (the table read as
# a 31-row catalog of a 32-price economy). It is minted by sim.nim's
# `recutMintSurvivalCredit` as a raw `GloryDeed`-kind event that bypasses
# `awardDeed`; see catalog_fold.CONTINUOUS_CREDIT_WEAPONS for the full
# semantics, its HANDED classification, and the measured realized effect.
# Reporting-only: this list never touches a fold, so adding it changes no
# reconciled score.
ALL_DEEDS = [
    "dFirstBlood", "dHonorableKill", "dSprayKill", "dGrenadeKill",
    "dPointBlankKill", "dLongshotKill", "dSplashMultiKill", "dRevengeKill",
    "dRunDown", "dAceTag", "dTeamKill", "dFlagSteal", "dCapture",
    "dCarrierKill", "dDenial", "dEscortKill", "dAssist", "dRescue",
    "dClutchHeal", "dShieldSoak", "dWipe", "dLevelUp",
    "dDuoDown", "dClosingTime", "dLastLight", "dVictory", "dTagBack",
    "dJointAct", "dFinal8", "dFinal4", "dFinal2",
] + sorted(catalog_fold.CONTINUOUS_CREDIT_WEAPONS)


def percentile(sorted_vals, p):
    k = (len(sorted_vals) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", required=True)
    args = ap.parse_args()

    with open(args.rows) as f:
        rows = json.load(f)

    n_seat_eps = len(rows)
    episodes = set(r["episode_id"] for r in rows)
    n_eps = len(episodes)
    rounds = set(r["round_number"] for r in rows)
    n_rounds = len(rounds)
    print(f"=== SAMPLE: {n_rounds} rounds, {n_eps} episodes, {n_seat_eps} seat-episodes ===")
    print(f"round range: r{min(rounds)}-r{max(rounds)}\n")

    matches = sum(1 for r in rows if r["reported"] is not None and r["recon_final"] == r["reported"])
    have_reported = sum(1 for r in rows if r["reported"] is not None)
    print(f"=== METHOD CHECK: recon == reported on {matches}/{have_reported} "
          f"({100*matches/have_reported:.2f}%) ===\n")

    deed_total = Counter()
    deed_eps_with_fire = defaultdict(set)
    ach_total = Counter()
    ach_eps = defaultdict(set)
    for r in rows:
        for w, c in r["deed_counts"].items():
            deed_total[w] += c
            deed_eps_with_fire[w].add(r["episode_id"])
        for w, c in r["ach_counts"].items():
            ach_total[w] += c
            ach_eps[w].add(r["episode_id"])

    print("=== Q1: PER-DEED MINT COUNT (per EPISODE, 16 seats pooled, AND "
          "per SEAT-episode) ===")
    print(f"{'deed':<18} {'mints/ep':>10} {'mints/seat-ep':>14} {'%eps>=1':>9} "
          f"{'total_mints':>12}")
    dead = []
    for d in ALL_DEEDS:
        total = deed_total.get(d, 0)
        per_ep, per_seat_ep = catalog_fold.deed_rates(total, n_eps, n_seat_eps)
        pct_eps = 100 * len(deed_eps_with_fire.get(d, set())) / n_eps
        print(f"{d:<18} {per_ep:>10.4f} {per_seat_ep:>14.4f} {pct_eps:>8.2f}% "
              f"{total:>12d}")
        if total == 0:
            dead.append(d)
    print(f"\nDEAD (0 mints across {n_eps} episodes): {dead}")
    print("\n-- achievement trees (separate catalog) --")
    for tree, total in ach_total.most_common():
        per_ep, per_seat_ep = catalog_fold.deed_rates(total, n_eps, n_seat_eps)
        print(f"{tree:<18} {per_ep:>10.4f} {per_seat_ep:>14.4f} "
              f"{100*len(ach_eps[tree])/n_eps:>8.2f}%")
    print()

    scores = sorted(r["reported"] for r in rows if r["reported"] is not None)
    p50, p90, p99 = percentile(scores, 0.50), percentile(scores, 0.90), percentile(scores, 0.99)
    p999, mx = percentile(scores, 0.999), scores[-1]
    print("=== Q2: EPISODE-GLORY PERCENTILES (seat-episode granularity) ===")
    print(f"n={len(scores)}  p50={p50:.0f}  p90={p90:.0f}  p99={p99:.0f}  "
          f"p99.9={p999:.0f}  max={mx:.0f}")
    print(f"p99/p50 = {p99/p50:.2f}x   p99.9/p50 = {p999/p50:.2f}x")
    print(f"NOTE: p99.9 rank corresponds to the top ~{len(scores)*0.001:.1f} "
          f"of {len(scores)} samples.\n")

    cap_hits = sum(1 for r in rows if r["reported"] is not None and r["reported"] >= CAP)
    print("=== Q3: CAP-HIT SHARE ===")
    print(f"seat-episodes at/over product cap ({CAP}): {cap_hits}/{len(scores)} = "
          f"{100*cap_hits/len(scores):.3f}%")
    win_scores = [r["reported"] for r in rows if r["win"] and r["reported"] is not None]
    lose_scores = [r["reported"] for r in rows if not r["win"] and r["reported"] is not None]
    win_cap = sum(1 for s in win_scores if s >= CAP)
    print(f"  of winners: {win_cap}/{len(win_scores)} = {100*win_cap/len(win_scores):.3f}%")
    print(f"  of non-winners: {sum(1 for s in lose_scores if s>=CAP)}/{len(lose_scores)}\n")

    print("=== Q4: RECIPE SHARE (top-decile seat-episodes) ===")
    top_decile_thresh = p90
    top = [r for r in rows if r["reported"] is not None and r["reported"] >= top_decile_thresh]
    print(f"top-decile threshold (p90): {top_decile_thresh:.0f}  n={len(top)}")
    shares, both_fire = [], 0
    for r in top:
        ct, ja = r["closing_time_amt"] or 1, r["jointact_amt"] or 1
        win_mult = 8 if r["win"] else 1
        recipe = ct * ja * win_mult
        final = r["reported"]
        if final and final > 1 and recipe > 1:
            shares.append(math.log2(recipe) / math.log2(final))
        if ct > 1 and ja > 1 and r["win"]:
            both_fire += 1
    if shares:
        print(f"recipe(closing_time x jointact x win8) log2-share of final score: "
              f"mean={statistics.mean(shares):.3f}  median={statistics.median(shares):.3f}  "
              f"n={len(shares)}")
    print(f"top-decile seat-episodes where ALL THREE fire together: "
          f"{both_fire}/{len(top)} = {100*both_fire/len(top):.2f}%")
    ct_fire = sum(1 for r in top if r["closing_time_amt"] > 1)
    ja_fire = sum(1 for r in top if r["jointact_amt"] > 1)
    win_fire = sum(1 for r in top if r["win"])
    print(f"  closing_time fires: {ct_fire}/{len(top)} ({100*ct_fire/len(top):.1f}%)  "
          f"jointact fires: {ja_fire}/{len(top)} ({100*ja_fire/len(top):.1f}%)  "
          f"is winner: {win_fire}/{len(top)} ({100*win_fire/len(top):.1f}%)\n")

    print("=== Q5a: LONGSHOT / ACETAG / WIPE / TAGBACK ===")
    for d in ["dLongshotKill", "dAceTag", "dWipe", "dTagBack"]:
        total = deed_total.get(d, 0)
        per_ep, per_seat_ep = catalog_fold.deed_rates(total, n_eps, n_seat_eps)
        pct_eps = 100 * len(deed_eps_with_fire.get(d, set())) / n_eps
        print(f"{d:<16} total={total:<6} per_ep={per_ep:.4f}  "
              f"per_seat_ep={per_seat_ep:.4f}  %eps>=1={pct_eps:.2f}%")
    print()

    print("=== Q5b: HEAT RUNG DISTRIBUTION (seat-time share, tick-weighted, full episode) ===")
    rung_ticks = defaultdict(int)
    total_ep_ticks = 0
    for r in rows:
        for rung_str, ticks in r["heat_occ"].items():
            rung_ticks[int(rung_str)] += ticks
        total_ep_ticks += r["episode_ticks"]
    labels = {0: "x1", 1: "x2", 2: "x4", 3: "x8"}
    for rung in [0, 1, 2, 3]:
        t = rung_ticks.get(rung, 0)
        print(f"  {labels[rung]}: {100*t/total_ep_ticks:.4f}%  ({t} ticks)")
    print(f"  total seat-episode-ticks accounted: {sum(rung_ticks.values())} / "
          f"{total_ep_ticks} ({100*sum(rung_ticks.values())/total_ep_ticks:.2f}% coverage)")


if __name__ == "__main__":
    main()
