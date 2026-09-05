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
entry_ids_by_play: dict = {}
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
    check(f"{label}: armament rung guaranteed (wanted)",
          "loot" in wanted, str(wanted))
    check(f"{label}: recovery outranks arming (supply_run above loot)",
          "supply_run" not in wanted or "loot" not in wanted
          or wanted.index("supply_run") < wanted.index("loot"),
          str(wanted))
    check(f"{label}: loot never claims medkits (that stays supply_run's job)",
          all(e["params"].get("medkits") is not True
              for e in seat.wanted_entries if e["play"] == "loot"),
          str(wanted))
    check(f"{label}: payload under cap", len(payload) <= 4096,
          f"{len(payload)} bytes")
    check(f"{label}: wire ladder carries no `when`",
          all("when" not in e for e in wire_entries))
    # `retune: true` is what lets src/shell/replacement.nim adopt/warm-
    # reconfigure a rung that is already running (matched by entry_id +
    # play + module hash) instead of the harness's every single call --
    # even a routine gate-flip resend -- cold-tearing-down and
    # re-instantiating every entry still on the ladder. It is a pure no-op
    # for a genuinely new entry (nothing to match), so this must hold on
    # every turn, not just the ones that reuse an id.
    check(f"{label}: every wire entry marks retune "
          f"(warm-reconfigure eligible, never a needless cold reinit)",
          all(e.get("retune") is True for e in wire_entries),
          str([e.get("entry_id") for e in wire_entries
               if e.get("retune") is not True]))
    for e in wire_entries:
        entry_ids_by_play.setdefault(e["play"], []).append(e.get("entry_id"))

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

# ── entry_id stability across turns: the retune fix only pays off when a
# rung keeps calling itself by the same name turn over turn (§7.2 matches
# on entry_id + play + module hash). Pin the two rungs the canned script
# already names consistently, so a future edit that scrambles one turn's
# id silently loses the warm-reconfigure path instead of failing loud.
check("target_law keeps entry_id \"law\" across every turn (retune-eligible)",
      entry_ids_by_play.get("target_law") == ["law"] * len(PERSONA.canned_turns),
      str(entry_ids_by_play.get("target_law")))
fs_ids = entry_ids_by_play.get("fire_superiority", [])
check("fire_superiority keeps one entry_id everywhere it appears "
      "(retune-eligible turn over turn)",
      len(set(fs_ids)) <= 1, str(fs_ids))

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

# ── combat-close band: entry_id-paired mutual exclusion (measured revive
# protocol) -- "shield-close" and "shield" must never both gate open on the
# same facts, and any OTHER bodyguard entry_id (e.g. the opening turn's
# unpaired "spring") keeps the original unconditional behavior untouched
# (combat-close pairing is opt-in by entry_id, not a global change to
# every bodyguard call). ───────────────────────────────────────────────
BG_CLOSE = {"play": "bodyguard", "entry_id": "shield-close",
            "params": {"leash": [40, 120], "interpose": True, "peelHp": 3}}
BG_QUIET = {"play": "bodyguard", "entry_id": "shield",
            "params": {"leash": [100, 150], "interpose": True, "peelHp": 3}}
BG_UNPAIRED = {"play": "bodyguard", "entry_id": "spring",
               "params": {"leash": [110, 280], "interpose": False,
                          "peelHp": 3}}
check("gate shield-close CLOSED: fully quiet field (healthy, in-band, no "
      "enemies) -- the wide band owns the tick instead",
      not starter_harness.gate_open(BG_CLOSE, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=110.0)))
check("gate shield OPEN: same quiet facts but drifted beyond ITS OWN "
      "leash max -- quiet-phase drift behavior is unchanged",
      starter_harness.gate_open(BG_QUIET, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=200.0)))
check("gate shield-close OPEN: self has a live enemy tracked, partner "
      "otherwise healthy and close",
      starter_harness.gate_open(BG_CLOSE, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=200.0, enemies=[ENEMY])))
check("gate shield CLOSED: same live-enemy facts -- defers to shield-close",
      not starter_harness.gate_open(BG_QUIET, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=200.0, enemies=[ENEMY])))
check("gate shield-close OPEN: partner downed and beyond its own leash "
      "max (no enemy in view, no hp on the grant track) -- downed does "
      "not get the wounded/in-combat unconditional-open branch (medic, "
      "ranked above bodyguard, owns the final close-in touch), but still "
      "opens via the ordinary drift check once out of the [40,120] band",
      starter_harness.gate_open(BG_CLOSE, facts(
          partner_track=dict(P_TRACK), partner_track_fresh=True,
          partner_dist=200.0, partner_downed=True)))
check("gate shield-close CLOSED: partner downed but already inside the "
      "[40,120] band -- nothing left for bodyguard to do (medic takes the "
      "final steps)",
      not starter_harness.gate_open(BG_CLOSE, facts(
          partner_track=dict(P_TRACK), partner_track_fresh=True,
          partner_dist=50.0, partner_downed=True)))
check("gate shield CLOSED: same downed+far facts -- defers to shield-close",
      not starter_harness.gate_open(BG_QUIET, facts(
          partner_track=dict(P_TRACK), partner_track_fresh=True,
          partner_dist=200.0, partner_downed=True)))
check("gate shield-close OPEN: partner wounded (hp <= peelHp)",
      starter_harness.gate_open(BG_CLOSE, facts(
          partner_track={**P_TRACK, "hp": 2}, partner_track_fresh=True,
          partner_dist=50.0)))
check("gate shield-close OPEN: partner under fire (in combat)",
      starter_harness.gate_open(BG_CLOSE, facts(
          partner_track=dict(P_TRACK), partner_track_fresh=True,
          partner_dist=50.0, partner_in_combat=True)))
check("gate shield-close CLOSED even when drifted, if the field reads "
      "quiet (no enemy, partner healthy/uncontested)",
      not starter_harness.gate_open(BG_CLOSE, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=400.0)))
check("gate shield-close OPEN: drifted beyond its OWN (tighter) leash max "
      "while combat-close -- closes the gap toward 120, not 150",
      starter_harness.gate_open(BG_CLOSE, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=130.0, enemies=[ENEMY])))
check("gate unpaired bodyguard entry_id (e.g. the opening turn's 'spring') "
      "keeps the ORIGINAL unconditional behavior -- combat-close pairing "
      "is opt-in by entry_id, so a rung with no shield/shield-close "
      "companion still opens on drift alone regardless of live enemies",
      starter_harness.gate_open(BG_UNPAIRED, facts(
          partner_track={**P_TRACK, "hp": 6}, partner_track_fresh=True,
          partner_dist=300.0, enemies=[ENEMY])))

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

# ── layer_ladder: combat-close band, end-to-end on the real mid turn ─────
# Turn 3 (mid) now carries BOTH "shield-close" and "shield" bodyguard
# rungs -- these views pin that exactly one of the two ever reaches the
# wire, never both, on the actual canned entries (not a synthetic fixture).
COMBAT_BG_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    # Same 300px partner separation as QUIET_DRIFT_BG_VIEW below, plus a
    # live enemy -- isolates the enemy-present branch as the thing that
    # flips which rung owns the tick.
    "tracks": [ENEMY, {"seat": 19, "pos": [500, 800], "fresh_tick": 1000}],
}
QUIET_DRIFT_BG_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    "tracks": [{"seat": 19, "pos": [500, 800], "fresh_tick": 1000}],
}
QUIET_INBAND_BG_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000], "phase": 1}},
    "tracks": [{"seat": 19, "pos": [500, 620], "fresh_tick": 1000}],
}
combat_bg = [e["entry_id"] for e in starter_harness.layer_ladder(
    TURN3, COMBAT_BG_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)
    if e["play"] == "bodyguard"]
quiet_drift_bg = [e["entry_id"] for e in starter_harness.layer_ladder(
    TURN3, QUIET_DRIFT_BG_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)
    if e["play"] == "bodyguard"]
quiet_inband_bg = [e["entry_id"] for e in starter_harness.layer_ladder(
    TURN3, QUIET_INBAND_BG_VIEW, FAKE_CONTEXT, [], base_play=PERSONA.base_play)
    if e["play"] == "bodyguard"]
