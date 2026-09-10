#!/usr/bin/env python3
"""C9 ledger projection over the integrated C2+V1 ledgers: the cache keeps the
C2 bitmap payload AND adds the list payload, lengths and a second seq owner.
Both capacities are retained by construction (preallocated), so both are
counted at capacity. Usage: c9_memory_calc.py <research dir> [slots=64]"""
import json, sys
R = sys.argv[1]; SLOTS = int(sys.argv[2]) if len(sys.argv) > 2 else 64
NONZERO = {331: 5385, 1300: 54173}; WORDS = {331: 113, 1300: 1671}
ENTRY = 8; SLOT_META_EXTRA = 4            # listLength int32 added to each slot (key int32 + lastUse uint64 already there)
OBJECT_BITMAP = 1056                       # measured C2 object (slots array + words + seq + clock)
ALLOWANCE = 16                             # per seq allocation (bitmap seq already has one; list seq adds one)
KERNEL = {331: 85*85*4, 1300: 327*327*4}; PERIM = {331: 236*16, 1300: 924*16}
CAP_SHARED_AUTH = 64*1024*1024; CAP_SHARED_NOW = 32*1024*1024; CAP_TOTAL = 256*1024*1024
def c9_cache_bytes(rng):
    bitmap = SLOTS * WORDS[rng] * 8
    lst = SLOTS * NONZERO[rng] * ENTRY
    obj = OBJECT_BITMAP + SLOTS * SLOT_META_EXTRA + 16   # + list seq/capacity fields
    return {"bitmap_payload": bitmap, "list_payload": lst, "object": obj, "extra_allowance": ALLOWANCE,
            "field_total": bitmap + lst + obj, "with_allowance": bitmap + lst + obj + ALLOWANCE}
def c2_field(rng): return OBJECT_BITMAP + SLOTS * WORDS[rng] * 8
act = json.load(open(f"{R}/C2-integrated-activation-mac.json"))["activation"]["maps"]
cfg = json.load(open(f"{R}/C2-integrated-configured-mac.json"))["configured_tick"]["maps"]
out = {"slots": SLOTS, "c9_cache": {str(k): c9_cache_bytes(k) for k in NONZERO}, "rows": []}
worst = {"shared_331": 0, "shared_1300": 0, "total_1300": 0, "colossal_331": 0, "colossal_1300_conservative": 0}
for r in act:
    ret = r["retained"]; old = ret["shared_danger_source_cache"]; assert old == c2_field(331), (old, c2_field(331))
    delta = c9_cache_bytes(331)["with_allowance"] - old
    shared = r["shared_retained_upper_bound_bytes"] + delta; total = ret["total"] + delta
    row = {"map": r["map"], "range_px": 331, "colossal": r["colossal"], "shared_after": shared, "total_after": total}
    if r["colossal"]:
        geom331 = ret["shared_danger_geometry"]; sight = geom331 - KERNEL[331] - PERIM[331]
        geom1300 = sight + KERNEL[1300] + PERIM[1300]
        total1300 = ret["total"] - old + c9_cache_bytes(1300)["with_allowance"] - geom331 + geom1300
        row["total_after_1300_conservative"] = total1300
        worst["colossal_331"] = max(worst["colossal_331"], total); worst["colossal_1300_conservative"] = max(worst["colossal_1300_conservative"], total1300)
    else:
        worst["shared_331"] = max(worst["shared_331"], shared)
    out["rows"].append(row)
for m in cfg:
    r = m["activation"]; ret = r["retained"]; old = ret["shared_danger_source_cache"]; assert old == c2_field(1300)
    delta = c9_cache_bytes(1300)["with_allowance"] - old
    shared = r["shared_retained_upper_bound_bytes"] + delta; total = ret["total"] + delta
    out["rows"].append({"map": m["map"], "range_px": 1300, "colossal": False, "shared_after": shared, "total_after": total})
    worst["shared_1300"] = max(worst["shared_1300"], shared); worst["total_1300"] = max(worst["total_1300"], total)
out["worst"] = worst
out["margins"] = {"shared_1300_vs_64MiB": CAP_SHARED_AUTH - worst["shared_1300"], "shared_1300_vs_32MiB": CAP_SHARED_NOW - worst["shared_1300"],
                  "shared_331_vs_32MiB": CAP_SHARED_NOW - worst["shared_331"], "colossal_331_vs_256MiB": CAP_TOTAL - worst["colossal_331"],
                  "colossal_1300_conservative_vs_256MiB": CAP_TOTAL - worst["colossal_1300_conservative"]}
print(json.dumps(out, indent=1))
