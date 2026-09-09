#!/usr/bin/env python3
"""GLORY GRADIENT S6 — fixture tests for the catalog-v2/v3 fold (stdlib
only, no network, no external cache paths). Two goldens, each built from
ONE REAL seat-episode's REAL wire events (verified against the live
platform's `reported` score -- see the source citations on each golden
below), plus direct unit checks on the `catalog_fold` primitives.

Run from anywhere: python3 tools/glory/test_catalog_fold.py

This is the repo's existing stdlib-only convention for tools/*  tests (see
tools/ci/test_next_coworld_version.py, tools/ladder/test_encounters.py) --
no pytest dependency, because none of this repo's CI runners install one.
There is currently no CI step that runs ANY tools/glory test (grep
.github/workflows/ -- tools/glory has never been wired into CI; it is
read-only investigative tooling, not part of the build/deploy/upload
pipeline this repo's workflows cover). This script is therefore runnable
locally on demand; wiring a CI step is a separate, out-of-scope decision
for whoever owns making tools/glory a CI-gated surface.
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import catalog_fold  # noqa: E402
import census_decode  # noqa: E402

FAILURES = []


def check(name, cond):
    status = "ok" if cond else "FAIL"
    print(f"  [{status}] {name}")
    if not cond:
        FAILURES.append(name)


def write_episode_jsonl(path, slot_team, winner, ticks, events):
    """`events`: list of (tick, kind, target, weapon, amount[, content])."""
    with open(path, "w") as f:
        f.write(json.dumps({
            "type": "summary", "ticks": ticks, "winner": winner,
            "slot_team": slot_team,
        }) + "\n")
        for ev in events:
            tick, kind, target, weapon, amount = ev[:5]
            content = ev[5] if len(ev) > 5 else ""
            f.write(json.dumps({
                "tick": tick, "kind": kind, "target": target,
                "weapon": weapon, "amount": amount, "content": content,
            }) + "\n")


# ── golden 1: GV62 (catalog v3), real seat-episode ──────────────────────
# round r4611, episode 84d65205-0dc3-4d7a-b616-544a9533b6c7, slot 2
# (team "green" -- NOT the round's winner, "ivory"/slot 6), platform
# `reported` = 46.0. Real wire events for this seat, extracted from the
# cached replay (`~/.ctf/scout/glory_census_replays/84d65205-...jsonl`,
# GameVersion 62 / GLORYVERSION 17, all five S6 catalog-v3 switches armed):
#   843  glory_deed  dHonorableKill  220
#   843  glory_deed  dFirstBlood     2120
#   844  achievement treeGun         100
#   1298 glory_deed  dFinal8         100
#   1514 glory_deed  dFinal4         100
#   1537 glory_deed  survivalCredit  102
#   2226 achievement treeSquad       105
# Hand-verified fold (`docs/designs/glory/CATALOG-V3-DRAFT.md`'s own
# `recutFoldPct`/GATE RULING 2 rules, GlorySCALE=1024):
#   product=1024 -[HonorableKill x2.20]-> 2252
#          -[FirstBlood x21.20]-> 47742
#          -[treeGun pct=100, no-op]-> 47742
#          -[dFinal8 pct=100, no-op]-> 47742
#          -[dFinal4 pct=100, no-op]-> 47742
#          -[survivalCredit pct=102 <200, product(47742) < 64*1024=65536:
#            GATE RULING 2 skip]-> 47742
#          -[treeSquad pct=105 <200, still < 65536: GATE RULING 2 skip]
#          -> 47742 (final)
#   score = 47742 // 1024 = 46  (floor division)  == reported.
GV62_GOLDEN_EVENTS = [
    (843, "glory_deed", 2, "dHonorableKill", 220),
    (843, "glory_deed", 2, "dFirstBlood", 2120),
    (844, "achievement", 2, "treeGun", 100),
    (1298, "glory_deed", 2, "dFinal8", 100),
    (1514, "glory_deed", 2, "dFinal4", 100),
    (1537, "glory_deed", 2, "survivalCredit", 102),
    (2226, "achievement", 2, "treeSquad", 105),
]
GV62_GOLDEN_REPORTED = 46.0


def test_v3_fold_primitive():
    print("test_v3_fold_primitive (GV62 golden, catalog_fold primitives directly)")
    product = catalog_fold.GLORY_SCALE
    cap = catalog_fold.RECUT_PRODUCT_CAP_ARMED
    scale = catalog_fold.GLORY_SCALE
    for _tick, _kind, _target, weapon, amt in GV62_GOLDEN_EVENTS:
        product = catalog_fold.recut_fold_pct(product, amt, cap, scale)
    check("product folds to 47742 (pre-scale-strip)", product == 47742)
    final = catalog_fold.recut_score_scaled(product, 0, scale)
    check(f"recut_score_scaled == reported ({final} == {int(GV62_GOLDEN_REPORTED)})",
          final == int(GV62_GOLDEN_REPORTED))


def test_v3_fold_via_census_decode():
    print("test_v3_fold_via_census_decode (GV62 golden, full analyze_episode "
          "path, catalog='v3')")
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        # 3 slots: target slot 2 is our golden seat; slot 0 is the (decisive)
        # winner, on a DIFFERENT team, so the win-as-multiplier fold never
        # touches slot 2 -- isolating exactly the events above.
        write_episode_jsonl(jp, slot_team=["teamA", "teamB", "teamC"],
                             winner="teamA", ticks=2227, events=GV62_GOLDEN_EVENTS)
        ep = dict(episode_id="golden-gv62", round_number=4611,
                   coworld_version="0.7.377",
                   participant_scores=[{"position": 2, "score": GV62_GOLDEN_REPORTED}])
        rows, _summary = census_decode.analyze_episode(ep, jp, catalog="v3")
    row = next(r for r in rows if r["slot"] == 2)
    check(f"recon_final == reported ({row['recon_final']} == {row['reported']})",
          row["recon_final"] == row["reported"])
    check("not flagged capped", row["capped"] is False)
    check("not the winner", row["win"] is False)


# ── golden 2: GV61 (catalog v2, the pre-S6/regression fold), real
#    seat-episode ──────────────────────────────────────────────────────
# round r4552, episode 39dc9403-948e-4909-a5e9-557723333e95, slot 2, NOT
# the round's winner, platform `reported` = 12.0. Real wire events
# (`~/.ctf/scout/glory_gv61_replays/39dc9403-...jsonl`, GameVersion 61 /
# GLORYVERSION 16, catalog v3 switches all dark):
#   954  glory_deed  dHonorableKill  1
#   954  glory_deed  dFirstBlood     6
#   955  achievement treeGun         1
#   3451 achievement treeSquad       2
# v2 fold (flat-integer `product *= amt` for amt>1, seed 1): dHonorableKill
# (amt=1, skipped) -> dFirstBlood (product=6) -> treeGun (amt=1, skipped)
# -> treeSquad (product=6*2=12) == reported.
GV61_GOLDEN_EVENTS = [
    (954, "glory_deed", 2, "dHonorableKill", 1),
    (954, "glory_deed", 2, "dFirstBlood", 6),
    (955, "achievement", 2, "treeGun", 1),
    (3451, "achievement", 2, "treeSquad", 2),
]
GV61_GOLDEN_REPORTED = 12.0


def test_v2_fold_via_census_decode():
    print("test_v2_fold_via_census_decode (GV61 golden, full analyze_episode "
          "path, DEFAULT catalog -- exercises the untouched v2 branch)")
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB", "teamC"],
                             winner="teamA", ticks=3452, events=GV61_GOLDEN_EVENTS)
        ep = dict(episode_id="golden-gv61", round_number=4552,
                   coworld_version="0.7.369",
                   participant_scores=[{"position": 2, "score": GV61_GOLDEN_REPORTED}])
        # NOTE: no `catalog=` kwarg -- exercises the default, proving every
        # PRE-EXISTING caller (no code change on their end) still gets the
        # historical v2 fold untouched.
        rows, _summary = census_decode.analyze_episode(ep, jp)
    row = next(r for r in rows if r["slot"] == 2)
    check(f"recon_final == reported ({row['recon_final']} == {row['reported']})",
          row["recon_final"] == row["reported"])
    check("not the winner", row["win"] is False)


# ── unit checks on the fold primitives themselves ───────────────────────

def test_recut_fold_pct_gate_ruling_2():
    print("test_recut_fold_pct_gate_ruling_2 (floor guard: pct<200 skipped "
          "while the unscaled accumulator is <= 64)")
    scale = catalog_fold.GLORY_SCALE
    cap = catalog_fold.RECUT_PRODUCT_CAP_ARMED
    # accumulator sits at the seed (1024 == 1.0 unscaled, well under 64):
    # a pct<200 fold must be a pure no-op.
    check("pct=150 skipped at seed (accumulator=1.0 <= 64)",
          catalog_fold.recut_fold_pct(scale, 150, cap, scale) == scale)
    # pct>=200 is UNRESTRICTED even at the seed.
    check("pct=250 applies at seed (unrestricted, >=200)",
          catalog_fold.recut_fold_pct(scale, 250, cap, scale) == (scale * 250) // 100)
    # once the (unscaled) accumulator climbs past 64, pct<200 folds apply.
    above_floor = 65 * scale
    check("pct=150 applies once accumulator > 64",
          catalog_fold.recut_fold_pct(above_floor, 150, cap, scale)
          == (above_floor * 150) // 100)
    # pct<=100 is always a true no-op (the crushed placement-ramp case).
    check("pct=100 is a no-op regardless of accumulator",
          catalog_fold.recut_fold_pct(above_floor, 100, cap, scale) == above_floor)


def test_recut_fold_cap_saturation():
    print("test_recut_fold_cap_saturation")
    cap = catalog_fold.RECUT_PRODUCT_CAP_ARMED
    check("recut_fold saturates at cap",
          catalog_fold.recut_fold(cap, 2, cap) == cap)
    check("recut_fold_pct saturates at cap",
          catalog_fold.recut_fold_pct(cap, 200, cap, catalog_fold.GLORY_SCALE) == cap)


def test_recut_win_factor():
    print("test_recut_win_factor")
    check("solo winner (1 seat) -> x8",
          catalog_fold.recut_win_factor(True, 1) == catalog_fold.RECUT_WIN_FACTOR_BR_SOLO)
    check("duo winner (2 seats) -> x4",
          catalog_fold.recut_win_factor(True, 2) == catalog_fold.RECUT_WIN_FACTOR_BR)
    check("non-BR mode -> x1",
          catalog_fold.recut_win_factor(False, 1) == 1)


def test_catalog_switches_label():
    print("test_catalog_switches_label")
    check("CATALOG_V2 labels 'v2'", catalog_fold.CATALOG_V2.label == "v2")
    check("CATALOG_V3 labels 'v3'", catalog_fold.CATALOG_V3.label == "v3")
    check("placementRampV3 alone still labels 'v3' (either v3 switch selects it)",
          catalog_fold.CatalogSwitches(placementRampV3=True).label == "v3")


def main():
    test_recut_fold_pct_gate_ruling_2()
    test_recut_fold_cap_saturation()
    test_recut_win_factor()
    test_catalog_switches_label()
    test_v3_fold_primitive()
    test_v3_fold_via_census_decode()
    test_v2_fold_via_census_decode()

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
