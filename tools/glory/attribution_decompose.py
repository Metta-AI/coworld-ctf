#!/usr/bin/env python3
"""GLORY GRADIENT S1b — TOP-DECILE ATTRIBUTION: full per-seat-episode
decomposition of the recut product into every named contributor (recipe
legs, achievements, heat, carry, ally-stack, territory, placement, FF
divisions), not just the aggregate recipe share the census (Q4) measured.

Reuses the SAME population and SAME cached replays as
`tools/glory/census_decode.py` (era: GloryVersion 15, coworld_version
0.7.361-0.7.367, rounds r4515-r4539, 305 episodes, 4,880 seat-episodes). It
does not re-download anything.

Per-event decomposition needs ground truth this population's existing
tooling never captured: the live-state sub-factors (heat rung, carry flag,
ally-stack k, territory site) that were folded into each glory_deed event's
`amount` at mint time (glory.nim `recutFactor`). Those sub-factors are NOT
independently recoverable from the wire by observation alone (heat/carry/
stack/territory are transient sim state, not serialized fields) --
statistically inferring them risks exactly the kind of confident-wrong
attribution this investigation exists to avoid.

So this reads them from an ANALYSIS-ONLY instrumented `extract_events`
binary (private local build, never lands in the shipped repo -- see
docs/designs/glory/TOP-ATTRIBUTION.md's "Method" section for the full diff
and rationale): one line at the exact `recutFactor` call site
(src/ctf/sim.nim `awardDeed`) now stashes
"shiftedClass|heatMult|carryMult|stackMult" into the tier-2 GloryDeed
event's existing `content` field (analysis-only wire slot: "" on the live
path, never enters gameHash -- events.nim's own doc comment). Zero
sim/scoring behavior change; the instrumented binaries are built at
permanent paths under ~/.ctf/pipeline-loop/tools/attr_gv{59,60}_build,
exactly like the census's own extractor binaries.

Usage:
  python3 attribution_decompose.py \\
      --rows seat_episode_rows_final.json \\
      --attr-dir ~/.ctf/scout/glory_attr_replays \\
      --out /tmp/glory-attr/attribution_rows.json
"""
import argparse
import json
import math
import os
import statistics
from collections import Counter, defaultdict

CAP = 2 ** 24

# glory.nim RecutClassTable, verbatim (re-verified against the instrumented
# build's own source at ~/.ctf/pipeline-loop/tools/attr_gv59_build).
RECUT_CLASS_TABLE = {
    "dNone": 1, "dFirstBlood": 2, "dHonorableKill": 1, "dSprayKill": 1,
    "dGrenadeKill": 1, "dPointBlankKill": 1, "dLongshotKill": 3,
    "dSplashMultiKill": 3, "dRevengeKill": 2, "dRunDown": 2, "dAceTag": 4,
    "dTeamKill": 1, "dFlagSteal": 4, "dCapture": 8, "dCarrierKill": 4,
    "dDenial": 6, "dEscortKill": 2, "dAssist": 2, "dRescue": 2,
    "dClutchHeal": 1, "dShieldSoak": 1, "dWipe": 8, "dLevelUp": 1,
    "dAchievement": 1, "dDuoDown": 2, "dClosingTime": 2, "dLastLight": 4,
    "dVictory": 8, "dTagBack": 2, "dJointAct": 2, "dFinal8": 2,
    "dFinal4": 3, "dFinal2": 4,
}
# dClosingTime's own win-conditional base bump (glory.nim recutShiftedClass):
# winAsMultiplier bumps its base 2 -> 3 BEFORE any territory shift. Verified
# universal for this cohort (win_mult=8 always matched in the census's own
# 100.00% reconciliation, i.e. winAsMultiplier is armed for every episode
# here) -- cross-checked per-event below (WINBUMP_MISMATCH counter).
CLOSING_TIME_WINBUMPED_BASE = 3

RECIPE_DEEDS = {"dClosingTime", "dJointAct"}
PLACEMENT_DEEDS = {"dFinal8", "dFinal4", "dFinal2"}

BUCKETS = ["RECIPE_BASE", "PLACEMENT_BASE", "OTHER_DEED_BASE", "HEAT",
           "CARRY", "ALLY_STACK", "TERRITORY", "ACHIEVEMENTS", "WIN",
           "FRIENDLY_FIRE", "UNRESOLVED"]


def base_class_for(deed):
    if deed == "dClosingTime":
        return CLOSING_TIME_WINBUMPED_BASE
    return RECUT_CLASS_TABLE.get(deed, 1)