check("layer_ladder mid turn + live enemy: shield-close on the wire, "
      "shield is not, at the SAME 300px separation that opens the quiet "
      "band on its own (QUIET_DRIFT_BG_VIEW below) -- isolates the enemy "
      "as what flips which rung owns the tick",
      combat_bg == ["shield-close"], str(combat_bg))
check("layer_ladder mid turn, quiet + drifted (300px, no enemy): shield "
      "on the wire, shield-close is not -- quiet-phase drift behavior "
      "reaches the wire unchanged",
      quiet_drift_bg == ["shield"], str(quiet_drift_bg))
check("layer_ladder mid turn, quiet + already in the [100,150] band: "
      "neither bodyguard rung on the wire (nothing to do)",
      quiet_inband_bg == [], str(quiet_inband_bg))

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
stack_bg = [e for e in stack_seat.wanted_entries if e["play"] == "bodyguard"]
cf = next(e for e in stack_seat.wanted_entries if e["play"] == "crossfire")
# v15: a self-named, stacked bodyguard leash ([10,60], entry_id "spring")
# no longer just floors -- policy._normalize_bodyguard replaces it outright
# with the canonical pair, which clears the stack floor on both rungs by
# construction. Full bodyguard-normalize coverage is the next section.
check("anti-stack: self-named stacked bodyguard normalizes to the "
      "canonical pair, clear of the stack floor",
      [e["entry_id"] for e in stack_bg] == ["shield-close", "shield"]
      and all(e["params"]["leash"][0] >= policy.MIN_LEASH_COMBAT
              for e in stack_bg),
      str(stack_bg))
check("anti-stack: crossfire spacing floored", cf["params"]["spacing"][0] >= 120,
      str(cf["params"]["spacing"]))

# ── bodyguard-normalize: the two-entry split is MECHANICAL now, not prose
# (v15). v14's prompt DIRECTED the model to submit two literal entries
# ("shield-close"/"shield") and measured only ~25% compliance across 52
# real bodyguard call-entries from 15 agents (qualification episode
# b6798f78, 2026-09-04) -- the self-named majority's leash even drifted
# WIDER, away from combat-close. adjust_entries now enforces the split
# structurally via policy._normalize_bodyguard, the same pattern as pact
# re-aiming (truce honor) and the retune:true injection: whatever the
# model calls bodyguard, however it names it, it always reaches the wire
# as exactly these two entries. See BODYGUARD_LEASH's comment in
# policy.py for the full measurement. ─────────────────────────────────────
def _bg_wanted(raw_entries):
    seat = fake_seat()
    starter_harness.repair_call(
        {"call": {"entries": raw_entries}}, PERSONA, seat, AVAILABLE)
    return [e for e in seat.wanted_entries if e["play"] == "bodyguard"]


for alias in ("ride", "spring", "duo_hold"):
    normalized = _bg_wanted([{"play": "bodyguard", "entry_id": alias,
                              "params": {"leash": [110, 280],
                                         "interpose": False}}])
    check(f"bodyguard-normalize: self-named entry_id {alias!r} never "
          "reaches the wire -- only the canonical ids exist after "
          "normalization",
          sorted(e["entry_id"] for e in normalized)
          == ["shield", "shield-close"],
          str([e["entry_id"] for e in normalized]))

exact = _bg_wanted([{"play": "bodyguard", "entry_id": "ride",
                     "params": {"leash": [110, 280], "interpose": False}}])
bands = {e["entry_id"]: e["params"]["leash"] for e in exact}
check("bodyguard-normalize: emitted leash bands are exactly [40,120] and "
      "[100,150] (policy.BODYGUARD_LEASH), never the self-named "
      "submission it replaced",
      bands == policy.BODYGUARD_LEASH, str(bands))
check("bodyguard-normalize: interpose forced true on both rungs",
      all(e["params"]["interpose"] is True for e in exact), str(exact))

# Idempotence: re-normalizing an already-canonical pair must yield the
# same pair -- never four entries (two duplicated).
already_canonical = [
    {"play": "bodyguard", "entry_id": "shield-close",
     "params": {"leash": [40, 120], "interpose": True, "ward": "seat:9"}},
    {"play": "bodyguard", "entry_id": "shield",
     "params": {"leash": [100, 150], "interpose": True, "ward": "seat:9"}},
]
idempotent = policy._normalize_bodyguard(
    policy._normalize_bodyguard([dict(e) for e in already_canonical]))
check("bodyguard-normalize: idempotent -- normalizing an already-"
      "canonical pair yields the same pair, not four entries",
      len(idempotent) == 2
      and sorted(e["entry_id"] for e in idempotent)
      == ["shield", "shield-close"],
      str(idempotent))

# The model keeps the WHOM (ward) and its priority/ordering intent; code
# owns only the mechanical id + leash-band split.
targeted = _bg_wanted([{"play": "bodyguard", "entry_id": "ride",
                        "params": {"leash": [110, 280], "interpose": False,
                                   "ward": "seat:9", "peelHp": 5}}])
check("bodyguard-normalize: the model's target (ward) survives onto both "
      "canonical entries",
      all(e["params"].get("ward") == "seat:9" for e in targeted),
      str(targeted))
check("bodyguard-normalize: the model's peelHp survives normalization",
      all(e["params"].get("peelHp") == 5 for e in targeted), str(targeted))

# A ward the model actually asked for, in the wrong shape, must not vanish
# indistinguishably from ward simply being omitted -- CLEAN_REJECTED
# (starter_harness.py's generic param cleaner) is the counter that tells
# the two apart. "9" is the realistic miss: the brief demands the exact
# form "seat:<N>", and a bare seat number is the most likely way a model
# drifts off it. ward is a scalar seat_ref, not a clearable collection, so
# ANY failure here is a rejection -- there is no "empty" form of it.
_ward_key = "bodyguard.ward"
_rejected_before = dict(getattr(starter_harness, "CLEAN_REJECTED", {}))
starter_harness.repair_call(
    {"call": {"entries": [
        {"play": "bodyguard", "entry_id": "ride",
         "params": {"leash": [110, 280], "interpose": False,
                    "ward": "9"}},
    ]}}, PERSONA, fake_seat(), AVAILABLE)
_rejected_after = getattr(starter_harness, "CLEAN_REJECTED", {})
check("bodyguard-normalize: a malformed ward (\"9\", missing the "
      "\"seat:\" prefix) the model actually supplied is COUNTED in "
      "CLEAN_REJECTED, not silently indistinguishable from ward being "
      "omitted",
      _rejected_after.get(_ward_key, 0) > _rejected_before.get(_ward_key, 0),
      f"before {_rejected_before.get(_ward_key, 0)} after "
      f"{_rejected_after.get(_ward_key, 0)}")
_ward_samples = getattr(starter_harness, "REJECTED_SAMPLES", {}).get(
    _ward_key, [])
check("bodyguard-normalize: the rejected ward's raw value (\"9\") is "
      "captured verbatim (not just counted) in REJECTED_SAMPLES",
      any("9" in s for s in _ward_samples), str(_ward_samples))

_rejected_before2 = dict(getattr(starter_harness, "CLEAN_REJECTED", {}))
_cleared_before2 = dict(getattr(starter_harness, "CLEAN_CLEARED", {}))
_bg_wanted([{"play": "bodyguard", "entry_id": "ride",
            "params": {"leash": [110, 280], "interpose": False,
                       "ward": "seat:9"}}])
_rejected_now = getattr(starter_harness, "CLEAN_REJECTED", {})
_cleared_now = getattr(starter_harness, "CLEAN_CLEARED", {})
check("bodyguard-normalize: a well-formed ward never counts as a drop "
      "(neither CLEAN_REJECTED nor CLEAN_CLEARED fires on a value that "
      "cleans successfully)",
      _rejected_now.get(_ward_key, 0) == _rejected_before2.get(_ward_key, 0)
      and _cleared_now.get(_ward_key, 0) == _cleared_before2.get(_ward_key, 0),
      f"rejected={_rejected_now} cleared={_cleared_now}")

# REJECTED_SAMPLES must be capped hard, on both axes, so a model that keeps
# sending garbage cannot blow up the end-of-match log: chars per sample...
_huge_ward = "x" * 5000
starter_harness.repair_call(
    {"call": {"entries": [
        {"play": "bodyguard", "entry_id": "ride-huge",
         "params": {"leash": [110, 280], "interpose": False,
                    "ward": _huge_ward}},
    ]}}, PERSONA, fake_seat(), AVAILABLE)
