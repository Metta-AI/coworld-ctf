#!/usr/bin/env python3
"""Offline self-check for the MONET persona: no server, no model.

Drives every canned turn through the harness's OWN repair path
(``repair_call`` = generic clean -> ``adjust_entries`` -> client-side gating
via ``layer_ladder``) against the full manifest, and asserts the structural
clamps hold: truce honor, fire discipline, conversion, anti-stack, and the
gate behavior of monet's two custom plays. Guards (`when`) are never sent
since the layer_ladder harness -- gating is asserted here instead, on the
client, where it now lives. Run from anywhere:

    python3 policies/monet/selfcheck.py
"""

from __future__ import annotations

import pathlib
import sys
import types

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE.parent / "starters" / "common"))

import plays  # noqa: E402
import starter_harness  # noqa: E402
import policy  # noqa: E402  (defines PERSONA; does not run main)

PERSONA = policy.PERSONA
AVAILABLE = list(plays.PLAYS)

# Seat 3 -> team 3, partner seat 19; neighboring duo is team 4 = seats 4+20.
FAKE_CONTEXT = {"self": {"seat": 3, "duo_partner": 19}}
PARTNER_REF = "seat:19"
NEIGHBOR_REFS = {"seat:4", "seat:20"}


def fake_seat(context=None, view=None):
    return types.SimpleNamespace(context=context or dict(FAKE_CONTEXT),
                                 view=view or {}, kill_feed=[])


