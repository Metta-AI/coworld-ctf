"""GLORY GRADIENT S7 — pytest goldens for `cap_sweep.py`.

Two tiers, same convention `test_catalog_fold.py` already documents for
this directory (no CI step runs ANY `tools/glory` test today -- this file
is `pytest`-collectible on request, per this program's own S7 brief, not
wired into a CI job):

1. **Self-contained unit tests** (always run, no external data, no
   network) -- hand-verified synthetic seat-episodes proving `cap_sweep.py`
   (a) folds a CUSTOM cap value correctly (not just the two real
   `RecutProductCapArmed`/`RecutProductCap` consts `catalog_fold.py` itself
   is limited to), and (b) synthesizes the S4b `achievementLightableModes`
   bonus fold correctly from real per-seat claim events (lightCount ->
   `recutModeLitBonus` -> a whole-integer fold on top of the tier's own
   price), matching glory.nim's `claimAchievement` fold order exactly.

2. **The harness-proof golden** (`test_harness_proof_pins_s6_measured_gv62_numbers`,
   skipped -- not failed -- when the local-only GV62 replay cache isn't
   present): pins cap=2^24 (current, `2^14` reported), S4b OFF against the
   EXACT S6 MEASURED numbers in `01e-gv62-cohort-attribution-2026-09-09.md`
   -- 5,456 rows, 154 capped, top-decile n=555 (threshold=24), TOP-DECILE
   CHOSEN (all rows) mean 72.26% / median 78.28%. Run locally with:
     python3 -m pytest tools/glory/test_cap_sweep.py -v
   (needs `~/.ctf/knowledge/glory-gradient/data/gv62/gv62_episodes.json` +
   the content-populated replay cache -- see `cap_sweep.py`'s own
   docstring for exactly which cache dir).
"""
import json
import math
import os
import sys
import tempfile

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cap_sweep  # noqa: E402
import catalog_fold  # noqa: E402


def write_episode_jsonl(path, slot_team, winner, ticks, events):
    """`events`: list of (tick, kind, target, weapon, amount, hp[, content]).
    Same shape `test_catalog_fold.py`'s own fixtures use, extended with an
    `hp` (achievement tier) field -- the field `cap_sweep.sweep_episode`
    reads to track which of a tree's lower tiers a seat has banked."""
    with open(path, "w") as f:
        f.write(json.dumps({
            "type": "summary", "ticks": ticks, "winner": winner,
            "slot_team": slot_team,
        }) + "\n")
        for ev in events:
            tick, kind, target, weapon, amount, hp = ev[:6]
            content = ev[6] if len(ev) > 6 else ""
            f.write(json.dumps({
                "tick": tick, "kind": kind, "target": target,
                "weapon": weapon, "amount": amount, "hp": hp,
                "content": content,
            }) + "\n")


# ── unit tests: recutModeLitBonus ladder (glory.nim, verbatim) ──────────

def test_recut_mode_lit_bonus_ladder():
    # RecutModeLitLadder = [1, 1, 2, 3, 4] (glory.nim ~L2884), clamped both
    # ends (recutModeLitBonus, ~L2916).
    assert cap_sweep.recut_mode_lit_bonus(-1) == 1
    assert cap_sweep.recut_mode_lit_bonus(0) == 1
    assert cap_sweep.recut_mode_lit_bonus(1) == 1
    assert cap_sweep.recut_mode_lit_bonus(2) == 2
    assert cap_sweep.recut_mode_lit_bonus(3) == 3
    assert cap_sweep.recut_mode_lit_bonus(4) == 4
    assert cap_sweep.recut_mode_lit_bonus(99) == 4  # clamped at the top


# ── unit test: S4b synthesis, hand-verified fold ────────────────────────
#
# Seat 0 claims treeGun's four LOWER tiers (hp 0/1/2/3) at pct=100 (a true
# no-op -- matches RecutTierClassV3Pct[0]/[1]=100 for real Tier I/II under
# catalog v3), then the TOP tier (hp=4, AchievementTiers-1) at pct=346
# (matches LIGHTABLE-MODES-S4B.md's own "v3 pct pricing... DARK=[200, 346]"
# citation for treeGun.V FIRST-claim). Hand fold (GlorySCALE=1024):
#   product=1024 -[tier0..3, pct=100, true no-op]-> 1024 (unchanged)
#   -[tier4, pct=346]-> (1024*346)//100 = 3543
#   S4b OFF: reported = 3543 // 1024 = 3
#   S4b ON: lightCount=4 (all 4 lower tiers banked) -> bonus=4
#     -[whole-integer fold x4]-> 3543*4 = 14172
#     reported = 14172 // 1024 = 13