_ward_samples_huge = getattr(starter_harness, "REJECTED_SAMPLES", {}).get(
    _ward_key, [])
_char_cap = starter_harness._REJECTED_SAMPLE_CHAR_CAP
check("REJECTED_SAMPLES: a huge malformed value is truncated at the char "
      "cap, not stored verbatim",
      bool(_ward_samples_huge)
      and all(len(s) <= _char_cap + len("...<truncated>")
              for s in _ward_samples_huge)
      and any(len(s) < len(repr(_huge_ward)) for s in _ward_samples_huge),
      str([len(s) for s in _ward_samples_huge]))

# ... and samples per key, even across many separate rejects on that key.
for _i in range(10):
    starter_harness.repair_call(
        {"call": {"entries": [
            {"play": "bodyguard", "entry_id": f"ride-cap-{_i}",
             "params": {"leash": [110, 280], "interpose": False,
                        "ward": f"bad-{_i}"}},
        ]}}, PERSONA, fake_seat(), AVAILABLE)
_ward_samples_capped = getattr(starter_harness, "REJECTED_SAMPLES", {}).get(
    _ward_key, [])
_count_cap = starter_harness._REJECTED_SAMPLE_COUNT_CAP
check("REJECTED_SAMPLES: capped at a small number of samples per key even "
      "after many rejects land on the same key",
      len(_ward_samples_capped) <= _count_cap,
      f"len={len(_ward_samples_capped)} cap={_count_cap}")

# ── target_law.never: seat_or_duo_set must PRESERVE duo refs (Commit A) ──
# The golden engine contract (manifest_target_law.golden.json) declares
# never's "of" as "seat_or_duo_ref" -- a duo reference is legal here, unlike
# pact.partners/bodyguard.ward above. Before this fix, never routed through
# the same _clean_partners as pact and silently stripped every duo entry;
# live CLEAN_DROPS (the old, undifferentiated counter) on real model output
# showed target_law.never dropped in 9 of 16 seats.
_never_key = "target_law.never"


def _never_cleaned(value):
    _, entries = starter_harness.build_call(
        {"call": {"entries": [
            {"play": "target_law", "entry_id": "law",
             "params": {"never": value}}]}}, AVAILABLE)
    return entries[0].get("params", {}).get("never")


check("target_law.never: a duo-only never list SURVIVES cleaning",
      _never_cleaned(["duo:navy"]) == ["duo:navy"],
      str(_never_cleaned(["duo:navy"])))
check("target_law.never: a mixed seat+duo list keeps BOTH forms",
      set(_never_cleaned(["duo:navy", "seat:3"]) or [])
      == {"duo:navy", "seat:3"},
      str(_never_cleaned(["duo:navy", "seat:3"])))

# THE ONE CHANGE: an EMPTY never list is the model deliberately asking to
# CLEAR the param -- every observed live drop in the v18/v19 samples was
# exactly this, not garbage. It must still drop the param (no canonical way
# to represent "explicitly nothing" downstream of `cleaned`), but it must
# land in CLEAN_CLEARED, never CLEAN_REJECTED.
_cleared_before = dict(getattr(starter_harness, "CLEAN_CLEARED", {}))
_rejected_before4 = dict(getattr(starter_harness, "CLEAN_REJECTED", {}))
_empty_never = _never_cleaned([])
_cleared_after = getattr(starter_harness, "CLEAN_CLEARED", {})
_rejected_after4 = getattr(starter_harness, "CLEAN_REJECTED", {})
check("target_law.never: an EMPTY list still drops the param (the play "
      "default applies -- cleaning behavior is unchanged)",
      _empty_never is None, str(_empty_never))
check("target_law.never: (a) an empty list increments CLEARED and NOT "
      "REJECTED -- the model asked to clear the param, it did not misfire",
      _cleared_after.get(_never_key, 0) > _cleared_before.get(_never_key, 0)
      and _rejected_after4.get(_never_key, 0)
      == _rejected_before4.get(_never_key, 0),
      f"cleared before {_cleared_before.get(_never_key, 0)} after "
      f"{_cleared_after.get(_never_key, 0)}; rejected before "
      f"{_rejected_before4.get(_never_key, 0)} after "
      f"{_rejected_after4.get(_never_key, 0)}")

_rejected_before3 = dict(getattr(starter_harness, "CLEAN_REJECTED", {}))
_cleared_before3 = dict(getattr(starter_harness, "CLEAN_CLEARED", {}))
_garbage_never = _never_cleaned(["garbage", 999999, "duo:"])
_rejected_after3 = getattr(starter_harness, "CLEAN_REJECTED", {})
_cleared_after3 = getattr(starter_harness, "CLEAN_CLEARED", {})
check("target_law.never: an all-garbage never list (bare unprefixed junk, "
      "an out-of-range seat number, and an empty \"duo:\" token) still "
      "drops the param",
      _garbage_never is None, str(_garbage_never))
check("target_law.never: (b) that garbage is a REJECTED drop (a "
      "non-empty list where every entry failed to parse) NOT a CLEARED "
      "one -- it is not silently indistinguishable from never being "
      "omitted",
      _rejected_after3.get(_never_key, 0) > _rejected_before3.get(_never_key, 0)
      and _cleared_after3.get(_never_key, 0)
      == _cleared_before3.get(_never_key, 0),
      f"rejected before {_rejected_before3.get(_never_key, 0)} after "
      f"{_rejected_after3.get(_never_key, 0)}; cleared before "
      f"{_cleared_before3.get(_never_key, 0)} after "
      f"{_cleared_after3.get(_never_key, 0)}")
_never_samples = getattr(starter_harness, "REJECTED_SAMPLES", {}).get(
    _never_key, [])
check("target_law.never: (b) the rejected garbage list's raw value is "
      "captured verbatim (truncated) in REJECTED_SAMPLES",
      any("garbage" in s and "999999" in s for s in _never_samples),
      str(_never_samples))

# REGRESSION GUARD: pact.partners and bodyguard.ward stay seat-only BY
# POLICY DESIGN (their briefs say "No other form is legal" / 'No "duo:" '
# 'form') even though the engine's own contract allows seat_or_duo_ref for
# both -- a future refactor must not route them through the new
# duo-preserving cleaner instead of _clean_partners/_clean_seat_ref.
_, _pact_entries = starter_harness.build_call(
    {"call": {"entries": [
        {"play": "pact", "entry_id": "p",
         "params": {"partners": ["duo:navy", "seat:2"]}}]}}, AVAILABLE)
check("REGRESSION: pact.partners still strips duo refs (seat-only by "
      "design -- must not be swapped onto the new seat_or_duo_set cleaner)",
      _pact_entries[0].get("params", {}).get("partners") == ["seat:2"],
      str(_pact_entries[0].get("params")))

_, _bg_entries = starter_harness.build_call(
    {"call": {"entries": [
        {"play": "bodyguard", "entry_id": "b",
         "params": {"ward": "duo:navy"}}]}}, AVAILABLE)
check("REGRESSION: bodyguard.ward still rejects a duo ref outright "
      "(seat_ref, never routed through the new seat_or_duo_set cleaner)",
      "ward" not in _bg_entries[0].get("params", {}),
      str(_bg_entries[0].get("params")))

order_seat = fake_seat()
starter_harness.repair_call(
    {"call": {"entries": [
        {"play": "target_law", "entry_id": "law", "params": {}},
        {"play": "bodyguard", "entry_id": "ride",
         "params": {"leash": [110, 280], "interpose": False}},
        {"play": "jackal", "entry_id": "third", "params": {}},
    ]}}, PERSONA, order_seat, AVAILABLE)
order_plays = [e["play"] for e in order_seat.wanted_entries]
check("bodyguard-normalize: priority/ordering intent survives -- the "
      "split pair lands where the single entry was called, not shuffled "
      "to the front or back",
      order_plays.index("target_law") < order_plays.index("bodyguard")
      < order_plays.index("jackal"),
      str(order_plays))

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
        # partner: pos/team/fresh_tick are LIVE today via the unconditional
        # grant row (view.nim partnerTelemetry); hp is NOT (withheld by
        # design -- body.nim PartnerSample) and never appears on a real
        # grant row. This fixture still carries "hp" so the trend-tracking
        # branch below stays covered for the day hp arrives some other way.
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
check("endgame woundedPct ZEROED to 0 (v10 amendment: kill the standoff)",
      endgame_fs["params"].get("woundedPct") == 0, str(endgame_fs["params"]))


