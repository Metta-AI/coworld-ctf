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

import json
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
                partner_track_fresh=False, partner_in_combat=False,
                self_downed=False, partner_downed=False,
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

MEDIC = {"play": "medic", "params": {"abortHpFloor": 1, "zoneReach": 220}}
GHOST = {"seat": 19, "pos": [700, 700], "fresh_tick": 995, "downed": True}
check("gate medic OPEN: partner grant row reads downed",
      starter_harness.gate_open(MEDIC, facts(
          partner_track=dict(GHOST), partner_downed=True)))
check("gate medic CLOSED: no partner",
      not starter_harness.gate_open(MEDIC, facts(partner=None)))
check("gate medic CLOSED: self is downed too",
      not starter_harness.gate_open(MEDIC, facts(
          partner_track=dict(GHOST), partner_downed=True, self_downed=True)))
check("gate medic CLOSED: partner upright",
      not starter_harness.gate_open(MEDIC, facts(
          partner_track={"seat": 19, "pos": [700, 700], "fresh_tick": 995})))
check("gate medic CLOSED: partner already dead",
      not starter_harness.gate_open(MEDIC, facts(
          partner_track=dict(GHOST), partner_downed=True, partner_dead=True)))

for _i, _t in enumerate(PERSONA.canned_turns, start=1):
    _order = [e["play"] for e in _t["call"]["entries"]]
    _fights = [j for j, p in enumerate(_order)
               if p in ("fire_superiority", "hold_vs_gun", "jackal",
                        "crossfire")]
    check(f"turn {_i}: medic rides directly below ring_walker, above fights",
          _order.index("medic") == _order.index("ring_walker") + 1
          and (not _fights or _order.index("medic") < min(_fights)),
          str(_order))

# Downed partner on the grant row: medic gates onto the wire ladder.
DOWNED_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    "tracks": [{"seat": 19, "pos": [700, 700], "fresh_tick": 1000,
                "downed": True}],
}
downed_ladder = [e["play"] for e in starter_harness.layer_ladder(
    [dict(e) for e in PERSONA.canned_turns[0]["call"]["entries"]],
    DOWNED_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)]
check("layer_ladder downed partner: medic on the wire ladder",
      "medic" in downed_ladder, str(downed_ladder))

BG = {"play": "bodyguard",
      "params": {"leash": [100, 200], "interpose": True, "peelHp": 2}}
P_TRACK = {"seat": 19, "pos": [520, 500], "fresh_tick": 990}
check("gate bodyguard OPEN: partner track reads wounded (hp <= peelHp)",
      starter_harness.gate_open(BG, facts(
          partner_track={**P_TRACK, "hp": 2}, partner_track_fresh=True,
          partner_dist=20.0)))
check("gate bodyguard OPEN: partner under fire (enemy at their pos)",
      starter_harness.gate_open(BG, facts(
          partner_track=dict(P_TRACK), partner_track_fresh=True,
          partner_in_combat=True, partner_dist=20.0)))
check("gate bodyguard CLOSED: partner healthy, close, unpressed",
      not starter_harness.gate_open(BG, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=150.0)))
check("gate bodyguard CLOSED: outside the safe rect (never anchor in dps)",
      not starter_harness.gate_open(BG, facts(
          partner_track={**P_TRACK, "hp": 2}, partner_track_fresh=True,
          partner_dist=20.0, in_zone=False)))
CF = {"play": "crossfire", "params": {"spacing": [120, 280], "minAngle": 36}}
ENEMY_CF = {"seat": 9, "team": "peach", "pos": [700, 500], "fresh_tick": 990}
check("gate crossfire CLOSED: outside the safe rect",
      not starter_harness.gate_open(CF, facts(
          partner_track=dict(P_TRACK), enemies=[ENEMY_CF], in_zone=False)))
check("gate crossfire OPEN: in zone, partner tracked, enemies live",
      starter_harness.gate_open(CF, facts(
          partner_track=dict(P_TRACK), enemies=[ENEMY_CF])))
