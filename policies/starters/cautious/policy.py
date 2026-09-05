#!/usr/bin/env python3
"""The CAUTIOUS starter policy: survives, rides wide margins, calls rarely.

Harness deltas (the code that makes this seat behave unlike the other two):

* the sparsest live-loop schedule of the three (up to 4 model calls a match,
  15 s apart); between calls the seat rides its standing ladder and the
  harness only re-sends it when a gate (a medkit while wounded, a safe
  pickup) opens or closes,
* ``target_law holdTrigger {zonePhase: 1}`` -- which releases at the drop
  (the zone reports phase 1 from the first tick), so in practice NO hold: the
  phase-2 hold it replaced cost 26 gun deaths in 30 competitive episodes,
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
        elif entry.get("play") == "target_law":
            # Hold fire through the opening brawl, then FIGHT. The old
            # `aliveTeams: 6` trigger never released in practice -- across
            # 19 hosted episodes cautious seats fired 0.08 shots and banked
            # zero Glory, because they died before the field thinned to six.
            # A zone-phase trigger releases on the clock (phase 2 is ~25 s
            # into play), and an aliveTeams trigger is clamped so it can
            # release once the first team falls.
            # Competitive rounds 3705-3706: 26 of 45 cautious deaths were gun
            # kills, 12 of them before tick 600, while the seat held fire
            # for zone phase 2 -- it walked around visible and never shot
            # back. The zone reports phase 1 from the first tick, so a
            # phase-1 trigger releases at the drop: effectively no hold at
            # all -- and the seat leads the field that way (1.00 kills, 1st
            # of 8 on GV52). Kept as the documented shape rather than
            # dropping target_law, so the never-list still rides along.
            trigger = params.get("holdTrigger")
            if isinstance(trigger, dict) and "aliveTeams" in trigger:
                trigger["aliveTeams"] = max(int(trigger["aliveTeams"]), 7)
            elif isinstance(trigger, dict) and "zonePhase" in trigger:
                trigger["zonePhase"] = min(int(trigger["zonePhase"]), 1)
            elif not isinstance(trigger, dict):
                params["holdTrigger"] = {"zonePhase": 1}
        elif entry.get("play") == "supply_run":
            # Heal early and never fight over an item. whenHpBelow is
            # ABSOLUTE hp units (a full seat is only a few), so the floor
            # of 4 means "any wound sends you to a medkit".
            params.setdefault("detourMax", 900)
            params["whenHpBelow"] = max(int(params.get("whenHpBelow", 4)), 4)
            params["contested"] = "avoid"
        elif entry.get("play") == "loot":
            params["contested"] = "avoid"
            params["detourMax"] = min(int(params.get("detourMax", 300)), 300)
    if not any(e.get("play") == "loot" for e in entries):
        # Short, safe detours only: a shield or a grenade within 300 px
        # when nobody is tracked. The harness guard keeps it off the
        # ladder the moment an enemy appears.
        entries.append({"play": "loot", "entry_id": "loot",
                        "params": {"detourMax": 300, "contested": "avoid"}})
    return entries


PERSONA = Persona(
    name="cautious",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "loot": ("loot: short, safe detours only -- a shield or a grenade "
                 "within 300 px while nobody is tracked; the harness keeps "
                 "it off the ladder the moment an enemy appears."),
        "edge_ride": ("edge_ride is your whole game: margin 280 or wider, "
                      "enterLead 220 or more, coverBias 0.8+. Rotate early, "
                      "arrive first, sit in cover."),
        "pact": ("accept a pact when it reduces threats; onBetrayal is "
                 "always disengage."),
        "supply_run": ("supply_run rides above your edge_ride in every call "
                       "once you have taken ANY damage: whenHpBelow 4+ (hp "
                       "is a small absolute number -- a full seat is only a "
                       "few units), wide detourMax, contested always avoid."),
        "bodyguard": ("bodyguard only for an ally already in a pact, and "
                      "with a wide leash -- never interpose. Solo is the "
                      "default; this is for the rare in-match ally, not a "
                      "duo you start with."),
        "target_law": ("target_law: always carry a holdTrigger, but one "
                       "that actually releases while you are alive -- "
                       '{"zonePhase": 1} releases at the drop (the zone '
                       "reports phase 1 from the first tick) -- carry it, "
                       "but do not expect a hold; an aliveTeams "
                       "trigger below 7 never fires before you die. A "
                       "released hold NEVER re-arms."),
    },
    canned_turns=[
        {
            "chat": "No heroes over here. Riding the wide line, shooting "
                    "only what comes to me. Good luck all.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "shelter",
                 "params": {"margin": 420, "enterLead": 320,
                            "coverBias": 1.0}},
                # The documented hold shape; phase 1 is the opening phase,
                # so this releases at the drop (see adjust_entries).
                {"play": "target_law", "entry_id": "discipline",
                 "params": {"holdTrigger": {"zonePhase": 1}}},
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
    recall_seconds=15.0,
    max_calls=4,
    adjust_entries=adjust_entries,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