# ── v10 amendment: the endgame standoff fix, pinned against the SOURCE
# formula (fire_superiority.nim play_step), not just the raw param value --
# a future param edit that keeps woundedPct==0 but changes the arithmetic
# would still be caught here. `superior`/`inferior` are exact mirrors of the
# Nim booleans; see plays/fire_superiority.nim's play_step for the source. ─
def fs_superior(our_guns: int, their_guns: int, wounded: int,
                wounded_pct: int) -> bool:
    return (our_guns > their_guns
            or (our_guns >= their_guns
                and wounded * 100 >= wounded_pct * their_guns))


def fs_inferior(our_guns: int, their_guns: int, break_deficit: int) -> bool:
    return their_guns - our_guns >= break_deficit


mid_fs = next(e for e in PERSONA.canned_turns[2]["call"]["entries"]
              if e["play"] == "fire_superiority")
_endgame_wp = endgame_fs["params"]["woundedPct"]
_endgame_bd = endgame_fs["params"]["breakDeficit"]
_mid_wp = mid_fs["params"]["woundedPct"]

check("endgame: a tied, fully-healthy 1v1 now PRESSES (was: hold at cover)",
      fs_superior(1, 1, 0, _endgame_wp), f"woundedPct={_endgame_wp}")
check("endgame: a tied, fully-healthy 2v2 (both duos whole) now PRESSES",
      fs_superior(2, 2, 0, _endgame_wp), f"woundedPct={_endgame_wp}")
check("endgame: numeric superiority still presses regardless of wounded",
      fs_superior(2, 1, 0, _endgame_wp), f"woundedPct={_endgame_wp}")
check("endgame: still BREAKS off when actually outgunned by breakDeficit "
      "(woundedPct never touches the break threshold -- not a license to "
      "brawl outgunned)",
      fs_inferior(1, 3, _endgame_bd) and not fs_superior(1, 3, 0, _endgame_wp),
      f"breakDeficit={_endgame_bd} woundedPct={_endgame_wp}")
check("endgame: a tie is never classified as outgunned",
      not fs_inferior(1, 1, _endgame_bd)
      and not fs_inferior(2, 2, _endgame_bd),
      f"breakDeficit={_endgame_bd}")
check("mid-turn: a tied, fully-healthy fight still HOLDS (re-arm is "
      "endgame-scoped, not a global aggression change)",
      not fs_superior(1, 1, 0, _mid_wp) and not fs_superior(2, 2, 0, _mid_wp),
      f"mid woundedPct={_mid_wp}")

check("prompt: endgame doctrine says parity is enough late (matches the "
      "zeroed woundedPct lever)",
      "parity IS the edge" in prompt, "endgame prompt text not found")
check("prompt: endgame doctrine names the standoff being killed",
      "paint can in hand" in prompt, "endgame prompt text not found")

# ── v11 EARLY CREDIT STACK (leader-template finding, 9/3): the
# consolidation turn (index 1, "turn 2") gains fire_superiority + jackal --
# structurally, dFirstBlood (the episode's single first kill) and the early
# dClosingTime hits observed in the leader's 27x head-stack can ONLY be
# claimed if a press-capable controller exists before the mid turn; there
# was none. Pinned two ways: presence (a future edit cannot silently drop
# the entries) and posture (consolidation must stay at mid's cautious bar,
# never drift to endgame's zeroed one -- the field is still near full
# strength this early). ───────────────────────────────────────────────────
consolidation_fs = next((e for e in PERSONA.canned_turns[1]["call"]["entries"]
                         if e["play"] == "fire_superiority"), None)
consolidation_jk = next((e for e in PERSONA.canned_turns[1]["call"]["entries"]
                         if e["play"] == "jackal"), None)
check("turn 2 (consolidation): fire_superiority is now on the ladder "
      "(v11 early credit stack -- was mid-turn-only)",
      consolidation_fs is not None)
check("turn 2 (consolidation): jackal is now on the ladder (v11 early "
      "credit stack -- was mid-turn-only)",
      consolidation_jk is not None)
if consolidation_fs is not None:
    _cons_wp = consolidation_fs["params"].get("woundedPct")
    check("turn 2: fire_superiority matches MID's cautious woundedPct "
          "(50), not endgame's zeroed 0 -- widening WHEN it presses, "
          "never making it MORE aggressive than the already-vetted turn",
          _cons_wp == _mid_wp == 50, f"turn2={_cons_wp} mid={_mid_wp}")
    check("turn 2: a tied, fully-healthy fight still HOLDS here too (same "
          "bar as mid -- consolidation is not a second endgame)",
          not fs_superior(1, 1, 0, _cons_wp)
          and not fs_superior(2, 2, 0, _cons_wp),
          f"turn2 woundedPct={_cons_wp}")
    check("turn 2: breakDeficit stays PARKED at 2 (same as every other "
          "turn -- this build never trades away win probability)",
          consolidation_fs["params"].get("breakDeficit") == 2,
          str(consolidation_fs["params"]))
if consolidation_jk is not None:
    check("turn 2: jackal keeps joinWhen=afterKill (it still cannot claim "
          "dFirstBlood -- it only cleans up a fight fire_superiority or "
          "the enemy already opened, so it adds no early solo-hunt risk)",
          consolidation_jk["params"].get("joinWhen") == "afterKill",
          str(consolidation_jk["params"]))
check("turn 1 (opening): still NO press-capable controller (deliberately "
      "scoped -- the very first window is politics + loot only; the "
      "leader-template window measures ~87-102s in, which the "
      "consolidation turn already covers)",
      not any(e["play"] in ("fire_superiority", "jackal")
              for e in PERSONA.canned_turns[0]["call"]["entries"]))

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
# SUPERSEDED by zoneBlocksRevive (armed 0.7.323, r3965). The v10 check
# asserted zoneReach STRICTLY SHRINKS into the endgame -- a ranking call
# between "alive at Last Light" and "partner down-then-revived". That
# ranking is now moot: a ghost on ground the ring has taken cannot be
# revived in ANY phase, so the dip budget is 0 in every turn and a
# strictly-decreasing assertion can no longer be satisfied by a correct
# policy. Replaced -- not dropped -- by the stronger flat invariant.
check("medic zoneReach is 0 in EVERY turn (zoneBlocksRevive supersedes the "
      "v10 endgame-only tightening)",
      bool(zone_reaches) and all(z == 0 for _, z in zone_reaches),
      str(zone_reaches))
check("medic zoneReach never re-opens an outward dip budget in any turn",
      all(z is not None and z <= 0 for _, z in zone_reaches),
      str(zone_reaches))

# ── v11: the duo-partner grant row is LIVE, not dormant. Pins the exact
# shape view.nim's unconditional partnerTelemetry channel puts on the wire
# (pos/aim_brads/fresh_tick=tick, hp genuinely absent, downed only when
# true) and that _view_facts recovers pos/dist/fresh/in_combat/downed from
# it end-to-end -- the fact the stale comments this lane fixed had been
# claiming was impossible. ─────────────────────────────────────────────
PARTNER_GRANT_VIEW = {
    "tick": 1000,
    "self": {"pos": [500, 500], "hp_frac": 1.0},
    "world": {"zone": {"current": [0, 0, 2000, 2000]}},
    "tracks": [
        # The partner grant row: no "hp" key (withheld by design), and
        # fresh_tick equal to the current tick (the grant is never stale).
        {"seat": 19, "team": "peach", "pos": [560, 500], "aim_brads": 40,
         "fresh_tick": 1000},
        {"seat": 9, "team": "blue", "pos": [700, 500], "fresh_tick": 995},
    ],
}
PARTNER_GRANT_CONTEXT = {"self": {"seat": 3, "team": "peach", "duo_partner": 19}}

live_facts = starter_harness._view_facts(PARTNER_GRANT_VIEW,
                                          PARTNER_GRANT_CONTEXT, [])
check("_view_facts: partner grant row is recovered from view.tracks",
      live_facts["partner_track"] is not None, str(live_facts["partner_track"]))
