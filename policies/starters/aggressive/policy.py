#!/usr/bin/env python3
"""The AGGRESSIVE starter policy: hunts, rides tight margins, re-calls often.

Harness deltas (the code that makes this seat behave unlike the other two):

* the tightest live-loop schedule of the three (up to 8 model calls a match,
  6 s apart); a tight edge_ride is the always-on base rung, and jackal rides
  above it whenever an enemy is tracked,
* the match summary carries kill-feed lines, so the model reacts to fights,
* ``adjust_entries`` pins the wire ladder to one lane ride -- ``target_law``
  (prefer weakened, isolated; empty never-list) over ``edge_ride`` at margin
  240 / enterLead 260 / coverBias 0.8 -- whatever the model asked for. The
  model still talks and re-calls, but it no longer drives the seat off the
  rotation lane. ``HUNTER_RIDE=free`` restores the model-driven ladder (the
  v5 behaviour: clamped edge_ride, jackal/loot/supply_run rungs).
"""

from __future__ import annotations

import os
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# The tight-end clamps. build_call has already ranged-checked the values, so
# these only ever NARROW toward the aggressive corner of each range.
MAX_MARGIN = 260
MAX_ENTER_LEAD = 200
MAX_COVER_BIAS = 0.8

# HUNTER_RIDE=wide rides the margins the two canned policies that out-tag
# this seat use (edge_ride defaults / margin 300, cover 0.9): the tight ride
# spent 3x the field's ticks in reflex_zone_escape.
RIDE_MODE = os.environ.get("HUNTER_RIDE", "lane").lower()
WIDE_RIDE = RIDE_MODE == "wide"
WIDE_MIN_MARGIN = 220
WIDE_MAX_MARGIN = 320
WIDE_MIN_ENTER_LEAD = 120
WIDE_MIN_COVER_BIAS = 0.8

# The lane ride: the one ladder the pure edge_ride seats in the S2 league
# (docxology, relh, richard) call all game, and every one of them out-tags
# the model-driven ladder. The harness still puts scatter on top during the
# spawn phase and the zone reflex still fires; nothing else rides.
LANE_LADDER = [
    {"play": "target_law", "entry_id": "law",
     "params": {"prefer": ["weakened", "isolated"], "never": []}},
    {"play": "edge_ride", "entry_id": "lane",
     "params": {"margin": 240, "enterLead": 260, "coverBias": 0.8}},
]


def adjust_entries(entries, context, view):
    if RIDE_MODE != "free" and not WIDE_RIDE:
        entries[:] = [dict(e, params=dict(e["params"])) for e in LANE_LADDER]
        return entries
    # Season 2 seats are solo: a pact is a no-shoot list handed to an
    # opponent who owes nothing back, and a never-list is the same thing by
    # another name (the model was putting the nearest 1-hp target on it).
    entries[:] = [e for e in entries if e.get("play") != "pact"]
    for entry in entries:
        params = entry.setdefault("params", {})
        if entry.get("play") == "edge_ride":
            if WIDE_RIDE:
                params["margin"] = max(WIDE_MIN_MARGIN, min(
                    int(params.get("margin", 220)), WIDE_MAX_MARGIN))
                params["enterLead"] = max(WIDE_MIN_ENTER_LEAD,
                                          int(params.get("enterLead", 120)))
                params["coverBias"] = max(WIDE_MIN_COVER_BIAS,
                                          float(params.get("coverBias", 0.8)))
            else:
                params["margin"] = min(int(params.get("margin", 180)), MAX_MARGIN)
                params["enterLead"] = min(int(params.get("enterLead", 120)),
                                          MAX_ENTER_LEAD)
                params["coverBias"] = min(float(params.get("coverBias", 0.5)),
                                          MAX_COVER_BIAS)
        elif entry.get("play") == "target_law":
            params["never"] = []
            params.pop("holdTrigger", None)
        elif entry.get("play") == "supply_run":
            # A contested medkit is a fight worth taking.
            params["contested"] = "race"
        elif entry.get("play") == "loot":
            params["contested"] = "race"
    if not any(e.get("play") == "loot" for e in entries):
        # Grenades and spray cans are the hunter's tools; race for them.
        entries.append({"play": "loot", "entry_id": "loot",
                        "params": {"detourMax": 500, "contested": "race"}})
    return entries


PERSONA = Persona(
    name="aggressive",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "loot": ("loot: grenades and spray cans are your tools -- race for "
                 "them when nobody is tracked; the harness gates it."),
        "edge_ride": ("edge_ride is your hunting lane: margin 140-260, "
                      "enterLead up to 200, coverBias up to 0.8. The edge is "
                      "where the rotations funnel -- meet them there, from "
                      "cover."),
        "pact": ("pact is not your play: every seat is solo, nobody owes "
                 "you a truce back, and a pact only takes targets off your "
                 "gun. Skip it."),
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
        "target_law": ("target_law: prefer weakened and isolated targets. "
                       "The never-list is a DO-NOT-SHOOT list, not a target "
                       "list: keep it EMPTY (never put a tracked enemy on "
                       "it), and NEVER set a holdTrigger -- you fire at "
                       "will."),
    },
    canned_turns=[
        {
            "chat": "Dropping hot. First blood inside the minute -- "
                    "watch the feed.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "hunt",
                 "params": {"margin": 200, "enterLead": 140,
                            "coverBias": 0.5}},
            ]},
        },
        {
            "chat": "Feed is ticking. Pushing the next fight -- the "
                    "wounded first.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "hunt",
                 "params": {"margin": 170, "enterLead": 110,
                            "coverBias": 0.45}},
                # The hunter's standing law: bias toward the easy kills,
                # no never-list, no hold -- fire at will.
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
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
                 "params": {"margin": 140, "enterLead": 80,
                            "coverBias": 0.4}},
            ]},
        },
    ],
    recall_count=2,
    recall_seconds=6.0,
    max_calls=8,
    # The always-on rung is a close edge_ride; jackal is a gated rung that
    # the harness puts above it only while an enemy is tracked. Jackal as
    # the base (v4-v15) won the all-starter self-play arms, but against the
    # field (XP xreq_619f6a5f, 20 episodes) it finished 7th of 8 at 0.53
    # kills while both edge_ride-based starters scored 0.70-0.78: an idle
    # jackal holds in cover and waits for fights that a field of cautious
    # bots never starts. v16 tried edge_ride at the old 40-60 px margins
    # and lost survival (944 -> 567 ticks) and items (1.27 -> 0.35): the
    # seat lived on the zone line with no cover. v17 keeps edge_ride and
    # rides it at 140-260 px like the two starters that outscore it.
    base_play="edge_ride",
    # Scatter until the first shrink (~340 ticks), not 150: on GV52 the
    # aggressive seat still lost 17 of 37 lives before tick 300, hunting
    # into a field that is densest right after the drop.
    spawn_phase_ticks=340,
    include_kill_feed=True,
    adjust_entries=adjust_entries,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
