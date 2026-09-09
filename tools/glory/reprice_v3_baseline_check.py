#!/usr/bin/env python3
"""GLORY GRADIENT S4 FREEZE — static re-attribution of the SAME 4,880 census
seat-episodes under CATALOG-V3-DRAFT's proposed re-pricing.

STATIC PASS ONLY: re-prices RECORDED events (the same jsonl streams
attribution_decompose.py already reads), no sim, no rig, no new episodes.
Reuses attribution_decompose.py's own per-event method verbatim (same
content field parsing, same bucket set, same HANDED/CONSTANT/CHOSEN
semantics from docs/designs/glory/TOP-ATTRIBUTION.md) and only swaps in
new base-class / heat-ladder / achievement-tier values where CATALOG-V3
proposes a reprice. Buckets that are NOT repriced use the EXACT SAME
values #494 already measured.

Base-class values are allowed to be fractional here on purpose: this
script measures MAGNITUDE ALLOCATION (log2 shares) under a proposed
pricing, not the wire's integer representation -- that engine-side
question (percent-scaled fixed point, SCALE=2^10) is a separate,
already-decided concern (CATALOG-V3-DRAFT.md Section 9).
"""
import argparse, json, math, os, statistics
from collections import Counter, defaultdict

CAP = 2 ** 24

# ---- BASELINE CHECK: NO reprice, only the dJointAct era-split applied --
# every value here matches #494's OWN original RECUT_CLASS_TABLE exactly,
# so the ONLY change from #494's published 11.14% is the reclassification.
NEW_BASE_CLASS = {
    "dFinal8": 2, "dFinal4": 3, "dFinal2": 4,
    "dClosingTime": 2, "dClosingTime_winbumped": 3, "dJointAct": 2,
    "dHonorableKill": 1, "dShieldSoak": 1, "dClutchHeal": 1,
    "dPointBlankKill": 1, "dLevelUp": 1,
    "dFirstBlood": 2, "dLongshotKill": 3, "dSplashMultiKill": 3,
    "dRevengeKill": 2, "dRunDown": 2, "dAceTag": 4, "dLastLight": 4,
}
TERRITORY_SCALE = 1.0
HEAT_REMAP = {1: 1, 2: 2, 4: 4, 8: 8}
STACK_SCALE = 1.0
CLEAN_SHEET_NEW_AMT = 2                     # treeSquad tier IV (0-idx hp=3), unchanged
SHARPSHOOTER_SCALE = 1.0                    # treeGun tier V (hp=4), unchanged

RECIPE_DEEDS = {"dClosingTime"}  # dJointAct reclassified below (era-split)
PLACEMENT_DEEDS = {"dFinal8", "dFinal4", "dFinal2"}
# JOINTACT_R4517_BOUNDARY: lead ruling -- dJointAct fires unconditionally
# (CONSTANT) for rounds BEFORE r4517, and only inside a declared/formed
# pact (CHOSEN -- pact formation is the hardest choice on the board) from
# r4517 onward. OBSERVED in this population's own coworld_version map, not
# assumed: r4515/4516 = coworld_version 0.7.361; r4517+ = 0.7.362 and
# later -- a clean build boundary exactly at r4517, matching the ruling.
JOINTACT_R4517_BOUNDARY = 4517
BUCKETS = ["RECIPE_BASE", "PLACEMENT_BASE", "OTHER_DEED_BASE", "HEAT",
           "CARRY", "ALLY_STACK", "TERRITORY", "ACHIEVEMENTS", "WIN",
           "FRIENDLY_FIRE", "UNRESOLVED", "JOINTACT_CHOSEN"]
CHOSEN = {"RECIPE_BASE", "OTHER_DEED_BASE", "HEAT", "ALLY_STACK",
          "TERRITORY", "ACHIEVEMENTS", "CARRY"}
