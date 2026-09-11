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

THIS FILE IS WIRED INTO CI (the `era-tripwire` job in
.github/workflows/build.yml), and it is the only tools/glory test that is:
it needs no replay cache and no network. It carries the ERA-KEYING
TRIPWIRE -- `catalog_fold.py` live-ports src/ctf/glory.nim's scoring
constants AND backward-decodes recorded cohorts, so a ship that MOVES a
constant must era-key it in the same PR (#538 did not, and the GV62 census
silently fell from 5,456/5,456 to 5,302/5,456). The other tools/glory
tests, which do need local-only cached replays, stay local-on-demand:
`test_cohort_reconciliation.py` (the three-cohort gate) and
`test_cap_sweep.py`.
"""
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

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

    # A v2 caller with no usable build tag (why_one.py builds an episode
    # stub by hand) must still decode: the v2 branch reads neither the
    # era-keyed ceiling nor the placement ramp, and v2 only ever ran
    # pre-S8. A v3 caller in the same position must FAIL instead of
    # guessing an era.
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "ep.jsonl")
        write_episode_jsonl(jp, slot_team=["teamA", "teamB", "teamC"],
                             winner="teamA", ticks=3452, events=GV61_GOLDEN_EVENTS)
        stub = dict(episode_id="golden-gv61", round_number=4552,
                     participant_scores=[{"position": 2,
                                          "score": GV61_GOLDEN_REPORTED}])
        rows2, _ = census_decode.analyze_episode(stub, jp)
        row2 = next(r for r in rows2 if r["slot"] == 2)
        check("v2 fold survives an episode stub with no coworld_version",
              row2["recon_final"] == row2["reported"])
        raised = False
        try:
            census_decode.analyze_episode(stub, jp, catalog="v3")
        except ValueError:
            raised = True
        check("v3 fold REFUSES an episode with no resolvable era", raised)


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


def test_deed_rates_reports_both():
    """Pins BOTH mint rates for one known deed, and pins that every census
    table still PRINTS both, so the pair can never silently collapse back
    to a single per-episode number -- the units error that published
    `survivalCredit` as "roughly x1.16 over a typical episode" when the
    realized per-seat effect is x1.0002."""
    print("test_deed_rates_reports_both")
    # survivalCredit on the live GV18/GameVersion-63 cohort (r4828-r4833):
    # 714 mints, 90 episodes, 1,440 seat-episodes (16 seats each).
    per_ep, per_seat_ep = catalog_fold.deed_rates(714, 90, 1440)
    check("survivalCredit is 7.9333 mints/EPISODE (16 seats pooled)",
          abs(per_ep - 7.933333) < 1e-4)
    check("survivalCredit is 0.4958 mints/SEAT-episode",
          abs(per_seat_ep - 0.495833) < 1e-4)
    check("the per-episode rate is 16x the per-seat rate (the whole point)",
          abs(per_ep / per_seat_ep - 16.0) < 1e-9)
    check("zero episodes does not divide by zero",
          catalog_fold.deed_rates(0, 0, 0) == (0.0, 0.0))

    # The tables themselves must emit BOTH columns, not just the pair being
    # computable. Source-level check (these emitters need a full census rows
    # file to run, which this stdlib-only test deliberately does not carry).
    here = os.path.dirname(os.path.abspath(__file__))
    for fname in ("census_analyze.py", "census_achievements_analyze.py"):
        with open(os.path.join(here, fname)) as f:
            src = f.read()
        check(f"{fname} prints a per-SEAT-episode rate column",
              "mints/seat-ep" in src)
        check(f"{fname} computes it via catalog_fold.deed_rates",
              "catalog_fold.deed_rates" in src)
    with open(os.path.join(here, "census_analyze.py")) as f:
        src = f.read()
    check("census_analyze.py Q5a prints per_seat_ep beside per_ep",
          "per_seat_ep=" in src and "per_ep=" in src)


# ── ERA KEYING (the #538 regression, as unit tests) ─────────────────────
#
# `catalog_fold.py` is a LIVE PORT of src/ctf/glory.nim AND a backward
# decoder. #538 (1b92ec46) moved two ported constants to HEAD's values and
# broke every pre-S8 decode. These checks are the mechanical form of the
# rule that came out of it: EVERY CONSTANT A SHIP MOVES MUST BE ERA-KEYED
# IN THE SAME PR. The tripwire below fails the moment glory.nim's HEAD
# value stops matching this module's HEAD alias, which is exactly when a
# new `_S<n>` literal + `GLORY_VERSION_BY_BUILD` row are owed.

def _read_glory_nim():
    path = os.path.join(REPO_ROOT, "src", "ctf", "glory.nim")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read()


def test_era_stamp_agrees_with_source_and_era_md():
    print("test_era_stamp_agrees_with_source_and_era_md")
    src = _read_glory_nim()
    if src is None:
        check("SKIP: src/ctf/glory.nim not in this checkout", True)
        return
    m = catalog_fold.GLORY_VERSION_RE.search(src)
    check("src/ctf/glory.nim declares GloryVersion*", m is not None)
    if m:
        check(f"CURRENT_GLORY_VERSION ({catalog_fold.CURRENT_GLORY_VERSION}) == "
              f"glory.nim GloryVersion* ({m.group(1)})",
              catalog_fold.CURRENT_GLORY_VERSION == int(m.group(1)))

    era_py = os.path.join(REPO_ROOT, "policies", "starters", "common", "era.py")
    if os.path.exists(era_py):
        with open(era_py) as f:
            era_src = f.read()
        gv = re.search(r"GLORY_VERSION\s*:\s*int\s*=\s*(\d+)", era_src)
        tag = re.search(r'BUILD_TAG\s*:\s*str\s*=\s*"([^"]+)"', era_src)
        check("era.py GLORY_VERSION == CURRENT_GLORY_VERSION",
              gv is not None and int(gv.group(1)) == catalog_fold.CURRENT_GLORY_VERSION)
        # The newest era-boundary row must be the build tag era.py/_era.md
        # stamps, so "which build starts this era" is never guessed.
        newest_build, newest_era = catalog_fold.GLORY_VERSION_BY_BUILD[-1]
        check("newest GLORY_VERSION_BY_BUILD row == CURRENT_GLORY_VERSION",
              newest_era == catalog_fold.CURRENT_GLORY_VERSION)
        check(f"newest era boundary {newest_build} == era.py BUILD_TAG "
              f"({tag.group(1) if tag else None})",
              tag is not None
              and catalog_fold.parse_build_version(tag.group(1)) == newest_build)


def test_shipped_era_literals_are_frozen():
    """RECORDED HISTORY, never editable. Each `_S<n>` literal is the value
    some cohort's wire data was ACTUALLY folded against; changing one
    re-breaks that cohort's decode. A ship that moves a constant adds a NEW
    literal + a new `GLORY_VERSION_BY_BUILD` row -- it never edits these.
    (This is the half of the tripwire `test_head_aliases_still_match_glory_nim`
    cannot see: repointing BOTH glory.nim and the port keeps them agreeing
    with each other while silently destroying the backward decode.)"""
    print("test_shipped_era_literals_are_frozen")
    check("RECUT_PRODUCT_CAP_ARMED_V13 frozen at 2**26",
          catalog_fold.RECUT_PRODUCT_CAP_ARMED_V13 == 1 << 26)
    check("RECUT_PRODUCT_CAP_ARMED_S6 frozen at 2**24 (GV61/GV62 cohorts)",
          catalog_fold.RECUT_PRODUCT_CAP_ARMED_S6 == 1 << 24)
    check("RECUT_PRODUCT_CAP_ARMED_S8 frozen at 2**31 (GV63 cohort)",
          catalog_fold.RECUT_PRODUCT_CAP_ARMED_S8 == 1 << 31)
    check("RECUT_PLACEMENT_RAMP_PCT_S6 frozen at 100/100/130",
          catalog_fold.RECUT_PLACEMENT_RAMP_PCT_S6
          == {"dFinal8": 100, "dFinal4": 100, "dFinal2": 130})
    check("RECUT_PLACEMENT_RAMP_PCT_S8 frozen at 115/130/160 (LADDER B)",
          catalog_fold.RECUT_PLACEMENT_RAMP_PCT_S8
          == {"dFinal8": 115, "dFinal4": 130, "dFinal2": 160})
    for name, table in (("GLORY_VERSION_BY_BUILD",
                         catalog_fold.GLORY_VERSION_BY_BUILD),
                        ("RECUT_PRODUCT_CAP_ARMED_BY_ERA",
                         catalog_fold.RECUT_PRODUCT_CAP_ARMED_BY_ERA),
                        ("RECUT_PLACEMENT_RAMP_PCT_BY_ERA",
                         catalog_fold.RECUT_PLACEMENT_RAMP_PCT_BY_ERA)):
        keys = [row[0] for row in table]
        check(f"{name} is ascending by key (the _era_lookup contract)",
              keys == sorted(keys))
    # The OBSERVED build-tag boundaries: each is the first build at which
    # `git show <build>:src/ctf/glory.nim` declares that GloryVersion*.
    check("observed build-tag boundaries are recorded exactly",
          catalog_fold.GLORY_VERSION_BY_BUILD == (
              ((0, 0, 0), 13), ((0, 7, 342), 14), ((0, 7, 361), 15),
              ((0, 7, 369), 16), ((0, 7, 377), 17), ((0, 7, 397), 18)))


def test_head_aliases_still_match_glory_nim():
    """THE TRIPWIRE. If a ship moves `RecutProductCapArmed` or
    `RecutPlacementRampPct` in glory.nim and only repoints the literal
    here, this fails -- which is the signal to add a NEW `_S<n>` literal and
    a `GLORY_VERSION_BY_BUILD` boundary instead, keeping the old value
    decodable."""
    print("test_head_aliases_still_match_glory_nim")
    src = _read_glory_nim()
    if src is None:
        check("SKIP: src/ctf/glory.nim not in this checkout", True)
        return
    m = re.search(r"RecutProductCapArmed\*\s*=\s*int64\(1\)\s*shl\s*(\d+)", src)
    check("glory.nim declares RecutProductCapArmed*", m is not None)
    if m:
        check(f"RECUT_PRODUCT_CAP_ARMED == glory.nim's 1 shl {m.group(1)} "
              f"(if this fails: ERA-KEY the new value, do not repoint the old one)",
              catalog_fold.RECUT_PRODUCT_CAP_ARMED == (1 << int(m.group(1))))
    for deed in ("dFinal8", "dFinal4", "dFinal2"):
        d = re.search(r"pcts\[" + deed + r"\]\s*=\s*(\d+)", src)
        check(f"glory.nim declares RecutPlacementRampPct[{deed}]", d is not None)
        if d:
            check(f"RECUT_PLACEMENT_RAMP_PCT[{deed}] == glory.nim's {d.group(1)} "
                  f"(if this fails: ERA-KEY the new ladder)",
                  catalog_fold.RECUT_PLACEMENT_RAMP_PCT[deed] == int(d.group(1)))


def test_glory_version_for_build():
    print("test_glory_version_for_build")
    # Real cohort build tags, all four measured cohorts.
    check("0.7.327 -> GLORYVERSION 13 (cap still 2**26)",
          catalog_fold.glory_version_for_build("0.7.327") == 13)
    check("0.7.369 (GV61 cohort) -> GLORYVERSION 16",
          catalog_fold.glory_version_for_build("0.7.369") == 16)
    check("0.7.376 (last GV61-cohort build) -> GLORYVERSION 16",
          catalog_fold.glory_version_for_build("0.7.376") == 16)
    check("0.7.377 (first GV62 / S6 build) -> GLORYVERSION 17",
          catalog_fold.glory_version_for_build("0.7.377") == 17)
    check("0.7.383 (GV62 / S6 cohort) -> GLORYVERSION 17",
          catalog_fold.glory_version_for_build("0.7.383") == 17)
    check("0.7.396 (last pre-S8 build) -> GLORYVERSION 17",
          catalog_fold.glory_version_for_build("0.7.396") == 17)
    check("0.7.397 (the S8 build tag itself) -> GLORYVERSION 18",
          catalog_fold.glory_version_for_build("0.7.397") == 18)
    check("0.7.400 (GV63 cohort) -> GLORYVERSION 18",
          catalog_fold.glory_version_for_build("0.7.400") == 18)
    check("paintbot-v0.7.397 prefix form parses the same",
          catalog_fold.glory_version_for_build("paintbot-v0.7.397") == 18)
    # A version it cannot resolve must FAIL, never silently decode at HEAD.
    raised = False
    try:
        catalog_fold.glory_version_for_build(None)
    except ValueError:
        raised = True
    check("an unparseable coworld_version raises instead of guessing", raised)


def test_cap_is_era_keyed_not_head_keyed():
    """The #538 defect itself: a GV62-era seat whose product saturated at
    the S6 ceiling must still saturate when re-folded today."""
    print("test_cap_is_era_keyed_not_head_keyed")
    check("GLORYVERSION 13 cap == 2**26 (pre-v14 ceiling)",
          catalog_fold.recut_product_cap_armed(13) == 1 << 26)
    check("GLORYVERSION 14 cap == 2**24 (v14 'CAP 2^26 -> 2^24')",
          catalog_fold.recut_product_cap_armed(14) == 1 << 24)
    check("GLORYVERSION 17 cap == 2**24 (16,384 reported)",
          catalog_fold.recut_product_cap_armed(17) == 1 << 24)
    check("GLORYVERSION 18 cap == 2**31 (2,097,152 reported)",
          catalog_fold.recut_product_cap_armed(18) == 1 << 31)

    gv62 = catalog_fold.CATALOG_V3.for_episode({"coworld_version": "0.7.383"})
    gv63 = catalog_fold.CATALOG_V3.for_episode({"coworld_version": "0.7.400"})
    check("a GV62 episode folds against the S6 ceiling", gv62.cap == 1 << 24)
    check("a GV63 episode folds against the S8 ceiling", gv63.cap == 1 << 31)

    # Same seat-events, two eras: the S6-era fold saturates at 16,384
    # reported (the value the 154 GV62 capped rows actually carry), the
    # S8-era fold does not. Folding GV62 under HEAD's ceiling is precisely
    # what dropped the GV62 census from 5,456/5,456 to 5,302/5,456.
    events = [("dHonorableKill", 900)] * 12
    p_s6 = catalog_fold.fold_events_v3(events, gv62)
    p_s8 = catalog_fold.fold_events_v3(events, gv63)
    check("S6-era fold saturates", p_s6 == gv62.cap)
    check("S6-era saturated score reports 16,384",
          catalog_fold.score_from_product(p_s6, 0, gv62) == 16384)
    check("S8-era fold of the SAME events does NOT saturate at 16,384",
          catalog_fold.score_from_product(p_s8, 0, gv63) != 16384)

    check("CATALOG_V2 is era-keyed too",
          catalog_fold.catalog_for("v2", 17).cap == 1 << 24)
    check("fold_events_v2 defaults to the S6-era ceiling (v2 has one era)",
          catalog_fold.fold_events_v2([("dCapture", 1 << 30)]) == 1 << 24)


def test_placement_ramp_is_era_keyed():
    print("test_placement_ramp_is_era_keyed")
    check("GLORYVERSION 17 ramp is S5/S6's 100/100/130",
          catalog_fold.recut_placement_ramp_pct(17)
          == {"dFinal8": 100, "dFinal4": 100, "dFinal2": 130})
    check("GLORYVERSION 18 ramp is LADDER B's 115/130/160",
          catalog_fold.recut_placement_ramp_pct(18)
          == {"dFinal8": 115, "dFinal4": 130, "dFinal2": 160})
    gv62 = catalog_fold.CATALOG_V3.for_episode({"coworld_version": "0.7.383"})
    check("a GV62 episode prices dFinal2 off the S6 ladder",
          gv62.placement_ramp_pct["dFinal2"] == 130)


def test_catalog_map_entries_normalize():
    print("test_catalog_map_entries_normalize")
    label, era = catalog_fold.normalize_catalog_entry(
        {"label": "v3", "gloryVersion": 17}, "0.7.383")
    check("era-keyed entry keeps its own GLORYVERSION", (label, era) == ("v3", 17))
    # Legacy maps on disk hold a bare string; the era then comes from the
    # episode's own build tag, so an old map stays usable.
    label, era = catalog_fold.normalize_catalog_entry("v3", "0.7.383")
    check("legacy bare-string entry falls back to the build tag",
          (label, era) == ("v3", 17))
    label, era = catalog_fold.normalize_catalog_entry("v3", "0.7.400")
    check("legacy bare-string entry on an S8 build resolves to 18",
          (label, era) == ("v3", 18))


def main():
    test_era_stamp_agrees_with_source_and_era_md()
    test_shipped_era_literals_are_frozen()
    test_head_aliases_still_match_glory_nim()
    test_glory_version_for_build()
    test_cap_is_era_keyed_not_head_keyed()
    test_placement_ramp_is_era_keyed()
    test_catalog_map_entries_normalize()
    test_recut_fold_pct_gate_ruling_2()
    test_recut_fold_cap_saturation()
    test_recut_win_factor()
    test_catalog_switches_label()
    test_deed_rates_reports_both()
    test_v3_fold_primitive()
    test_v3_fold_via_census_decode()
    test_v2_fold_via_census_decode()

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
