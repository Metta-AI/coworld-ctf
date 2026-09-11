#!/usr/bin/env python3
"""GLORY GRADIENT S7 — cap-ceiling empirical re-fold sweep.

Replays the cached GV62 per-seat-episode wire event streams (already
extracted, OFFLINE, by this program's own S6 tooling -- no live network
here) through `catalog_fold.py`'s v3 fold state machine, with TWO swept
parameters instead of the two fixed real-economy values:

  1. `cap` -- the `RecutProductCapArmed` ceiling. The GV62 (S6-era) value
     this module's harness proof pins is `int64(1) shl 24` = 16,777,216
     internal units / 16,384 reported at `GlorySCALE`=1024; GLORY GRADIENT
     S8 (#538) moved the LIVE one to `shl 31`, which is exactly why
     `catalog_fold.py` now keys that constant BY ERA
     (`recut_product_cap_armed(glory_version)`) instead of holding one
     value. `CatalogSwitches.cap` only ever returns a ceiling the live
     economy actually shipped in that era -- this module takes an explicit
     `cap: int` instead, so a cell can ask "what if the ceiling were
     higher". Everything NOT swept (notably the placement ramp, which #538
     also moved) is era-keyed off `glory_version`, derived per episode from
     its own `coworld_version` in `run_cell`.

  2. `s4b_armed` -- whether S4b's "bank lights the jackpot" bonus
     (`achievementLightableModes`, DARK on every cohort measured so far,
     including this one) folds on top of each top-tier achievement claim.
     Synthesized from the seat's OWN real achievement-claim events
     (src/ctf/sim.nim `claimAchievement`, ~L631-652): `lightCount` = how
     many of the SAME tree's four lower tiers (`hp` 0..`AchievementTiers`-2)
     this seat's OWN prior claims already banked THIS episode, at the
     moment the tree's top tier (`hp` == `AchievementTiers`-1 == 4) claims;
     `recutModeLitBonus(lightCount)` (glory.nim ~L2884-2923, `RecutModeLitLadder
     = [1, 1, 2, 3, 4]`) folds via the WHOLE-INTEGER `recutFold` (never
     `recutFoldPct`, matching sim.nim's own `weapon="achModeLit"` event kind
     and `catalog_fold.WHOLE_INTEGER_MARKUP_WEAPONS`), strictly AFTER the
     tier's own price, subject to the SAME running product and the SAME
     cap. This is a legitimate counterfactual because the wire's per-event
     `amount`/`content` fields already ARE the deed's/claim's own
     class x heat x carry x stack (or tier) price, computed independent of
     the accumulator/cap -- catalog_fold.py's own module docstring proves
     this, and the harness proof below re-confirms it end to end.

CAVEAT (state it once, own it everywhere the sweep is used): this replays
REAL recorded play through a DIFFERENT economy. It holds BEHAVIOUR fixed --
no seat plays differently because the ceiling moved or S4b armed. It is the
right instrument for "what would today's real population have scored under
a different ceiling", not for "what would players do differently once they
can feel the new ceiling".

HARNESS PROOF (own function below, `--harness-proof`): at cap=2^24 (current)
and s4b_armed=False, this module's fold+decompose must reproduce the S6
MEASURED numbers in
`~/.ctf/knowledge/glory-gradient/01e-gv62-cohort-attribution-2026-09-09.md`
exactly: 5,456 seat-episode rows, 154 capped (2.823%), top-decile n=555
(p90 threshold=24), TOP-DECILE CHOSEN (all rows) mean 72.26% / median
78.28%, TOP-DECILE CHOSEN (capped excluded, n=401) mean 84.89% / median
98.83%, MID-BAND [4,256] CHOSEN mean 62.06% / median 67.01%. Verified by
this module's own `pytest` golden (`test_cap_sweep.py`) AND by hand,
re-running the repo's own committed, UNMODIFIED `census_decode.py
--catalog v3` and `attribution_decompose.py --catalog v3` against the same
cached replays and diffing every row -- see CAP-CEILING-S7.md's "harness
proof" section for the exact commands and the byte-for-byte match.

HANDED/CONSTANT/CHOSEN mapping (verbatim, `docs/designs/glory/
CATALOG-V3-DRAFT.md` "FREEZE CONDITION 1", the load-bearing classification
this whole program's freeze criterion is judged against):
  HANDED   = {PLACEMENT_BASE, WIN}
  CONSTANT = {RECIPE_BASE, ACHIEVEMENTS, TERRITORY}
  CHOSEN   = {OTHER_DEED_BASE, HEAT, ALLY_STACK, CARRY}
    + JOINTACT_CHOSEN (the lead's `dJointAct` era-split ruling, live for
      the WHOLE GV62 cohort: every round here is r4611+, past the r4517
      boundary, so `dJointAct` always routes CHOSEN on this cohort)
    + MODE_LIT_CHOSEN (THIS document's own classification call, S4b never
      having been armed on any measured cohort before: the bonus rewards
      *banking* a tree's lower tiers along the way -- "CHOSEN breadth of
      play, not the rare act alone", glory.nim's own `RecutModeLitLadder`
      comment -- so it is bucketed CHOSEN, separately from the tier's own
      base price (which stays ACHIEVEMENTS/CONSTANT, unchanged mechanism).
      Flagged, not silently folded into ACHIEVEMENTS, exactly like the
      `dJointAct` precedent this mirrors.)

Usage (data/gv62/ paths, all local -- no network):
  python3 tools/glory/cap_sweep.py \\
      --episodes ~/.ctf/knowledge/glory-gradient/data/gv62/gv62_episodes.json \\
      --jsonl-dir ~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays \\
      --cap-bits 14,15,16,17,18,20,uncapped --s4b off,on \\
      --out /tmp/glory-s7/sweep.json

  # harness proof only (single cell, prints the reconciliation table):
  python3 tools/glory/cap_sweep.py --harness-proof \\
      --episodes ~/.ctf/knowledge/glory-gradient/data/gv62/gv62_episodes.json \\
      --jsonl-dir ~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays

`--jsonl-dir` needs the CONTENT-populated cache (the private, never-committed
instrumented extractor's output -- see `01e-...md`'s own "Evidence paths")
for CHOSEN/HANDED/CONSTANT buckets to resolve; the plain `extract_events`
cache (`~/.ctf/scout/glory_census_replays/`) still gives correct
`reported`/`capped`/`product` (the fold never reads `content`), just with
every glory_deed leg landing in UNRESOLVED instead of its real bucket --
this module does not silently guess a shared cache location for you.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog_fold  # noqa: E402

# glory.nim `AchievementTiers* = 5` (src/ctf/glory.nim:1807).
ACHIEVEMENT_TIERS = 5
TOP_TIER = ACHIEVEMENT_TIERS - 1

# glory.nim `RecutModeLitLadder*: array[AchievementTiers, int] = [1, 1, 2, 3, 4]`
# (src/ctf/glory.nim ~L2884) and `recutModeLitBonus*` (~L2916), verbatim.
RECUT_MODE_LIT_LADDER = (1, 1, 2, 3, 4)


def recut_mode_lit_bonus(light_count: int) -> int:
    """glory.nim `func recutModeLitBonus*(lightCount: int): int`, verbatim."""
    if light_count <= 0:
        return RECUT_MODE_LIT_LADDER[0]
    if light_count >= len(RECUT_MODE_LIT_LADDER) - 1:
        return RECUT_MODE_LIT_LADDER[-1]
    return RECUT_MODE_LIT_LADDER[light_count]


# `docs/designs/glory/CATALOG-V3-DRAFT.md` "FREEZE CONDITION 1" mapping,
# verbatim (module docstring above has the full citation + the two
# CHOSEN additions this sweep introduces: JOINTACT_CHOSEN, MODE_LIT_CHOSEN).
# `PLACEMENT_BASE` carries `dFinal8`/`dFinal4`/`dFinal2` AND `survivalCredit`
# (the placement ladder's continuous twin -- catalog_fold.
# CONTINUOUS_CREDIT_WEAPONS has the reasoning), so survival credit scores
# HANDED here, never CHOSEN.
BUCKET_HANDED = frozenset({"PLACEMENT_BASE", "WIN"})
BUCKET_CONSTANT = frozenset({"RECIPE_BASE", "ACHIEVEMENTS", "TERRITORY"})
BUCKET_CHOSEN = frozenset({
    "OTHER_DEED_BASE", "HEAT", "ALLY_STACK", "CARRY",
    "JOINTACT_CHOSEN", "MODE_LIT_CHOSEN",
})

# attribution_decompose.py's own V3_RECIPE_WEAPONS (dJointAct handled
# separately by the era-split below) -- not exported by catalog_fold.py,
# copied verbatim (attribution_decompose.py ~L98).
V3_RECIPE_WEAPONS = frozenset({"dClosingTime"})


def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def sweep_episode(jsonl_path: str, round_number: int, cap: int, s4b_armed: bool,
                   scale: int = catalog_fold.GLORY_SCALE,
                   win_as_multiplier: bool = True, br_mode: bool = True,
                   glory_version: int = catalog_fold.GLORY_VERSION_S6):
    """One seat-episode's chronological fold, cap and S4b both swept
    PARAMETERS (not the two fixed real-economy values). Adapted from
    `census_decode.py`'s `analyze_episode` (v3 branch, for the fold/score/
    capped machinery) and `attribution_decompose.py`'s `decompose_episode_v3`
    (for the HANDED/CONSTANT/CHOSEN sub-factor decomposition) -- same fold
    primitives (`catalog_fold.recut_fold`/`recut_fold_pct`/
    `backsolve_heat_pct_v3`/`recut_win_factor`), fused into one per-seat walk
    so a single pass produces both the score/cap-hit read AND the bucket
    breakdown for every swept cell, with the S4b synthesis (this module's
    own addition) interleaved at the right point in fold order.
    """
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        return None
    n = len(summary["slot_team"])
    winner_team = summary.get("winner")
    slot_team = summary["slot_team"]
    winner_slots = ({i for i, t in enumerate(slot_team) if t == winner_team}
                     if winner_team else set())

    product = {s: scale for s in range(n)}
    ff = {s: 0 for s in range(n)}
    buckets = {s: Counter() for s in range(n)}
    unresolved_events = {s: 0 for s in range(n)}
    # seat -> tree -> set of LOWER tiers (0..TOP_TIER-1) already claimed
    # this episode -- mirrors `sim.claimed[team][achievementKey(tree,tier)]`
    # (sim.nim claimAchievement ~L636-639), reconstructed from the seat's
    # OWN real claim events (each (tree, tier) appears at most once on the
    # wire, since `claimed[]` dedups engine-side -- no defensive dedup
    # needed here).
    claimed_lower = {s: defaultdict(set) for s in range(n)}

    events = sorted(
        (e for e in lines if e.get("kind") in ("glory_deed", "achievement")),
        key=lambda e: e.get("tick") or 0,
    )
    # GLORY GRADIENT S8/GV63: was this SPECIFIC top-tier claim recorded with
    # `achievementLightableModes` actually armed (so its own wire `amount` is
    # already bonus-inclusive -- see the fix note below), or is this replay
    # from an era where the switch was dark (bare tier price on the wire,
    # this function's `s4b_armed` sweep param existing purely as a
    # counterfactual on that older data)? sim.nim only ever emits an
    # `achModeLit` marker at the SAME (target, tick) as its paired
    # Achievement event, and only when `bonus > 1` -- so its presence at
    # that exact (target, tick) is ground truth for "this claim's own amount
    # already includes the bonus", not a guess.
    lit_claim_ticks = {
        (e.get("target"), e.get("tick"))
        for e in events
        if e.get("kind") == "glory_deed" and e.get("weapon") == "achModeLit"
    }
    for e in events:
        t = e.get("target")
        if t is None or t < 0 or t >= n:
            continue
        kind = e.get("kind")
        weapon = e.get("weapon", "")
        amt = e.get("amount") or 0
        hp = e.get("hp")

        if kind == "glory_deed" and weapon == "dTeamKill":
            ff[t] += 1
            continue
        if kind == "glory_deed" and weapon in catalog_fold.NON_FOLD_MARKER_WEAPONS:
            continue
        if not amt:
            continue

        before = product[t]
        if kind == "glory_deed" and weapon in catalog_fold.WHOLE_INTEGER_MARKUP_WEAPONS:
            after = catalog_fold.recut_fold(before, amt, cap)
        else:
            after = catalog_fold.recut_fold_pct(before, amt, cap, scale)
        product[t] = after
        contributed = after != before
        contribution_log2 = (math.log2(after) - math.log2(before)) if contributed else 0.0

        if kind == "achievement":
            # GLORY GRADIENT S8/GV63 FIX. Two regimes now exist and must be
            # told apart, not assumed:
            #
            # (a) This claim's replay was recorded with `achievementLightable
            #     Modes` ACTUALLY armed (real GV18/GameVersion-63+ play, the
            #     first cohort where this is true) -- sim.nim `claimAchievement`
            #     (~L627-649) folds the bonus into `gloryProduct` ONCE, THEN
            #     sets `amount = amount * bonus` BEFORE this same claim's
            #     `emitEvent(Achievement, ..., amount = amount, ...)` call
            #     (~L677-681) -- so the wire `amt` we just folded above
            #     (`after = recut_fold_pct(before, amt, ...)`) is ALREADY
            #     bonus-inclusive (verified against real wire data: a Tier V
            #     non-first claim with lightCount=2 reports amt=600 = 300
            #     (RecutTierClassV3Pct non-first) x 2 (bonus), not 300).
            #     Folding the bonus a SECOND time here double-counts it --
            #     confirmed empirically: a real GV18 cohort read (r4828-4833)
            #     showed exactly 3 seat-episodes whose reconstruction was
            #     2.000x the platform's reported score, all three carrying a
            #     lit top-tier claim. Ground truth for "this exact claim was
            #     recorded armed": sim.nim only emits the `achModeLit` marker
            #     at the SAME (target, tick) as its paired Achievement event,
            #     and only when bonus > 1 -- `lit_claim_ticks` membership,
            #     not a guess.
            # (b) This claim's replay predates any armed cohort (GV61/GV62,
            #     `s4b_armed` used purely as this function's own documented
            #     COUNTERFACTUAL sweep parameter) -- the wire `amt` is bare
            #     (no bonus folded in at record time, no `achModeLit` marker
            #     exists at all), so a `s4b_armed=True` sweep must SYNTHESIZE
            #     the bonus from the seat's own claim order and fold it
            #     separately, exactly as this function did before this fix --
            #     preserved unchanged, still exercised by
            #     `test_s4b_armed_folds_the_bank_lights_the_jackpot_bonus`.
            recorded_armed = (t, e.get("tick")) in lit_claim_ticks
            light_count = (len(claimed_lower[t].get(weapon, ()))
                           if hp == TOP_TIER else 0)
            if recorded_armed:
                bonus = recut_mode_lit_bonus(light_count)
                if contributed and bonus > 1 and amt % bonus == 0:
                    tier_pct = amt // bonus
                    predicted_sum = (math.log2(tier_pct / 100) if tier_pct > 100 else 0.0) + math.log2(bonus)
                    rescale = (contribution_log2 / predicted_sum) if predicted_sum else 0.0
                    buckets[t]["ACHIEVEMENTS"] += (math.log2(tier_pct / 100) if tier_pct > 100 else 0.0) * rescale
                    buckets[t]["MODE_LIT_CHOSEN"] += math.log2(bonus) * rescale
                elif contributed:
                    buckets[t]["ACHIEVEMENTS"] += contribution_log2
            else:
                if contributed:
                    buckets[t]["ACHIEVEMENTS"] += contribution_log2
                if s4b_armed and hp == TOP_TIER:
                    bonus = recut_mode_lit_bonus(light_count)
                    if bonus > 1:
                        b_before = product[t]
                        b_after = catalog_fold.recut_fold(b_before, bonus, cap)
                        product[t] = b_after
                        if b_after != b_before:
                            buckets[t]["MODE_LIT_CHOSEN"] += (
                                math.log2(b_after) - math.log2(b_before))
            # `sim.claimed[team][key] = true` is set UNCONDITIONALLY at the
            # top of `claimAchievement` (sim.nim ~L598), BEFORE the pricing
            # fold runs -- a tier still counts as "banked" even on a
            # pct<=100 no-op price (Tier I/II under v3 = pct 100, a true
            # identity). Track membership regardless of `contributed`.
            if hp is not None and 0 <= hp < TOP_TIER:
                claimed_lower[t][weapon].add(hp)
            continue

        # glory_deed, folded for real -- sub-factor decomposition (same
        # method as attribution_decompose.decompose_episode_v3).
        if not contributed:
            continue
        content = e.get("content") or ""
        parts = content.split("|")
        if weapon in catalog_fold.CONTINUOUS_CREDIT_WEAPONS or len(parts) != 4:
            # The placement ladder's continuous twin -- HANDED, not CONSTANT
            # (catalog_fold.CONTINUOUS_CREDIT_WEAPONS carries the reasoning).
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
            # ERA-KEYED (not HEAD's ladder): #538 moved this table, and this
            # module's whole job is re-folding a RECORDED (pre-S8) cohort.
            base = catalog_fold.recut_placement_ramp_pct(glory_version)[weapon]
        elif weapon == "dClosingTime":
            base = (catalog_fold.RECUT_CLOSING_TIME_WIN_BUMP_V3_PCT if win_as_multiplier
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

        rel_err = (abs(predicted_sum - contribution_log2) / abs(contribution_log2)
                   if contribution_log2 else abs(predicted_sum))
        if predicted_sum == 0 or rel_err > 0.02:
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
            bucket = ("JOINTACT_CHOSEN"
                      if round_number > catalog_fold.JOINTACT_ERA_SPLIT_ROUND
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
        p = product[s]
        is_winner = s in winner_slots
        if is_winner and winner_team:
            winner_seats = len(winner_slots)
            win_factor = catalog_fold.recut_win_factor(br_mode, winner_seats)
            before_win = p
            p = catalog_fold.recut_fold(p, win_factor, cap)
            if p != before_win:
                buckets[s]["WIN"] += math.log2(p) - math.log2(before_win)
        if ff[s]:
            buckets[s]["FRIENDLY_FIRE"] -= ff[s]
        halvings = ff[s] if br_mode else ff[s] // 2
        reported = catalog_fold.recut_score_scaled(p, halvings, scale)
        capped = p >= cap
        rows.append(dict(
            round_number=round_number, slot=s, win=is_winner,
            product=p, reported=reported, capped=capped,
            buckets=dict(buckets[s]), unresolved_events=unresolved_events[s],
        ))
    return rows


def run_cell(episodes, jsonl_dir, cap, s4b_armed, glory_version=None):
    """All 5,456 seat-episode rows for one (cap, s4b_armed) cell.

    `glory_version` (the era whose glory.nim constants the non-swept legs --
    notably the placement ramp -- price against) is derived PER EPISODE from
    its own `coworld_version` unless overridden. The cap itself stays the
    swept parameter it has always been."""
    all_rows = []
    for ep in episodes:
        jp = os.path.join(jsonl_dir, f"{ep['episode_id']}.jsonl")
        era = (glory_version if glory_version is not None
               else catalog_fold.glory_version_for_build(ep.get("coworld_version")))
        rows = sweep_episode(jp, ep["round_number"], cap, s4b_armed,
                              glory_version=era)
        if rows is None:
            continue
        for r in rows:
            r["episode_id"] = ep["episode_id"]
        all_rows.extend(rows)
    return all_rows


def bucket_share_stats(subset):
    """Mean/median HANDED/CONSTANT/CHOSEN/UNRESOLVED share (log2-magnitude
    convention, `attribution_analyze.py`'s own method) for one row subset."""
    handed, constant, chosen, unresolved = [], [], [], []
    for r in subset:
        final = r["reported"]
        if not final or final <= 1:
            continue
        b = r["buckets"]
        # v3's fold saturates AT THE CAP mid-sequence (a sticky clamp, like
        # the real sim) -- there is no recoverable "true uncapped" product
        # once a row has capped (attribution_decompose.decompose_episode_v3's
        # own comment: `recon_uncapped` falls back to the capped score
        # itself for v3). So `reported` IS the right denominator whether or
        # not the row capped -- no v2-style uncapped-reconstruction branch.
        denom = math.log2(final)
        if denom <= 0:
            continue
        handed.append(sum(b.get(k, 0.0) for k in BUCKET_HANDED) / denom)
        constant.append(sum(b.get(k, 0.0) for k in BUCKET_CONSTANT) / denom)
        chosen.append(sum(b.get(k, 0.0) for k in BUCKET_CHOSEN) / denom)
        unresolved.append(b.get("UNRESOLVED", 0.0) / denom)
    if not chosen:
        return dict(n=0, handed_mean=float("nan"), constant_mean=float("nan"),
                    chosen_mean=float("nan"), chosen_median=float("nan"),
                    unresolved_mean=float("nan"))
    return dict(
        n=len(chosen),
        handed_mean=100 * statistics.mean(handed),
        constant_mean=100 * statistics.mean(constant),
        chosen_mean=100 * statistics.mean(chosen),
        chosen_median=100 * statistics.median(chosen),
        unresolved_mean=100 * statistics.mean(unresolved),
    )


def continuity_check(rows):
    """CONTINUITY (TARGET-DISTRIBUTION.md §5): population must be
    continuous through the 6-9 log2-point band (raw score 64-512).
    Returns (share_in_band_pct, gap: bool, per_bucket_counts)."""
    counts = Counter()
    n = 0
    for r in rows:
        v = r["reported"]
        if not v or v <= 0:
            continue
        n += 1
        pts = math.log2(v)
        b = math.floor(pts)
        if 6 <= b <= 9:
            counts[b] += 1
    in_band = sum(counts.values())
    gap = any(counts.get(b, 0) == 0 for b in (6, 7, 8, 9))
    return (100 * in_band / n if n else float("nan")), gap, dict(counts)


def separation_check(rows):
    """SEPARATION (TARGET-DISTRIBUTION.md §2 / 01e's own method): per
    round, geometric-mean(top ~10%) vs geometric-mean(middle third) of
    `reported`, log2-bits gap; a round "separates" if the gap is > 0.
    Returns (rounds_separated, rounds_total, mean_gap_bits)."""
    by_round = defaultdict(list)
    for r in rows:
        if r["reported"] and r["reported"] > 0:
            by_round[r["round_number"]].append(r["reported"])
    separated = 0
    gaps = []
    total = 0
    for rnd, scores in by_round.items():
        if len(scores) < 3:
            continue
        total += 1
        scores_sorted = sorted(scores)
        n = len(scores_sorted)
        top_n = max(1, round(n * 0.10))
        top = scores_sorted[-top_n:]
        third = n // 3
        mid = scores_sorted[third:2 * third] if third > 0 else scores_sorted
        if not mid:
            mid = scores_sorted
        gm_top = math.exp(statistics.mean(math.log(x) for x in top))
        gm_mid = math.exp(statistics.mean(math.log(x) for x in mid))
        gap_bits = math.log2(gm_top) - math.log2(gm_mid)
        gaps.append(gap_bits)
        if gap_bits > 0:
            separated += 1
    return separated, total, (statistics.mean(gaps) if gaps else float("nan"))


def percentile_ladder(rows):
    scores = sorted(r["reported"] for r in rows if r["reported"] and r["reported"] > 0)
    if not scores:
        return {}
    out = {}
    for label, p in (("p50", 0.50), ("p90", 0.90), ("p99", 0.99), ("p999", 0.999)):
        out[label] = percentile(scores, p)
    out["max"] = scores[-1]
    return out


def cell_summary(rows, cap, s4b_armed, cap_bits_label):
    scores = sorted(r["reported"] for r in rows if r["reported"] and r["reported"] > 0)
    n = len(rows)
    capped_rows = [r for r in rows if r.get("capped")]
    cap_hit_pct = 100 * len(capped_rows) / n if n else float("nan")

    p90 = percentile(scores, 0.90)
    top = [r for r in rows if r["reported"] and r["reported"] >= p90]
    top_capped = sum(1 for r in top if r.get("capped"))
    top_capped_pct = 100 * top_capped / len(top) if top else float("nan")
    top_clean = [r for r in top if not r.get("capped")]

    mid = [r for r in rows if r["reported"] and 4 <= r["reported"] <= 256]

    ladder = percentile_ladder(rows)
    jackpot_ratio_x = (ladder["p999"] / ladder["p50"]
                        if ladder.get("p50") else float("nan"))
    jackpot_bits = (math.log2(jackpot_ratio_x) if jackpot_ratio_x and jackpot_ratio_x > 0
                     else float("nan"))

    cont_pct, cont_gap, cont_counts = continuity_check(rows)
    sep_n, sep_total, sep_mean_gap = separation_check(rows)

    return dict(
        cap_bits=cap_bits_label, cap_internal=cap, s4b_armed=s4b_armed,
        n=n, cap_hit_pct=cap_hit_pct, cap_hit_n=len(capped_rows),
        top_decile_n=len(top), top_decile_threshold=p90,
        top_decile_capped_pct=top_capped_pct, top_decile_capped_n=top_capped,
        top_decile_chosen=bucket_share_stats(top),
        top_decile_chosen_clean=bucket_share_stats(top_clean),
        mid_band_chosen=bucket_share_stats(mid),
        continuity_in_band_pct=cont_pct, continuity_gap=cont_gap,
        continuity_counts=cont_counts,
        separation_rounds=sep_n, separation_total=sep_total,
        separation_mean_gap_bits=sep_mean_gap,
        jackpot_ratio_x=jackpot_ratio_x, jackpot_ratio_bits=jackpot_bits,
        percentile_ladder=ladder,
    )


def parse_cap_bits(spec: str):
    """'14,15,16,17,18,20,uncapped' -> [14, 15, 16, 17, 18, 20, None]."""
    out = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.lower() in ("uncapped", "none", "inf"):
            out.append(None)
        else:
            out.append(int(tok))
    return out


def cap_bits_to_internal(bits):
    """None (uncapped) -> the dark int64-overflow-guard bound
    (`RECUT_PRODUCT_CAP_DARK`, 2^62) -- effectively unreachable, matching
    glory.nim's own dark-path semantics; otherwise `2**bits * GLORY_SCALE`
    (REPORTED-space bits, matching TARGET-DISTRIBUTION.md's pinned ladder
    units and this program's own '2^14 (current)' candidate framing)."""
    if bits is None:
        return catalog_fold.RECUT_PRODUCT_CAP_DARK
    return (1 << bits) * catalog_fold.GLORY_SCALE


def print_harness_proof(episodes, jsonl_dir):
    cap = cap_bits_to_internal(14)  # 2^14 reported == RecutProductCapArmed
    rows = run_cell(episodes, jsonl_dir, cap, s4b_armed=False)
    n = len(rows)
    capped = sum(1 for r in rows if r["capped"])
    p90 = percentile(sorted(r["reported"] for r in rows if r["reported"]), 0.90)
    top = [r for r in rows if r["reported"] and r["reported"] >= p90]
    top_stats = bucket_share_stats(top)
    clean = [r for r in top if not r["capped"]]
    clean_stats = bucket_share_stats(clean)
    mid = [r for r in rows if r["reported"] and 4 <= r["reported"] <= 256]
    mid_stats = bucket_share_stats(mid)

    print("=== HARNESS PROOF: cap=2^24 internal (2^14 reported), S4b OFF ===")
    print(f"rows: {n} (target 5456) {'OK' if n == 5456 else 'MISMATCH'}")
    print(f"capped: {capped} (target 154) {'OK' if capped == 154 else 'MISMATCH'}")
    print(f"top-decile n: {len(top)} threshold={p90} (target n=555 threshold=24)")
    print(f"TOP DECILE all rows: CHOSEN mean={top_stats['chosen_mean']:.2f}% "
          f"(target 72.26%) median={top_stats['chosen_median']:.2f}% (target 78.28%)")
    print(f"TOP DECILE clean: CHOSEN mean={clean_stats['chosen_mean']:.2f}% "
          f"(target 84.89%) median={clean_stats['chosen_median']:.2f}% (target 98.83%)")
    print(f"MID BAND [4,256]: CHOSEN mean={mid_stats['chosen_mean']:.2f}% "
          f"(target 62.06%) median={mid_stats['chosen_median']:.2f}% (target 67.01%)")
    ok = (n == 5456 and capped == 154 and len(top) == 555 and p90 == 24
          and abs(top_stats['chosen_mean'] - 72.26) < 0.01
          and abs(top_stats['chosen_median'] - 78.28) < 0.01)
    print(f"\nHARNESS PROOF: {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--episodes", required=True,
                     help="data/gv62/gv62_episodes.json (or equivalent)")
    ap.add_argument("--jsonl-dir", required=True,
                     help="cache dir of per-episode {episode_id}.jsonl wire "
                          "event extracts; needs the content-populated "
                          "(instrumented-extractor) cache for CHOSEN/"
                          "HANDED/CONSTANT buckets to resolve")
    ap.add_argument("--cap-bits", default="14,15,16,17,18,20,uncapped",
                     help="comma list of REPORTED-space log2 cap candidates "
                          "('uncapped' allowed)")
    ap.add_argument("--s4b", default="off,on",
                     help="comma list of 'off'/'on'")
    ap.add_argument("--out", default="/tmp/glory-s7/cap_sweep.json")
    ap.add_argument("--harness-proof", action="store_true",
                     help="run only the harness-proof cell and print the "
                          "reconciliation table (exits 0/1 on pass/fail)")
    args = ap.parse_args()

    episodes_path = os.path.expanduser(args.episodes)
    jsonl_dir = os.path.expanduser(args.jsonl_dir)
    with open(episodes_path) as f:
        episodes = json.load(f)

    if args.harness_proof:
        ok = print_harness_proof(episodes, jsonl_dir)
        sys.exit(0 if ok else 1)

    cap_bits_list = parse_cap_bits(args.cap_bits)
    s4b_list = [tok.strip().lower() == "on" for tok in args.s4b.split(",") if tok.strip()]

    results = []
    for bits in cap_bits_list:
        cap = cap_bits_to_internal(bits)
        label = "uncapped" if bits is None else f"2^{bits}"
        for s4b_armed in s4b_list:
            rows = run_cell(episodes, jsonl_dir, cap, s4b_armed)
            summary = cell_summary(rows, cap, s4b_armed, label)
            results.append(summary)
            print(f"cap={label:<10} s4b={'ON ' if s4b_armed else 'OFF'}  "
                  f"n={summary['n']}  cap-hit={summary['cap_hit_pct']:.3f}%  "
                  f"top-capped={summary['top_decile_capped_pct']:.2f}%  "
                  f"top-CHOSEN={summary['top_decile_chosen']['chosen_mean']:.2f}%  "
                  f"mid-CHOSEN={summary['mid_band_chosen']['chosen_mean']:.2f}%  "
                  f"jackpot={summary['jackpot_ratio_x']:.1f}x "
                  f"({summary['jackpot_ratio_bits']:.2f} bits)  "
                  f"continuity_gap={summary['continuity_gap']}  "
                  f"separation={summary['separation_rounds']}/{summary['separation_total']}")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nwrote {len(results)} cells to {args.out}")


if __name__ == "__main__":
    main()