failures = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(("PASS  " if ok else "FAIL  ") + label + (f" -- {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


# ── prompt assembly ───────────────────────────────────────────────────────
unknown_notes = set(PERSONA.play_notes) - set(plays.PLAYS)
check("play_notes only name real plays", not unknown_notes, str(unknown_notes))

prompt = starter_harness.build_system_prompt(PERSONA, AVAILABLE)
check("system prompt assembles", bool(prompt.strip()))
check("prompt carries the persona intro", "MONET" in prompt)
missing_notes = [p for p in PERSONA.play_notes
                 if PERSONA.play_notes[p][:30] not in prompt]
check("all play notes reach the full-playbook prompt", not missing_notes,
      str(missing_notes))

# ── canned turns: guards are dead, the wanted ladder is the contract ──────
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    label = f"turn {i}"
    chat = turn.get("chat", "")
    check(f"{label}: chat under the model cap", len(chat) < 200,
          f"{len(chat)} chars")
    check(f"{label}: no dead `when` keys in the canned call",
          all("when" not in e for e in turn["call"]["entries"]))

    submitted = [e["play"] for e in turn["call"]["entries"]]
    seat = fake_seat()
    payload, wire_entries = starter_harness.repair_call(
        turn, PERSONA, seat, AVAILABLE)
    wanted = [e["play"] for e in seat.wanted_entries]
    on_wire = [e["play"] for e in wire_entries]

    check(f"{label}: no submitted entry dropped from the wanted ladder",
          all(p in wanted for p in submitted),
          f"submitted {submitted} wanted {wanted}")
    check(f"{label}: conversion rung guaranteed (wanted)",
          "supply_run" in wanted, str(wanted))
    check(f"{label}: payload under cap", len(payload) <= 4096,
          f"{len(payload)} bytes")
    check(f"{label}: wire ladder carries no `when`",
          all("when" not in e for e in wire_entries))

    # Overlays fold through gating untouched: politics reach the wire.
    pacts = [e for e in wire_entries if e["play"] == "pact"]
    laws = [e for e in wire_entries if e["play"] == "target_law"]
    pact_partners = {p for e in pacts for p in e["params"]["partners"]}

    if pacts:
        check(f"{label}: pact aimed at the neighboring duo",
              pact_partners == NEIGHBOR_REFS, str(pact_partners))
        check(f"{label}: pact answers betrayal in kind",
              all(e["params"].get("onBetrayal") == "returnFire" for e in pacts))
    for law in laws:
        never = set(law["params"].get("never", []))
        check(f"{label}: fire discipline (partner on never-list)",
              PARTNER_REF in never, str(never))
        check(f"{label}: truce honor (pact seats mirrored into never)",
              pact_partners <= never, f"pact {pact_partners} never {never}")
        if not pacts:
            check(f"{label}: truce-break releases the neighbors",
                  never == {PARTNER_REF}, str(never))

# ── gate_open unit checks: monet's two custom plays ───────────────────────
def facts(**kw):
    base = dict(pos=[500, 500], hp_frac=1.0, enemies=[], items=[],
                nearest_enemy=None, in_zone=True, in_next_zone=True,
                ticks_to_shrink=None, partner=19,
                partner_dead=False, partner_track=None, partner_dist=None,
                max_hp=6)
    base.update(kw)
    return base


ENEMY = {"seat": 9, "team": "peach", "pos": [700, 500], "fresh_tick": 990}
HVG = {"play": "hold_vs_gun", "params": {"engageDist": 500}}
FS = {"play": "fire_superiority", "params": {}}

check("gate hold_vs_gun OPEN: fresh enemy inside engageDist, in zone",
      starter_harness.gate_open(HVG, facts(enemies=[ENEMY], nearest_enemy=300)))
check("gate hold_vs_gun CLOSED: nearest enemy beyond engageDist",
      not starter_harness.gate_open(HVG, facts(enemies=[ENEMY],
                                               nearest_enemy=800)))
check("gate hold_vs_gun CLOSED: no enemy tracked",
      not starter_harness.gate_open(HVG, facts()))
check("gate hold_vs_gun CLOSED: outside the zone",
      not starter_harness.gate_open(HVG, facts(enemies=[ENEMY],
                                               nearest_enemy=300,
                                               in_zone=False)))
check("gate fire_superiority OPEN: any fresh enemy, in zone",
      starter_harness.gate_open(FS, facts(enemies=[ENEMY], nearest_enemy=900)))
check("gate fire_superiority CLOSED: no enemies",
      not starter_harness.gate_open(FS, facts()))
check("gate fire_superiority CLOSED: outside the zone",
      not starter_harness.gate_open(FS, facts(enemies=[ENEMY],
                                              nearest_enemy=900,
                                              in_zone=False)))
check("all three custom plays are registered as gated",
      "hold_vs_gun" in starter_harness.GATED_PLAYS
      and "fire_superiority" in starter_harness.GATED_PLAYS
      and "ring_walker" in starter_harness.GATED_PLAYS)

RW = {"play": "ring_walker", "params": {"inset": 64, "leadTicks": 240}}
check("gate ring_walker OPEN: outside the current rect",
      starter_harness.gate_open(RW, facts(in_zone=False)))
check("gate ring_walker OPEN: outside next rect, shrink inside leadTicks",
      starter_harness.gate_open(RW, facts(in_next_zone=False,
                                          ticks_to_shrink=100)))
check("gate ring_walker CLOSED: inside current and next rects",
      not starter_harness.gate_open(RW, facts(ticks_to_shrink=100)))
check("gate ring_walker CLOSED: outside next rect but shrink still far",
      not starter_harness.gate_open(RW, facts(in_next_zone=False,
                                              ticks_to_shrink=600)))

# ── layer_ladder: the gates actually steer the wire ladder ────────────────
TURN3 = [dict(e) for e in PERSONA.canned_turns[2]["call"]["entries"]]
NEAR_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    "tracks": [ENEMY],
}
CALM_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    "tracks": [],
}
near = [e["play"] for e in starter_harness.layer_ladder(
    TURN3, NEAR_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)]
calm = [e["play"] for e in starter_harness.layer_ladder(
    TURN3, CALM_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)]
check("layer_ladder turn 3 + near enemy: hold_vs_gun on the ladder",
      "hold_vs_gun" in near, str(near))
check("layer_ladder turn 3 + near enemy: fire_superiority on the ladder",
      "fire_superiority" in near, str(near))
check("layer_ladder turn 3, no enemies: neither custom play",
      "hold_vs_gun" not in calm and "fire_superiority" not in calm, str(calm))
check("layer_ladder turn 3, no enemies: base jackal present",
      "jackal" in calm, str(calm))
check("monet base_play is jackal", PERSONA.base_play == "jackal",
      str(PERSONA.base_play))

