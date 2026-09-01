#!/usr/bin/env python3
"""The CAUTIOUS starter policy: survives, rides wide margins, calls rarely.

Harness deltas (the code that makes this seat behave unlike the other two):

* ONE re-call, held long -- fewest model turns of the three; between calls
  the seat simply rides its standing ladder,
* ``adjust_entries`` clamps every edge_ride toward the safe end (margin
  floored at 280, early enterLead, high coverBias) and fills any parameter
  the model omitted with a conservative default instead of the play's own --
  whatever the model asked for, this seat plays it safe,
* any pact is softened to ``onBetrayal: disengage`` -- never trade shots.
"""

from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# The safe-end clamps and defaults. build_call has already range-checked the
# values, so these only ever NARROW toward the cautious corner of each range.
MIN_MARGIN = 280
MIN_ENTER_LEAD = 220
MIN_COVER_BIAS = 0.8
SAFE_DEFAULTS = {"margin": 340, "enterLead": 280, "coverBias": 0.9}


def adjust_entries(entries, context, view):
    for entry in entries:
        params = entry.setdefault("params", {})
        if entry.get("play") == "edge_ride":
            for key, value in SAFE_DEFAULTS.items():
                params.setdefault(key, value)
            params["margin"] = max(int(params["margin"]), MIN_MARGIN)
            params["enterLead"] = max(int(params["enterLead"]),
                                      MIN_ENTER_LEAD)
            params["coverBias"] = max(float(params["coverBias"]),
                                      MIN_COVER_BIAS)
        elif entry.get("play") == "pact":
            # Never trade shots, not even with a betrayer.
            params["onBetrayal"] = "disengage"
        elif entry.get("play") == "supply_run":
            # Heal early and never fight over an item. whenHpBelow is
            # ABSOLUTE hp units (a full seat is only a few), so the floor
            # of 4 means "any wound sends you to a medkit".
            params.setdefault("detourMax", 900)
            params["whenHpBelow"] = max(int(params.get("whenHpBelow", 4)), 4)
            params["contested"] = "avoid"
    return entries


PERSONA = Persona(
    name="cautious",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "edge_ride": ("edge_ride is your whole game: margin 280 or wider, "
                      "enterLead 220 or more, coverBias 0.8+. Rotate early, "
                      "arrive first, sit in cover."),
        "pact": ("accept a pact when it reduces threats; onBetrayal is "
                 "always disengage."),
        "supply_run": ("supply_run rides above your edge_ride in every call "
                       "once you have taken ANY damage: whenHpBelow 4+ (hp "
                       "is a small absolute number -- a full seat is only a "
                       "few units), wide detourMax, contested always avoid."),
        # Notes for plays lane C has not landed yet; each activates
        # automatically once its module is baked and plays.py knows it.
        "bodyguard": ("bodyguard only for a partner already in a pact, and "
                      "with a wide leash -- never interpose."),
        "target_law": ("target_law: a long never-list and a hold trigger; "
                       "the first shot is a commitment you rarely want."),
    },
    canned_turns=[
        {
            "chat": "No heroes over here. Riding the wide line, "
                    "cover to cover. Good luck all.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "shelter",
                 "params": {"margin": 420, "enterLead": 320,
                            "coverBias": 1.0}},
            ]},
        },
        {
            "chat": "Holding my corridor. If I take a scratch I am "
                    "going straight for a medkit.",
            "call": {"entries": [
                {"play": "supply_run", "entry_id": "medkit",
                 "params": {"whenHpBelow": 5, "detourMax": 900,
                            "contested": "avoid"}},
                {"play": "edge_ride", "entry_id": "shelter",
                 "params": {"margin": 340, "enterLead": 300,
                            "coverBias": 1.0}},
            ]},
        },
    ],
    recall_count=1,
    recall_seconds=14.0,
    adjust_entries=adjust_entries,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