def _s4b_scenario_events():
    return [
        (100, "achievement", 0, "treeGun", 100, 0),
        (101, "achievement", 0, "treeGun", 100, 1),
        (102, "achievement", 0, "treeGun", 100, 2),
        (103, "achievement", 0, "treeGun", 100, 3),
        (104, "achievement", 0, "treeGun", 346, 4),
    ]


def test_s4b_dark_matches_hand_fold():
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB"], winner=None,
                             ticks=200, events=_s4b_scenario_events())
        rows = cap_sweep.sweep_episode(jp, round_number=4620,
                                        cap=catalog_fold.RECUT_PRODUCT_CAP_ARMED,
                                        s4b_armed=False)
    row0 = rows[0]
    assert row0["product"] == 3543
    assert row0["reported"] == 3
    assert row0["capped"] is False
    assert "MODE_LIT_CHOSEN" not in row0["buckets"]


def test_s4b_armed_folds_the_bank_lights_the_jackpot_bonus():
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB"], winner=None,
                             ticks=200, events=_s4b_scenario_events())
        rows = cap_sweep.sweep_episode(jp, round_number=4620,
                                        cap=catalog_fold.RECUT_PRODUCT_CAP_ARMED,
                                        s4b_armed=True)
    row0 = rows[0]
    assert row0["product"] == 3543 * 4
    assert row0["reported"] == 13
    assert row0["capped"] is False
    assert row0["buckets"]["MODE_LIT_CHOSEN"] == pytest.approx(math.log2(4), abs=1e-9)


def test_s4b_recorded_armed_does_not_double_fold_the_bonus():
    # GLORY GRADIENT S8/GV63 regression: real armed play (GameVersion 63+)
    # bakes the S4b bonus INTO the top-tier claim's own wire `amount`
    # (sim.nim `claimAchievement` ~L647, `amount = amount * bonus`, BEFORE
    # the achievement event's own `emitEvent` a few lines later) and ALSO
    # emits a separate `achModeLit` marker (weapon="achModeLit") at the SAME
    # tick, carrying the bonus for display/audit only -- it is not a second
    # independent fold. An earlier version of this function could not tell
    # this apart from the OLD dark-recording sweep case and folded the
    # bonus a SECOND time, exactly doubling the score -- caught empirically
    # on a real GV18 cohort read (r4828-4833): 3/1440 seat-episodes
    # reconstructed at 2.000x the platform's own reported score, every one
    # of them carrying a lit top-tier claim.
    events = [
        (100, "achievement", 0, "treeGun", 100, 0),
        (101, "achievement", 0, "treeGun", 100, 1),
        (102, "achievement", 0, "treeGun", 100, 2),
        (103, "achievement", 0, "treeGun", 100, 3),
        # Recorded-armed wire shape: the bonus (4, at lightCount=4) is
        # ALREADY folded into this claim's own amount (346 * 4 = 1384), and
        # a paired `achModeLit` marker fires at the identical tick.
        (104, "achievement", 0, "treeGun", 1384, 4),
        (104, "glory_deed", 0, "achModeLit", 4, None, "GLORY_ACH_MODE_LIT"),
    ]
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB"], winner=None,
                             ticks=200, events=events)
        rows = cap_sweep.sweep_episode(jp, round_number=4620,
                                        cap=catalog_fold.RECUT_PRODUCT_CAP_ARMED,
                                        s4b_armed=True)
    row0 = rows[0]
    # Same net product as the dark-recording + hypothetical-arm case above
    # (1024 * 1384 // 100 == 3543 * 4 == 14172): one fold, not two.
    assert row0["product"] == 3543 * 4
    assert row0["reported"] == 13
    assert row0["capped"] is False
    assert row0["buckets"]["MODE_LIT_CHOSEN"] == pytest.approx(math.log2(4), abs=1e-2)


def test_s4b_bonus_is_a_real_no_op_at_lightcount_0_or_1():
    # A seat that lands ONLY the top tier (no lower tiers banked first)
    # scores IDENTICALLY dark vs armed -- glory.nim's own "no bonus, no
    # regression" guarantee (LIGHTABLE-MODES-S4B.md, "Non-negotiables" #4).
    events = [(104, "achievement", 0, "treeGun", 346, 4)]
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB"], winner=None,
                             ticks=200, events=events)
        dark = cap_sweep.sweep_episode(jp, 4620, catalog_fold.RECUT_PRODUCT_CAP_ARMED,
                                        s4b_armed=False)[0]
        armed = cap_sweep.sweep_episode(jp, 4620, catalog_fold.RECUT_PRODUCT_CAP_ARMED,
                                         s4b_armed=True)[0]
    assert dark["reported"] == armed["reported"]
    assert "MODE_LIT_CHOSEN" not in armed["buckets"]


