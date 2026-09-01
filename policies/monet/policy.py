#!/usr/bin/env python3
"""MONET: the house test policy. Field-reading, duo-tight, political.

Fourth persona on the starter seam and the painter after Picasso. The three
starters each embody one instinct; MONET carries the measured doctrine of the
whole research program, translated to the play-calling layer:

* the summary carries BOTH the partner's state and the kill feed (the two
  observables the doctrine actually keys on),
* four model turns spread across the match arc (opening / consolidation /
  mid / endgame) instead of a burst of early re-calls,
* ``adjust_entries`` enforces the three non-negotiables structurally:
  TRUCE HONOR -- every pact's partners are mirrored into every target_law
  never-list, so betrayal requires explicitly dropping the pact and can
  never be an accident of aim; FIRE DISCIPLINE -- the duo partner is on the
  never-list whether or not the model remembered (a partner tag is -60g);
  CONVERSION -- a supply_run rung is guaranteed in every ladder, because the
  lineage's oldest measured failure is winning the fight and never banking
  the life.
"""

from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "starters" / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# 32 seats, 16 duos: seat k pairs with k+16 and team is k % 16. The
# "neighboring" duo is the next team number -- arbitrary but computable from
# lobby context alone, which is all a canned opener has to aim politics at.
TEAM_COUNT = 16

# The guaranteed conversion rung. hp is a small absolute number on this
# engine (a bodyguard peels at 2-3); below 2 means genuinely wounded.
SUPPLY_DEFAULTS = {"whenHpBelow": 2, "detourMax": 400, "contested": "avoid"}

# A pact with no partners is dropped by the generic repair BEFORE the hook
# runs (partners is required), so a canned pact carries team 0's duo as a
# placeholder that survives cleaning; adjust_entries re-aims it at the
# actual neighboring duo. Also re-aimed: any pact naming our own duo (which
# includes the placeholder when we ARE team 0).
PACT_PLACEHOLDER = {"seat:0", "seat:16"}

# Jackal doctrine: leave with the profit. A second tag is allowed, a third
# is greed the attrition ledger punishes.
JACKAL_MAX_KILLS = 2


def _neighbor_duo(context):
    seat = (context.get("self") or {}).get("seat")
    if not isinstance(seat, int):
        return None
    team = seat % TEAM_COUNT
    nt = (team + 1) % TEAM_COUNT
    return (nt, nt + TEAM_COUNT)


def adjust_entries(entries, context, view):
    self_facts = context.get("self") or {}
    partner = self_facts.get("duo_partner")
    seat = self_facts.get("seat")
    own_duo = {f"seat:{s}" for s in (seat, partner) if isinstance(s, int)}

    # Re-aim placeholder or self-referential pacts at the neighboring duo;
    # keep a model's real choice of partners. Betrayal is answered in kind.
    pact_seats = []
    for entry in entries:
        if entry.get("play") != "pact":
            continue
        params = entry.setdefault("params", {})
        partners = [p for p in params.get("partners", []) if isinstance(p, str)]
        unaimed = (not partners or set(partners) == PACT_PLACEHOLDER
                   or set(partners) & own_duo)
        if unaimed:
            neighbors = _neighbor_duo(context)
            if neighbors is not None:
                partners = [f"seat:{n}" for n in neighbors]
            elif not partners and partner is not None:
                partners = [f"seat:{partner}"]
        params["partners"] = partners
        params["onBetrayal"] = "returnFire"
        pact_seats.extend(partners)

    # TRUCE HONOR + FIRE DISCIPLINE: the never-list is derived, not trusted.
    # Ending a truce means dropping the pact entry -- the law then releases
    # those seats on the same call, and never sooner.
    law_never = list(pact_seats)
    if partner is not None and f"seat:{partner}" not in law_never:
        law_never.append(f"seat:{partner}")
    law = next((e for e in entries if e.get("play") == "target_law"), None)
    if law is None and law_never:
        law = {"play": "target_law", "entry_id": "law",
               "params": {"prefer": ["weakened", "isolated"]}}
        entries.insert(0, law)
    if law is not None:
        params = law.setdefault("params", {})
        never = [p for p in params.get("never", []) if isinstance(p, str)]
        for seat in law_never:
            if seat not in never:
                never.append(seat)
        if never:
            params["never"] = never

    for entry in entries:
        if entry.get("play") == "jackal":
            exit_after = entry.setdefault("params", {}).get("exitAfter")
            if (isinstance(exit_after, dict)
                    and isinstance(exit_after.get("kills"), int)):
                exit_after["kills"] = min(exit_after["kills"],
                                          JACKAL_MAX_KILLS)

    # CONVERSION: every ladder banks the life. The rung sits above the
    # rotation controller (wounded beats rotating) and below any fight
    # controller already chosen (never turn your back on a live gun).
    if not any(e.get("play") == "supply_run" for e in entries):
        rung = {"play": "supply_run", "entry_id": "bank",
                "params": dict(SUPPLY_DEFAULTS)}
        for i, entry in enumerate(entries):
            if entry.get("play") == "edge_ride":
                entries.insert(i, rung)
                break
        else:
            entries.append(rung)
    return entries