check("_view_facts: partner hp stays genuinely absent on the grant row",
      "hp" not in (live_facts["partner_track"] or {}),
      str(live_facts["partner_track"]))
check("_view_facts: partner_track_fresh is True (grant fresh_tick == tick)",
      live_facts["partner_track_fresh"] is True)
check("_view_facts: partner_dist matches the grant row's real position",
      live_facts["partner_dist"] == 60.0, str(live_facts["partner_dist"]))
check("_view_facts: partner_downed is False when the grant carries no flag",
      live_facts["partner_downed"] is False)

FAR_ENEMY_VIEW = dict(PARTNER_GRANT_VIEW,
                       tracks=[PARTNER_GRANT_VIEW["tracks"][0],
                               {**PARTNER_GRANT_VIEW["tracks"][1],
                                "pos": [1400, 1400]}])
far_facts = starter_harness._view_facts(FAR_ENEMY_VIEW, PARTNER_GRANT_CONTEXT, [])
check("_view_facts: partner_in_combat is False once the only enemy is far",
      far_facts["partner_in_combat"] is False)
check("_view_facts: partner_in_combat is True with an enemy inside 200px "
      "of the partner (the same radius the engine's partner.in_combat "
      "guard path uses)",
      live_facts["partner_in_combat"] is True)

DOWNED_GRANT_VIEW = dict(PARTNER_GRANT_VIEW, tracks=[
    {**PARTNER_GRANT_VIEW["tracks"][0], "downed": True},
    PARTNER_GRANT_VIEW["tracks"][1],
])
downed_facts = starter_harness._view_facts(DOWNED_GRANT_VIEW,
                                            PARTNER_GRANT_CONTEXT, [])
check("_view_facts: partner_downed tracks the grant row's downed flag",
      downed_facts["partner_downed"] is True)

# ── v-next (stranger-partner audit): ourGuns credit requires the partner
# be WITHIN engageDist of self, not merely alive somewhere on the map. A
# fresh partner track used to count as a full second gun unconditionally;
# since the duo partner is a re-drawn stranger every episode (not our own
# second Monet seat, R3746/47), presence is not evidence they are in THIS
# fight. Mirrors fire_superiority.nim's `ally` branch. ────────────────────
def fs_partner_counts(partner_dist: float, engage_dist: int) -> bool:
    return partner_dist <= engage_dist


for i, turn in enumerate(PERSONA.canned_turns, start=1):
    fs = next((e for e in turn["call"]["entries"]
               if e.get("play") == "fire_superiority"), None)
    if fs is None:
        continue
    ed = fs["params"]["engageDist"]
    check(f"turn {i}: fs_partner_counts -- partner just inside engageDist "
          "still counts as a second gun",
          fs_partner_counts(ed - 1, ed))
    check(f"turn {i}: fs_partner_counts -- partner beyond engageDist does "
          "NOT count (alive elsewhere on the map is not a gun in THIS "
          "fight)", not fs_partner_counts(ed + 1, ed))

# ── v-next (stranger-partner audit): partner-line exposure. We cannot read
# a stranger's actual aim (no brads-to-vector decode exists in this SDK),
# so fire_superiority.nim's press-target tie-break instead treats every
# OTHER visible enemy as a plausible aim target FOR the partner, and
# deprioritizes a stand point that falls in that line. `within_fire_cone`
# below is the exact sqrt-free mirror fire_superiority.nim uses (== the
# engine's sprayContains, pinned independently by
# tests/test_shell_body_spray_cone.nim -- ArcFireRangePx=170,
# ArcMaxWidthPx=85, src/shell/body.nim). ──────────────────────────────────
def within_fire_cone(origin, aim_at, other) -> bool:
    arc_range, arc_width = 170, 85
    dx, dy = aim_at[0] - origin[0], aim_at[1] - origin[1]
    d_sq = dx * dx + dy * dy
    if d_sq <= 0:
        return False
    vx, vy = other[0] - origin[0], other[1] - origin[1]
    forward = vx * dx + vy * dy
    cross = vx * dy - vy * dx
    if forward <= 0:
        return False
    if forward * forward > arc_range * arc_range * d_sq:
        return False
    return 2 * arc_range * abs(cross) <= arc_width * forward


check("within_fire_cone: straight ahead, in range and width, is caught",
      within_fire_cone((0, 0), (500, 0), (100, 0)))
check("within_fire_cone: directly behind the aim is never caught",
      not within_fire_cone((0, 0), (500, 0), (-50, 0)))
check("within_fire_cone: 300px off-axis at forward=100 is not caught "
      "(half-width there is ~25px)",
      not within_fire_cone((0, 0), (500, 0), (100, 300)))
check("exposure proxy: a stand point sitting on the partner's plausible "
      "line to ANOTHER enemy is flagged exposed",
      within_fire_cone((0, 0), (500, 0), (100, 0)))
check("exposure proxy: a stand point well off that line is not flagged",
      not within_fire_cone((0, 0), (500, 0), (100, 300)))

# ── v-next: prompt carries the stranger-partner doctrine (audit deliverable
# -- a future edit reverting to "our own second seat" language is caught
# here, same convention as the endgame-standoff prompt pins above). ───────
check("prompt: partner doctrine states the partner is redrawn each episode "
      "(not our own second seat)",
      "drawn fresh each episode" in prompt, "stranger-partner text not found")
check("prompt: chat doctrine no longer treats partner lines as a lever",
      "not a lever" in prompt, "chat doctrine text not found")

# ── medic-conversion audit: medic converted 0/96 revivable downs on live
# replays (partner upright at down time) even though it is installed and
# called every turn. Root cause measured from decoded frames, not sim:
# ladder.nim's nativeBase branch runs the native zone-escape/default-
# rotation reflex INSTEAD OF the whole controller loop whenever armed, so
# no ladder position for medic can outrank it, and the reviver closed >20px
# toward the ghost in only 11/96 cases. zoneReach/abortHpFloor are not the
# binding gates (5-8/96 and 2/96 respectively). The lever that IS ours:
# separation at down-time, which bodyguard's leash governs directly. These
# pin the leashMax tightening (200->150, under the ~177px break-even
# distance for the median 103-tick zone-bleedout window) in the two turns
# covering 75% of revivable downs, and that it never loosens leashMin
# (the anti-stack floor) or touches turns outside that window. ───────────
BODYGUARD_TIGHTENED_TURNS = (2, 3)  # 1-indexed: consolidation, mid
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    # The quiet-phase rung specifically -- "shield-close" (see below) is a
    # separate, intentionally tighter rung and must not be picked up here.
    bg = next((e for e in turn["call"]["entries"]
               if e.get("play") == "bodyguard"
               and e.get("entry_id") != "shield-close"), None)
    if bg is None:
        continue
    leash_min, leash_max = bg["params"]["leash"]
    check(f"turn {i}: bodyguard leashMin never drops below the anti-stack "
          "floor (medic-conversion audit)",
          leash_min >= 100, str(bg["params"]))
    if i in BODYGUARD_TIGHTENED_TURNS:
        check(f"turn {i}: bodyguard leashMax tightened under the revive "
              "break-even distance (medic-conversion audit)",
              leash_max <= 150, str(bg["params"]))

# ── combat-close band (measured revive protocol, 28 leader tag-backs):
# a second, entry_id-keyed bodyguard rung ("shield-close") tightens the
# leash toward revive range the instant either seat has a live enemy
# tracked or the partner reads wounded/downed, mutually exclusive with
# "shield" above by construction (gate_open in starter_harness.py). Pins:
# present only in the same two turns as the quiet-phase tightening (same
# zone-bleedout window, not a general retune), the exact band chosen
# ([40,120], the softer option this lane picked over [20,100]), and that
# the quiet-phase [100,150] band above is genuinely UNCHANGED by its
# presence. ─────────────────────────────────────────────────────────────
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    close = next((e for e in turn["call"]["entries"]
                  if e.get("play") == "bodyguard"
                  and e.get("entry_id") == "shield-close"), None)
    order = [e.get("play") for e in turn["call"]["entries"]]
    if i in BODYGUARD_TIGHTENED_TURNS:
        check(f"turn {i}: combat-close bodyguard rung present",
              close is not None, str(order))
        if close is not None:
            leash_min, leash_max = close["params"]["leash"]
            check(f"turn {i}: combat-close leash matches the chosen "
                  "[40,120] band (softer than the [20,100] the measured "
                  "data would also support -- see policy.py's "
                  "MIN_LEASH_COMBAT comment)",
                  [leash_min, leash_max] == [40, 120], str(close["params"]))
            check(f"turn {i}: combat-close leashMin clears the literal "
                  "20px anti-stack floor with real margin",
                  leash_min > 20, str(close["params"]))
            check(f"turn {i}: combat-close band sits fully inside the "
                  "quiet-phase [100,150] band -- confirms this is a "
                  "deliberately tighter rung, not a stray unfloored value",
                  leash_max < 150, str(close["params"]))
    else:
        check(f"turn {i}: no combat-close bodyguard rung outside the "
              "tightened window (scoped fix, not a general leash retune)",
              close is None, str(order))