# ── unit test: cap is a real, arbitrary PARAMETER (not just the two real
#    consts catalog_fold.CatalogSwitches.cap is limited to) ─────────────

def test_cap_is_an_arbitrary_parameter_not_just_the_two_real_consts():
    events = _s4b_scenario_events()
    small_cap = 5000  # far below either real economy value
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB"], winner=None,
                             ticks=200, events=events)
        capped_row = cap_sweep.sweep_episode(jp, 4620, small_cap, s4b_armed=True)[0]
        uncapped_row = cap_sweep.sweep_episode(
            jp, 4620, catalog_fold.RECUT_PRODUCT_CAP_ARMED, s4b_armed=True)[0]
    # tier4 fold alone already exceeds 5000 (1024*346//100=3543 < 5000, but
    # the NEXT check saturates it: recut_fold_pct(1024, 346, 5000, 1024) ->
    # product(1024) >= cap//pct(5000//346=14) -> True -> returns cap.
    assert capped_row["product"] == small_cap
    assert capped_row["capped"] is True
    assert capped_row["reported"] == small_cap // 1024
    assert uncapped_row["product"] != small_cap
    assert uncapped_row["capped"] is False


def test_cap_bits_to_internal():
    # GLORY GRADIENT S8 (#538) moved the armed ceiling from 2^14 reported
    # (2^24 internal) to 2^21 reported (2^31 internal, CAP-CEILING-S7.md's
    # sized value) -- this assertion pins the CURRENT armed constant, not
    # the pre-S8 one; the middle assertion below already covers an
    # arbitrary cap-bits value independent of whichever is "armed" today.
    assert cap_sweep.cap_bits_to_internal(21) == catalog_fold.RECUT_PRODUCT_CAP_ARMED
    assert cap_sweep.cap_bits_to_internal(20) == (1 << 20) * catalog_fold.GLORY_SCALE
    assert cap_sweep.cap_bits_to_internal(None) == catalog_fold.RECUT_PRODUCT_CAP_DARK


def test_parse_cap_bits():
    assert cap_sweep.parse_cap_bits("14,15,16,uncapped") == [14, 15, 16, None]


# ── the harness-proof golden: pins the S6 MEASURED numbers exactly ──────

GV62_EPISODES = os.path.expanduser(
    "~/.ctf/knowledge/glory-gradient/data/gv62/gv62_episodes.json")
GV62_ATTR_JSONL_DIR = os.path.expanduser(
    "~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays")


def _gv62_cache_available():
    return os.path.exists(GV62_EPISODES) and os.path.isdir(GV62_ATTR_JSONL_DIR)


@pytest.mark.skipif(
    not _gv62_cache_available(),
    reason="local-only GV62 replay cache not present in this checkout "
           "(this golden mirrors test_catalog_fold.py's own documented "
           "convention: tools/glory tests are not wired into CI and "
           "several depend on locally-cached replay data)")
def test_harness_proof_pins_s6_measured_gv62_numbers():
    with open(GV62_EPISODES) as f:
        episodes = json.load(f)
    cap = cap_sweep.cap_bits_to_internal(14)  # RecutProductCapArmed
    rows = cap_sweep.run_cell(episodes, GV62_ATTR_JSONL_DIR, cap, s4b_armed=False)

    assert len(rows) == 5456

    capped = [r for r in rows if r["capped"]]
    assert len(capped) == 154

    scores = sorted(r["reported"] for r in rows if r["reported"])
    p90 = cap_sweep.percentile(scores, 0.90)
    assert p90 == 24
    top = [r for r in rows if r["reported"] and r["reported"] >= p90]
    assert len(top) == 555

    top_stats = cap_sweep.bucket_share_stats(top)
    assert top_stats["chosen_mean"] == pytest.approx(72.26, abs=0.01)
    assert top_stats["chosen_median"] == pytest.approx(78.28, abs=0.01)

    clean = [r for r in top if not r["capped"]]
    assert len(clean) == 401
    clean_stats = cap_sweep.bucket_share_stats(clean)
    assert clean_stats["chosen_mean"] == pytest.approx(84.89, abs=0.01)
    assert clean_stats["chosen_median"] == pytest.approx(98.83, abs=0.01)

    mid = [r for r in rows if r["reported"] and 4 <= r["reported"] <= 256]
    assert len(mid) == 831
    mid_stats = cap_sweep.bucket_share_stats(mid)
    assert mid_stats["chosen_mean"] == pytest.approx(62.06, abs=0.01)
    assert mid_stats["chosen_median"] == pytest.approx(67.01, abs=0.01)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