# Outside the NEXT rect with the shrink close: ring_walker leads the ladder.
RING_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000],
                       "next": [900, 900, 600, 600], "phase": 2,
                       "ticks_to_shrink": 100}},
    "tracks": [ENEMY],
}
ring = [e["play"] for e in starter_harness.layer_ladder(
    TURN3, RING_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)]
controllers = [p for p in ring
               if plays.PLAYS[p]["class"] == "controller"]
check("layer_ladder outside next rect: ring_walker on the ladder",
      "ring_walker" in ring, str(ring))
check("layer_ladder outside next rect: ring_walker is the FIRST controller",
      bool(controllers) and controllers[0] == "ring_walker", str(ring))

# ── anti-stack formation floors ───────────────────────────────────────────
stack_seat = fake_seat()
starter_harness.repair_call(
    {"call": {"entries": [
        {"play": "bodyguard", "entry_id": "spring",
         "params": {"leash": [10, 60], "interpose": False}},
        {"play": "crossfire", "entry_id": "shape",
         "params": {"spacing": [20, 200], "minAngle": 36}},
    ]}}, PERSONA, stack_seat, AVAILABLE)
bg = next(e for e in stack_seat.wanted_entries if e["play"] == "bodyguard")
cf = next(e for e in stack_seat.wanted_entries if e["play"] == "crossfire")
check("anti-stack: bodyguard leash floored", bg["params"]["leash"][0] >= 100,
      str(bg["params"]["leash"]))
check("anti-stack: crossfire spacing floored", cf["params"]["spacing"][0] >= 120,
      str(cf["params"]["spacing"]))

# canned turns cover the arc; extra model turns clamp to the last (endgame)
# entry by harness design, so the budget may exceed the scripted count.
check("canned turns cover the arc within the model-turn budget",
      4 <= len(PERSONA.canned_turns) <= 1 + PERSONA.recall_count,
      f"{len(PERSONA.canned_turns)} turns vs recall_count {PERSONA.recall_count}")

# ── extra chat ────────────────────────────────────────────────────────────
for t in (1, 2, 3, 4):
    line = PERSONA.extra_chat(FAKE_CONTEXT, t)
    check(f"extra_chat turn {t} exists and fits the lobby cap",
          isinstance(line, str) and len(line.encode()) < 512,
          repr(line))
line1 = PERSONA.extra_chat(FAKE_CONTEXT, 1)
check("turn-1 truce offer addresses the neighboring duo",
      "seats 4 and 20" in (line1 or ""), repr(line1))

# ── 8-duo field: team count must derive from the roster, never assume 16 ──
duo8_seat = fake_seat(context={"self": {"seat": 3, "duo_partner": 11},
                               "roster": [{"seat": i} for i in range(16)]})
_, entries8 = starter_harness.repair_call(
    PERSONA.canned_turns[0], PERSONA, duo8_seat, AVAILABLE)
pact8 = next((e for e in entries8 if e["play"] == "pact"), None)
law8 = next((e for e in entries8 if e["play"] == "target_law"), None)
check("8-duo field: pact aims at the roster-derived neighbor duo",
      pact8 is not None
      and set(pact8["params"]["partners"]) == {"seat:4", "seat:12"},
      str(pact8))
check("8-duo field: partner still on the never-list",
      law8 is not None and "seat:11" in set(law8["params"].get("never", [])),
      str(law8))

# ── the team-0 edge: the placeholder IS our own duo and must be re-aimed ──
team0_seat = fake_seat(context={"self": {"seat": 0, "duo_partner": 16}})
_, entries0 = starter_harness.repair_call(
    PERSONA.canned_turns[0], PERSONA, team0_seat, AVAILABLE)
pact0 = next((e for e in entries0 if e["play"] == "pact"), None)
check("team-0 seat re-aims the placeholder pact off its own duo",
      pact0 is not None
      and set(pact0["params"]["partners"]) == {"seat:1", "seat:17"},
      str(pact0))

print()
if failures:
    print(f"SELF-CHECK FAILED: {len(failures)} failing check(s)")
    sys.exit(1)
print("SELF-CHECK PASSED")