BREAK_EVEN_PX = 26 + (103 - 48) * (704 / 256)
check("medic-conversion audit: break-even distance matches the measured "
      "arithmetic (StandInPx + (window-channel) * MaxSpeed/MotionScale)",
      abs(BREAK_EVEN_PX - 177.2) < 1.0, str(BREAK_EVEN_PX))
check("medic-conversion audit: tightened leashMax sits under the "
      "break-even distance with margin for pathing/latency",
      150 < BREAK_EVEN_PX, str(BREAK_EVEN_PX))

check("prompt: bodyguard doctrine names the quiet-phase leash band",
      "leash [100, 150]" in prompt, "bodyguard quiet-phase leash text not found")
check("prompt: bodyguard doctrine names the combat-close leash band",
      "leash [40, 120]" in prompt, "combat-close bodyguard text not found")
# ── v14: the note must be DIRECTIVE, not descriptive -- 21 sampled bodyguard
# calls showed the model inventing a single self-named entry (echoing
# format_rules' generic "ride" exemplar) instead of the two-entry split that
# only ever appeared in canned templates it never sees. Pin both literal
# entry_id strings and both leash bands in the note text itself so the
# directive survives any future rewrite.
check("prompt: bodyguard doctrine names the literal entry_id "
      "\"shield-close\"", "\"shield-close\"" in prompt,
      "shield-close entry_id text not found")
check("prompt: bodyguard doctrine names the literal entry_id \"shield\"",
      "\"shield\"" in prompt, "shield entry_id text not found")
check("prompt: bodyguard doctrine directs submitting TWO simultaneous "
      "entries, never a single self-named one",
      "TWO simultaneous bodyguard entries" in prompt
      and "never one self-named entry" in prompt,
      "directive two-entry language not found")
check("prompt: partner doctrine states the revive-close combat rule "
      "(system_prompt.md)",
      "revive-close" in prompt, "revive-close doctrine text not found")

# ── win-as-multiplier ROLLED BACK (commit d595f300 #401,
# 2026-09-04T10:34:18-07:00): the dTagBack revive-loop (zone-bleed re-downs
# the partner, revive completes at 48 ticks, repeat -- a 57-tick metronome)
# mints dTagBack x2 per completed Revived event, 24-27x per episode; the
# multiplicative recut PRODUCT compounds those per-event x2 factors
# together, so the product overshot the 28,311,552 design ceiling by
# ~10^6x (r3894 hit 9.15e15). The manifest flag winAsMultiplier flipped
# back to false on battle-royale-s2 -- confirmed from source
# (coworld_manifest_paintbot.json variants[0].game_config), not the commit
# metadata alone. This did NOT fix the metronome: sim.nim still emits an
# unconditional `Revived` event every completed channel (the down/revive
# LOOP is untouched -- only the deed mint is gated). What the flag flip
# actually does, read from sim.nim directly:
#   - dVictory (sim.nim ~line 5108-5118) mints again: gated on
#     `gloryMultiplierRecut and brMode and not isDraw and not
#     winAsMultiplier` -- all four now true on battle-royale-s2, so the
#     win is back to being an ordinary x8 deed, routed through the same
#     RecutClassTable/heat/carry/stack pricing as every other deed (NOT a
#     flat multiplier bypass -- that was the retired winAsMultiplier fold,
#     sim.nim ~line 5120-5131, now dark).
#   - dTagBack (sim.nim ~line 7164-7174) and dJointAct are BOTH gated on
#     `gloryMultiplierRecut AND winAsMultiplier` (glory.nim ~line 246-262)
#     -- with winAsMultiplier false, NEITHER mints at all right now, so
#     the metronome's repeated Revived events are scoring-inert today.
#     Revive-farming is not currently a live strategy, but the loop
#     itself is only latent, not closed -- re-arming winAsMultiplier
#     without a per-episode dTagBack mint cap reproduces the exact
#     overshoot (owner's own rollback-commit ruling: "re-arm only after
#     repeatable deeds get per-episode mint caps / diminishing rungs").
# This is the SECOND flip on this key in <36h (dark -> armed a1acd96a
# #393 2026-09-03 ~21:xx -> dark d595f300 #401 2026-09-04 10:34), so the
# pinned phrase below deliberately names the DOCTRINE ("the win itself is
# a deed that multiplies like everything else") rather than the specific
# fold arithmetic (no "x4"/"x8" in the prose) -- a future recut-class
# repricing of dVictory does not need to touch this passage; only another
# winAsMultiplier flip does, and this comment block is where to update it
# when that happens. ─────────────────────────────────────────────────────
check("prompt: objective lists the win itself as a deed that multiplies "
      "(winAsMultiplier DARK again on battle-royale-s2 as of d595f300 "
      "#401 2026-09-04T10:34:18-07:00 -- dVictory is back, x8, "
      "recutFactor-routed; dTagBack/dJointAct are dark, gated on "
      "winAsMultiplier too)",
      "duo-downs, a clustered spray, the win itself" in prompt,
      "win-as-deed text not found")

# ── loss/placement economics (glory.nim: recutFold folds the x4 ONLY onto
# the winner's own gloryProduct at finishGame; a losing team's product is
# never touched, so every deed minted before the loss is still banked and
# reported through recutScore). What actually reads zero is an UNMINTED
# episode -- no deed landed -- not the act of losing. Self-contradiction
# fix (this commit): THE OBJECTIVE used to claim "a loss pays NOTHING",
# directly contradicting the endgame doctrine's own "losses now bank what
# you minted" a few lines down. Pins the corrected, single position and
# guards against the stale win-gate claim creeping back in. ───────────────
check("prompt: objective states deeds mint win or lose",
      "win or lose" in prompt, "win-or-lose text not found")
check("prompt: objective states idle (not losing) is what banks nothing",
      "idle pays NOTHING" in prompt, "idle-pays-nothing text not found")
check("prompt: partner doctrine states idle placement banks zero, not "
      "a loss",
      "idle placement\n  banks zero" in prompt
      or "idle placement banks zero" in prompt,
      "idle-placement text not found")
check("prompt: endgame doctrine still states losses bank what you minted",
      "losses now bank what you minted" in prompt,
      "losses-bank text not found")
check("prompt: NEGATIVE -- does not claim a loss pays nothing "
      "(the self-contradiction this commit fixes)",
      "a loss pays NOTHING" not in prompt
      and "banks the same as a loss" not in prompt
      and "nothing but the win pays" not in prompt
      and "zeroes the whole product" not in prompt,
      "stale win-gate loss-pays-nothing text found in prompt")

# ── deedMintCaps ARMED (coworld-ctf origin/main ba6ae904, PR #417,
# 2026-09-04 16:19): coworld_manifest_paintbot.json flips deedMintCaps
# false -> true on battle-royale-s2. This repo's own engine checkout
# (src/ctf/glory.nim, src/ctf/sim.nim) predates the BR deed vocabulary
# entirely (dDuoDown/dJointAct/dTagBack/winAsMultiplier/deedMintCaps do
# not exist there yet -- glory.nim's Deed enum ends at dAchievement), so
# this cannot be re-derived from local source; taken as given per the
# hourly verification. What changes for the model: per-episode, per-duo
# mint BUDGETS now cap dTagBack 3, dJointAct 6, dDuoDown 4, dShieldSoak 3
# -- a mint past its cap still FIRES the event (kill feed, counters) but
# folds a factor of 1, i.e. scores zero, indistinguishable from a success
# in every count except the payout. THE OBJECTIVE used to frame finishing
# opposing duos as unlimited volume ("each one stacks your take again --
# volume, not one big finish") and the jackal doctrine echoed the same
# unlimited framing ("working through fights beats holding out for one
# perfect finish") -- both are now false for dDuoDown past its 4-per-
# episode-per-duo budget. dTagBack (revive) and dShieldSoak (ambient
# absorb) carry no comparable volume claim in this prompt today, so they
# are left untouched -- nothing to correct there. dJointAct has no
# confident textual anchor in this prompt (the "clustered spray" line
# reads as dSplashMultiKill, a different, uncapped-by-this-change deed),
# so it is also left untouched rather than guessed at. ────────────────────
check("prompt: objective states the duo-finish cap (dDuoDown, 4 per "
      "episode per duo) and that a mint past it still fires but scores "
      "nothing",
      "up to\n4 per episode per duo" in prompt
      and "mints nothing" in prompt,
      "duo-finish cap text not found")