check("gate bodyguard OPEN: drift beyond leash max (existing rule intact)",
      starter_harness.gate_open(BG, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=400.0)))
check("gate bodyguard CLOSED: stale wounded track does not open the shield",
      not starter_harness.gate_open(BG, facts(
          partner_track={**P_TRACK, "hp": 2}, partner_track_fresh=False,
          partner_dist=20.0)))

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

# ── awareness digest (the extra_summary seam) ─────────────────────────────
check("persona wires the awareness digest",
      PERSONA.extra_summary is policy.awareness_lines)
check("awareness is silent before the first view",
      policy.awareness_lines(fake_seat()) is None)

AW_VIEW = {
    "tick": 1200,
    "self": {"pos": [500, 500], "hp": 4, "hp_frac": 0.67, "alive": True},
    "world": {"zone": {"current": [0, 0, 2000, 2000],
                       "next": [800, 800, 600, 600], "phase": 2,
                       "ticks_to_shrink": 210, "dps": 1},
              "alive_teams": 9},
    "tracks": [
        # partner (same-team tracks are dormant on today's server; the
        # digest must still read them the day partner perception lands)
        {"seat": 19, "team": 3, "pos": [600, 400], "fresh_tick": 1190,
         "hp": 5},
        {"seat": 9, "team": 5, "pos": [760, 500], "fresh_tick": 1100,
         "hp": 2},                                      # fresh enemy, 260px E
        {"seat": 12, "team": 6, "pos": [1500, 1500], "fresh_tick": 100,
         "hp": 6},                                      # stale enemy
    ],
    "items": [{"kind": "medkit", "pos": [500, 310], "present": True},
              {"kind": "ammo", "pos": [1900, 1900], "present": True}],
    "aggressors": [{"seat": 9, "tick": 1150}],
}
aw_seat = fake_seat(context={"self": {"seat": 3, "team": 3,
                                      "duo_partner": 19}},
                    view=AW_VIEW)
block = policy.awareness_lines(aw_seat)
check("awareness is one dense line",
      isinstance(block, list) and len(block) == 1, str(block))
line = (block or [""])[0]
check("awareness stays tight (under 320 chars)", len(line) < 320,
      f"{len(line)} chars")
check("awareness: ring in cur / out of next + shrink clock",
      "IN cur" in line and "OUT of next" in line and "210t" in line, line)
check("awareness: partner hp and distance off the track",
      "partner s19 hp 5" in line and "141px NE" in line, line)
check("awareness: fresh-vs-stale threat census with nearest bearing",
      "threats 1 fresh (+1 stale)" in line and "260px E hp 2" in line, line)
check("awareness: incoming fire counted", "shot at x1" in line, line)
check("awareness: near items only (far ammo dropped)",
      "medkit 190px N" in line and "ammo" not in line, line)

# hp trend across model turns: same seat, partner track falls 5 -> 3 while
# INSIDE the safe rect => UNDER FIRE, not zone-burning.
AW_VIEW["tracks"][0]["hp"] = 3
line2 = policy.awareness_lines(aw_seat)[0]
check("awareness: partner hp trend reads UNDER FIRE inside the rect",
      "FALLING 5->3 (UNDER FIRE)" in line2, line2)

dead_seat = fake_seat(context={"self": {"seat": 3, "team": 3,
                                        "duo_partner": 19}},
                      view=AW_VIEW)
dead_seat.kill_feed = [{"tick": 900, "victim_seat": 19, "killer_team": 5}]
check("awareness: dead partner reads DOWN",
      "partner s19 DOWN" in policy.awareness_lines(dead_seat)[0])

unseen_seat = fake_seat(context={"self": {"seat": 3, "team": 3,
                                          "duo_partner": 19}},
                        view={**AW_VIEW, "tracks": AW_VIEW["tracks"][1:]})
check("awareness: no partner track reads honestly as unseen",
      "partner s19 alive, unseen" in policy.awareness_lines(unseen_seat)[0])

