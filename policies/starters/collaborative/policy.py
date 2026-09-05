#!/usr/bin/env python3
"""The COLLABORATIVE starter policy: the social-alliance seat.

16-solo pivot (this file was rewritten, not patched): S2 is now 16 solo
entrants, one policy/bot/team each -- there is no duo partner, and no
wire-level alliance mechanic exists at all (no shared team, no protect
scoring, nothing the engine enforces). Every other starter just survives
solo; this one is the showcase for the one thing that is still true of a
16-solo field: seats can still make and keep PACTS -- entirely through
conduct, negotiated and honored in the open over lobby chat (the closest
thing this match has to the forum's pre-match huddle), never enforced by
the sim.

Harness deltas (the code that makes this seat behave unlike the other two):

* it opens every match with a public truce offer on the lobby channel
  instead of a directed coordination line -- there is no partner to direct
  it at,
* ``pact``'s partners are never hardcoded (there is no ground-truth ally):
  whatever seat references the MODEL proposes from reading the roster and
  lobby chat are kept as-is, with only generic repair (a sane onBetrayal
  default) -- the alliance itself is the model's judgment call, not a
  scripted seat number,
* otherwise the ladder is a straight solo-survival build, keyed between
  the cautious and aggressive starters' margins: alliances are a bonus a
  social seat can earn, not a substitute for surviving alone.

The shared harness (``starter_harness.py``) still carries all of its
duo-partner plumbing (``context.self.duo_partner``, ``partner_focus``,
``bodyguard``/``crossfire``'s ward-defaults-to-partner) unchanged -- it is
simply never exercised here, because a solo match's context carries no
``duo_partner`` to find. Kept code, not dead code: nothing about this file
depends on it being removed.
"""

from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# Solo-survival defaults, deliberately between the cautious and aggressive
# starters' clamps -- this seat is not the widest margin in the field, but
# it is not the tightest either.
SOLO_DEFAULTS = {"margin": 260, "enterLead": 180, "coverBias": 0.7}


def adjust_entries(entries, context, view):
    for entry in entries:
        params = entry.setdefault("params", {})
        if entry.get("play") == "edge_ride":
            for key, value in SOLO_DEFAULTS.items():
                params.setdefault(key, value)
        elif entry.get("play") == "pact":
            # No hardcoded ally: whatever seat(s) the model named from
            # reading the roster/lobby chat stay as proposed. Honor the
            # pact by default (disengage on betrayal is the courteous
            # floor); the model may set returnFire itself if it judges a
            # partner has genuinely turned.
            params.setdefault("onBetrayal", "disengage")
        elif entry.get("play") == "loot":
            params["contested"] = "avoid"
    if not any(e.get("play") == "edge_ride" for e in entries):
        entries.append({"play": "edge_ride", "entry_id": "solo",
                        "params": dict(SOLO_DEFAULTS)})
    if not any(e.get("play") == "loot" for e in entries):
        entries.append({"play": "loot", "entry_id": "loot",
                        "params": {"detourMax": 400, "contested": "avoid"}})
    return entries


def extra_chat(context, turn):
    """A public truce offer, not a partner-directed line -- there is no
    fixed partner to address in a 16-solo field. Named allies (from a
    lobby reply, or from a chat pact struck earlier) are the model's own
    read of the roster; this line only ever proposes or reaffirms, in the
    open, on the assumption anyone can take it up."""
    if turn == 1:
        return ("Open offer: first two minutes, no fights with me if you "
                "return the favor. After that we are all solo again -- no "
                "hard feelings either way.")
    return ("Standing offer still open to anyone who wants it. If we struck "
            "something earlier I am keeping it unless you shoot first.")


PERSONA = Persona(
    name="collaborative",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "loot": ("loot: grenades, shields, and spray cans are worth a short "
                 "detour whenever nobody is tracked; never fight over one. "
                 "The harness gates it."),
        "pact": ("pact is how you make a chat alliance real: name the "
                 "seat(s) you have actually agreed something with -- never "
                 "invent one nobody offered -- protect off by default "
                 "(you are not obligated to die for an ally you only just "
                 "met), onBetrayal disengage unless they have already "
                 "shot at you."),
        "edge_ride": ("edge_ride is your solo game between calls: margin "
                      "around 260, moderate enterLead and coverBias -- "
                      "not the widest line in the field, not the "
                      "tightest."),
        "supply_run": ("supply_run when wounded, same as anyone: race for "
                       "nothing, avoid a contested medkit."),
        "target_law": ("target_law: keep any chat allies on the never-list "
                       "while the pact holds; drop them off it the moment "
                       "they shoot first. Otherwise prefer weakened or "
                       "isolated targets like anyone playing to survive."),
    },
    canned_turns=[
        {
            "chat": "Open offer: first two minutes, no fights with me if "
                    "you return the favor.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "solo",
                 "params": dict(SOLO_DEFAULTS)},
            ]},
        },
        {
            "chat": "Nobody took the offer, or somebody already broke it. "
                    "Playing it straight from here.",
            "call": {"entries": [
                {"play": "edge_ride", "entry_id": "solo",
                 "params": dict(SOLO_DEFAULTS)},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
            ]},
        },
    ],
    recall_count=1,
    recall_seconds=10.0,
    max_calls=6,
    adjust_entries=adjust_entries,
    extra_chat=extra_chat,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