check("prompt: jackal doctrine repeats the same duo-finish cap rather "
      "than the old unlimited-volume framing",
      "up to 4 per episode per duo" in prompt
      and "mints nothing" in prompt,
      "jackal duo-finish cap text not found")
check("prompt: NEGATIVE -- does not claim finishing duos is unlimited "
      "volume (the deedMintCaps era correction this commit makes)",
      "volume, not one big finish" not in prompt
      and "working through fights beats holding out" not in prompt,
      "stale unlimited-duo-finish text found in prompt")

# ── bedrock escape hatch (live incident 2026-09-03): the sidecar's
# OpenAI-compatible / OpenRouter lane returned pooled-key 503s and both v10
# and v11 qualified as league champion on canned play (0 real model calls)
# with no visible failure short of grepping "real model calls: 0" out of
# the ladder log. Pins that the Dockerfile arms the sanctioned escape hatch
# (brain.py SIDECAR_PROTOCOL_ENV) so a future rebuild can't silently drop
# back onto the broken lane. ───────────────────────────────────────────────
DOCKERFILE_TEXT = (_HERE / "Dockerfile").read_text()
check("Dockerfile: arms POC_LLM_PROTOCOL=bedrock (the sanctioned escape "
      "hatch off the broken OpenRouter sidecar lane)",
      "POC_LLM_PROTOCOL=bedrock" in DOCKERFILE_TEXT,
      "POC_LLM_PROTOCOL=bedrock not found in Dockerfile ENV block")


# ── win-economics staleness, WHOLE-PROMPT (era audit 2026-09-04): the
# ladder armed a flat x4 win multiplier, then ROLLED IT BACK, so the win is
# once again an ordinary deed that multiplies in like any other. Commit
# e8dce78c fixed THE OBJECTIVE but a second "only the win pays the x4" line
# survived in the Endgame section, because every existing check pinned the
# OBJECTIVE phrase only and nothing scanned the rest of the file. These
# checks scan the WHOLE prompt so the next era flip cannot hide in a
# paragraph nobody asserted on. ────────────────────────────────────────────
import re as _re  # noqa: E402

check("prompt: NEGATIVE -- no sentence ties the WIN to a flat x4 anywhere in "
      "the built prompt (that multiplier was armed then rolled back)",
      _re.search(r"win[^.]{0,60}\bx4\b", prompt) is None,
      "a win-pays-x4 claim survives in the built prompt")
check("prompt: NEGATIVE -- no 'only the win pays' framing anywhere",
      "only the win pays" not in prompt,
      "win-gate framing survives in the prompt")
check("prompt: POSITIVE guard -- the STREAK multiplier doctrine (x2/x4/x8 as "
      "clustered tags climb) is untouched; it is a different mechanic from "
      "the retired win multiplier and must not be collaterally deleted",
      "x2, x4, x8 as the streak climbs" in prompt,
      "streak-multiplier doctrine missing from the prompt")
check("prompt: endgame frames the win as minting one more deed, not as a "
      "special multiplier",
      "the win mints one more" in prompt,
      "endgame win-as-deed text not found")

# ── truncated-reply repair (live incident 2026-09-04): in BOTH the v14 and
# v15 qualification matches, 2 of 16 seats hit
# `model did not return JSON` where the payload was neither prose nor a
# fenced block -- it was well-formed JSON cut off mid-token, on the first
# attempt AND on the corrective retry. Because ResilientBrain latches its
# error on first failure, one truncated reply turned that seat canned for
# every remaining tick of the match. parse_model_json now salvages the
# complete prefix. These checks pin BOTH halves of the contract: what the
# repair must recover, and what it must still refuse. ───────────────────────
sys.path.insert(0, str(_HERE.parent / "poc_llm_policy"))
import brain  # noqa: E402

check("brain: a plain JSON object still parses unchanged",
      brain.parse_model_json('{"a": 1}') == {"a": 1})
check("brain: a ```-fenced object still parses unchanged",
      brain.parse_model_json('```json\n{"b": 2}\n```') == {"b": 2})
check("brain: an object embedded in prose still parses unchanged",
      brain.parse_model_json('sure thing {"c": 3} hope that helps') == {"c": 3})

_TRUNC_MID_KEY = (
    '{"chat": "ride tight", "call": {"entries": ['
    '{"play": "scatter", "entry_id": "s"}, '
    '{"play": "medic", "entry_id": "m", "params": {"abortHpF')
_repaired = brain.parse_model_json(_TRUNC_MID_KEY)
check("brain: a reply cut mid-key salvages every complete entry",
      [e["play"] for e in _repaired["call"]["entries"]] == ["scatter", "medic"],
      str(_repaired))
check("brain: the entry whose params were cut keeps its play, drops the "
      "half-written params (the harness repair path defaults them)",
      "params" not in _repaired["call"]["entries"][-1],
      str(_repaired["call"]["entries"][-1]))
check("brain: the chat line survives the repair",
      _repaired.get("chat") == "ride tight", str(_repaired.get("chat")))

_TRUNC_MID_ARRAY = (
    '{"chat": "zone closing", "call": {"entries": ['
    '{"play": "pact", "entry_id": "clones"}, {')
check("brain: a reply cut mid-array keeps the entries that did close",
      [e["play"] for e in
       brain.parse_model_json(_TRUNC_MID_ARRAY)["call"]["entries"]] == ["pact"])


def _still_raises(text: str) -> bool:
    try:
        brain.parse_model_json(text)
    except ValueError:
        return True
    return False


check("brain: NEGATIVE -- a salvage with no complete entry is REFUSED, so a "
      "seat cannot quietly no-op every tick while reporting a healthy model",
      _still_raises('{"chat": "hold the line", "call": {"entries": [{"play": "sca'))
check("brain: NEGATIVE -- the bare `{` prefill (the exact live failure "
      "signature) still raises",
      _still_raises("{"))
check("brain: NEGATIVE -- prose still raises, degrade path intact",
      _still_raises("I do not think I should answer that"))
check("brain: NEGATIVE -- a top-level array still raises",
      _still_raises("[1, 2, 3]"))
check("brain: NEGATIVE -- structurally broken JSON is not 'repaired'",
      _still_raises('{"a": 1}}} trailing'))
check("brain: NEGATIVE -- empty output still raises",
      _still_raises(""))

# The salvaged plan must survive the SAME repair path a canned turn takes --
# a recovered reply is worthless if the harness then rejects it.
_salvaged_payload, _salvaged_wire = starter_harness.repair_call(
    brain.parse_model_json(_TRUNC_MID_KEY), PERSONA, fake_seat(), AVAILABLE)
check("brain: a repaired reply survives the harness repair path and reaches "
      "the wire",
      bool(_salvaged_wire) and all("play" in e for e in _salvaged_wire),
      str(_salvaged_wire)[:200])

print()
if failures:
    print(f"SELF-CHECK FAILED: {len(failures)} failing check(s)")
    sys.exit(1)
print("SELF-CHECK PASSED")