# End to end: summarize() carries the digest on a populated live view.
full_seat = types.SimpleNamespace(context=aw_seat.context, view=AW_VIEW,
                                  kill_feed=[], chat=[], slot=3,
                                  last_view_tick=1200)
summary = starter_harness.summarize(
    full_seat, starter_harness.match_phase(full_seat), PERSONA)
check("summarize() carries the awareness digest", "AWARENESS: " in summary)
check("summarize() keeps partner-first and the kill feed around the digest",
      "PARTNER STATUS FIRST" in summary and "Kill feed" in summary)

# ── cadence: priority triggers and the recall-gap floor ───────────────────
import types as _types

CALM_SNAP_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp": 6, "alive": True},
    "world": {"zone": {"current": [0, 0, 2000, 2000],
                       "next": [900, 900, 600, 600], "phase": 2,
                       "ticks_to_shrink": 500}},
    "tracks": [{"seat": 19, "pos": [520, 500], "fresh_tick": 1000}],
}


def snap(view, kill_feed=()):
    seat = _types.SimpleNamespace(view=view, kill_feed=list(kill_feed))
    return starter_harness._snapshot(seat, 19)


import copy
calm = snap(CALM_SNAP_VIEW)
check("cadence: calm snapshot is not ring-exposed and partner is upright",
      not calm["ring_exposed"] and not calm["partner_downed"], str(calm))

ring_view = copy.deepcopy(CALM_SNAP_VIEW)
ring_view["world"]["zone"]["ticks_to_shrink"] = 300  # < RING_IMMINENT_TICKS
ring_now = snap(ring_view)
check("cadence: outside next rect + shrink < 360 reads ring_exposed",
      ring_now["ring_exposed"], str(ring_now))
pr = starter_harness._priority_triggers(calm, ring_now)
check("cadence: ring-imminent-while-exposed is a PRIORITY trigger",
      any("ring is imminent" in r for r in pr), str(pr))

down_view = copy.deepcopy(CALM_SNAP_VIEW)
down_view["tracks"][0]["downed"] = True
down_now = snap(down_view)
pr2 = starter_harness._priority_triggers(calm, down_now)
check("cadence: partner DOWN is a PRIORITY trigger",
      any("DOWN" in r for r in pr2), str(pr2))
check("cadence: no priority trigger on a calm pair of snapshots",
      not starter_harness._priority_triggers(calm, snap(CALM_SNAP_VIEW)))

hp_before = dict(calm, partner_hp=5)
hp_now = dict(calm, partner_hp=3)
ordinary = starter_harness._triggers(hp_before, hp_now)
check("cadence: partner-hp-falling fires as an ORDINARY trigger (dormant "
      "today: grant row withholds hp)",
      any("partner's hp fell" in r for r in ordinary), str(ordinary))
check("cadence: partner-hp-falling is NOT priority",
      not starter_harness._priority_triggers(hp_before, hp_now))

ga = starter_harness._gap_allows
check("cadence gap: ordinary trigger honors the full min gap",
      not ga(12.0, 30.0, False, 5.0) and ga(31.0, 30.0, False, 5.0))
check("cadence gap: priority trigger cuts in at the 5s floor",
      ga(6.0, 30.0, True, 5.0) and not ga(3.0, 30.0, True, 5.0))
check("cadence gap: no floor configured = no bypass (upstream default)",
      not ga(6.0, 30.0, True, None))
check("monet opts into the 5s priority floor",
      PERSONA.priority_recall_floor == 5.0,
      str(PERSONA.priority_recall_floor))

