#!/usr/bin/env python3
"""GLORY GRADIENT S1 ADDENDUM: analyze census_achievements.py's decomposed
rows for the four addendum questions (mint census, product-share
distribution, top-decile explanation test, tier structure).

Usage:
  python3 census_achievements_analyze.py --rows achievement_rows.json \\
      --census-rows seat_episode_rows_final.json
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

TREES = [
    "treeGun", "treeSpray", "treeGrenade", "treeShield", "treeMedKit",
    "treeCarrier", "treeDefender", "treeSquad",
]
TIER_NAMES = ["I", "II", "III", "IV", "V"]
RECUT_TIER_CLASS = [1, 1, 2, 2, 4]


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
    print(f"=== SAMPLE: {n_eps} episodes, {n_seat_eps} seat-episodes ===\n")

    # ---- Q1: per-achievement mint rate (tree, tier) ----
    mint_total = Counter()
    mint_eps = defaultdict(set)
    first_total = Counter()
    tier_fire_total = Counter()
    tier_fire_eps = defaultdict(set)
    for r in rows:
        for tree, tier, amt, first in r["ach_mints"]:
            key = (tree, tier)
            mint_total[key] += 1
            mint_eps[key].add(r["episode_id"])
            tier_fire_total[tier] += 1
            tier_fire_eps[tier].add((r["episode_id"], r["slot"]))
            if first:
                first_total[key] += 1

    print("=== Q1: PER-ACHIEVEMENT MINT RATE (8 trees x 5 tiers = 40; per "
          "EPISODE, 16 seats pooled, AND per SEAT-episode) ===")
    print(f"{'tree':<14}{'tier':<6}{'mints/ep':>10}{'mints/seat-ep':>15}"
          f"{'%eps>=1':>9}{'total':>8}{'firsts':>8}")
    dead = []
    for tree in TREES:
        for tier in range(5):
            key = (tree, tier)
            total = mint_total.get(key, 0)
            per_ep, per_seat_ep = catalog_fold.deed_rates(total, n_eps, n_seat_eps)
            pct = 100 * len(mint_eps.get(key, set())) / n_eps
            firsts = first_total.get(key, 0)
            print(f"{tree:<14}{TIER_NAMES[tier]:<6}{per_ep:>10.4f}"
                  f"{per_seat_ep:>15.4f}{pct:>8.2f}%{total:>8d}{firsts:>8d}")
            if total == 0:
                dead.append(f"{tree}.{TIER_NAMES[tier]}")
    print(f"\nZERO-MINT achievements ({len(dead)}/40): {dead}\n")

    # ---- Q2: share of the product (log2-magnitude), achievements vs deeds ----
    scores = sorted(r["reported"] for r in rows if r["reported"] is not None)
    p90 = percentile(scores, 0.90)
    print(f"=== Q2: LOG2-MAGNITUDE SHARE OF THE PRODUCT (achievements vs deeds) ===")
    print(f"top-decile threshold (p90, same as census Q4): {p90:.0f}\n")

    def ach_share(r):
        final = r["reported"]
        ap = r["ach_product"]
        if final is None or final <= 1 or ap <= 1:
            return 0.0
        return math.log2(ap) / math.log2(final)

    all_shares = [ach_share(r) for r in rows]
    nonzero_shares = [s for s in all_shares if s > 0]
    print(f"WHOLE POPULATION (n={n_seat_eps}): mean={statistics.mean(all_shares):.3f} "
          f"median={statistics.median(all_shares):.3f}  "
          f"(n with any ach contribution={len(nonzero_shares)}, "
          f"{100*len(nonzero_shares)/n_seat_eps:.1f}%)")

    top = [r for r in rows if r["reported"] is not None and r["reported"] >= p90]
    top_shares_all = [ach_share(r) for r in top]
    top_shares_nz = [s for s in top_shares_all if s > 0]
    print(f"TOP DECILE (n={len(top)}): mean={statistics.mean(top_shares_all):.3f} "
          f"median={statistics.median(top_shares_all):.3f}  "
          f"(n with any ach contribution={len(top_shares_nz)}, "
          f"{100*len(top_shares_nz)/len(top):.1f}%)")
    if top_shares_nz:
        print(f"  of those with ach contribution: mean={statistics.mean(top_shares_nz):.3f} "
              f"median={statistics.median(top_shares_nz):.3f}")
    print()

    # ---- Q3: does achievement explain the top? recipe vs achievement vs combined ----
    print("=== Q3: TOP-DECILE EXPLANATION -- recipe vs achievement vs combined ===")
    census_recipe_shares = []
    ach_only_shares = []
    combined_shares = []
    max_ach_product = 0
    max_ach_row = None
    ach24_count = 0
    tier5_first_count = 0
    clean_sheet_count = 0
    both_x24_ingredients = 0
    for r in top:
        final = r["reported"]
        if not final or final <= 1:
            continue
        ap = r["ach_product"]
        if ap > max_ach_product:
            max_ach_product = ap
            max_ach_row = r
        if ap == 24:
            ach24_count += 1
        has_clean_sheet = any(t == "treeSquad" and ti == 3 for t, ti, a, f in r["ach_mints"])
        has_tier5_first = any(ti == 4 and f for t, ti, a, f in r["ach_mints"])
        if has_clean_sheet:
            clean_sheet_count += 1
        if has_tier5_first:
            tier5_first_count += 1
        if has_clean_sheet and has_tier5_first:
            both_x24_ingredients += 1
        if ap > 1:
            ach_only_shares.append(math.log2(ap) / math.log2(final))
    print(f"max ach_product observed in top decile: {max_ach_product} "
          f"(episode {max_ach_row['episode_id'] if max_ach_row else None}, "
          f"slot {max_ach_row['slot'] if max_ach_row else None})")
    print(f"top-decile seat-episodes with ach_product==24 exactly: {ach24_count}/{len(top)}")
    print(f"top-decile seat-episodes with Clean Sheet (treeSquad.IV): "
          f"{clean_sheet_count}/{len(top)} ({100*clean_sheet_count/len(top):.1f}%)")
    print(f"top-decile seat-episodes with a tier-V FIRST claim (any tree): "
          f"{tier5_first_count}/{len(top)} ({100*tier5_first_count/len(top):.1f}%)")
    print(f"top-decile seat-episodes with BOTH (the '24' recipe's two ingredients): "
          f"{both_x24_ingredients}/{len(top)} ({100*both_x24_ingredients/len(top):.1f}%)")
    if ach_only_shares:
        print(f"achievement-only log2-share among top-decile rows where ach_product>1: "
              f"mean={statistics.mean(ach_only_shares):.3f} "
              f"median={statistics.median(ach_only_shares):.3f} n={len(ach_only_shares)}")
    print()

    # ---- Q4: tier structure (RecutTierClass) ----
    print("=== Q4: TIER STRUCTURE (RecutTierClass = [1,1,2,2,4]) ===")
    total_mints_all_tiers = sum(tier_fire_total.values())
    for tier in range(5):
        cnt = tier_fire_total.get(tier, 0)
        pct_of_mints = 100 * cnt / total_mints_all_tiers if total_mints_all_tiers else 0
        pct_seat_eps = 100 * len(tier_fire_eps.get(tier, set())) / n_seat_eps
        print(f"  tier {TIER_NAMES[tier]} (class x{RECUT_TIER_CLASS[tier]}): "
              f"{cnt} mints ({pct_of_mints:.1f}% of all achievement mints), "
              f"fires in {pct_seat_eps:.2f}% of seat-episodes")
    total_firsts = sum(first_total.values())
    print(f"  FIRST-claim bonus (x3, tier V only by law): {total_firsts} mints total "
          f"= {100*total_firsts/n_seat_eps:.2f}% of seat-episodes")


if __name__ == "__main__":
    main()
