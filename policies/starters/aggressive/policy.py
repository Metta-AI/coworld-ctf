#!/usr/bin/env python3
"""The AGGRESSIVE starter policy: hunts, rides tight margins, re-calls often.

Harness deltas (the code that makes this seat behave unlike the other two):

* short re-call interval and TWO re-calls (three model turns total),
* the match summary carries kill-feed lines, so the model reacts to fights,
* ``adjust_entries`` clamps every edge_ride toward the tight end (margin
  capped at 160, small enterLead, low coverBias) and forces any pact to
  ``onBetrayal: returnFire`` -- whatever the model asked for, this seat plays
  forward.
"""

from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# The tight-end clamps. build_call has already ranged-checked the values, so
# these only ever NARROW toward the aggressive corner of each range.
MAX_MARGIN = 160
MAX_ENTER_LEAD = 120
MAX_COVER_BIAS = 0.5


def adjust_entries(entries, context, view):
    for entry in entries:
        params = entry.setdefault("params", {})
        if entry.get("play") == "edge_ride":
            params["margin"] = min(int(params.get("margin", 100)), MAX_MARGIN)
            params["enterLead"] = min(int(params.get("enterLead", 60)),
                                      MAX_ENTER_LEAD)
            params["coverBias"] = min(float(params.get("coverBias", 0.3)),
                                      MAX_COVER_BIAS)
        elif entry.get("play") == "pact":
            # An aggressive pact is a tool: any betrayal is answered.
            params["onBetrayal"] = "returnFire"
            params["protect"] = False
        elif entry.get("play") == "supply_run":
            # A contested medkit is a fight worth taking.
            params["contested"] = "race"
    return entries


PERSONA = Persona(
    name="aggressive",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "edge_ride": ("edge_ride is your hunting lane: margin under 160, "
                      "small enterLead, low coverBias. The edge is where the "
                      "rotations funnel -- meet them there."),
        "pact": ("pact only when it buys you a fight you would lose alone; "
                 "never protect, always returnFire on betrayal."),
        "supply_run": ("supply_run only when a kit is on your path or "
                       "contested -- and a contested kit you RACE, never "
                       "avoid. Keep whenHpBelow low; healing is for after "
                       "the fight."),
        "bodyguard": ("bodyguard is not your play -- you are nobody's "
                      "shield. Skip it."),
        "jackal": ("jackal is your signature: wide earshot, join after the "
                   "first kill, exit with one or two kills banked. Be "
                   "honest with yourself: the kill feed only tells you a "
                   "fight HAPPENED -- you can only move on fights your own "
                   "fog tracks can see."),
        "crossfire": ("crossfire: tight spacing band, wide angles -- "
                      "concentrate the opening volley. Your partner is only "
                      "where your own tracks last saw them."),
        # Notes for plays lane C has not landed yet; each activates
        # automatically once its module is baked and plays.py knows it.
        "target_law": ("target_law: prefer weakened and isolated targets; "
                       "keep the never-list empty unless a pact demands it."),
    },
    canned_turns=[
        {
            "chat": "Dropping hot. First blood inside the minute -- "
                    "watch the feed.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "hunt",
                 "params": {"margin": 60, "enterLead": 40,
                            "coverBias": 0.25}},
            ]},
        },
        {
            "chat": "Feed is ticking. Pushing the next fight.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "hunt",
                 "params": {"margin": 50, "enterLead": 20,
                            "coverBias": 0.2}},
            ]},
        },
        {
            "chat": "Somebody just died out there. Going shopping.",
            "call": {"entries": [
                # The jackal takes over as the driving controller; the tight
                # edge ride stays behind it as the fallback rung.
                {"play": "jackal", "entry_id": "scavenge",
                 "params": {"earshot": 900, "joinWhen": "afterKill",
                            "exitAfter": {"kills": 2}}},
                {"play": "edge_ride", "entry_id": "hunt",
                 "params": {"margin": 40, "enterLead": 0,
                            "coverBias": 0.15}},
            ]},
        },
    ],
    recall_count=2,
    recall_seconds=4.0,
    include_kill_feed=True,
    adjust_entries=adjust_entries,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
