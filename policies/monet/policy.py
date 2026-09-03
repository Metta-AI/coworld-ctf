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

# Duo fields pair seat k with k+teamCount and team is k % teamCount; the
# team count is DERIVED from the roster (the hosted field is flipping to 8
# duos, so 16 must not be assumed). The "neighboring" duo is the next team
# number -- arbitrary but computable from lobby context alone, which is all
# a canned opener has to aim politics at. 16 is only the no-roster fallback.
TEAM_COUNT = 16

# The guaranteed conversion rung. hp is a small absolute number on this
# engine (a bodyguard peels at 2-3); below 2 means genuinely wounded.
SUPPLY_DEFAULTS = {"whenHpBelow": 3, "detourMax": 300, "contested": "avoid"}

# A pact with no partners is dropped by the generic repair BEFORE the hook
# runs (partners is required), so a canned pact carries team 0's duo as a
# placeholder that survives cleaning; adjust_entries re-aims it at the
# actual neighboring duo. Also re-aimed: any pact naming our own duo (which
# includes the placeholder when we ARE team 0).
PACT_PLACEHOLDER = {"seat:0", "seat:16"}

# Formation floors: below these the duo is stacked and tags itself.
MIN_LEASH = 100
MIN_SPACING = 120

# Jackal doctrine: leave with the profit. A second tag is allowed, a third
# is greed the attrition ledger punishes.
JACKAL_MAX_KILLS = 2