def decompose_episode(jsonl_path):
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        return None
    n = len(summary["slot_team"])

    deed_product = {s: 1 for s in range(n)}
    ach_product = {s: 1 for s in range(n)}
    ff = {s: 0 for s in range(n)}
    buckets = {s: Counter() for s in range(n)}
    winbump_mismatch = {s: 0 for s in range(n)}
    unresolved_events = {s: 0 for s in range(n)}

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
            if amt and amt > 1:
                ach_product[t] *= amt
                buckets[t]["ACHIEVEMENTS"] += math.log2(amt)
            continue

        # glory_deed
        if weapon == "dTeamKill":
            ff[t] += 1
            continue
        if not amt or amt <= 1:
            continue
        deed_product[t] *= amt

        content = e.get("content") or ""
        parts = content.split("|") if content else []
        if len(parts) != 4:
            # Should not happen for amt>1 on the armed recut path (every
            # positive-factor mint sets `content` before emitting) -- fail
            # LOUD into a named bucket rather than silently misattributing.
            buckets[t]["UNRESOLVED"] += math.log2(amt)
            unresolved_events[t] += 1
            continue
        shifted_class, heat_m, carry_m, stack_m = (int(x) for x in parts)
        recombined = shifted_class * heat_m * carry_m * stack_m
        if recombined != amt:
            buckets[t]["UNRESOLVED"] += math.log2(amt)
            unresolved_events[t] += 1
            continue

        base = base_class_for(weapon)
        if weapon == "dClosingTime" and shifted_class not in (base, base + 1):
            winbump_mismatch[t] += 1
        territory_fired = shifted_class > base
        base_log2 = math.log2(base) if base > 1 else 0.0
        territory_log2 = (math.log2(shifted_class) - math.log2(base)
                           if territory_fired else 0.0)
        heat_log2 = math.log2(heat_m) if heat_m > 1 else 0.0
        carry_log2 = math.log2(carry_m) if carry_m > 1 else 0.0
        stack_log2 = math.log2(stack_m) if stack_m > 1 else 0.0

        if weapon in RECIPE_DEEDS:
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
        rows.append(dict(
            slot=s, deed_product=deed_product[s], ach_product=ach_product[s],
            ff_halvings=ff[s], buckets=dict(buckets[s]),
            winbump_mismatch=winbump_mismatch[s],
            unresolved_events=unresolved_events[s],
        ))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", required=True)
    ap.add_argument("--attr-dir", default=os.path.expanduser(
        "/tmp/glory-attr/replays"))
    ap.add_argument("--out", default="/tmp/glory-attr/attribution_rows.json")
    args = ap.parse_args()

    with open(args.rows) as f:
        census_rows = json.load(f)
    by_ep_slot = {(r["episode_id"], r["slot"]): r for r in census_rows}
    episode_ids = sorted(set(r["episode_id"] for r in census_rows))

    all_rows = []
    mismatches = []
    total_winbump_mismatch = 0
    total_unresolved_events = 0
    missing = []
    for eid in episode_ids:
        jp = os.path.join(args.attr_dir, f"{eid}.jsonl")
        if not os.path.exists(jp):
            missing.append(eid)
            continue
        decomposed = decompose_episode(jp)
        if decomposed is None:
            missing.append(eid)
            continue
        for d in decomposed:
            key = (eid, d["slot"])
            census = by_ep_slot.get(key)
            if census is None:
                continue
            d["episode_id"] = eid
            d["round_number"] = census["round_number"]
            d["win"] = census["win"]
            d["reported"] = census["reported"]
            d["recon_final"] = census["recon_final"]
            total_winbump_mismatch += d["winbump_mismatch"]
            total_unresolved_events += d["unresolved_events"]

            # WIN + FF, applied at finalize (not per-event): fold into the
            # SAME bucket ledger this row already carries so buckets sum to
            # the full log2(recon_final).
            win_mult = 8 if d["win"] else 1
            if d["win"]:
                d["buckets"]["WIN"] = d["buckets"].get("WIN", 0.0) + math.log2(8)
            if d["ff_halvings"]:
                d["buckets"]["FRIENDLY_FIRE"] = (
                    d["buckets"].get("FRIENDLY_FIRE", 0.0) - d["ff_halvings"])

            # INTEGER reconciliation -- identical method to census_decode.py
            # (same amount fields, same halving, same win, same cap), so it
            # must match the ALREADY-VALIDATED recon_final for every row.
            combined = d["deed_product"] * d["ach_product"]
            recon_uncapped = (combined >> d["ff_halvings"]
                               if d["ff_halvings"] else combined)
            recon_uncapped *= win_mult
            recon = min(recon_uncapped, CAP)
            d["recon_uncapped"] = recon_uncapped
            d["capped"] = recon_uncapped >= CAP
            if census["recon_final"] is not None and recon != census["recon_final"]:
                mismatches.append((eid, d["slot"], recon, census["recon_final"]))
            all_rows.append(d)

    print(f"decomposed {len(all_rows)} seat-episodes across "
          f"{len(episode_ids) - len(missing)} episodes "
          f"({len(missing)} episodes missing attribution jsonl)")
    print(f"integer reconciliation vs census recon_final: "
          f"{len(all_rows) - len(mismatches)}/{len(all_rows)} match "
          f"({100*(len(all_rows)-len(mismatches))/len(all_rows):.2f}%)")
    for m in mismatches[:10]:
        print("  MISMATCH", m)
    print(f"per-event breakdown recombination failures (UNRESOLVED bucket "
          f"used): {total_unresolved_events} events")
    print(f"dClosingTime win-bump base assumption mismatches: "
          f"{total_winbump_mismatch}")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(all_rows, f)
    print(f"wrote {len(all_rows)} rows to {args.out}")


if __name__ == "__main__":
    main()