HANDED = {"PLACEMENT_BASE", "WIN"}
# S4's own 3-way refinement of #494's CHOSEN set, per TOP-ATTRIBUTION.md's
# own prose (not invented here): RECIPE_BASE/ACHIEVEMENTS/TERRITORY read as
# "closer to a constant" (automatic timing, one-shot claim, map geometry);
# OTHER_DEED_BASE/HEAT/ALLY_STACK/CARRY are the "genuinely graded" ~11%.
CONSTANT_OF_CHOSEN = {"RECIPE_BASE", "ACHIEVEMENTS", "TERRITORY"}
CHOSEN_STRICT = {"OTHER_DEED_BASE", "HEAT", "ALLY_STACK", "CARRY",
                 "JOINTACT_CHOSEN"}


def new_base(weapon, old_base):
    if weapon in NEW_BASE_CLASS:
        return NEW_BASE_CLASS[weapon]
    return old_base


def decompose_episode(jsonl_path, round_number):
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    n = None
    for e in lines:
        if e.get("kind") == "phase":
            continue
    # slot count: infer from max target index across relevant events + 1
    max_slot = -1
    for e in lines:
        if e.get("kind") in ("glory_deed", "achievement"):
            t = e.get("target")
            if t is not None and t > max_slot:
                max_slot = t
    n = max_slot + 1
    if n <= 0:
        return None

    deed_product = {s: 1.0 for s in range(n)}
    ach_product = {s: 1.0 for s in range(n)}
    ff = {s: 0 for s in range(n)}
    buckets = {s: Counter() for s in range(n)}

    for e in lines:
        kind = e.get("kind")
        if kind not in ("glory_deed", "achievement"):
            continue
        t = e.get("target")
        if t is None or t < 0 or t >= n:
            continue
        weapon = e.get("weapon", "")
        amt = e.get("amount") or 0

        if kind == "achievement":
            if not (amt and amt > 1):
                continue
            tier = e.get("hp", -1)
            eff_amt = amt
            if weapon == "treeSquad" and tier == 3:  # 0-idx tier IV = Clean Sheet
                eff_amt = CLEAN_SHEET_NEW_AMT
            elif weapon == "treeGun" and tier == 4:  # 0-idx tier V = Sharpshooter
                # amt already includes the FIRST-claim x3 where it applies;
                # scale the whole claim down uniformly in log2 space.
                eff_amt = max(1.01, amt ** SHARPSHOOTER_SCALE)
            ach_product[t] *= eff_amt
            buckets[t]["ACHIEVEMENTS"] += math.log2(eff_amt)
            continue

        # glory_deed
        if weapon == "dTeamKill":
            ff[t] += 1
            continue
        if not amt or amt <= 1:
            continue

        content = e.get("content") or ""
        parts = content.split("|") if content else []
        if len(parts) != 4:
            buckets[t]["UNRESOLVED"] += math.log2(amt)
            deed_product[t] *= amt
            continue
        shifted_class, heat_m, carry_m, stack_m = (int(x) for x in parts)
        recombined = shifted_class * heat_m * carry_m * stack_m
        if recombined != amt:
            buckets[t]["UNRESOLVED"] += math.log2(amt)
            deed_product[t] *= amt
            continue

        old_base = 3 if (weapon == "dClosingTime" and shifted_class >= 3) else \
                   ({"dFinal8": 2, "dFinal4": 3, "dFinal2": 4,
                     "dJointAct": 2}.get(weapon) or
                    (1 if weapon in ("dHonorableKill", "dSprayKill",
                                     "dGrenadeKill", "dPointBlankKill",
                                     "dTeamKill", "dClutchHeal",
                                     "dShieldSoak", "dLevelUp",
                                     "dAchievement") else
                     {"dFirstBlood": 2, "dLongshotKill": 3,
                      "dSplashMultiKill": 3, "dRevengeKill": 2,
                      "dRunDown": 2, "dAceTag": 4, "dFlagSteal": 4,
                      "dCapture": 8, "dCarrierKill": 4, "dDenial": 6,
                      "dEscortKill": 2, "dAssist": 2, "dRescue": 2,
                      "dWipe": 8, "dDuoDown": 2, "dLastLight": 4,
                      "dVictory": 8, "dTagBack": 2}.get(weapon, 1)))
        territory_fired = shifted_class > old_base
        # NEW base for magnitude purposes:
        if weapon == "dClosingTime":
            b = NEW_BASE_CLASS["dClosingTime_winbumped"] if old_base >= 3 else NEW_BASE_CLASS["dClosingTime"]
        else:
            b = new_base(weapon, old_base)

        base_log2 = math.log2(b) if b > 1 else 0.0
        # Territory: keep the OLD ratio's magnitude, then apply the
        # design-law's shrink factor to it (still riding on the SAME
        # recorded firing events, not fabricated).
        territory_log2 = ((math.log2(shifted_class) - math.log2(old_base))
                           * TERRITORY_SCALE if territory_fired else 0.0)
        heat_new = HEAT_REMAP.get(heat_m, heat_m)
        heat_log2 = math.log2(heat_new) if heat_new > 1 else 0.0
        carry_log2 = math.log2(carry_m) if carry_m > 1 else 0.0
        stack_new = stack_m * STACK_SCALE if stack_m > 1 else stack_m
        stack_log2 = math.log2(stack_new) if stack_new > 1 else 0.0

        deed_product[t] *= b  # not used for recon (float), only for reference

        if weapon == "dJointAct":
            # Era-split reclassification (lead ruling): unconditional
            # pre-r4517 firing stays CONSTANT (RECIPE_BASE); pact-gated
            # r4517+ firing is CHOSEN (pact formation is the hardest
            # choice on the board) -- routed to its own bucket so the
            # split is auditable, not silently merged into another one.
            if round_number < JOINTACT_R4517_BOUNDARY:
                buckets[t]["RECIPE_BASE"] += base_log2
            else:
                buckets[t]["JOINTACT_CHOSEN"] += base_log2
        elif weapon in RECIPE_DEEDS:
            buckets[t]["RECIPE_BASE"] += base_log2
        elif weapon in PLACEMENT_DEEDS:
            buckets[t]["PLACEMENT_BASE"] += base_log2
        else:
            buckets[t]["OTHER_DEED_BASE"] += base_log2
        buckets[t]["HEAT"] += heat_log2
        buckets[t]["CARRY"] += carry_log2
        buckets[t]["ALLY_STACK"] += stack_log2
        buckets[t]["TERRITORY"] += territory_log2

    rows = []
    for s in range(n):
        rows.append(dict(slot=s, buckets=dict(buckets[s]), ff_halvings=ff[s]))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--census-rows", default="/tmp/glory-census/seat_episode_rows_final.json")
    ap.add_argument("--attr-dir", default="/tmp/glory-attr/replays")
    args = ap.parse_args()

    with open(args.census_rows) as f:
        census_rows = json.load(f)
    by_ep_slot = {(r["episode_id"], r["slot"]): r for r in census_rows}
    episode_ids = sorted(set(r["episode_id"] for r in census_rows))

    ep_round = {r["episode_id"]: r["round_number"] for r in census_rows}
    pre_seat_rows = sum(1 for r in census_rows if r["round_number"] < JOINTACT_R4517_BOUNDARY)
    post_seat_rows = sum(1 for r in census_rows if r["round_number"] >= JOINTACT_R4517_BOUNDARY)
    print(f"JOINTACT ERA SPLIT: {pre_seat_rows} seat-episode rows pre-r{JOINTACT_R4517_BOUNDARY} "
          f"(CONSTANT), {post_seat_rows} rows at/after r{JOINTACT_R4517_BOUNDARY} (CHOSEN) "
          f"-- total {pre_seat_rows + post_seat_rows}")

    all_rows = []
    pre_boundary_rows = 0
    post_boundary_rows = 0
    for eid in episode_ids:
        jp = os.path.join(args.attr_dir, f"{eid}.jsonl")
        if not os.path.exists(jp):
            continue
        rn = ep_round.get(eid)
        if rn is None:
            continue
        if rn < JOINTACT_R4517_BOUNDARY:
            pre_boundary_rows += 1
        else:
            post_boundary_rows += 1
        decomposed = decompose_episode(jp, rn)
        if decomposed is None:
            continue
        for d in decomposed:
            key = (eid, d["slot"])
            census = by_ep_slot.get(key)
            if census is None:
                continue
            d["episode_id"] = eid
            d["win"] = census["win"]
            d["reported_old"] = census["reported"]  # OLD pricing, for population selection
            win_mult = 8 if d["win"] else 1
            if d["win"]:
                d["buckets"]["WIN"] = d["buckets"].get("WIN", 0.0) + math.log2(8)
            if d["ff_halvings"]:
                d["buckets"]["FRIENDLY_FIRE"] = d["buckets"].get("FRIENDLY_FIRE", 0.0) - d["ff_halvings"]
            # NEW total magnitude (float log2 domain -- this IS the "recon"
            # for the repriced trial; no integer wire representation implied)
            total_log2 = sum(v for k, v in d["buckets"].items() if k != "FRIENDLY_FIRE") \
                         + d["buckets"].get("FRIENDLY_FIRE", 0.0)
            d["new_log2_total"] = total_log2
            all_rows.append(d)

    print(f"decomposed {len(all_rows)} seat-episodes under CATALOG-V3 pricing")

    def report_population(rows, label):
        vals = []
        per_bucket_shares = defaultdict(list)
        for r in rows:
            denom = r["new_log2_total"] - r["buckets"].get("FRIENDLY_FIRE", 0.0)
            if denom <= 0.01:
                continue
            for b in BUCKETS:
                v = r["buckets"].get(b, 0.0)
                per_bucket_shares[b].append(v / denom)
        print(f"\n=== {label}: n={len(rows)} ===")
        handed = constant = chosen = 0.0
        for b in BUCKETS:
            if b not in per_bucket_shares or not per_bucket_shares[b]:
                continue
            m = statistics.mean(per_bucket_shares[b])
            print(f"  {b:<16}{100*m:>8.2f}%")
            if b in HANDED: handed += m
            if b in CONSTANT_OF_CHOSEN: constant += m
            if b in CHOSEN_STRICT: chosen += m
        print(f"  ---")
        print(f"  HANDED   = {100*handed:.2f}%")
        print(f"  CONSTANT = {100*constant:.2f}%")
        print(f"  CHOSEN   = {100*chosen:.2f}%")
        return handed, constant, chosen

    # Population selection on the NEW (repriced) distribution's own points
    # (log2 total) -- consistent with the S3-signed ladder's own units and
    # with what "a top-decile ROUND UNDER CATALOG V3" actually means. Also
    # report the OLD-selection population for comparison/transparency.
    new_points = sorted(r["new_log2_total"] for r in all_rows)
    def pctn(p):
        k = (len(new_points) - 1) * p
        f, c = math.floor(k), math.ceil(k)
        if f == c: return new_points[int(k)]
        return new_points[f] + (new_points[c] - new_points[f]) * (k - f)
    p90n = pctn(0.90)
    print(f"NEW-pricing points percentiles: p90={p90n:.3f} bits")
    top_new = [r for r in all_rows if r["new_log2_total"] >= p90n]
    mid_new = [r for r in all_rows if 2.0 <= r["new_log2_total"] <= 8.0]  # S3 ladder's own MID band, 2-8 pts

    report_population(top_new, f"TOP DECILE under NEW pricing (p90={p90n:.2f} pts)")
    report_population(mid_new, "MID BAND under NEW pricing (S3 ladder: 2-8 pts)")

    scores_old = sorted(r["reported_old"] for r in all_rows)
    def pct(p):
        k = (len(scores_old) - 1) * p
        f, c = math.floor(k), math.ceil(k)
        if f == c: return scores_old[int(k)]
        return scores_old[f] + (scores_old[c] - scores_old[f]) * (k - f)
    p90 = pct(0.90)
    print(f"\n[for comparison] OLD-pricing p90 threshold = {p90}")
    top_old = [r for r in all_rows if r["reported_old"] >= p90]
    report_population(top_old, "TOP DECILE under OLD-selection population (repriced)")


if __name__ == "__main__":
    main()
