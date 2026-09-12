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

GLORY GRADIENT S6 (`--catalog v3`, default `v2`): catalog v3 (GLORYVERSION
17 / GameVersion 62+) changed what a wire event's `content` sub-factors and
`amount` mean -- see `tools/glory/catalog_fold.py`'s module docstring for
the fold, and `decompose_episode_v3` below for the v3 decomposition
(percent-scaled sub-shares, the `dJointAct` era-split into a
`JOINTACT_CHOSEN` bucket, and a correction for a real off-by-one-bump
artifact in the private instrumented extractor's own `heatPct` capture).
`--catalog v2` (default) is BYTE-IDENTICAL to this script's original
(pre-S6) behavior -- `decompose_episode` below is unmodified.
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

# ── v3 (catalog_fold.CATALOG_V3) decomposition ──────────────────────────
# Same bucket NAMES as the v2 taxonomy above, plus `JOINTACT_CHOSEN`
# (CATALOG-V3-DRAFT.md's `dJointAct` era-split, lead ruling): post-r4517,
# `dJointAct` fires only inside a declared, formed pact, so its base-class
# leg is CHOSEN, not CONSTANT -- routed to its own bucket rather than
# folded into `RECIPE_BASE`, matching the GV61 read's own "on top of
# attribution_analyze.py's own bucket output" split, but built in natively
# here per round_number instead of as an external post-process.
# `survivalCredit` is the placement ladder's CONTINUOUS twin, not a fourth
# milestone rung -- see catalog_fold.CONTINUOUS_CREDIT_WEAPONS for the
# catalogued semantics and why its bucket is HANDED, not CONSTANT.
V3_PLACEMENT_WEAPONS = (frozenset({"dFinal8", "dFinal4", "dFinal2"})
                         | catalog_fold.CONTINUOUS_CREDIT_WEAPONS)
V3_RECIPE_WEAPONS = {"dClosingTime"}  # dJointAct handled by era-split below


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


def decompose_episode_v3(jsonl_path, round_number, catalog=catalog_fold.CATALOG_V3):
    """Catalog-v3 sibling of `decompose_episode`. Unlike v2 (where
    deed-product and achievement-product can be folded as two INDEPENDENT
    running multiplies and combined at the end, because plain multiplication
    is order-independent), v3 folds deeds AND achievements into ONE shared,
    ORDER- and STATE-dependent accumulator (GATE RULING 2's floor guard
    reads the CURRENT combined product) -- so this walks every
    glory_deed/achievement event for a seat in chronological (tick) order
    against a single running `product`, exactly like
    `catalog_fold.fold_events_v3`, and attributes each event's REAL log2
    contribution (`log2(after) - log2(before)`, zero for any event GATE
    RULING 2 or the `pct<=100` identity skipped) rather than trusting the
    wire `amount` blindly -- this is what makes each row's bucket sum equal
    `log2(reported)` exactly, including the (empirically zero, for GV62)
    cap-saturation edge case.
    """
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        return None
    n = len(summary["slot_team"])

    product = {s: (catalog.scale if catalog.gloryFixedPointScale else 1) for s in range(n)}
    ff = {s: 0 for s in range(n)}
    buckets = {s: Counter() for s in range(n)}
    unresolved_events = {s: 0 for s in range(n)}

    events = sorted(
        (e for e in lines if e.get("kind") in ("glory_deed", "achievement")),
        key=lambda e: e.get("tick") or 0,
    )
    for e in events:
        t = e.get("target")
        if t is None or t < 0 or t >= n:
            continue
        kind = e.get("kind")
        weapon = e.get("weapon", "")
        amt = e.get("amount") or 0

        if kind == "glory_deed" and weapon == "dTeamKill":
            ff[t] += 1
            continue
        if kind == "glory_deed" and weapon in catalog_fold.NON_FOLD_MARKER_WEAPONS:
            continue  # capHit/pactWipe/pactDuoDown: never folded (see catalog_fold)
        if not amt:
            continue

        before = product[t]
        if kind == "glory_deed" and weapon in catalog_fold.WHOLE_INTEGER_MARKUP_WEAPONS:
            after = catalog_fold.recut_fold(before, amt, catalog.cap)
        else:
            after = catalog_fold.recut_fold_pct(before, amt, catalog.cap, catalog.scale)
        product[t] = after
        if after == before:
            continue  # real no-op (pct<=100 identity OR GATE RULING 2 skip)
        contribution_log2 = math.log2(after) - math.log2(before)

        if kind == "achievement":
            buckets[t]["ACHIEVEMENTS"] += contribution_log2
            continue

        # glory_deed, folded, needs a named bucket + (where possible) a
        # class/heat/carry/stack/territory sub-split.
        content = e.get("content") or ""
        parts = content.split("|")
        if weapon in catalog_fold.CONTINUOUS_CREDIT_WEAPONS or len(parts) != 4:
            # survivalCredit's content is a plain marker string ("GLORY_
            # SURVIVAL_CREDIT"), not a 4-part tuple -- it is the placement
            # ramp's own continuous companion credit (CATALOG-V3-DRAFT.md
            # Sec 4), bucketed PLACEMENT_BASE wholesale, no sub-split.
            if weapon in catalog_fold.CONTINUOUS_CREDIT_WEAPONS:
                buckets[t]["PLACEMENT_BASE"] += contribution_log2
            else:
                buckets[t]["UNRESOLVED"] += contribution_log2
                unresolved_events[t] += 1
            continue

        try:
            class_pct, _dirty_heat_pct, carry_pct, stack_pct = (int(x) for x in parts)
        except ValueError:
            buckets[t]["UNRESOLVED"] += contribution_log2
            unresolved_events[t] += 1
            continue

        pays_heat = weapon in catalog_fold.HEAT_PAYING_DEEDS
        heat_pct = catalog_fold.backsolve_heat_pct_v3(
            class_pct, carry_pct, stack_pct, amt, pays_heat)
        if heat_pct is None:
            buckets[t]["UNRESOLVED"] += contribution_log2
            unresolved_events[t] += 1
            continue

        if weapon in catalog_fold.PLACEMENT_RAMP_DEEDS:
            # ERA-KEYED (not HEAD's ladder): #538 moved this table, and a
            # pre-S8 row's placement mints priced off the OLD rungs.
            base = catalog.placement_ramp_pct[weapon]
        elif weapon == "dClosingTime":
            base = (catalog_fold.RECUT_CLOSING_TIME_WIN_BUMP_V3_PCT if catalog.winAsMultiplier
                    else catalog_fold.RECUT_CLASS_TABLE_V3_PCT["dClosingTime"])
        else:
            base = catalog_fold.RECUT_CLASS_TABLE_V3_PCT.get(weapon, 100)

        territory_fired = class_pct > base
        base_log2 = math.log2(base / 100) if base > 100 else 0.0
        territory_log2 = math.log2(class_pct / base) if territory_fired else 0.0
        heat_log2 = math.log2(heat_pct / 100) if heat_pct > 100 else 0.0
        carry_log2 = math.log2(carry_pct / 100) if carry_pct > 100 else 0.0
        stack_log2 = math.log2(stack_pct / 100) if stack_pct > 100 else 0.0
        predicted_sum = base_log2 + territory_log2 + heat_log2 + carry_log2 + stack_log2

        # `recutFoldPct` truncates (`(product*pct)//100`) EVERY fold -- the
        # realized `contribution_log2` (from the actual, truncated integer
        # `before`/`after`) is therefore always a hair below the NOMINAL
        # `predicted_sum` (from the clean class/heat/carry/stack percents
        # alone), by construction, not by bug: this is exactly the
        # `GlorySCALE`-sized drift `tests/test_glory_percent_scale_
        # headroom.nim` measured and bounded at "worst-case 0.131% across
        # every tested seed" (glory.nim's own `GlorySCALE` doc comment).
        # Rescale the nominal sub-shares onto the REALIZED delta so the
        # bucket sum equals `contribution_log2` EXACTLY (the row-sums-to-
        # reported invariant this whole decomposition exists to prove),
        # while still reporting each bucket's correct RELATIVE share.
        # `rel_err` catches a genuine misclassification (wrong base/heat
        # table entry), which would miss by far more than truncation drift
        # -- flagged to UNRESOLVED with real headroom above the measured
        # drift bound, not fudged through.
        rel_err = (abs(predicted_sum - contribution_log2) / abs(contribution_log2)
                   if contribution_log2 else abs(predicted_sum))
        if predicted_sum == 0 or rel_err > 0.02:
            # Zero observed on the measured GV62 cohort (Q3 cap-hit is
            # 0/5,456): only reachable on a genuine misclassification or a
            # cap-saturating fold. Report the real delta as UNRESOLVED
            # rather than a decomposition that would misstate the row.
            buckets[t]["UNRESOLVED"] += contribution_log2
            unresolved_events[t] += 1
            continue
        rescale = contribution_log2 / predicted_sum
        base_log2 *= rescale
        territory_log2 *= rescale
        heat_log2 *= rescale
        carry_log2 *= rescale
        stack_log2 *= rescale

        if weapon in catalog_fold.PLACEMENT_RAMP_DEEDS:
            buckets[t]["PLACEMENT_BASE"] += base_log2
        elif weapon == "dJointAct":
            bucket = ("JOINTACT_CHOSEN" if round_number > catalog_fold.JOINTACT_ERA_SPLIT_ROUND
                      else "RECIPE_BASE")
            buckets[t][bucket] += base_log2
        elif weapon in V3_RECIPE_WEAPONS:
            buckets[t]["RECIPE_BASE"] += base_log2
        else:
            buckets[t]["OTHER_DEED_BASE"] += base_log2
        buckets[t]["HEAT"] += heat_log2
        buckets[t]["CARRY"] += carry_log2
        buckets[t]["ALLY_STACK"] += stack_log2
        buckets[t]["TERRITORY"] += territory_log2

    rows = []
    for s in range(n):
        rows.append(dict(
            slot=s, product=product[s], ff_halvings=ff[s],
            buckets=dict(buckets[s]), unresolved_events=unresolved_events[s],
        ))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", required=True)
    ap.add_argument("--attr-dir", default=os.path.expanduser(
        "/tmp/glory-attr/replays"))
    ap.add_argument("--out", default="/tmp/glory-attr/attribution_rows.json")
    ap.add_argument("--catalog", choices=["v2", "v3"], default="v2",
                     help="'v2' (default, ORIGINAL behavior -- every "
                          "existing invocation is UNCHANGED) or 'v3' "
                          "(percent-scaled fixed-point fold + the "
                          "dJointAct era-split; see catalog_fold.py)")
    ap.add_argument("--glory-version", type=int, default=None,
                     help="ESCAPE HATCH ONLY. Force every episode's fold to "
                          "use this GLORYVERSION's glory.nim constants. "
                          "Leave unset: the era is derived per episode from "
                          "its own coworld_version (catalog_fold.py, "
                          "'ERA KEYING')")
    args = ap.parse_args()
    catalog_template = (catalog_fold.CATALOG_V3 if args.catalog == "v3"
                        else catalog_fold.CATALOG_V2)

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
        some_census_row = next((r for r in census_rows if r["episode_id"] == eid), None)
        round_number = some_census_row["round_number"] if some_census_row else 0
        era = args.glory_version
        if era is None:
            era = catalog_fold.glory_version_for_build(
                (some_census_row or {}).get("coworld_version"))
        catalog = catalog_template.for_era(era)
        if args.catalog == "v3":
            decomposed = decompose_episode_v3(jp, round_number, catalog)
        else:
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
            total_winbump_mismatch += d.get("winbump_mismatch", 0)
            total_unresolved_events += d["unresolved_events"]

            if args.catalog == "v3":
                # WIN, applied at finalize (invisible on the wire -- see
                # catalog_fold.py module docstring), folds via the classic
                # WHOLE-INTEGER `recutFold` (never `recutFoldPct`) even
                # under v3 -- same as census_decode.py's own v3 branch.
                product_final = d["product"]
                if d["win"]:
                    winner_seats = sum(
                        1 for r in census_rows
                        if r["episode_id"] == eid and r["win"])
                    win_factor = catalog_fold.recut_win_factor(
                        catalog.brMode, winner_seats)
                    before_win = product_final
                    product_final = catalog_fold.recut_fold(
                        product_final, win_factor, catalog.cap)
                    if product_final != before_win:
                        d["buckets"]["WIN"] = (d["buckets"].get("WIN", 0.0)
                                                + math.log2(win_factor))
                if d["ff_halvings"]:
                    d["buckets"]["FRIENDLY_FIRE"] = (
                        d["buckets"].get("FRIENDLY_FIRE", 0.0) - d["ff_halvings"])
                recon = catalog_fold.score_from_product(product_final, d["ff_halvings"], catalog)
                # NOTE: unlike v2's Python-side reconstruction (which
                # multiplies every raw amount then caps ONCE at the end, so
                # it can recover a true "uncapped" magnitude for a capped
                # row), v3's fold saturates AT THE CAP mid-sequence exactly
                # like the real sim (sticky cap) -- there is no recoverable
                # "true uncapped" value once `product_final` has clamped.
                # `recon_uncapped` therefore falls back to the capped score
                # itself here; this is unreached on the measured GV62
                # cohort (Q3 cap-hit = 0/5456) and flagged rather than
                # silently assumed correct for a future cap-hitting cohort.
                d["recon_uncapped"] = recon
                d["capped"] = product_final >= catalog.cap
            else:
                # WIN + FF, applied at finalize (not per-event): fold into
                # the SAME bucket ledger this row already carries so
                # buckets sum to the full log2(recon_final).
                win_mult = 8 if d["win"] else 1
                if d["win"]:
                    d["buckets"]["WIN"] = d["buckets"].get("WIN", 0.0) + math.log2(8)
                if d["ff_halvings"]:
                    d["buckets"]["FRIENDLY_FIRE"] = (
                        d["buckets"].get("FRIENDLY_FIRE", 0.0) - d["ff_halvings"])

                # INTEGER reconciliation -- identical method to
                # census_decode.py (same amount fields, same halving, same
                # win, same cap), so it must match the ALREADY-VALIDATED
                # recon_final for every row.
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
