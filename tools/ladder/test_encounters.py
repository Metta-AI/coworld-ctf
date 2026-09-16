#!/usr/bin/env python3
"""Fixture tests for encounters.py (stdlib only, no network, no cache needed).

Run from anywhere: python3 tools/ladder/test_encounters.py

Exercises the pure encounter-splitting logic directly, then runs the real
`analyze_file` entry point against testdata/encounters_fixture.jsonl — a
hand-built extraction containing an "achievement" row and a "glory_deed" row
(kinds `events.nim`/`extract_events.nim` on main do not emit) plus an extra
"gloryVersion" key on the summary row, standing in for the sibling
Achievement/GloryDeed/LevelUp branch's additions. The fixture proves
encounters.py reads only the kinds/keys it names and silently ignores
anything else, rather than crashing or double-counting.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from encounters import (  # noqa: E402
    analyze_file, encounters_by_pair, is_combat_damage, pair_key,
)

FIXTURE = str(Path(__file__).resolve().parent / "testdata" / "encounters_fixture.jsonl")


def dmg(tick, source, target, weapon="gun"):
    return {"tick": tick, "kind": "damage", "source": source, "target": target,
            "weapon": weapon, "amount": 1}


# --- is_combat_damage -------------------------------------------------

assert is_combat_damage(dmg(1, 0, 1)) is True
assert is_combat_damage(dmg(1, -1, 1, weapon="puddle")) is False, \
    "puddle damage (source=-1) must not count as combat"
assert is_combat_damage(dmg(1, 2, 2, weapon="grenade")) is False, \
    "source == target (self-hit) must not count as combat"
assert is_combat_damage({"tick": 1, "kind": "achievement", "source": 0,
                          "target": -1, "weapon": "", "deed": "pacifist"}) is False, \
    "a non-damage kind, even with extra unknown fields, must not count"
assert is_combat_damage(dmg(1, 0, -1)) is False, "negative target must not count"

# --- encounters_by_pair: gap splitting, unordered pair, unknown-kind noise

events = [
    dmg(100, 0, 1), dmg(150, 1, 0), dmg(200, 0, 1),  # one run, same pair
    {"tick": 120, "kind": "glory_deed", "source": 0, "xp": 40},  # noise row
    dmg(800, 0, 1),  # gap of 600 > 300 -> a second encounter, same pair
]
by_pair = encounters_by_pair(events, gap=300)
assert by_pair == {pair_key(0, 1): 2}, by_pair

# A 300-tick gap exactly at the threshold does NOT split (only > gap does).
tight = [dmg(0, 0, 1), dmg(300, 0, 1)]
assert encounters_by_pair(tight, gap=300) == {pair_key(0, 1): 1}
loose = [dmg(0, 0, 1), dmg(301, 0, 1)]
assert encounters_by_pair(loose, gap=300) == {pair_key(0, 1): 2}

# --- analyze_file against the real fixture -----------------------------

stats = analyze_file(FIXTURE, player="softmaxwell", gap=300)
assert stats is not None
assert not stats.missing_summary
assert stats.game_version == "99"
assert stats.seats == 4
# pair(0,1): ticks 100,150,200,800 -> 2 encounters (gap 600 > 300 splits once)
# pair(0,2): tick 300 -> 1 encounter, both "softmaxwell" seats -> friendly fire
# pair(1,3): tick 400 -> 1 encounter, relh vs Baseline, neither is us -> 3rd party
assert stats.total_encounters == 4, stats.total_encounters
assert stats.friendly_fire_encounters == 1, stats.friendly_fire_encounters
assert stats.third_party_encounters == 1, stats.third_party_encounters
assert stats.my_encounters == 3, stats.my_encounters  # 2 vs relh + 1 friendly-fire
assert stats.per_opponent == {"relh": 2}, stats.per_opponent
assert stats.opponents_faced == 1
# playing window: tick 0 ("playing") to summary ticks=900 -> 900 ticks = 0.5 min
assert abs(stats.playing_sec - 30.0) < 1e-6, stats.playing_sec
assert abs(stats.encounters_per_min - 8.0) < 1e-6, stats.encounters_per_min
assert abs(stats.my_encounters_per_min - 6.0) < 1e-6, stats.my_encounters_per_min

print("all encounters.py fixture tests passed "
      f"({FIXTURE}: unknown kinds + extra summary key tolerated cleanly)")