# ── zoneBlocksRevive ARMED (engine commit 2d651034 / PR #402, armed on the
# battle-royale-s2 variant at build 0.7.323 ~= round 3965): once the closing
# ring's damage/arrival field covers a DOWNED player's own tile, the revive
# channel is reset to 0 every tick and no Revived event is ever emitted. The
# guard tests the GHOST's tile (not the reviver's), re-runs continuously, and
# the field is monotonic -- it never recedes, so there is no waiting it out,
# no repainting over it, and no dragging the body clear (a ghost is frozen).
# Nothing surfaces "this revive is impossible" to the policy: the failure is a
# SILENT no-op, which is exactly the shape a reviver stands in forever.
# Our revive doctrine predated this and said the pickup "outranks every tag"
# unconditionally. These pin the correction, and the NEGATIVE pins that the
# unconditional framing does not creep back. ───────────────────────────────
check("prompt: revive doctrine names the ring's ground as the place a "
      "pickup can NEVER land (zoneBlocksRevive, armed 0.7.323)",
      "ground the ring has already taken" in prompt,
      "ring-blocked-revive doctrine text not found")
check("prompt: the blocked revive is stated as SILENT -- the policy is told "
      "no signal marks it, because the engine emits none",
      "no message tells you" in prompt,
      "silent-failure framing not found in the revive doctrine")
check("prompt: the block is stated as PERMANENT (the paint front is "
      "monotonic; that ground never becomes good again)",
      "never becomes good again" in prompt,
      "monotonic/permanent framing not found in the revive doctrine")
check("prompt: doctrine directs ABANDONING a body the ring owns rather than "
      "holding a channel that cannot fill",
      "hold a body the ring owns" in prompt,
      "abandon-the-blocked-body directive not found")
check("prompt: NEGATIVE -- the pickup is no longer framed as outranking "
      "every tag WITHOUT the ring exception following it",
      "EXCEPT on ground the ring has already taken" in prompt,
      "unconditional pickup-outranks-every-tag framing has crept back")
check("prompt: doctrine converts the mechanic into a POSITIONAL rule -- keep "
      "the partner inward of the closing edge, not merely close",
      "which side of the edge the fall happens on" in prompt,
      "inward-of-the-edge positional doctrine not found")

# ── medic's ring-dead guard, mirrored (the sqrt-free house pattern): the
# engine exposes no paint bit to a play (SdkZone carries phase/current/
# next/ticksToShrink only), so medic tests the one invariant the engine
# DOES assert about its arrival field -- painted(p) implies p is outside
# rect, within ZoneCornerRoundPx = 16px slack. Channel only where the tile
# is guaranteed dry: inside the current rect by MORE than that slack.
# Direction is deliberate and asymmetric -- paint lags the rect by up to
# ZoneFlowDelayCapTicks, so this abandons some still-dry bodies and never
# stands a channel that cannot advance. ─────────────────────────────────
_ZONE_PAINT_SLACK_PX = 16  # ZoneCornerRoundPx (zone_field.nim:69)


def _edge_depth(rect, p):
    """Mirror of medic.nim edgeDepth: >0 outside by px, <=0 inside with
    that much clearance. rect = (x1, y1, x2, y2)."""
    x1, y1, x2, y2 = rect
    lox, hix = min(x1, x2), max(x1, x2)
    loy, hiy = min(y1, y2), max(y1, y2)
    if p[0] < lox or p[0] > hix or p[1] < loy or p[1] > hiy:
        dx = lox - p[0] if p[0] < lox else (p[0] - hix if p[0] > hix else 0)
        dy = loy - p[1] if p[1] < loy else (p[1] - hiy if p[1] > hiy else 0)
        return max(dx, dy)
    return -min(min(p[0] - lox, hix - p[0]), min(p[1] - loy, hiy - p[1]))


def _ring_dead(rect, ghost, zone_reach):
    """Mirror of medic.nim's guard: True == refuse to channel."""
    return _edge_depth(rect, ghost) > zone_reach - _ZONE_PAINT_SLACK_PX


_RECT = (0, 0, 1000, 1000)
check("medic guard: a ghost OUTSIDE the current rect is refused at the "
      "shipped budget (that ground may already be painted)",
      _ring_dead(_RECT, (1040, 500), 0), "outside ghost was accepted")
check("medic guard: a ghost inside the rect but WITHIN the 16px paint "
      "slack is refused (paint may reach that band)",
      _ring_dead(_RECT, (990, 500), 0), "slack-band ghost was accepted")
check("medic guard: a ghost comfortably inside the rect is accepted -- the "
      "guard must not refuse every pickup",
      not _ring_dead(_RECT, (500, 500), 0), "interior ghost was refused")
check("medic guard: the accept/refuse boundary sits exactly at the paint "
      "slack, not at the rect edge -- clearance of one px less is refused, "
      "clearance equal to the slack is the first accepted tile",
      _ring_dead(_RECT, (1000 - _ZONE_PAINT_SLACK_PX + 1, 500), 0)
      and not _ring_dead(_RECT, (1000 - _ZONE_PAINT_SLACK_PX, 500), 0),
      "boundary is not at ZoneCornerRoundPx")
check("medic guard: REGRESSION -- the retired 220px dip budget would have "
      "walked a reviver 200px onto ring-taken ground; the shipped budget "
      "refuses it",
      not _ring_dead(_RECT, (1200, 500), 220)
      and _ring_dead(_RECT, (1200, 500), 0),
      "the old dip budget no longer differs from the shipped one")

_MEDIC_SRC = (_HERE / "plays" / "medic.nim").read_text(encoding="utf-8")
check("medic.nim: the manifest ships zoneReach default 0, so a retune that "
      "omits the param cannot resurrect the dip",
      '\\"zoneReach\\":{\\"default\\":0' in _MEDIC_SRC,
      "manifest zoneReach default is not 0")
check("medic.nim: the refusal is emitted under its own reason so a blocked "
      "pickup is distinguishable from a storm-depth abort in the logs",
      '"medic:ringDead"' in _MEDIC_SRC, "medic:ringDead reason not emitted")
check("medic.nim: NEGATIVE -- the old unsigned outsideDepth test no longer "
      "gates the pickup (it cannot see the slack band)",
      "outsideDepth(decoded.world.zone.current" not in _MEDIC_SRC,
      "the superseded outsideDepth zone guard is still wired")

# ── era correction (engine commits 040f1451/9a318548/cc64f0a4, PRs #420 and
# #422, merged 2026-09-04 ~20:29 PT): coworld_manifest_paintbot.json flips
# battle-royale-s2 from 8 duos w/ loot+downed to 16 solo entrants, with
# lootStart/downedMode/giveItem/dropItem all OFF and lootSpawnSeedGuns/
# Hoppers/Radius/hopperSiteTrafficPermille/bandagePickups all zeroed; a new
# solo-team guard (sim.nim ~L2706) makes dDuoDown structurally unmintable
# once a victim's team has <2 seats. NOT YET CONFIRMED REALIZED in live
# play (r4000, the one round dispatched after the change, failed with zero
# episodes) -- so the prompt must read correctly under EITHER shape, not
# assume the new one is live. These pin that the doctrine's partner/loot/
# downed claims are now gated on what the policy actually observes this
# episode, not stated as guaranteed match facts. ──────────────────────────
check("prompt: an era-check gate precedes the partner/loot/downed doctrine",
      "ERA CHECK BEFORE ANY OF THIS" in prompt,
      "era-check gate not found in prompt")
check("prompt: partner existence is now conditional on the roster, not "
      "assumed (duo_partner absent/self => no partner this match)",
      "there is no partner this match" in prompt,
      "conditional partner-existence text not found")
check("prompt: loot presence is now conditional on what's observed, not "
      "guaranteed (an empty items list means none spawned)",
      "loot never spawned here" in prompt,
      "conditional loot-presence text not found")
check("prompt: the downed/revive economy is now conditional on what's "
      "observed, not assumed to exist every match",
      "no revive to stand" in prompt,
      "conditional downed-economy text not found")
check("prompt: the duo-down deed is named as structurally unmintable when "
      "duos can't go down together (solo-team guard, sim.nim ~L2706)",
      "never mints the duo-down deed" in prompt,
      "duo-down-unmintable text not found")
check("prompt: NEGATIVE -- loot at spawn is no longer stated as an "
      "unconditional guarantee (the era correction this commit makes)",
      "there is always enough dropped near spawn" not in prompt,
      "stale unconditional loot-guarantee text found in prompt")
check("prompt: the loot bullet's guarantee is now scoped to matches that "
      "actually spawn it",
      "whenever the field actually spawns loot" in prompt,
      "conditional loot-spawn scoping text not found")
