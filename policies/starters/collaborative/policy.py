#!/usr/bin/env python3
"""The COLLABORATIVE starter policy: duo-first, pact always, talks constantly.

Harness deltas (the code that makes this seat behave unlike the other two):

* the match summary leads with the PARTNER's state (position, hp, alive),
  before the seat's own facts,
* an extra partner-directed coordination line is sent on the lobby channel
  every model turn, on top of whatever the model chose to say,
* ``adjust_entries`` guarantees the duo pact: a pact entry with the actual
  duo partner (read from the seat's own play_context, never hardcoded),
  ``protect: true`` forced, disengage on betrayal -- and a steady edge_ride
  controller behind it if the model forgot one.
"""

from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

TOGETHER_DEFAULTS = {"margin": 260, "enterLead": 180, "coverBias": 0.85}


def adjust_entries(entries, context, view):
    partner = (context.get("self") or {}).get("duo_partner")

    pact = next((e for e in entries if e.get("play") == "pact"), None)
    if pact is None:
        pact = {"play": "pact", "entry_id": "duo_pact", "params": {}}
        entries.insert(0, pact)
    params = pact.setdefault("params", {})
    partners = [p for p in params.get("partners", []) if isinstance(p, str)]
    if partner is not None and f"seat:{partner}" not in partners:
        partners.append(f"seat:{partner}")
    params["partners"] = partners
    params["protect"] = True                  # the non-negotiable
    params.setdefault("onBetrayal", "disengage")

    for entry in entries:
        if entry.get("play") == "bodyguard":
            # Guarding is always for the duo partner, and always interposing.
            guard = entry.setdefault("params", {})
            guard["interpose"] = True
            if partner is not None:
                guard["ward"] = f"seat:{partner}"
        elif entry.get("play") == "target_law":
            # The partner is on the never-list, whatever the model said.
            law = entry.setdefault("params", {})
            never = [p for p in law.get("never", []) if isinstance(p, str)]
            if partner is not None and f"seat:{partner}" not in never:
                never.append(f"seat:{partner}")
            if never:
                law["never"] = never

    if not any(e.get("play") in ("edge_ride", "bodyguard")
               for e in entries):
        entries.append({"play": "edge_ride", "entry_id": "together",
                        "params": dict(TOGETHER_DEFAULTS)})
    return entries


def extra_chat(context, turn):
    """One deliberate partner-directed coordination line per model turn."""
    partner = (context.get("self") or {}).get("duo_partner")
    if partner is None:
        return None
    if turn == 1:
        return (f"seat {partner}: pact is live and protect is on. Hold "
                "150px off my shoulder, stay out of my firing line, and "
                "we rotate together.")
    return (f"seat {partner}: rotating with the zone edge -- stay on my "
            "flank, shout if you take fire and I will peel.")


PERSONA = Persona(
    name="collaborative",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "pact": ("pact is your first entry in EVERY call: your duo partner "
                 "in partners, protect true, disengage on betrayal."),
        "edge_ride": ("edge_ride steady and readable (margin ~260) so your "
                      "partner can hold formation on you."),
        "bodyguard": ("bodyguard is how you carry the pact mid-match: ward "
                      "your partner (it defaults to them), tight leash like "
                      "[60, 180], interpose true, peelHp 3 so you peel "
                      "attackers off them early (hp is a small absolute "
                      "number)."),
        # Notes for plays lane C has not landed yet; each activates
        # automatically once its module is baked and plays.py knows it.
        "crossfire": ("crossfire is the duo's teeth: keep the spacing band "
                      "so both guns bear without friendly-fire geometry. It "
                      "sees your partner only through your own fog tracks, "
                      "so stay where you can see each other."),
        "supply_run": ("supply_run for your PARTNER's health as much as "
                       "yours; race the medkit they cannot reach."),
        "target_law": ("target_law's never-list always carries your "
                       "partner (the harness guarantees it); prefer "
                       '"revenge" so their attacker becomes your target.'),
    },
    canned_turns=[
        {
            "chat": "Partner, on me -- pact up, protect on. We rotate "
                    "as one.",
            "call": {"entries": [
                # No partners/never named here on purpose: adjust_entries
                # injects the actual duo partner from the seat's own
                # play_context into both the pact and the law.
                {"play": "pact", "entry_id": "duo_pact",
                 "params": {"protect": True, "onBetrayal": "disengage"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge"]}},
                {"play": "edge_ride", "entry_id": "together",
                 "params": {"margin": 260, "enterLead": 180,
                            "coverBias": 0.85}},
            ]},
        },
        {
            "chat": "Tight now -- I am your shield, you are my gun.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "duo_pact",
                 "params": {"protect": True, "onBetrayal": "disengage"}},
                # Mid-match the controller switches to guarding the partner
                # (ward is injected by adjust_entries).
                {"play": "bodyguard", "entry_id": "guard",
                 "params": {"leash": [60, 180], "interpose": True,
                            "peelHp": 3}},
                # A dormant crossfire rung under the guard: if the guard
                # yields, the duo fights in a spaced formation.
                {"play": "crossfire", "entry_id": "cross",
                 "params": {"spacing": [100, 260], "minAngle": 40}},
            ]},
        },
    ],
    recall_count=1,
    recall_seconds=8.0,
    partner_focus=True,
    adjust_entries=adjust_entries,
    extra_chat=extra_chat,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
