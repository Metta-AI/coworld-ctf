#!/usr/bin/env python3
"""C7 memory substitution over the integrated C2+V1 ledgers (proposal arithmetic,
not a measured ledger). Reads C2-integrated-activation-mac.json (65 rows at
331 px incl. colossal) and C2-integrated-configured-mac.json (11 rows at
1300 px), replaces the bitmap cache field with a list cache of N slots whose
capacity is the nonzero-kernel count at the row's range, and (for the
conservative colossal-at-1300 case) also substitutes the 1300 px geometry.
Usage: c7_memory_calc.py <research dir> [slots=64]"""
import json, sys
R = sys.argv[1]; SLOTS = int(sys.argv[2]) if len(sys.argv) > 2 else 64
NONZERO = {331: 5385, 1300: 54173}          # C8_ZERO_REVIEW.md, measured from the real kernel
BITMAP_WORDS = {331: 113, 1300: 1671}        # C6/C2 entry words
ENTRY_BYTES = 8                              # int32 grid index + float32 weight
SLOT_META = 16                               # key int32 + length int32 + lastUse uint64 (per slot)
OBJECT_FIXED = 32                            # words/capacity ints, seq pointer, clock (order of magnitude)
ALLOWANCE = 16                               # one seq allocation allowance (same as bitmap seq today)
CAP_SHARED_NOW = 32 * 1024 * 1024; CAP_SHARED_AUTH = 64 * 1024 * 1024; CAP_TOTAL = 256 * 1024 * 1024
KERNEL_BYTES = {331: 85 * 85 * 4, 1300: 327 * 327 * 4}
PERIMETER_BYTES = {331: 236 * 16, 1300: 924 * 16}
def list_cache_bytes(rng, slots=SLOTS):
    return slots * NONZERO[rng] * ENTRY_BYTES + slots * SLOT_META + OBJECT_FIXED + ALLOWANCE
def bitmap_cache_bytes_field(row_cache_field):
    return row_cache_field                   # as ledgered (object + words*8; allowance is separate)
act = json.load(open(f"{R}/C2-integrated-activation-mac.json"))["activation"]["maps"]
cfg = json.load(open(f"{R}/C2-integrated-configured-mac.json"))["configured_tick"]["maps"]
out = {"slots": SLOTS, "list_cache_bytes": {str(k): list_cache_bytes(k) for k in NONZERO}, "rows": []}
worst = {"shared_331": 0, "total_331": 0, "shared_1300": 0, "total_1300": 0, "colossal_total_331": 0, "colossal_total_1300_conservative": 0}
for r in act:
    ret = r["retained"]; old = ret["shared_danger_source_cache"]; new = list_cache_bytes(331)
    delta = new - old
    shared = r["shared_retained_upper_bound_bytes"] + delta; total = ret["total"] + delta
    row = {"map": r["map"], "range_px": 331, "colossal": r["colossal"], "shared_before": r["shared_retained_upper_bound_bytes"], "shared_after": shared, "total_before": ret["total"], "total_after": total}
    if r["colossal"]:
        # conservative: colossal at 1300 px = replace 331 cache with 1300 list and 331 geometry with 1300 geometry
        geom_331 = ret["shared_danger_geometry"]; sight = geom_331 - KERNEL_BYTES[331] - PERIMETER_BYTES[331]   # object + sightBlocked
        geom_1300 = sight + KERNEL_BYTES[1300] + PERIMETER_BYTES[1300]
        total_1300 = ret["total"] - old + list_cache_bytes(1300) - geom_331 + geom_1300
        row.update({"geometry_331": geom_331, "geometry_1300_est": geom_1300, "total_after_1300_conservative": total_1300})
        worst["colossal_total_331"] = max(worst["colossal_total_331"], total); worst["colossal_total_1300_conservative"] = max(worst["colossal_total_1300_conservative"], total_1300)
    else:
        worst["shared_331"] = max(worst["shared_331"], shared); worst["total_331"] = max(worst["total_331"], total)
    out["rows"].append(row)
for m in cfg:
    r = m["activation"]; ret = r["retained"]; old = ret["shared_danger_source_cache"]; new = list_cache_bytes(1300)
    delta = new - old
    shared = r["shared_retained_upper_bound_bytes"] + delta; total = ret["total"] + delta
    out["rows"].append({"map": m["map"], "range_px": 1300, "colossal": False, "shared_before": r["shared_retained_upper_bound_bytes"], "shared_after": shared, "total_before": ret["total"], "total_after": total})
    worst["shared_1300"] = max(worst["shared_1300"], shared); worst["total_1300"] = max(worst["total_1300"], total)
out["worst"] = worst
out["margins"] = {"shared_1300_vs_64MiB": CAP_SHARED_AUTH - worst["shared_1300"], "shared_1300_vs_32MiB": CAP_SHARED_NOW - worst["shared_1300"],
                  "shared_331_vs_32MiB": CAP_SHARED_NOW - worst["shared_331"], "colossal_331_vs_256MiB": CAP_TOTAL - worst["colossal_total_331"],
                  "colossal_1300_conservative_vs_256MiB": CAP_TOTAL - worst["colossal_total_1300_conservative"], "total_1300_vs_256MiB": CAP_TOTAL - worst["total_1300"]}
print(json.dumps(out, indent=1))
