#!/usr/bin/env python3
"""Fixture tests for br_reads.py (stdlib only, no network, no live cache
needed) — same idiom as test_encounters.py: hand-built extractions with
pre-computed expected numbers, so a wrong classification or a swapped
source/target convention fails loudly instead of reporting a confident wrong
answer. This is the offline half of validation; br_reads.py has also been
smoke-tested against the live Paintbot ffa4 corpus (see the module docstring
and the tool's own README entry) — that catches drift from the real wire
schema, this catches drift from the tool's own arithmetic.

Run from anywhere: python3 tools/ladder/test_br_reads.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import scout                                                   # noqa: E402
import br_reads as br                                          # noqa: E402

FIXTURE_DIR = str(HERE / "testdata" / "br_reads_fixture")

# Point scout's event cache at our fixtures instead of ~/.ctf/scout/events —
# build_row() reaches events exclusively through scout.load_events(ep), the
# same path the live tool uses, so this exercises the real code, not a copy.
scout.EVENT_DIR = FIXTURE_DIR


def ep_for(name, replay="fixture", coworld_version="0.7.999", participants=None):
    return {
        "replay_url": f"https://example.invalid/replays/{replay}.replay",
        "variant_name": "4-team free-for-all",
        "coworld_version": coworld_version,
        "participants": participants or [],
    }


# ep-ok.jsonl needs its event file to resolve to the exact replay name used
# below (scout.event_path replaces ".replay" with ".jsonl" on the url tail).
def participants_for_ok():
    # positions 0,1=red -> pv "P_RED"; 2,3=blue -> "P_BLUE"; 4,5=green ->
    # "P_GREEN"; 6,7=yellow -> "P_YELLOW" (the Baseline control's own policy).
    out = []
    for pos, pv, name in [
        (0, "P_RED", "Red Policy"), (1, "P_RED", "Red Policy"),
        (2, "P_BLUE", "Blue Policy"), (3, "P_BLUE", "Blue Policy"),
        (4, "P_GREEN", "Green Policy"), (5, "P_GREEN", "Green Policy"),
        (6, "P_YELLOW", "Baseline"), (7, "P_YELLOW", "Baseline"),
    ]:
        out.append({"position": pos, "policy_version_id": pv,
                    "policy_name": name})
    return out


# --- pure functions -----------------------------------------------------

assert br.classify_weapon("gun") == "combat"
assert br.classify_weapon("spray") == "combat"
assert br.classify_weapon("grenade") == "combat"
assert br.classify_weapon("puddle") == "hazard_other"
assert br.classify_weapon("ring") == "zone"
assert br.classify_weapon("zone") == "zone"
assert br.classify_weapon("") == "unknown"
assert br.classify_weapon("never-seen") == "unknown"

assert br.base_name("relh (3)") == "relh"
assert br.base_name("relh (2)") == "relh"
assert br.base_name("Baseline") == "Baseline"
assert br.base_name("") == ""
assert br.base_name("weird (x)") == "weird (x)", "non-digit suffix must not strip"

assert abs(br.percentile_interp([1, 2, 3, 4], 0.5) - 2.5) < 1e-9
assert br.percentile_interp([5], 0.025) == 5
assert br.percentile_interp([], 0.5) != br.percentile_interp([], 0.5)  # nan != nan

# --- boot_floor: grading + point estimate --------------------------------
# 3 spawns: a=6/10 (graded, share .6), b=2/10 (thin, only 2 wins), c=5/5
# (graded, share 1.0, exactly at the min-wins boundary -> included).
shares = {"a": (6, 10), "b": (2, 10), "c": (5, 5)}
pt, lo, hi, n_graded, n_thin = br.boot_floor(shares, min_wins=5)
assert n_graded == 2, n_graded
assert n_thin == 1, n_thin
expected_pt = br.percentile_interp([0.6, 1.0], br.FLOOR_PCT)
assert abs(pt - expected_pt) < 1e-9, (pt, expected_pt)

# --- boot_mean / boot_ratio: basic correctness ---------------------------
pt, lo, hi, n = br.boot_mean([1, 1, 1, 0, 0])
assert abs(pt - 0.6) < 1e-9  # 3/5
assert n == 5
pt, lo, hi, n = br.boot_mean([])
assert pt != pt  # nan

pt, lo, hi, n, den = br.boot_ratio([(5, 10), (3, 10)])
assert abs(pt - 0.4) < 1e-9  # 8/20
assert den == 20

# --- build_row: the real fixture ------------------------------------------

ep_ok = ep_for("ok", replay="ep-ok", participants=participants_for_ok())
row = br.build_row(rnd=1, ep=ep_ok, groups=4)
assert row is not None, "ep-ok.jsonl should build a row"
assert row["n_groups"] == 4
assert row["winner"] == "red"
teams = row["teams"]
assert set(teams) == {"red", "blue", "green", "yellow"}

red, blue, green, yellow = teams["red"], teams["blue"], teams["green"], teams["yellow"]

# red: killed by green (gun, combat), shots 10+5=15, hits 5+2=7, dmg taken 1+1=2
assert red["won"] is True
assert red["deaths"] == 1 and red["deaths_combat"] == 1
assert red["deaths_zone"] == 0 and red["deaths_hazard_other"] == 0
assert red["kills"] == 0
assert red["dmg_taken"] == 2 and red["dmg_dealt"] == 0
assert red["shots"] == 15 and red["hits"] == 7
assert red["is_control"] is False

# blue: killed by an environmental puddle hit (source=-1) -> hazard_other,
# NOT zone (puddle is an existing CTF hazard, distinct from the BR shrink).
assert blue["won"] is False
assert blue["deaths"] == 1 and blue["deaths_hazard_other"] == 1
assert blue["deaths_combat"] == 0 and blue["deaths_zone"] == 0
assert blue["dmg_taken"] == 1
assert blue["shots"] == 12 and blue["hits"] == 4

# green: credited with red's kill via the `kill` event (source=killer=4)
assert green["kills"] == 1
assert green["deaths"] == 0
assert green["dmg_dealt"] == 2  # the two `damage` rows at tick 10/20
assert green["shots"] == 18 and green["hits"] == 8

# yellow: two shield pickups + one grenade pickup; fields Baseline -> control
assert yellow["pickups"] == {"shield": 2, "grenade": 1}
assert yellow["is_control"] is True
assert yellow["policy_version_id"] == "P_YELLOW"
assert yellow["mixed_policy"] is False

# --- build_row: exclusions -------------------------------------------------

br.EXCLUSION_REASONS.clear()
ep_bad_geom = ep_for("bad-geom", replay="ep-wrong-geometry")
row = br.build_row(rnd=1, ep=ep_bad_geom, groups=4)
assert row is None, "a 2-team episode must be excluded when groups=4"
assert any(k.startswith("geometry_") for k in br.EXCLUSION_REASONS), br.EXCLUSION_REASONS

# ...but the SAME file is fine if the caller actually wants 2-group geometry.
row2 = br.build_row(rnd=1, ep=ep_bad_geom, groups=2)
assert row2 is not None and row2["n_groups"] == 2

br.EXCLUSION_REASONS.clear()
ep_unfin = ep_for("unfin", replay="ep-unfinished")
row = br.build_row(rnd=1, ep=ep_unfin, groups=4)
assert row is None, "an unfinished episode must be excluded"
assert br.EXCLUSION_REASONS["unfinished"] == 1

# a replay with no cached event file at all (never fetched) must also be
# excluded, not crash.
br.EXCLUSION_REASONS.clear()
ep_missing = ep_for("missing", replay="does-not-exist")
row = br.build_row(rnd=1, ep=ep_missing, groups=4)
assert row is None
assert br.EXCLUSION_REASONS["no_extraction"] == 1

print("all br_reads.py fixture tests passed "
      f"({FIXTURE_DIR}: kill/death source-target convention, puddle-vs-zone "
      "classification, Baseline-via-slot_address, and geometry/unfinished/"
      "missing exclusions all verified against hand-computed expected values)")