def extra_chat(context, turn):
    """One deliberate line per turn: politics first, then the partner."""
    partner = (context.get("self") or {}).get("duo_partner")
    neighbors = _neighbor_duo(context)
    if turn == 1 and neighbors is not None:
        return (f"seats {neighbors[0]} and {neighbors[1]}: MONET offers a "
                "truce -- neither duo tags the other while the field is "
                "crowded. We both outlive the brawlers.")
    if partner is None:
        return None
    if turn == 2:
        return (f"seat {partner}: hold the spacing band off my shoulder and "
                "watch the feed -- we move on the first fight we can third.")
    if turn == 3:
        return (f"seat {partner}: arrive third, tag the weakened, leave "
                "paid. No detours while a gun is on us.")
    return (f"seat {partner}: field is thin -- truces are over, range over "
            "brawl, and we finish what we start.")


PERSONA = Persona(
    name="monet",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "pact": ("pact is your political weapon, not a comfort blanket: "
                 "offer it in chat FIRST, then call it with the other duo's "
                 "seats (seat:N form only). A pact nobody heard is not a "
                 "truce. Keep it in every call while it stands -- dropping "
                 "it IS the betrayal, so say so when you do."),
        "target_law": ("target_law: prefer weakened and isolated -- the "
                       "proven greatest-threat lever. The harness mirrors "
                       "your partner and every pact seat into never; you "
                       "release seats by dropping the pact, never by "
                       "editing the list. Set a holdTrigger only for a "
                       "planned endgame release: a released hold LATCHES "
                       "and can never re-arm."),
        "edge_ride": ("edge_ride is your default rotation: margin around "
                      "200 with high coverBias early, enterLead generous -- "
                      "the ring closes fully this season, and the wall is "
                      "crossed with a lead, never raced in the open."),
        "supply_run": ("supply_run is the conversion play this lineage "
                       "always skipped: after a fight, bank the life. The "
                       "harness guarantees the rung; you tune it. Avoid "
                       "contested kits unless your pact gives you the "
                       "numbers to race."),
        "bodyguard": ("bodyguard when your partner is the wounded one: ward "
                      "defaults to them, interpose true, moderate leash. "
                      "One gun always up while they recover."),
        "crossfire": ("crossfire is the duo's fighting shape: a spacing "
                      "band wide enough that no line crosses your partner, "
                      "minAngle real. You see your partner only through "
                      "your own fog tracks -- hold formation where you can "
                      "see each other."),
        "jackal": ("jackal is your signature tag source: join after the "
                   "first tag lands, exit after one or two -- leave with "
                   "the profit. The feed only says a fight HAPPENED, not "
                   "where; move on fights your own tracks can place."),
    },
    canned_turns=[
        {
            # Opening: politics + formation. The pact carries the
            # placeholder duo (see PACT_PLACEHOLDER); adjust_entries re-aims
            # it at the neighboring duo and derives the law's never-list.
            "chat": "Truce first, tags later. Partner, spread on me -- one "
                    "gun always up.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
                {"play": "edge_ride", "entry_id": "rotate",
                 "params": {"margin": 220, "enterLead": 160,
                            "coverBias": 0.8}},
                {"play": "crossfire", "entry_id": "shape",
                 "params": {"spacing": [140, 300], "minAngle": 40}},
            ]},
        },
        {
            # Consolidation: same posture, tightened; the guaranteed
            # supply_run rung lands above the rotation.
            "chat": "Holding the truce. We rotate with cover and bank "
                    "every life.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 2, "detourMax": 500,
                            "contested": "avoid"}},
                {"play": "edge_ride", "entry_id": "rotate",
                 "params": {"margin": 190, "enterLead": 140,
                            "coverBias": 0.75}},
            ]},
        },
        {
            # Mid: the jackal takes over as the driving controller; the
            # fight we take is the one already started.
            "chat": "Feed is ticking. We arrive third, tag the weakened, "
                    "leave paid.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
                {"play": "jackal", "entry_id": "third",
                 "params": {"earshot": 600, "joinWhen": "afterKill",
                            "exitAfter": {"kills": 1}}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 2, "detourMax": 400,
                            "contested": "avoid"}},
                {"play": "edge_ride", "entry_id": "rotate",
                 "params": {"margin": 170, "enterLead": 150,
                            "coverBias": 0.7}},
            ]},
        },
        {
            # Endgame: the pact is DROPPED -- said out loud -- so the law
            # releases the truce seats on this same call. Converge, finish.
            "chat": "Field is thin: our truce ends here, no hard feelings. "
                    "Partner, on me -- we finish.",
            "call": {"entries": [
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["weakened", "isolated"]}},
                {"play": "crossfire", "entry_id": "shape",
                 "params": {"spacing": [120, 280], "minAngle": 36}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 2, "detourMax": 300,
                            "contested": "avoid"}},
                {"play": "edge_ride", "entry_id": "rotate",
                 "params": {"margin": 120, "enterLead": 220,
                            "coverBias": 0.6}},
            ]},
        },
    ],
    recall_count=3,
    recall_seconds=45.0,
    include_kill_feed=True,
    partner_focus=True,
    adjust_entries=adjust_entries,
    extra_chat=extra_chat,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
