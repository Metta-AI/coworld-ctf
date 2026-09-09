#!/usr/bin/env python3
"""GLORY GRADIENT S1b: aggregate attribution_decompose.py's rows into the
top-decile attribution table -- mean/median log2-magnitude share per named
contributor, plus the residual and reconciliation check.

Convention (explicit, per review note): a "share" is
log2(bucket_subtotal) / log2(recon_final) for POSITIVE buckets, and
ff_halvings / log2(recon_final) (as a negative share) for FRIENDLY_FIRE --
i.e. summing logs of the multiplicative legs that compose the one product,
matching census_analyze.py's own Q4 method exactly (recipe log2-share of
final score) so the numbers here are directly comparable to the census's
42.2% recipe figure and the achievements addendum's 18.0% figure.

Usage:
  python3 attribution_analyze.py --rows attribution_rows.json
"""
import argparse
import json
import math
import statistics
from collections import defaultdict

BUCKETS = ["RECIPE_BASE", "PLACEMENT_BASE", "OTHER_DEED_BASE", "HEAT",
           "CARRY", "ALLY_STACK", "TERRITORY", "ACHIEVEMENTS", "WIN",
           "FRIENDLY_FIRE"]

CHOSEN = {"RECIPE_BASE", "OTHER_DEED_BASE", "HEAT", "ALLY_STACK",
          "TERRITORY", "ACHIEVEMENTS", "CARRY"}
HANDED = {"PLACEMENT_BASE", "WIN"}
# FRIENDLY_FIRE is its own thing (a self-inflicted penalty, chosen in the
# sense that avoiding it is a choice, but it never ADDS magnitude) --
# reported separately, not folded into either side.


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

    n = len(rows)
    scores = sorted(r["reported"] for r in rows if r["reported"] is not None)
    p90 = percentile(scores, 0.90)
    top = [r for r in rows if r["reported"] is not None and r["reported"] >= p90]
    print(f"=== SAMPLE: {n} seat-episodes; top-decile threshold (p90 of "
          f"`reported`) = {p90:.0f}, n={len(top)} ===\n")

    capped_in_top = sum(1 for r in top if r.get("capped"))
    print(f"capped (>= 2^24) in top decile: {capped_in_top}/{len(top)} "
          f"({100*capped_in_top/len(top):.2f}%) -- for these rows the "
          f"log2(final) denominator is clamped at 24, so their per-bucket "
          f"shares are computed against the UNCAPPED reconstructed total "
          f"instead (noted per-row below), not against 24.\n")

    per_bucket_shares = defaultdict(list)
    residuals = []
    for r in top:
        final = r["reported"]
        if not final or final <= 1:
            continue
        buckets = r["buckets"]
        if r.get("capped"):
            denom = math.log2(r["recon_uncapped"]) if r["recon_uncapped"] > 1 else math.log2(final)
        else:
            denom = math.log2(final)
        if denom <= 0:
            continue
        row_total = 0.0
        for b in BUCKETS:
            v = buckets.get(b, 0.0)
            share = v / denom
            per_bucket_shares[b].append(share)
            row_total += v
        # UNRESOLVED (should be ~0 given 0 events hit it, but keep the
        # channel so a residual would be VISIBLE, not silently dropped)
        unresolved = buckets.get("UNRESOLVED", 0.0)
        if unresolved:
            per_bucket_shares["UNRESOLVED"].append(unresolved / denom)
            row_total += unresolved
        residual = 1.0 - (row_total / denom)
        residuals.append(residual)

    print("=== TOP-DECILE ATTRIBUTION TABLE (log2-magnitude share of "
          "recon_final; same convention as census Q4 / achievements Q2) ===")
    print(f"{'contributor':<18}{'mean %':>10}{'median %':>10}{'n>0':>8}")
    for b in BUCKETS + (["UNRESOLVED"] if "UNRESOLVED" in per_bucket_shares else []):
        vals = per_bucket_shares.get(b, [])
        if not vals:
            continue
        nz = sum(1 for v in vals if abs(v) > 1e-9)
        print(f"{b:<18}{100*statistics.mean(vals):>9.2f}%"
              f"{100*statistics.median(vals):>9.2f}%{nz:>8d}")

    print(f"\nmean residual (unexplained): {100*statistics.mean(residuals):.3f}%")
    print(f"median residual (unexplained): {100*statistics.median(residuals):.3f}%")
    print(f"max |residual| observed: {100*max(abs(x) for x in residuals):.3f}%")

    chosen_mean = sum(statistics.mean(per_bucket_shares[b]) for b in CHOSEN if b in per_bucket_shares)
    handed_mean = sum(statistics.mean(per_bucket_shares[b]) for b in HANDED if b in per_bucket_shares)
    ff_mean = statistics.mean(per_bucket_shares["FRIENDLY_FIRE"]) if per_bucket_shares.get("FRIENDLY_FIRE") else 0.0
    print(f"\nCHOSEN-by-the-seat share (recipe+other-kills+heat+stack+"
          f"territory+achievements+carry), mean of means: {100*chosen_mean:.2f}%")
    print(f"HANDED-to-the-seat share (placement+win), mean of means: "
          f"{100*handed_mean:.2f}%")
    print(f"FRIENDLY_FIRE mean (self-inflicted, subtracts): {100*ff_mean:.2f}%")


if __name__ == "__main__":
    main()
