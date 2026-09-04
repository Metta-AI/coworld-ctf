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
  the life,
* ``extra_summary`` appends a one-line AWARENESS digest to every model turn:
  ring in/out + shrink clock, partner state (hp TREND across turns, falling
  hp attributed UNDER FIRE vs zone-burning by rect), fresh-vs-stale threat
  census with nearest bearing, incoming fire, near items -- numbers, not
  prose, because summary tokens are sidecar cost.
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

# The guaranteed armament rung. self.hasGun/hasHopper are never exposed to
# a policy (only the human broadcast HUD sees them), so this cannot gate on
# "am I armed" -- it is the same blind loot the three starters already run
# unconditionally, never fighting anyone for it (medkits stay off; that
# family is supply_run's job).
LOOT_DEFAULTS = {"detourMax": 400, "contested": "avoid"}

# A pact with no partners is dropped by the generic repair BEFORE the hook
# runs (partners is required), so a canned pact carries team 0's duo as a
# placeholder that survives cleaning; adjust_entries re-aims it at the
# actual neighboring duo. Also re-aimed: any pact naming our own duo (which
# includes the placeholder when we ARE team 0).
PACT_PLACEHOLDER = {"seat:0", "seat:16"}

# Formation floors: below these the duo is stacked and tags itself.
MIN_LEASH = 100
MIN_SPACING = 120

# COMBAT-CLOSE floor (measured revive protocol, 28 leader tag-backs: revives
# succeed when the duo is ALREADY within ~40px at the down -- 27/28
# zero-travel, median separation 0-15px, successes cluster under 100px).
# MIN_LEASH's 100px anti-stack floor is right for a quiet field but too
# loose to land inside that window once a fight (or a wounded/downed
# partner) is live. This is a SECOND, narrower floor for the entry_id
# "shield-close" rung only -- applying MIN_LEASH here instead would invert
# the deliberately tighter band (max(leash[0], 100) drags a [40,120] pair
# back up to [100,120]), which is exactly the generic-sorter trap this
# floor exists to avoid. Held at 40, not the literal 20px stacking floor:
# fire_superiority's withinFireCone exclusion (a0854837) only screens OUR
# OWN press-target choice, not a stranger partner's fire, so closer
# spacing still raises cluster-fire exposure -- 40 is the value this lane
# can defend (inside the <100px success cluster, clear margin off the
# literal stack floor) over the more aggressive [20,100] the measured data
# would also support.
MIN_LEASH_COMBAT = 40

# Jackal doctrine: leave with the profit. A second tag is allowed, a third
# is greed the attrition ledger punishes.
JACKAL_MAX_KILLS = 2

# Awareness digest: a track older than this is a memory, not a threat (the
# harness's own 10-s freshness/aggressor window). An item further than
# NEAR_ITEM_PX is a detour, not "near".
FRESH_TICKS = 240
NEAR_ITEM_PX = 500


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
            # pixel -- stacked duos tag each other by accident. The
            # combat-close rung (entry_id "shield-close") gets its OWN,
            # lower floor: applying the quiet-phase MIN_LEASH here would
            # invert that deliberately tighter band (see MIN_LEASH_COMBAT's
            # comment above) -- lift BOTH ends off the right floor for the
            # band, never the same floor for every bodyguard entry.
            leash = entry.setdefault("params", {}).get("leash")
            if (isinstance(leash, list) and len(leash) == 2
                    and isinstance(leash[0], int)):
                floor = (MIN_LEASH_COMBAT
                         if entry.get("entry_id") == "shield-close"
                         else MIN_LEASH)
                leash[0] = max(leash[0], floor)
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

    # ARMAMENT: the lineage cannot tag from range, cluster streaks, or
    # avenge a partner with empty hands, and lootStart makes "empty hands"
    # the default spawn state -- the marker and its hopper are two separate
    # one-shot crates, gated 12px like every pickup. self.hasGun/hasHopper
    # and the crates' own item kind are never exposed to a policy
    # (src/shell/body.nim, play_sdk/play.nim), so this cannot key off "am I
    # armed" -- but the SDK view DOES carry grenade/shield/spray/barrier
    # item kind and position, and on every live BR map (0 of the 64 br_s2
    # + 11 br pool maps author a separate weaponSpawns pool) the gun crate
    # lands on exactly the resolved grenade-spawn points
    # (sim.nim:resetLootCrates) -- so walking to the nearest grenade is,
    # today, walking to the gun. aggressive/cautious/collaborative all
    # guarantee this rung already; MONET never did. Sits below the
    # conversion rung (recovery is still the first call) and above
    # rotation, same slot as supply_run.
    if not any(e.get("play") == "loot" for e in entries):
        rung = {"play": "loot", "entry_id": "arm",
                "params": dict(LOOT_DEFAULTS)}
        for i, entry in enumerate(entries):
            if entry.get("play") == "edge_ride":
                entries.insert(i, rung)
                break
        else:
            entries.append(rung)
    return entries