def _neighbor_duo(context):
    seat = (context.get("self") or {}).get("seat")
    if not isinstance(seat, int):
        return None
    roster = context.get("roster")
    seats = (len(roster) if isinstance(roster, list) and roster
             else 2 * TEAM_COUNT)
    team_count = max(1, seats // 2)
    team = seat % team_count
    nt = (team + 1) % team_count
    return (nt, nt + team_count)


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
               "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}}
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
        elif entry.get("play") == "bodyguard":
            # ANTI-STACK: a leash floor keeps the duo off each other's
            # pixel -- stacked duos tag each other by accident.
            leash = entry.setdefault("params", {}).get("leash")
            if (isinstance(leash, list) and len(leash) == 2
                    and isinstance(leash[0], int)):
                leash[0] = max(leash[0], MIN_LEASH)
                leash[1] = max(leash[1], leash[0])
        elif entry.get("play") == "crossfire":
            spacing = entry.setdefault("params", {}).get("spacing")
            if (isinstance(spacing, list) and len(spacing) == 2
                    and isinstance(spacing[0], int)):
                spacing[0] = max(spacing[0], MIN_SPACING)
                spacing[1] = max(spacing[1], spacing[0])

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
        "target_law": ("target_law: prefer revenge, bounty, weakened, "
                       "isolated -- all four. Your fallen partner's tagger "
                       "pays once (revenge leads); bounty marks pay extra; "
                       "weakened+isolated is the proven greatest-threat "
                       "lever. The harness mirrors your partner and every "
                       "pact seat into never; you release seats by dropping "
                       "the pact, never by editing the list. Set a "
                       "holdTrigger only for a planned endgame release: a "
                       "released hold LATCHES and can never re-arm."),
        "edge_ride": ("edge_ride: the native escape reflex outranks every "
                      "play at the wall, and calling a rotation REPLACES "
                      "the default one. Call it only with a specific "
                      "positional read; margin is depth inside the safe "
                      "zone (deeper = safer) if you do."),
        "supply_run": ("supply_run is the conversion play this lineage "
                       "always skipped: after a fight, bank the life. The "
                       "harness guarantees the rung; you tune it. Avoid "
                       "contested kits unless your pact gives you the "
                       "numbers to race."),
        "bodyguard": ("bodyguard is BOTH the formation spring and the "
                      "shield: on a calm field ride it with leash "
                      "[110, 280] and interpose false so the duo is held "
                      "apart, never stacked (the harness floors the "
                      "leash). But your partner alive is worth more than "
                      "any tag -- when their track reads wounded or under "
                      "fire, shield them: interpose true, tight leash, one "
                      "gun always up while they recover."),
        "crossfire": ("crossfire is the duo's fighting shape: a spacing "
                      "band wide enough that no line crosses your partner, "
                      "minAngle real. You see your partner only through "
                      "your own fog tracks -- hold formation where you can "
                      "see each other."),
        "hold_vs_gun": ("hold_vs_gun is the Picasso lever: never turn "
                        "your back on a live gun. Keep it a GUARDED rung "
                        "above jackal and supply_run -- when the proximity "
                        "guard passes it owns movement and stands its "
                        "ground facing the threat; when the field is calm "
                        "the guard fails and the rungs below drive. Never "
                        "call it unguarded as your only controller: on a "
                        "calm field it just stands still."),
        "fire_superiority": ("fire_superiority is press-vs-break: count "
                             "the guns you can SEE, and treat unknown hp "
                             "as healthy -- never reason about invisible "
                             "state. Superior means press to the FAR band "
                             "-- a longshot tag mints 2.5x a point-blank "
                             "one -- never a brawl; outgunned means break "
                             "to facing cover. Keep it guarded on enemy "
                             "contact: it is how a winning fight gets "
                             "FINISHED instead of drawn, and a draw pays "
                             "nobody."),
        "ring_walker": ("ring_walker is survival rule zero: the ring is "
                        "a schedule, not a surprise -- leave the building "
                        "BEFORE the walk turns into an escape, and only "
                        "ever toward reachable ground (the play routes "
                        "every target through the engine's reachability "
                        "query, so it never beelines into a wall pocket). "
                        "Keep it above every fight rung: no tag is worth "
                        "being cornered by the storm."),
        "jackal": ("jackal is your signature tag source: join after the "
                   "first tag lands and stay for TWO -- clustered tags in "
                   "one fight multiply the glory (x2, x4, x8 as the streak "
                   "climbs); scattered pokes never do. Leave when the "
                   "second tag banks or your hp says the streak is over. "
                   "The feed only says a fight HAPPENED, not where; move "
                   "on fights your own tracks can place."),
    },
    canned_turns=[
        {
            # Opening: politics only. The liveness probe proved the native
            # zone-escape reflex + default rotation OUTPLACE any rotation
            # controller we call, so movement is deliberately left to them;
            # the ladder carries what actually bites -- targeting law,
            # truce, and the hp-gated conversion rung. The pact carries the
            # placeholder duo (see PACT_PLACEHOLDER); adjust_entries re-aims
            # it and derives the law's never-list.
            "chat": "Truce first, tags later. Partner, spread on me -- one "
                    "gun always up.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "spring",
                 "params": {"leash": [110, 280], "interpose": False,
                            "peelHp": 2}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Consolidation: same minimal posture -- stay out of trouble,
            # let the reflex own the wall, bank any wounds.
            "chat": "Holding the truce. We rotate with cover and bank "
                    "every life.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield",
                 "params": {"leash": [100, 200], "interpose": True,
                            "peelHp": 2}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Mid: jackal is the ONE controller rung -- kill conversion is
            # where monet already led the field; everything else stays with
            # the reflex/default movement.
            "chat": "Feed is ticking. We arrive third, tag the weakened, "
                    "leave paid.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 "params": {"breakDeficit": 2, "coverMax": 260,
                            "engageDist": 600, "pressRange": 400,
                            "woundedPct": 50}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield",
                 "params": {"leash": [100, 200], "interpose": True,
                            "peelHp": 2}},
                {"play": "jackal", "entry_id": "third",
                 "params": {"earshot": 450, "joinWhen": "afterKill",
                            "exitAfter": {"kills": 2}}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 250,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Endgame: the pact is DROPPED -- said out loud -- so the law
            # releases the truce seats on this same call. fire_superiority
            # is the DRIVING controller on contact -- press-vs-break is how
            # a winning fight gets finished (the engine's own bots stall at
            # full health and let the ring decide; a draw pays nobody) --
            # with crossfire beneath it owning the duo's shape off contact.
            "chat": "Field is thin: our truce ends here, no hard feelings. "
                    "Partner, on me -- we finish.",
            "call": {"entries": [
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 "params": {"breakDeficit": 2, "coverMax": 200,
                            "engageDist": 600, "pressRange": 340,
                            "woundedPct": 34}},
                {"play": "crossfire", "entry_id": "shape",
                 "params": {"spacing": [120, 280], "minAngle": 36}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 150,
                            "contested": "avoid"}},
            ]},
        },
    ],
    recall_count=5,
    recall_seconds=30.0,
    # Upstream's own measurement note (layer_ladder): hold-until-fight-heard
    # plus the zone reflex out-survives active riding, and it matches this
    # persona's doctrine -- jackal IS monet's patience.
    base_play="jackal",
    include_kill_feed=True,
    partner_focus=True,
    adjust_entries=adjust_entries,
    extra_chat=extra_chat,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