# ── v10: param round-trip -- no submitted lever is silently dropped or
# reclamped by drift between a play's own manifest and this harness's
# mirrored plays.py spec (the exact "prompt and levers disagree" failure
# mode the brief calls out; _clean_params is where that drift would hide).
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    for entry in turn["call"]["entries"]:
        play = entry.get("play")
        submitted = entry.get("params") or {}
        cleaned = starter_harness._clean_params(play, submitted)
        check(f"turn {i}: {play} params match the manifest spec exactly "
              "(no silent drop or reclamp)",
              cleaned is not None
              and json.loads(json.dumps(cleaned, sort_keys=True))
                  == json.loads(json.dumps(submitted, sort_keys=True)),
              f"submitted {submitted} cleaned {cleaned}")

# ── v10: fire_superiority's new finishRange lever (point-blank yield) ────
check("plays registry declares finishRange for fire_superiority",
      "finishRange" in plays.PLAYS["fire_superiority"]["params"],
      str(plays.PLAYS["fire_superiority"]["params"]))

for i, turn in enumerate(PERSONA.canned_turns, start=1):
    fs = next((e for e in turn["call"]["entries"]
               if e.get("play") == "fire_superiority"), None)
    if fs is None:
        continue
    fr = fs["params"].get("finishRange")
    pr = fs["params"].get("pressRange")
    check(f"turn {i}: fire_superiority carries finishRange",
          isinstance(fr, int), str(fs["params"]))
    check(f"turn {i}: finishRange strictly tighter than pressRange (else "
          "the wounded-target exception is a no-op or backwards)",
          isinstance(fr, int) and isinstance(pr, int) and fr < pr,
          f"finishRange {fr} pressRange {pr}")

# ── v10 aggression decision, pinned so a future edit cannot silently flip
# it: breakDeficit stays PARKED (negative sign under either glory rule --
# a self tag-out forfeits the rest of the episode's minting whether a loss
# banks zero or banks its own sum); woundedPct/earshot are RE-ARMED (they
# only move press-vs-hold or where we loiter, never hold-vs-break on a
# fight we are losing, so the win-probability downside they carry is small
# under either rule, and Amendment 6 makes the upside larger). ───────────
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    fs = next((e for e in turn["call"]["entries"]
               if e.get("play") == "fire_superiority"), None)
    if fs is not None:
        check(f"turn {i}: breakDeficit stays PARKED at 2 (v10 decision)",
              fs["params"].get("breakDeficit") == 2, str(fs["params"]))
    jk = next((e for e in turn["call"]["entries"]
               if e.get("play") == "jackal"), None)
    if jk is not None:
        check(f"turn {i}: jackal earshot RE-ARMED to 550 (v10 decision)",
              jk["params"].get("earshot") == 550, str(jk["params"]))

endgame_fs = next(e for e in PERSONA.canned_turns[-1]["call"]["entries"]
                   if e["play"] == "fire_superiority")
check("endgame woundedPct RE-ARMED to 25 (v10 decision)",
      endgame_fs["params"].get("woundedPct") == 25, str(endgame_fs["params"]))

# ── v10: partner-enabling -- bodyguard shields at half health, not a
# quarter (peelHp 2->3), since the duo-shared OR-gate mints for both of us
# every episode now, win or lose. ─────────────────────────────────────────
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    for e in turn["call"]["entries"]:
        if e.get("play") == "bodyguard":
            check(f"turn {i}: bodyguard peelHp RAISED to 3 (v10)",
                  e["params"].get("peelHp") == 3, str(e["params"]))

# ── v10: marquee chaining -- medic's storm-dip budget tightens in the
# endgame turn only (survival-to-close outranks the revive dip when the
# two conflict; see policy.py's endgame medic comment). ──────────────────
zone_reaches = [
    (i, e["params"].get("zoneReach"))
    for i, turn in enumerate(PERSONA.canned_turns, start=1)
    for e in turn["call"]["entries"] if e.get("play") == "medic"
]
check("medic zoneReach tightens in the endgame turn (v10)",
      bool(zone_reaches) and zone_reaches[-1][1] < zone_reaches[0][1],
      str(zone_reaches))

print()
if failures:
    print(f"SELF-CHECK FAILED: {len(failures)} failing check(s)")
    sys.exit(1)
print("SELF-CHECK PASSED")