def awareness_lines(seat):
    """MONET's per-turn awareness digest: ONE dense numeric line -- ring
    (in current? in next? shrink clock), partner (hp with a TREND across
    model turns, distance, dead/unseen honestly stated), fresh-vs-stale
    threat census with the nearest bearing, incoming fire, near items.

    The common state block carries the prose; this is the glanceable strip
    the doctrine keys on, numbers not sentences (summary tokens are sidecar
    cost). Partner dist/pos DO arrive: the duo partner rides its own
    unconditional grant row (view.nim partnerTelemetry, landed 9511b240),
    a separate channel from the ordinary same-team-excluded track loop the
    harness's _view_facts note still correctly describes for enemies. hp
    stays genuinely absent on that row by design (body.nim: hp withheld
    even from the partner grant), so the trend machinery below only ever
    arms once hp itself is exposed some other way -- distance/bearing are
    live today. A falling partner hp is attributed by rect: inside the
    safe zone it reads UNDER FIRE, outside it reads zone-burning."""
    view = seat.view or {}
    me = view.get("self") or {}
    pos = me.get("pos")
    if not view or not starter_harness._is_pos(pos):
        return None
    _dist = starter_harness._dist
    _bearing = starter_harness._bearing
    context = seat.context or {}
    self_facts = context.get("self") or {}
    my_seat = self_facts.get("seat")
    my_team = self_facts.get("team")
    partner = self_facts.get("duo_partner")
    tick = view.get("tick", 0)
    parts = []

    zone = (view.get("world") or {}).get("zone") or {}
    cur, nxt = zone.get("current"), zone.get("next")
    if isinstance(cur, list) and len(cur) == 4:
        ring = ("ring IN cur" if starter_harness._inside(pos, cur)
                else "ring OUT of cur (burning)")
        if isinstance(nxt, list) and len(nxt) == 4:
            if starter_harness._inside(pos, nxt):
                ring += ", IN next"
            else:
                center = starter_harness._rect_center(nxt)
                ring += (f", OUT of next ({int(_dist(pos, center))}px "
                         f"{_bearing(pos, center)} to center)")
        tts = zone.get("ticks_to_shrink")
        if isinstance(tts, (int, float)):
            ring += f", shrink {int(tts)}t (~{int(tts) // 24}s)"
        parts.append(ring)

    if partner is not None:
        label = f"partner s{partner}"
        if any(k.get("victim_seat") == partner for k in seat.kill_feed):
            parts.append(label + " DOWN -- you are solo")
        else:
            track = next(
                (t for t in view.get("tracks", [])
                 if isinstance(t, dict) and t.get("seat") == partner
                 and starter_harness._is_pos(t.get("pos"))), None)
            if track is None:
                parts.append(label + " alive, unseen")
            else:
                hp = track.get("hp")
                last = getattr(seat, "_monet_partner_hp", None)
                trend = ""
                if isinstance(hp, int) and isinstance(last, int) and hp < last:
                    in_cur = (isinstance(cur, list) and len(cur) == 4
                              and starter_harness._inside(track["pos"], cur))
                    trend = (f" FALLING {last}->{hp} "
                             + ("(UNDER FIRE)" if in_cur else "(zone-burning)"))
                if isinstance(hp, int):
                    seat._monet_partner_hp = hp
                parts.append(f"{label} hp {hp}{trend}, "
                             f"{int(_dist(pos, track['pos']))}px "
                             f"{_bearing(pos, track['pos'])}")

    fresh, stale = [], 0
    for track in view.get("tracks", []):
        if (not isinstance(track, dict)
                or not starter_harness._is_pos(track.get("pos"))
                or track.get("seat") in (my_seat, partner)
                or (my_team is not None and track.get("team") == my_team)):
            continue
        age = (tick - track["fresh_tick"]
               if isinstance(track.get("fresh_tick"), int) else None)
        if age is not None and age <= FRESH_TICKS:
            fresh.append(track)
        else:
            stale += 1
    stale_note = f" (+{stale} stale)" if stale else ""
    if fresh:
        fresh.sort(key=lambda t: _dist(pos, t["pos"]))
        near = fresh[0]
        parts.append(f"threats {len(fresh)} fresh{stale_note}, nearest "
                     f"{int(_dist(pos, near['pos']))}px "
                     f"{_bearing(pos, near['pos'])} hp {near.get('hp', '?')}")
    else:
        parts.append("threats 0 fresh" + stale_note)

    shots = sum(1 for a in view.get("aggressors", [])
                if isinstance(a, dict) and isinstance(a.get("tick"), int)
                and tick - a["tick"] <= FRESH_TICKS)
    if shots:
        parts.append(f"shot at x{shots} in 10s")

    items = [i for i in view.get("items", [])
             if isinstance(i, dict) and i.get("present", True)
             and starter_harness._is_pos(i.get("pos"))
             and _dist(pos, i["pos"]) <= NEAR_ITEM_PX]
    items.sort(key=lambda i: _dist(pos, i["pos"]))
    if items:
        parts.append("items " + ", ".join(
            f"{i.get('kind', '?')} {int(_dist(pos, i['pos']))}px "
            f"{_bearing(pos, i['pos'])}" for i in items[:2]))

    return ["AWARENESS: " + " | ".join(parts) + "."]


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
                      "zone (deeper = safer) if you do -- and under "
                      "late-phase dps set enterLead 300 or more: starting "
                      "the rotation late is how seats die to an "
                      "uncontested wall."),
        "supply_run": ("supply_run is the conversion play this lineage "
                       "always skipped: after a fight, bank the life. The "
                       "harness guarantees the rung; you tune it. Avoid "
                       "contested kits unless your pact gives you the "
                       "numbers to race."),
        "loot": ("loot is how you get a gun in your hands at all: you "
                 "spawn empty-handed, the marker and its hopper are two "
                 "separate pickups, and a paint can none of us ever finds "
                 "is a paint can that never tags anyone. The harness "
                 "guarantees the rung and gates it -- it only walks when "
                 "the field is calm and something is in reach, never "
                 "fights anyone over a contested crate. You cannot see "
                 "which crate is which, so do not call it looking for a "
                 "specific item; tune detourMax if you want it to reach "
                 "further, nothing more."),
        "bodyguard": ("bodyguard is BOTH the formation spring and the "
                      "shield: on a calm field ride it with leash "
                      "[110, 280] and interpose false so the duo is held "
                      "apart, never stacked (the harness floors the "
                      "leash). But your partner alive is worth more than "
                      "any tag -- when their track reads wounded or under "
                      "fire, shield them: interpose true, tight leash, one "
                      "gun always up while they recover. Consolidation and "
                      "mid tighten leashMax to 150 (medic-conversion audit): "
                      "a downed partner's revive is only reachable in the "
                      "time zone-bleedout allows if you were already close "
                      "when they went down -- medic itself cannot outrun a "
                      "chase, the native reflex owns the walk there. Those "
                      "same two turns also carry a COMBAT-CLOSE rung "
                      "(leash [40, 120], measured revive protocol: real "
                      "tag-back revives land from ~40px, not 150) that "
                      "takes over the instant either of you has a live "
                      "enemy tracked or your partner reads wounded/downed, "
                      "and hands back to the wider [100, 150] band the "
                      "moment the field goes quiet again -- the two never "
                      "run together."),
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
                             "state. Superior means press -- to the FAR "
                             "band against a fresh or full-health target "
                             "(a longshot tag mints 2.5x a point-blank "
                             "one; never brawl one), but ALL THE WAY IN "
                             "(finishRange) against a target you already "
                             "know is wounded -- the accuracy penalty up "
                             "close is a risk against a live gun, not a "
                             "finishing tag on someone this close to done; "
                             "outgunned means break to facing cover. Keep "
                             "it guarded on enemy contact: it is how a "
                             "winning fight gets FINISHED instead of "
                             "drawn, and a draw pays nobody. Your partner "
                             "only counts as a second gun when they are "
                             "close enough to THIS fight to matter -- "
                             "alive-but-distant is not a 1v1 flipped to a "
                             "2v1. Among targets you could press, the play "
                             "already steers off any line that would catch "
                             "your partner, and off any spot that would "
                             "put you in theirs."),
        "ring_walker": ("ring_walker is survival rule zero: the ring is "
                        "a schedule, not a surprise -- leave the building "
                        "BEFORE the walk turns into an escape, and only "
                        "ever toward reachable ground (the play routes "
                        "every target through the engine's reachability "
                        "query, so it never beelines into a wall pocket). "
                        "Keep it above every fight rung: no tag is worth "
                        "being cornered by the storm."),
        "medic": ("medic is the pickup: a downed partner is not a loss "
                  "-- it is 48 ticks of walking; go get them. Your gun "
                  "stays free while you stand the revive, so the only "
                  "real choices are the honest refusals: do not walk a "
                  "nearly-dead body into a camped ghost, and do not chase "
                  "one deep into the storm. Below ring_walker, above "
                  "every fight rung: you cannot revive if the ring kills "
                  "you, and no tag outranks the pickup."),
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
                {"play": "medic", "entry_id": "pickup",
                 "params": {"abortHpFloor": 1, "zoneReach": 220}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "spring",
                 # peelHp RAISED (v10) 2->3: shield the ward at half of a
                 # 6-hp seat, not just the last quarter -- the duo-shared
                 # OR-gate (claimAchievement, sim.nim:273-310) means a live
                 # partner mints for BOTH of us every episode, win or lose
                 # (Amendment 6, 774ab1d4); protecting proactively rather
                 # than reactively is a bet that pays under either glory
                 # rule, since it only moves WHEN we shield, never whether.
                 "params": {"leash": [110, 280], "interpose": False,
                            "peelHp": 3}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Consolidation: NO LONGER minimal -- v11 adds a press-capable
            # controller here (leader-template finding, 9/3: the top two
            # standings' entire edge over ours is an EARLY credit stack --
            # dFirstBlood + 2 early dClosingTime hits landing ~ticks
            # 2098-2458 (8-19% into the match) -- a 27x head-multiplier on
            # their chain vs our 3x. dFirstBlood is the episode's single
            # first kill: jackal cannot claim it (it only JOINS a fight
            # after someone else's tag already landed), so the fix is not
            # "join more fights", it is "stop being structurally unable to
            # FINISH one" -- fire_superiority (press-vs-break) was installed
            # starting at the mid turn only; opening/consolidation ran
            # hold_vs_gun alone, which holds against a gun on us but never
            # presses to close one out. That gap sits exactly across the
            # leader's observed window (turn 2 fires ~30-60s+ under the
            # normal recall cadence, extending into the 87-102s window
            # above). Same structural shape as the endgame standoff bug
            # (75ccf920): a controller that would convert a winnable
            # encounter simply was not on the ladder yet, not a
            # threshold mistuned. Fix: install fire_superiority one turn
            # early, with mid's OWN already-vetted cautious parameters
            # (breakDeficit 2 PARKED, woundedPct 50 -- NOT the endgame's
            # zeroed 0, since a full field of undamaged duos is a genuinely
            # riskier bar to press than a thinned endgame) -- this is
            # widening WHEN the proven mid posture is available, never
            # making it more aggressive than mid already is. jackal rides
            # along for the same reason it rides at mid: it cannot win
            # dFirstBlood, but an early second/third tag in a fight fire_
            # superiority (or the enemy) already opened is still an early
            # dClosingTime candidate, and jackal never initiates on its
            # own (afterKill-only trigger) so it adds no early-game risk of
            # its own beyond what a fight already in progress carries.
            "chat": "Holding the truce. We rotate with cover, press what "
                    "we can finish, and bank every life.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": ["revenge", "bounty", "weakened",
                            "isolated"]}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "medic", "entry_id": "pickup",
                 "params": {"abortHpFloor": 1, "zoneReach": 220}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v11 EARLY CREDIT STACK: same cautious params as the mid
                 # turn (see that entry's comment for the breakDeficit/
                 # woundedPct rationale) -- deliberately NOT copying
                 # endgame's woundedPct=0, because the field is still near
                 # full strength here and a parity fight is a genuinely
                 # different bet than the endgame's thinned field.
                 "params": {"breakDeficit": 2, "coverMax": 260,
                            "engageDist": 600, "finishRange": 140,
                            "pressRange": 400, "woundedPct": 50}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield-close",
                 # COMBAT-CLOSE band (measured revive protocol, 28 leader
                 # tag-backs): revives succeed when the duo is ALREADY
                 # within ~40px at the down (27/28 zero-travel, median
                 # separation 0-15px, successes cluster under 100px) -- the
                 # [100,150] "shield" band below is right for a quiet field
                 # but too loose to land inside that window. Mutually
                 # exclusive with "shield" by entry_id (see gate_open's
                 # bodyguard branch in starter_harness.py): opens only when
                 # either seat has a live enemy tracked or the partner
                 # reads wounded/downed/under fire, hands back to the wider
                 # band the instant the field goes quiet -- the wire ladder
                 # never carries both at once. [40,120] chosen over the
                 # more aggressive [20,100] the data would also support:
                 # fire_superiority's withinFireCone exclusion (a0854837)
                 # only screens OUR OWN press-target choice, not a
                 # stranger partner's fire, so tighter spacing still raises
                 # cluster-fire exposure -- 40 clears the literal 20px
                 # stacking floor with real margin. PARTIAL closure only:
                 # medic's own movement priority still starves behind
                 # ladder.nim's nativeBase branch (see "shield" below), so
                 # a tighter leash is not expected to reach leader parity
                 # on its own.
                 "params": {"leash": [40, 120], "interpose": True,
                            "peelHp": 3}},
                {"play": "bodyguard", "entry_id": "shield",
                 # leashMax TIGHTENED (medic-conversion audit) 200->150:
                 # medic converted 0/96 revivable downs (partner upright at
                 # down) despite being installed+called every turn below
                 # ring_walker -- ladder.nim's nativeBase branch (line ~600)
                 # runs the native zone-escape/default-rotation reflex
                 # INSTEAD OF the whole controller loop whenever it is
                 # armed, so medic's own priority cannot outrank it (this
                 # matches the edge_ride doctrine note above: the native
                 # reflex "outranks every play at the wall"). Direct replay
                 # evidence: the reviver closed >20px toward the ghost in
                 # only 11/96 cases and never got within 60px in 86/96 --
                 # medic's navigate intent is essentially never executed as
                 # movement once a partner is down. zoneReach (only 5-8/96
                 # over-budget) and abortHpFloor (2/96) are NOT the binding
                 # gates. The lever that IS ours to pull: separation AT
                 # down-time. Break-even distance to still land a revive in
                 # the dominant zone-bleedout window (median 103 ticks,
                 # 74/96 of revivable downs) is StandInPx(26) + (103-48
                 # channel ticks) * MaxSpeed/MotionScale (704/256 px/tick)
                 # = ~177px -- but measured separation at down-time medians
                 # 210-217px, ABOVE break-even, with only 52/96 geometrically
                 # reachable even under a zero-latency straight-line walk.
                 # leashMax 150 (< 177px, with margin for pathing/latency)
                 # keeps steady-state duo separation under the break-even
                 # line during the two turns covering 75% of revivable
                 # downs (zone phase z=0.55/0.35), so a down more often
                 # starts inside medic's reach instead of requiring a
                 # cross-zone chase. leashMin held at 100 (selfcheck floors
                 # it) -- tightening the floor risks the friendly-fire loss
                 # mode, a documented worse failure than an unrevived down.
                 # This never fights zone routing: bodyguard's own call
                 # guard already refuses to run outside the safe rect (the
                 # anchored-outside-the-rect disaster, 48% early-mid deaths
                 # in the v8 miner), so tightening the leash only changes
                 # in-zone spacing, never asks anyone to chase into the
                 # storm.
                 "params": {"leash": [100, 150], "interpose": True,
                            "peelHp": 3}},
                {"play": "jackal", "entry_id": "third",
                 # v11 EARLY CREDIT STACK: rides with fire_superiority above
                 # (see that entry's comment) -- same mid-turn params, no
                 # earlier license to hunt alone (joinWhen stays afterKill).
                 "params": {"earshot": 550, "joinWhen": "afterKill",
                            "exitAfter": {"kills": 2}}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 3, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Mid: same fire_superiority + jackal ladder the consolidation
            # turn now also carries (v11) -- kill conversion is where monet
            # already led the field; everything else stays with the
            # reflex/default movement.
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
                {"play": "medic", "entry_id": "pickup",
                 "params": {"abortHpFloor": 1, "zoneReach": 220}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v10: breakDeficit STAYS PARKED at 2 -- "keep fighting
                 # while outgunned" trades win probability for size, and a
                 # self tag-out forfeits the rest of THIS episode's minting
                 # under either glory rule (old hard-win-gate, or Amendment
                 # 6's every-episode-banks -- 774ab1d4 dropping `and
                 # playerWon` at roster.nim:1017): negative sign both ways,
                 # so not re-armed. finishRange is NEW (v10, see
                 # fire_superiority.nim): closes to a tight band ONLY on a
                 # target already known wounded, aimed at the measured 3x
                 # dPointBlankKill gap without breakDeficit's downside.
                 "params": {"breakDeficit": 2, "coverMax": 260,
                            "engageDist": 600, "finishRange": 140,
                            "pressRange": 400, "woundedPct": 50}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield-close",
                 # COMBAT-CLOSE band: same rationale and [40,120] band as
                 # the consolidation turn's shield-close entry above --
                 # this is the OTHER turn covering the dominant
                 # zone-bleedout phase (z=0.55/0.35, 75% of revivable
                 # downs). Mutually exclusive with "shield" below by
                 # entry_id.
                 "params": {"leash": [40, 120], "interpose": True,
                            "peelHp": 3}},
                {"play": "bodyguard", "entry_id": "shield",
                 # leashMax TIGHTENED (medic-conversion audit) 200->150: same
                 # break-even rationale as the consolidation turn's shield
                 # entry above -- this is the OTHER turn covering the
                 # dominant zone-bleedout phase (z=0.55/0.35, 75% of
                 # revivable downs).
                 "params": {"leash": [100, 150], "interpose": True,
                            "peelHp": 3}},
                {"play": "jackal", "entry_id": "third",
                 # earshot RE-ARMED (v10) 450->550: a wider loiter net joins
                 # more fights. Under Amendment 6 every joined fight mints
                 # deeds in ALL ~20 episodes/round, not just the ~5 we win --
                 # a clear gain. Under the OLD hard-win-gate rule it is still
                 # a fair bet on its own: earshot only widens WHERE we
                 # loiter, it does not touch exitAfter's 2-kill leash or ask
                 # us to fight outgunned, so unlike breakDeficit it does not
                 # trade away win probability to get there.
                 "params": {"earshot": 550, "joinWhen": "afterKill",
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
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach TIGHTENED (v10) 220->160 for the endgame turn
                 # only: item-2 marquee chaining ranks "alive at Last Light"
                 # ABOVE "partner down-then-revived" (a dead reviver forfeits
                 # the win and every multiplier riding it, the revive
                 # forfeits only itself) -- so the storm-dip budget shrinks
                 # exactly where the ring bites hardest, never grows.
                 "params": {"abortHpFloor": 1, "zoneReach": 160}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v10 AMENDMENT (owner field report 2026-09-02): woundedPct
                 # ZEROED 25->0 for the ENDGAME TURN ONLY -- kills the exact
                 # standoff the owner watched happen live: a tied, fully-
                 # healthy fight (ourGuns == theirGuns, nobody wounded) fell
                 # through fire_superiority.nim's own "Even: hold at cover"
                 # branch (the play's last fallback when neither `superior`
                 # nor `inferior` fires) and just stood there, paint can in
                 # hand, until the ring decided it for us. `superior` reads
                 # `ourGuns > theirGuns or (ourGuns >= theirGuns and
                 # wounded*100 >= woundedPct*theirGuns)`; at woundedPct=0 the
                 # wounded clause is trivially true, so ANY numeric parity or
                 # better now PRESSES instead of holding. This does NOT touch
                 # `inferior` (theirGuns - ourGuns >= breakDeficit) at all --
                 # a fight we are actually behind in still breaks to cover
                 # unchanged, so this is "take the fight we can already win,"
                 # never "brawl while outgunned." Press still respects the
                 # point-blank inversion: an unknown/healthy target keeps the
                 # wider pressRange band, only a CONFIRMED-wounded target
                 # (hp<=2) gets closed to finishRange. Scoped to the endgame
                 # turn alone (mid-turn keeps woundedPct 50) because this is
                 # specifically the small-zone, few-duos-left failure mode
                 # the report described, not a general license to brawl
                 # early. breakDeficit STAYS PARKED at 2 (see the mid-turn
                 # note -- negative sign under either glory rule, and
                 # orthogonal to this fix: the standoff was an EVEN fight,
                 # never an outgunned one, so the break threshold was never
                 # the lever that needed to move). finishRange NEW (v10),
                 # tighter than mid's 140: fewer duos left means less flank
                 # risk while closing on a target already known wounded.
                 "params": {"breakDeficit": 2, "coverMax": 200,
                            "engageDist": 600, "finishRange": 120,
                            "pressRange": 340, "woundedPct": 0}},
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
    # Awareness-audit cadence: a lost/downed partner or an imminent ring
    # while exposed may cut the recall gap to 5s. Budget (max_calls) is
    # untouched -- these are rare edge events, not extra spend.
    priority_recall_floor=5.0,
    # Upstream's own measurement note (layer_ladder): hold-until-fight-heard
    # plus the zone reflex out-survives active riding, and it matches this
    # persona's doctrine -- jackal IS monet's patience.
    base_play="jackal",
    include_kill_feed=True,
    partner_focus=True,
    adjust_entries=adjust_entries,
    extra_chat=extra_chat,
    extra_summary=awareness_lines,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
