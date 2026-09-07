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

# ── BUG #2 pin: opening call preserves non-idle gated plays ───────────────
# gate_and_build's spawn-phase strip exists to keep an IDLE-HOLDING
# controller (jackal parked on a tracked enemy, bodyguard anchored on a
# partner) off the spawn point -- not to discard every GATED_PLAYS entry.
# A tick-0 view already carrying a fresh enemy track opens fire_superiority's
# gate too; the opening call must keep it (it used to collapse to bare
# target_law+edge_ride) while jackal still comes off the spawn point.
_OPENING_VIEW = {
    "tick": 0,
    "self": {"pos": [100, 100], "hp_frac": 1.0},
    "tracks": [{"seat": 99, "team": 9, "pos": [110, 100], "fresh_tick": 0}],
}
_opening_seat = fake_seat(context=FAKE_CONTEXT, view=dict(_OPENING_VIEW))
_opening_seat.wanted_entries = [
    {"play": "jackal", "entry_id": "third", "params": {}},
    {"play": "fire_superiority", "entry_id": "pressbreak", "params": {}},
    {"play": "edge_ride", "entry_id": "ride"},
]
_, _opening_wire = starter_harness.gate_and_build(_opening_seat, AVAILABLE)
_opening_plays = [e["play"] for e in _opening_wire]
check("opening call (spawn phase) keeps a non-idle gated play whose gate "
      "is open (fire_superiority) while still holding jackal off the spawn "
      "point -- only jackal/bodyguard are spawn-phase idle-holders, not "
      "every GATED_PLAYS entry",
      "fire_superiority" in _opening_plays and "jackal" not in _opening_plays,
      str(_opening_plays))

# ── BUG #3 pin: per-play entry_id is stable across re-calls ───────────────
# The model renames a play's entry_id call over call (loot "arm" -> "loot",
# supply_run "bank" -> "heal", ...) and the engine's replacementKeyMatches
# (replacement.nim) requires an EXACT entry_id match to warm-reconfigure a
# live rung -- a renamed id reads as a brand-new entry and cold-restarts it.
# policy._stabilize_entry_ids generalizes bodyguard's fixed-id trick to
# every other play: whichever entry_id a play first ships with THIS match
# is the one every later call is forced back onto. Simulate a model that
# renames "loot" on every call and confirm the wanted ladder (what
# _stabilize_entry_ids writes) keeps one id throughout.
def _renamed_loot_decision(entry_id):
    return {"chat": "", "call": {"entries": [
        {"play": "loot", "entry_id": entry_id, "params": dict(policy.LOOT_DEFAULTS)},
        {"play": "edge_ride", "entry_id": "ride"},
    ]}}


_rename_ids = []
for _candidate in ("arm", "loot", "grab", "arm"):
    _seat = fake_seat()
    starter_harness.repair_call(_renamed_loot_decision(_candidate), PERSONA,
                                _seat, AVAILABLE)
    _loot_entry = next((e for e in _seat.wanted_entries if e["play"] == "loot"),
                       None)
    _rename_ids.append(_loot_entry.get("entry_id") if _loot_entry else None)
check("per-play entry_id is stable across re-calls even when the model "
      "renames it (loot 'arm'->'loot'->'grab'->'arm' all resolve to the "
      "SAME wanted-ladder entry_id, so replacement.nim warm-reconfigures "
      "instead of cold-restarting)",
      len(set(_rename_ids)) == 1 and None not in _rename_ids,
      str(_rename_ids))

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

# ── UNAIMABLE pact (IMPROVE queue #1, tick 15; fixed 2026-09-05): a SOLO
# seat (duo_partner missing or == own seat) has no neighboring duo
# (_neighbor_duo returns None) and no genuine partner to fall back on, so
# a placeholder/self-referential pact cannot be re-aimed at anything
# real. It must be DROPPED -- the same release mechanic as an ended
# truce -- rather than let the placeholder seats ride onto the wire and
# poison target_law's never-list with two arbitrary, unrelated solo
# opponents we hold no truce with. ─────────────────────────────────────────
solo_seat = fake_seat(context={"self": {"seat": 3, "duo_partner": None}})
_, entries_solo = starter_harness.repair_call(
    PERSONA.canned_turns[0], PERSONA, solo_seat, AVAILABLE)
pact_solo = next((e for e in entries_solo if e["play"] == "pact"), None)
law_solo = next((e for e in entries_solo if e["play"] == "target_law"), None)
check("SOLO + placeholder pact: the unaimable pact is DROPPED entirely, "
      "not re-aimed and not left carrying the placeholder",
      pact_solo is None, str(pact_solo))
check("SOLO + placeholder pact: the dropped pact's placeholder seats "
      "never reach target_law's never-list",
      law_solo is not None
      and not ({"seat:0", "seat:16"}
               & set(law_solo["params"].get("never", []))),
      str(law_solo))

# ── SOLO + a model's genuine, real, distinct pact choice: left untouched.
# Only an UNAIMED pact (placeholder / self-referential / empty) with no
# real target is dropped -- a model that names two real, non-own seats
# gets exactly what it asked for, same as today.
solo_real_seat = fake_seat(context={"self": {"seat": 3, "duo_partner": None}})
_, entries_solo_real = starter_harness.repair_call(
    {"call": {"entries": [
        {"play": "pact", "entry_id": "truce",
         "params": {"partners": ["seat:7", "seat:8"], "protect": False,
                    "onBetrayal": "returnFire"}},
        {"play": "target_law", "entry_id": "law",
         "params": {"prefer": ["revenge", "bounty", "weakened",
                                "isolated"]}},
    ]}}, PERSONA, solo_real_seat, AVAILABLE)
pact_solo_real = next((e for e in entries_solo_real if e["play"] == "pact"),
                      None)
check("SOLO + a real, distinct pact choice: kept exactly as submitted, "
      "not re-aimed and not dropped",
      pact_solo_real is not None
      and set(pact_solo_real["params"]["partners"]) == {"seat:7", "seat:8"},
      str(pact_solo_real))

# ── NEGATIVE CONTROL: a genuine DUO seat with the same placeholder pact
# must still re-aim at the neighboring duo exactly as before -- the
# UNAIMABLE drop above is scoped to the no-neighbor/no-partner case only,
# never widened to swallow the working duo fallback (the variant has
# flipped seven times in ~72h; reversibility beats commitment).
duo_control_seat = fake_seat()  # FAKE_CONTEXT: seat 3, duo_partner 19 (real)
_, entries_duo_control = starter_harness.repair_call(
    PERSONA.canned_turns[0], PERSONA, duo_control_seat, AVAILABLE)
pact_duo_control = next(
    (e for e in entries_duo_control if e["play"] == "pact"), None)
check("NEGATIVE CONTROL: a real DUO seat's placeholder pact is still "
      "re-aimed at the neighboring duo, not dropped (the fallback path "
      "is untouched by the SOLO-only drop)",
      pact_duo_control is not None
      and set(pact_duo_control["params"]["partners"]) == NEIGHBOR_REFS,
      str(pact_duo_control))

# ── _neighbor_duo: team size is OBSERVED per call (self/duo_partner
# offset), never a fixed divisor off seat or roster count. A 16-seat SOLO
# roster (2026-09-05 era, confirmed realized: 16 distinct teams, zero
# repeats, one seat each) must not be read as 8 duos just because it
# happens to carry 16 seats -- that misreading is exactly the retired
# `seats // 2` bug (it directed pact/truce politics at two unrelated solo
# seats as if they shared a team). ─────────────────────────────────────────
SOLO16_ROSTER = [{"seat": i} for i in range(16)]
check("_neighbor_duo: solo (duo_partner missing) is None at 1 seat/team, "
      "even with a 16-seat roster present -- no fixed divisor substitutes "
      "for the missing partner",
      policy._neighbor_duo({"self": {"seat": 3, "duo_partner": None},
                            "roster": SOLO16_ROSTER}) is None,
      str(policy._neighbor_duo({"self": {"seat": 3, "duo_partner": None},
                                "roster": SOLO16_ROSTER})))
check("_neighbor_duo: solo (duo_partner == own seat) is None at 1 "
      "seat/team",
      policy._neighbor_duo({"self": {"seat": 3, "duo_partner": 3},
                            "roster": SOLO16_ROSTER}) is None,
      str(policy._neighbor_duo({"self": {"seat": 3, "duo_partner": 3},
                                "roster": SOLO16_ROSTER})))
check("_neighbor_duo: duo fallback still derives correctly at 2 "
      "seats/team -- the self/duo_partner offset IS the team size, "
      "independent of roster length (8-seat offset on a 16-seat roster)",
      policy._neighbor_duo({"self": {"seat": 3, "duo_partner": 11},
                            "roster": SOLO16_ROSTER}) == (4, 12),
      str(policy._neighbor_duo({"self": {"seat": 3, "duo_partner": 11},
                                "roster": SOLO16_ROSTER})))
check("_neighbor_duo: NEGATIVE -- a fixed `seats // 2` divisor has not "
      "returned. This 16-seat roster's real duo offset is 5 (seat 0 / "
      "partner 5); the retired formula would derive team_count=8 from "
      "roster length alone and answer (1, 9) -- the observed offset must "
      "win and answer (1, 6) instead",
      policy._neighbor_duo({"self": {"seat": 0, "duo_partner": 5},
                            "roster": SOLO16_ROSTER}) == (1, 6),
      str(policy._neighbor_duo({"self": {"seat": 0, "duo_partner": 5},
                                "roster": SOLO16_ROSTER})))

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
mid_jk = next((e for e in PERSONA.canned_turns[2]["call"]["entries"]
               if e["play"] == "jackal"), None)
_endgame_wp = endgame_fs["params"]["woundedPct"]
_endgame_bd = endgame_fs["params"]["breakDeficit"]
_mid_wp = mid_fs["params"]["woundedPct"]

# v16 ALLY-STACK FIX, mid-turn half of the pair (consolidation's pin sits
# above, with the full measured rationale) -- mid carries the widest
# earshot window (v10, re-armed 450->550) so it gets the most fight-loiter
# time of any turn; the same afterKill->bothWeakened join-timing fix
# applies here.
if mid_jk is not None:
    check("turn 3 (mid): jackal ARMED to joinWhen=bothWeakened (v16 "
          "ally-stack fix, same as consolidation)",
          mid_jk["params"].get("joinWhen") == "bothWeakened",
          str(mid_jk["params"]))

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

# ── T22 (IMPROVE-QUEUE #3): ClosingTime/LastLight are the engine's own
# ZONE CLOCK (src/ctf/glory.nim recutZonePhase, mirrored by
# src/ctf/server.nim firstLightZonePhase/ticksToNextZoneShrink -- see
# policy.py's TOTAL_ZONE_PHASES/_in_marquee_zone_window for the full
# citation), not the endgame canned turn's ~30s-cadence guess at when the
# ring gets there. Prove the helper's own boundary cases first, then prove
# the override actually reaches the wire through repair_call -- a helper
# that answers correctly in isolation but is never wired into
# adjust_entries would pass the first block and fail every check below. ──
_final_view = {"world": {"zone": {"phase": policy.TOTAL_ZONE_PHASES,
                                   "ticks_to_shrink": 900}}}
_closing_view = {"world": {"zone": {"phase": 2, "ticks_to_shrink": 0}}}
_wait_view = {"world": {"zone": {"phase": 2, "ticks_to_shrink": 150}}}

check("_in_marquee_zone_window: phase >= N is LastLight's whole window "
      "(final), even mid-shrink",
      policy._in_marquee_zone_window(_final_view))
check("_in_marquee_zone_window: an EARLIER phase actively shrinking "
      "(ticks_to_shrink == 0) is ClosingTime's window",
      policy._in_marquee_zone_window(_closing_view))
check("_in_marquee_zone_window: an earlier phase still WAITING "
      "(ticks_to_shrink > 0) is neither window",
      not policy._in_marquee_zone_window(_wait_view))
check("_in_marquee_zone_window: missing/malformed zone data reads False, "
      "never a guess (pre-BR fixture, empty view, stripped self-check "
      "view)",
      not policy._in_marquee_zone_window({"world": {}})
      and not policy._in_marquee_zone_window({})
      and not policy._in_marquee_zone_window(
          {"world": {"zone": {"phase": "two"}}}))

_mid_idx, _endgame_idx = 2, 3  # canned_turns is 0-indexed; "turn 3"/"turn 4"
for _view, _expect, _label in (
        (_wait_view, 50, "still WAITING -- untouched (mid-turn's own v10 "
                          "posture holds)"),
        (_closing_view, 0, "an earlier phase CLOSING"),
        (_final_view, 0, "phase >= N, LAST LIGHT")):
    _seat = fake_seat(view=_view)
    starter_harness.repair_call(PERSONA.canned_turns[_mid_idx], PERSONA,
                                 _seat, AVAILABLE)
    _fs = next((e for e in _seat.wanted_entries
                if e["play"] == "fire_superiority"), None)
    check(f"marquee zone gate reaches mid-turn's wanted ladder -- {_label}",
          _fs is not None and _fs["params"].get("woundedPct") == _expect,
          str(_fs["params"] if _fs else None))

_seat = fake_seat(view=_closing_view)
starter_harness.repair_call(PERSONA.canned_turns[_endgame_idx], PERSONA,
                             _seat, AVAILABLE)
_fs = next(e for e in _seat.wanted_entries
           if e["play"] == "fire_superiority")
check("marquee zone gate is a no-op on the endgame turn (already 0 by "
      "the v10 amendment -- proves the new override never conflicts with "
      "the existing endgame fix)",
      _fs["params"].get("woundedPct") == 0, str(_fs["params"]))

_seat = fake_seat(view=_final_view)
starter_harness.repair_call(PERSONA.canned_turns[0], PERSONA, _seat,
                             AVAILABLE)
check("marquee zone gate never INVENTS a fire_superiority entry on a turn "
      "that did not call one (opening turn)",
      not any(e["play"] == "fire_superiority"
              for e in _seat.wanted_entries),
      str([e["play"] for e in _seat.wanted_entries]))

# ── T22 era-gate catch: PAYBACK's self-avenge framing ("whoever tagged
# YOU") describes `avengesKiller` (src/ctf/glory.nim killDeed), which the
# engine's own one-life BR rule makes structurally dead code (a killer who
# ever died is already permanently eliminated -- see glory.nim's
# KillContext.avengesPartner doc comment). The ONLY BR-reachable path is
# `avengesPartner`: killing whoever killed your DUO PARTNER, which needs a
# partner and so never mints solo either. The prompt must name the real
# path, not the dead one, and must not spend a solo-applicable bullet
# telling the model to chase the dead one. ────────────────────────────────
check("prompt: PAYBACK is tied to the DUO PARTNER's tagger, the only "
      "BR-reachable path",
      "killing your fallen DUO PARTNER's" in prompt, "wording not found")
check("prompt: PAYBACK is explicitly marked duo-only / never mints solo",
      "never mints solo" in prompt, "wording not found")
check("prompt: the solo-applicable ledger no longer tells the model to "
      "chase whoever tagged IT (the dead avengesKiller shape)",
      "whoever tagged\n  YOU first" not in prompt
      and "whoever tagged YOU first" not in prompt,
      "dead self-avenge phrasing still present")
check("prompt: the duo fallback names PAYBACK at its one real trigger "
      "(the fallen partner's tagger), not left anonymous",
      "PAYBACK's ONLY reachable path" in prompt, "wording not found")

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
    # v16 ALLY-STACK FIX RETIRES this pin's afterKill claim (2026-09-06,
    # measured): a 6-episode decode of the live v30 build showed named-deed
    # mints flat at 0-2/episode -- the v29 co-engagement prose registered
    # in the model's own reasoning but never moved a mint, because
    # afterKill (per play_sdk/reference/jackal.nim) only joins once the
    # ORIGINAL fight's kill has already landed, so our tag falls on a
    # fresh, uncontested survivor (k=1, stack x1) every time. The
    # dFirstBlood/solo-hunt-risk rationale below still holds -- bothWeakened
    # is equally gated on an existing tracked fight -- but the join TIMING
    # changes from after-the-kill to during-the-exchange, which is the
    # actual k>=2 co-engagement trigger.
    check("turn 2: jackal ARMED to joinWhen=bothWeakened (v16 ally-stack "
          "fix -- joins WHILE the target still reads weakened by someone "
          "else's fire, landing inside the SAME 120-tick window, instead "
          "of after the fight is already decided)",
          consolidation_jk["params"].get("joinWhen") == "bothWeakened",
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
# pinned phrase below deliberately named the DOCTRINE ("the win itself is
# a deed that multiplies like everything else") rather than the specific
# fold arithmetic -- a future recut-class repricing of dVictory does not
# need to touch this passage; only another winAsMultiplier flip does.
# ── SCORING-SOLVE (ground truth verified origin/main @ 3eed397f, landed
# this driver run 2026-09-05): the doctrine above is now the FULL solve,
# not a partial reading -- score = 1 x PI(recutFactor per minted deed) /
# 2^(friendly-fire incidents), floored. Commons (tag/sprayed/bombed/
# point-blank) are factor 1, EXEMPT from every multiplier. THE OBJECTIVE
# rewrite drops the old duo-only "duo-downs, a clustered spray, the win
# itself" framing (SOLO is the confirmed era; there is no duo-down deed
# to name) and replaces it with the named-class table (FIRST!/LONGSHOT/
# MULTI!/PAYBACK/CHASE/ACETAG/ClosingTime/LastLight/Victory) plus the
# three stacking multipliers (enemy-ground rung, heat ladder, Fibonacci
# co-engagement). The win-itself-is-a-deed-that-multiplies DOCTRINE this
# check pins survives intact -- Victory=8 rides the SAME heat ladder as
# every other deed (8 cold, up to 64 hot) -- so the pinned substring
# moves to that clause rather than retiring. ──────────────────────────────
check("prompt: objective lists the win itself as a deed that multiplies "
      "and rides the same heat ladder as every other deed (SCORING-SOLVE, "
      "origin/main @ 3eed397f, 2026-09-05 -- Victory=8 cold up to 64 hot, "
      "never stack-scaled)",
      "Victory=8 for the win itself" in prompt
      and "Victory alone rides the heat ladder too" in prompt
      and "cold 8 into a hot 16-64" in prompt,
      "win-as-heat-scaled-deed text not found")
check("prompt: objective states commons (plain tag/spray/bomb/point-blank) "
      "price at factor 1, EXEMPT from every multiplier (SCORING-SOLVE "
      "commons-worthless finding)",
      "factor 1 -- EXEMPT from every multiplier" in prompt,
      "commons-exempt text not found")
check("prompt: objective names the enemy-ground class rung as one of the "
      "three stacking multipliers (SCORING-SOLVE)",
      "+1 class rung for" in prompt
      and "fighting on ground you took off the enemy" in prompt,
      "enemy-ground rung text not found")
check("prompt: objective states one own-side hit halves the WHOLE episode "
      "product, uncapped and compounding (SCORING-SOLVE FF halving)",
      "One hit on your own side halves" in prompt
      and "uncapped, compounding, every single time" in prompt,
      "FF-halving text not found")

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
check("prompt: partner doctrine states what lasting alone now mints "
      "(GV57 placement trio superseded the old 'idle placement banks "
      "zero' claim -- see the GV57 ECONOMY RETUNE block below)",
      "simply lasting now mints its" in prompt
      and "own placement trio too" in prompt,
      "updated placement text not found")
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

# ── GV57 ECONOMY RETUNE (origin/main 82e4f547, "glory(s2): solo recut +
# alliance keying + heat retune", GameVersion 57 / GloryVersion 14):
# merged today (2026-09-06), held off the ladder pending observation --
# the ladder was last observed at coworld_version 0.7.341 / GV56 through
# round 4251. Five independent constant changes, pinned here so a future
# edit cannot drift the doctrine back onto the retired GV56 numbers
# without failing loud.
# ── heat retune (glory.nim:964,990): ember thresholds [2,5,10]->[1,2,4],
# decay window 45->270 ticks (11.25s). Ladder values {1,2,4,8} and cap 11
# are UNCHANGED (glory.nim:977,985) -- only the reachability claim moves:
# one ember now doubles, and four (the field's observed ceiling) now tops
# the ladder at x8 instead of needing ten embers inside a 1.875s window.
check("prompt: heat doctrine states the NEW ember thresholds (1, 2, 4 "
      "named deeds, GV57) not the retired GV56 thresholds",
      "ember rungs 1, 2, 4 named deeds" in prompt,
      "GV57 ember-threshold text not found")
check("prompt: NEGATIVE -- the retired GV56 ember thresholds (2, 5, 10) "
      "are gone from the prompt",
      "ember rungs 2, 5, 10" not in prompt,
      "stale GV56 ember thresholds (2, 5, 10) still in prompt")
check("prompt: heat doctrine states the new 270-tick (11.25s) decay "
      "window, not the retired 45-tick (1.875s) one",
      "270 ticks (11.25s)" in prompt,
      "GV57 decay-window text not found")
check("prompt: heat doctrine tells the model to chain inside the new "
      "window instead of treating heat as unreachable",
      "instead of treating heat as unreachable" in prompt,
      "heat-reachability directive not found")
check("prompt: heat doctrine names four embers (the field's observed "
      "ceiling) as already topping the ladder at x8 under the new table",
      "already tops the ladder at x8" in prompt,
      "four-embers-is-x8 text not found")

# ── placement ladder (NEW scoring surface, glory.nim RecutClassTable
# ~2500-2502 / RecutFinalThresholds:2679): dFinal8/dFinal4/dFinal2 mint
# x2/x3/x4 once each at 8/4/2 teams alive, composition-neutral. This class
# did not exist before GV57 and costs nothing but not dying.
check("prompt: objective names the new placement trio (dFinal8/dFinal4/"
      "dFinal2) and its x2/x3/x4 payout",
      "dFinal8, dFinal4, and dFinal2" in prompt
      and "pay x2, x3, x4, once each" in prompt,
      "placement-trio text not found")
check("prompt: placement trio is tied to the 8/4/2-teams-left thresholds",
      "8, 4, and 2 teams left" in prompt,
      "placement-threshold text not found")

# ── solo recut (glory.nim:2818,2829,2839 recutWinFactor): the win factor
# is now team-size-keyed -- solo (our 16-seat ladder) pays x8, duo+ pays
# half that, x4. Victory=8 was already correct for solo before this
# change landed (it used to be a flat, non-team-keyed number); what's new
# is that the fallback DUO ERA section now needs its OWN, lower number
# instead of silently inheriting solo's x8.
check("prompt: objective marks Victory=8 as SOLO's team-keyed factor and "
      "forward-references the duo+ number in the fallback",
      "SOLO's factor; a duo+ finish prices" in prompt,
      "solo-keyed Victory text not found")
check("prompt: duo fallback states its OWN Victory factor (x4, half of "
      "solo's x8) instead of silently reusing the solo number",
      "A duo+ Victory prices at x4, half of solo's x8" in prompt,
      "duo+ Victory factor text not found")

# ── product cap (glory.nim:2540): 2^26 -> 2^24 (16,777,216).
check("prompt: objective states the new product cap, 2^24 (16,777,216)",
      "2^24 (16,777,216)" in prompt,
      "product-cap text not found")
check("prompt: NEGATIVE -- the retired 2^26 cap is not quoted anywhere "
      "in the prompt",
      "67,108,864" not in prompt and "2^26" not in prompt,
      "stale 2^26 product cap text found in prompt")

# ── alliance keying (sim.nim:2654-2713): blanket co-engagement scoring is
# REMOVED -- the BR ally-stack only counts a co-engaged attacker when a
# REGISTERED, MUTUAL pact is active between the two teams (pacts register
# only when both sides declare each other). We already emit the pact play
# on the correct seam (policy.py declarePactPartners call sites) -- this
# is a doctrine-only tightening, no code path changes.
check("prompt: co-engagement doctrine requires a REGISTERED, MUTUAL pact "
      "(stated in both THE OBJECTIVE and the jackal bullet)",
      prompt.count("REGISTERED, MUTUAL pact") >= 2,
      f"found {prompt.count('REGISTERED, MUTUAL pact')} occurrences, "
      "want >= 2")
# ── JOINT ACTION RE-ARMED (t27, 2026-09-07; live build 0.7.344, engine
# source 2b66cec4, verified by GET /v2/coworlds/{id} ->
# manifest.game.runnable.source_url, NOT from a version string). The two
# pins that used to live here asserted "co-engagement no longer pays on
# its own" and "is still chipping tags alone too, stack x1". BOTH ARE NOW
# FALSE AGAINST SOURCE, and they were the load-bearing text telling the
# model to decline untruced third-party fights.
# What actually changed: `winAsMultiplier` flipped false -> TRUE on the
# battle-royale-s2 variant (coworld_manifest_paintbot.json:1390, PR #436),
# which re-arms dJointAct. Read at that commit:
#   - trigger (sim.nim:2734-2794, called from absorbDamage:3277-3278):
#     within a 120-tick rolling per-victim chain, once >=2 DISTINCT teams
#     have landed a hit on one victim, every recorded contributing seat
#     mints once. Guard verbatim (sim.nim:3277):
#       `if sim.config.winAsMultiplier and sim.config.brMode:`
#     nested in `if sim.config.gloryMultiplierRecut and attackerIndex >= 0`
#     (sim.nim:3262). All three true on the live variant -> LIVE, not dark.
#   - fold: each mint is a separate sequential multiplication of the team
#     product (sim.nim:438-439 -> recutFold, glory.nim:2791,2804), factor 2
#     (glory.nim:2496), or 3 via recutShiftedClass on enemy ground.
#     N mints therefore compound, not sum.
#   - cap: RecutMintCapTable dJointAct = 6 (glory.nim:2661), enforced
#     per-episode per-TEAM by recutCappedFolds (glory.nim:2705-2712); the
#     7th+ mint still fires the event but folds factor 1.
#   - eligibility: no damage floor beyond `amount > 0` (sim.nim:3262-3263),
#     victim need not die (hooked on absorbDamage, not killPlayer), no
#     first/last-hit requirement, mints retroactively once the 2nd team
#     joins (sim.nim:2787-2794), and NO pact requirement -- dJointAct
#     never passes stackK, so recutStackMult stays 1 (glory.nim:2765).
#   - SEPARATE from the Fibonacci k-stack, which keeps its pact gate:
#     recutContextK has exactly one call site, the kill-deed mint
#     (sim.nim:2917), gated on pactActive (sim.nim:2729-2730). So the two
#     multipliers key on the same 120-tick window and are independent --
#     that distinction is the whole doctrine change.
#   - reachable on THIS ladder: 16-solo means team == seat (verified on
#     r4273 and r4333 results.team: 16 single-seat teams), so our seat plus
#     any one other seat inside 5s satisfies it. Unlike the abandoned
#     866px range lever, this situation is ordinary, not geometric.
# dTagBack did NOT come back with it: downedMode = false
# (coworld_manifest_paintbot.json:1334) no-ops the whole downed/revive
# machinery at sim.nim:7868, so its mint site is unreachable regardless of
# the flag. The revive-farming path stays closed -- do not re-open it here.
# ⚠️ This is a FLAG. Rollback is a flip with no code change. Re-verify
# winAsMultiplier on the live manifest before extending any of this. ──────
check("prompt: objective states the Fibonacci co-engagement STACK is the "
      "pact-gated half and reads x1 without a pact (t27: the stack keeps "
      "its gate; joint action does not share it)",
      "that STACK is pact-gated and reads x1 without" in prompt,
      "pact-gated-stack text not found")
check("prompt: objective states JOINT ACTION is NOT pact-gated "
      "(t27 re-arm, sim.nim:2793-2794 passes no stackK)",
      "But JOINT ACTION itself is not pact-gated" in prompt,
      "joint-action-ungated text not found")
check("prompt: objective states ONE point of damage qualifies "
      "(no damage floor beyond amount > 0, sim.nim:3262-3263)",
      "ONE point of damage is" in prompt and "enough" in prompt,
      "one-damage-qualifies text not found")
check("prompt: objective states a second seat hitting inside the same "
      "120-tick (5s) window DOUBLES the whole episode product "
      "(glory.nim:2496 factor 2, AssistWindowTicks=120 @ 24 ticks/s)",
      "120-tick (5s) window DOUBLES your whole episode product" in prompt,
      "joint-action-doubles text not found")
check("prompt: objective states joint action triples on enemy ground "
      "(recutShiftedClass, glory.nim:2724,2742)",
      "triples it" in prompt
      and "on ground you took off the enemy. The target need not die"
      in prompt,
      "joint-action-enemy-ground text not found")
check("prompt: objective states the target need not die and the kill need "
      "not be ours (hooked on absorbDamage, not killPlayer)",
      "The target need not die, the kill need" in prompt
      and "not be yours, no truce is required" in prompt,
      "joint-action-no-kill-needed text not found")
check("prompt: objective states joint action pays RETROACTIVELY when we "
      "hit first and another seat joins inside the window "
      "(sim.nim:2787-2794 mints already-recorded seats)",
      "it pays RETROACTIVELY when you" in prompt,
      "joint-action-retroactive text not found")
check("prompt: objective states the SIX-mint per-episode budget and the "
      "x64 ceiling, and directs spending it on SEPARATE targets "
      "(RecutMintCapTable dJointAct=6, glory.nim:2661)",
      "It banks SIX times per" in prompt
      and "six SEPARATE" in prompt
      and "between a x1 and a x64 episode" in prompt,
      "joint-action-six-cap text not found")
check("prompt: jackal doctrine now DIRECTS taking the untruced "
      "third-party fight rather than declining it (t27 correction)",
      "is already chipping is NOT tags alone" in prompt
      and "so TAKE that fight" in prompt
      and "untruced third-partying is the most available" in prompt,
      "jackal-take-untruced-fight text not found")
check("prompt: NEGATIVE -- the retired FALSE claims that untruced "
      "co-engagement pays nothing are gone (they were the text that "
      "suppressed a live x2-per-incident multiplier)",
      "co-engagement no longer pays on its own" not in prompt
      and "is still chipping tags alone too, stack x1" not in prompt
      and "only\na standing, two-way pact does" not in prompt,
      "stale co-engagement-is-dead text still present in prompt")

# ── idle-placement doctrine correction: GV57's placement trio makes the
# old "idle placement banks zero" claim FALSE (lasting to 8/4/2 teams now
# mints x2/x3/x4 on its own) -- the SAME kind of self-contradiction fix
# as the loss/placement economics block above, just triggered by a new
# engine constant landing rather than a prose bug. The general "idle pays
# NOTHING" claim (THE OBJECTIVE) is narrowed to "toward a named call" so
# it stays true alongside the new placement trio, which is deliberately
# the one thing that still mints on lasting alone.
check("prompt: objective narrows the idle-pays-nothing claim to named "
      "calls specifically, now that placement mints on lasting alone",
      "idle pays NOTHING toward a named call" in prompt,
      "narrowed idle-pays-nothing text not found")
check("prompt: NEGATIVE -- the retired, now-false 'idle placement banks "
      "zero' claim is gone (GV57's placement trio mints on lasting alone)",
      "idle placement\n  banks zero" not in prompt
      and "idle placement banks zero" not in prompt,
      "stale idle-placement-banks-zero text still in prompt")

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
# ── SCORING-SOLVE retires this pin's anchor text (2026-09-05): dDuoDown
# is duo-only and structurally unmintable this SOLO era (see the
# duo-down-unmintable check below), so THE OBJECTIVE no longer frames the
# jackal/politics economy around a per-duo finish cap -- there is no duo
# to cap. The real solo-era pay for a third-partying jackal is the
# Fibonacci co-engagement stack (chip the SAME target a truced seat is
# already fighting, inside 120 ticks): the two checks below replace the
# retired duo-finish-cap pins with that mechanism instead. ────────────────
check("prompt: objective names the Fibonacci co-engagement stack as the "
      "multiplier for chipping a truced seat's target within 120 ticks "
      "(SCORING-SOLVE stack-via-co-engagement, replaces the retired "
      "duo-finish-cap framing)",
      "Fibonacci co-engagement stack {1,2,3,5,8,13}" in prompt,
      "co-engagement stack text not found")
check("prompt: jackal/politics doctrine pays third-partying through the "
      "SAME Fibonacci co-engagement stack, not a per-duo finish cap",
      "co-engagement" in prompt
      and "climbs Fibonacci (x1, x2, x3, x5, x8, x13)" in prompt,
      "jackal co-engagement text not found")
check("prompt: NEGATIVE -- does not claim finishing duos is unlimited "
      "volume (the deedMintCaps era correction this commit makes)",
      "volume, not one big finish" not in prompt
      and "working through fights beats holding out" not in prompt,
      "stale unlimited-duo-finish text found in prompt")

# ── v16 ALLY-STACK FIX (2026-09-06): the SCORING-SOLVE prose above already
# claimed the co-engagement mechanism but was WIRED WRONG (jackal's
# joinWhen sat at afterKill, see the consolidation/mid pins above) -- a
# 6-episode decode of the live v30 build showed named-deed mints flat at
# 0-2/episode, proving the prose alone never moved behavior. This pin
# checks that the prompt's join-timing claim now matches the ACTUAL wired
# param (bothWeakened), not just the stack-payout claim already pinned
# above -- "assert against the source, not the prose".
check("prompt: jackal doctrine states the join-TIMING mechanism (join "
      "while still weakened/live, not after the kill) -- matches the "
      "joinWhen=bothWeakened param pinned above, not the retired "
      "afterKill wiring",
      "fresh, uncontested survivor" in prompt
      and "join WHILE the target still reads weakened" in prompt,
      "jackal join-timing text not found")
for _i, _turn in enumerate(PERSONA.canned_turns, start=1):
    _jk = next((e for e in _turn["call"]["entries"] if e["play"] == "jackal"),
               None)
    if _jk is not None:
        check(f"turn {_i}: jackal doctrine/param AGREE -- prompt claims "
              "bothWeakened-style co-engagement and the wired entry is "
              "not left on the retired afterKill value",
              _jk["params"].get("joinWhen") != "afterKill",
              str(_jk["params"]))

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

# NOTE: the final `if failures: ... sys.exit(1)` gate lives at the true end
# of this file, past every section below -- see the tombstone comment there
# for why (a stray mid-file gate silently let ~20+ later checks run DARK:
# they printed PASS/FAIL but never touched the exit code, so a real
# regression there would never have failed CI or a local run).

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

# ── era correction, round 2 (measured 2026-09-05: 36/36 completed episodes
# across r4003/4004/4005 read 16 DISTINCT team colors per episode, zero
# repeats -- the direct signature of 16 solo entrants, not 8 duos; deaths
# are binary with no revive/down counts; the results schema carries no
# loot field at all). The prior era-correction (above) only made the
# doctrine's claims CONDITIONAL; the reshape is now CONFIRMED REALIZED, so
# solo becomes the DEFAULT/PRIMARY branch the prompt leads with, and the
# partner/downed/loot doctrine becomes an explicitly-labeled FALLBACK --
# not deleted, because this variant's rules have flipped seven times in
# about 72 hours and the fallback must stay correct with no code change if
# it flips back. These pin: (1) the prompt states solo as the lead/default
# BEFORE any duo-specific claim, (2) the duo doctrine carries an explicit
# FALLBACK label, (3) the stale unconditional duo-only phrasing this
# correction retired can never silently return, and (4) in CODE --
# policy.adjust_entries' new solo guard -- bodyguard/medic are mechanically
# dropped from the wanted ladder when there is no partner this match, while
# the fallback (a real duo_partner) still installs them exactly as before,
# so a future edit cannot silently delete either branch. ──────────────────
check("prompt: SOLO is stated as the observed default in the very first "
      "paragraph, not buried after the duo doctrine",
      "SOLO IS THE OBSERVED DEFAULT THIS ERA" in prompt,
      "solo-default lead sentence not found in prompt")
check("prompt: the era-check gate (solo-primary) precedes THE OBJECTIVE's "
      "duo-down/duo's-take scoring claims, so the hedge is read BEFORE any "
      "duo-specific mechanic, not after",
      "ERA CHECK BEFORE ANY OF THIS" in prompt and "THE OBJECTIVE" in prompt
      and prompt.index("ERA CHECK BEFORE ANY OF THIS") < prompt.index("THE OBJECTIVE"),
      "era-check gate does not precede THE OBJECTIVE")
check("prompt: the duo/partner/downed/revive doctrine carries an explicit "
      "FALLBACK -- DUO ERA label, not silent unlabeled prose",
      "FALLBACK -- DUO ERA" in prompt,
      "explicit duo-era fallback label not found")
check("prompt: the FALLBACK label sits AFTER the solo-default lead "
      "sentence -- solo is the branch the prompt leads with, duo is what "
      "follows it",
      prompt.index("SOLO IS THE OBSERVED DEFAULT THIS ERA")
      < prompt.index("FALLBACK -- DUO ERA"),
      "fallback label does not follow the solo-default lead")
check("prompt: NEGATIVE -- the old unconditional 'battle-royale match of "
      "duos' persona framing (stated as guaranteed fact, no era hedge) "
      "cannot silently return",
      "battle-royale match of duos." not in prompt,
      "stale unconditional duo-match framing found in prompt")
check("prompt: NEGATIVE -- the loot-at-spawn guarantee no longer implies "
      "exactly two beneficiaries ('for both of you'), which reads wrong "
      "under the solo default",
      "dropped near spawn for both of you" not in prompt,
      "stale duo-only loot-guarantee phrasing found in prompt")
check("prompt: NEGATIVE -- the endgame threshold is no longer phrased in "
      "duo-only units ('three duos or fewer'); 'teams' reads correctly "
      "under either era",
      "three duos or fewer" not in prompt,
      "stale duo-only endgame threshold phrasing found in prompt")

# ── code: adjust_entries' solo guard actually gates the ladder, not just
# the prompt's prose. A confirmed-solo context (duo_partner missing or
# equal to the seat's own number) must mechanically drop bodyguard and
# medic from the WANTED ladder on every canned turn that submits them --
# gate_open already refuses both when partner is None (see the "gate
# medic CLOSED: no partner" check above), so this closes the matching gap
# on the wanted-ladder side (fewer of wire.MAX_LADDER_ENTRIES' limited
# slots spent on a rung that can only ever sit gated shut). ───────────────
SOLO_CONTEXT = {"self": {"seat": 3, "duo_partner": None}}
SOLO_SELF_CONTEXT = {"self": {"seat": 3, "duo_partner": 3}}
for _label, _ctx in (("duo_partner missing", SOLO_CONTEXT),
                      ("duo_partner == own seat", SOLO_SELF_CONTEXT)):
    for _i, _turn in enumerate(PERSONA.canned_turns, start=1):
        _submitted = [e["play"] for e in _turn["call"]["entries"]]
        if not ({"bodyguard", "medic"} & set(_submitted)):
            continue
        _solo_seat = fake_seat(context=_ctx)
        starter_harness.repair_call(_turn, PERSONA, _solo_seat, AVAILABLE)
        _solo_wanted = [e["play"] for e in _solo_seat.wanted_entries]
        check(f"solo guard ({_label}), turn {_i}: bodyguard dropped from "
              "the wanted ladder (dead weight -- no partner to shield)",
              "bodyguard" not in _solo_wanted, str(_solo_wanted))
        check(f"solo guard ({_label}), turn {_i}: medic dropped from the "
              "wanted ladder (dead weight -- no partner to revive)",
              "medic" not in _solo_wanted, str(_solo_wanted))
        # "pact" is excluded here too: every canned turn submits it with
        # PACT_PLACEHOLDER partners, and under this SOLO context
        # _neighbor_duo has no duo to name and there is no genuine partner
        # to fall back on either -- adjust_entries drops that unaimable
        # pact outright (see the UNAIMABLE branch and its own pinned
        # checks below), a SEPARATE mechanism from the bodyguard/medic
        # solo guard asserted above.
        _other_submitted = [p for p in _submitted
                            if p not in ("bodyguard", "medic", "pact")]
        check(f"solo guard ({_label}), turn {_i}: every OTHER submitted "
              "rung still reaches the wanted ladder (the guard is scoped "
              "to bodyguard/medic/pact only, not a blanket strip)",
              all(p in _solo_wanted for p in _other_submitted),
              f"submitted {_other_submitted} wanted {_solo_wanted}")

# FALLBACK PIN: under a real duo_partner (the existing FAKE_CONTEXT, seat 3
# / partner 19), bodyguard and medic must still reach the wanted ladder
# exactly as before -- the solo guard's condition must stay scoped to the
# no-partner case, never widen to swallow the duo path it is explicitly
# forbidden from deleting.
for _i, _turn in enumerate(PERSONA.canned_turns, start=1):
    _submitted = [e["play"] for e in _turn["call"]["entries"]]
    if "medic" not in _submitted and "bodyguard" not in _submitted:
        continue
    _duo_seat = fake_seat()  # defaults to FAKE_CONTEXT: duo_partner 19
    starter_harness.repair_call(_turn, PERSONA, _duo_seat, AVAILABLE)
    _duo_wanted = [e["play"] for e in _duo_seat.wanted_entries]
    if "medic" in _submitted:
        check(f"fallback pin, turn {_i}: medic still reaches the wanted "
              "ladder under a real duo_partner (the fallback is retained, "
              "not deleted)",
              "medic" in _duo_wanted, str(_duo_wanted))
    if "bodyguard" in _submitted:
        check(f"fallback pin, turn {_i}: bodyguard still reaches the "
              "wanted ladder under a real duo_partner (the fallback is "
              "retained, not deleted)",
              "bodyguard" in _duo_wanted, str(_duo_wanted))

# ── module drop-set: an upload that never reaches module_ready must not ──
# poison the rest of the session (T17 fix). ``available`` is the SAME list
# ``build_call`` gates against (``if play not in available: continue``), so
# ``_drop_failed_module`` mutates it in place; these checks pin that a
# failed module disappears from later proposals, a succeeded module is
# untouched (negative control), and the drop can never empty the set into
# a no-op turn -- the amplifier was one dead play id voiding a WHOLE call
# (``call_rejected reason=playUnknown``), not just the one entry.
_drop_available = list(AVAILABLE)
starter_harness._drop_failed_module(_drop_available, "hold_vs_gun", PERSONA)
check("drop-set: a module whose upload failed leaves the proposable set",
      "hold_vs_gun" not in _drop_available, str(_drop_available))
check("drop-set: an untouched module stays in the proposable set "
      "(negative control)",
      "scatter" in _drop_available, str(_drop_available))

_drop_decision = {"call": {"entries": [
    {"play": "hold_vs_gun", "entry_id": "dead"},
    {"play": "scatter", "entry_id": "alive"},
]}}
_, _drop_entries = starter_harness.build_call(_drop_decision, _drop_available)
_drop_plays = [e["play"] for e in _drop_entries]
check("drop-set: build_call never proposes the play id an upload failure "
      "removed (the actual defect -- a dead id in a call reads back "
      "call_rejected reason=playUnknown and voids the WHOLE call)",
      "hold_vs_gun" not in _drop_plays, str(_drop_plays))
check("drop-set: build_call still proposes the surviving play (negative "
      "control -- the drop is scoped to the one failed module)",
      "scatter" in _drop_plays, str(_drop_plays))

# Degenerate case: the LAST play in the set must never be dropped -- an
# empty ``available`` would starve build_call's own fallback
# (``next(..., available[0])``), turning "one module failed" into
# "propose nothing", which is worse than today's behavior.
_last_one = ["scatter"]
starter_harness._drop_failed_module(_last_one, "scatter", PERSONA)
check("drop-set: the last remaining play is never dropped (would empty "
      "the proposable set into a no-op turn)",
      _last_one == ["scatter"], str(_last_one))
_, _last_entries = starter_harness.build_call(
    {"call": {"entries": [{"play": "scatter", "entry_id": "only"}]}},
    _last_one)
check("drop-set: the degenerate single-module set still yields a "
      "non-empty proposal",
      len(_last_entries) > 0, str(_last_entries))

# Fail-safe: if the drop-set mutation itself errors (e.g. a future caller
# passes something that isn't a plain list), the seat must degrade to
# today's behavior -- the module stays proposable -- not raise and not
# silently corrupt the set.
class _ExplodingList(list):
    def remove(self, item):
        raise RuntimeError("boom")

_exploding = _ExplodingList(["scatter", "hold_vs_gun"])
try:
    starter_harness._drop_failed_module(_exploding, "hold_vs_gun", PERSONA)
    _raised = False
except Exception:
    _raised = True
check("drop-set: an internal error in the drop logic never raises out of "
      "the upload loop (degrades to today's behavior instead)",
      not _raised)
check("drop-set: after a drop-logic error, the module is still in the set "
      "(explicit degrade-to-today's-behavior, not a half mutation)",
      "hold_vs_gun" in _exploding, str(list(_exploding)))

# ── prompt freshness after a drop (T19 fix) ───────────────────────────────
# T17 fixed the WIRE side: a dropped module can no longer be sent in a call.
# But `run()` built the model's system prompt ONCE, from `available` before
# the upload loop that can mutate it -- so the model kept being TOLD about,
# and kept proposing, a play the wire could no longer carry (live evidence:
# 32 affected seat-logs, 105 model calls after a drop, 52 (49.5%) still
# named the dropped play -- see the commit message). The fix: both model-call
# sites in `run()`/`_live_loop()` now call
# ``build_system_prompt(persona, available)`` fresh, at call time, instead
# of reusing a snapshot taken before any drop could happen.
#
# Group 1: build_system_prompt itself, given a post-drop `available`, must
# scrub the dropped play out of every CALLABLE-menu section (the numbered
# playbook list, the play count, format_rules' legal-name list, persona
# play_notes). Scoped to `plays.playbook_brief` / `plays.format_rules`
# rather than the whole assembled prompt: the persona's own doctrine prose
# (``prompt_intro``) legitimately names a play as a general concept
# ("when a live gun is near, hold_vs_gun is the stance") independent of
# whether THIS session can still call it -- only the menu sections are
# actually offering it.
_full_brief = plays.playbook_brief(list(AVAILABLE))
check("prompt freshness: the full-playbook menu names the play before "
      "any drop (positive control)",
      "hold_vs_gun" in _full_brief)

_dropped_available = list(AVAILABLE)
starter_harness._drop_failed_module(_dropped_available, "hold_vs_gun", PERSONA)
_post_drop_brief = plays.playbook_brief(_dropped_available)
_post_drop_rules = plays.format_rules(_dropped_available)
_post_drop_prompt = starter_harness.build_system_prompt(PERSONA, _dropped_available)
check("prompt freshness: rebuilding the numbered playbook menu from the "
      "post-drop `available` no longer names the dropped play",
      "hold_vs_gun" not in _post_drop_brief, _post_drop_brief[:300])
check("prompt freshness: rebuilding the legal-play-name list "
      "(format_rules) from the post-drop `available` no longer offers "
      "the dropped play as a callable option",
      '"hold_vs_gun"' not in _post_drop_rules, _post_drop_rules)
check("prompt freshness: the post-drop menu still names a surviving "
      "play (negative control -- not a blanket wipe)",
      "scatter" in _post_drop_brief and '"scatter"' in _post_drop_rules)
check("prompt freshness: the play count line drops by exactly one "
      f"after the drop ({len(AVAILABLE)} -> {len(AVAILABLE) - 1})",
      f"exactly {len(AVAILABLE) - 1} plays" in _post_drop_brief,
      _post_drop_brief.splitlines()[0] if _post_drop_brief else "")
_note_head = PERSONA.play_notes["hold_vs_gun"][:30]
check("prompt freshness: the dropped play's persona note disappears from "
      "the assembled prompt too (a note for an unbaked play was always "
      "dropped; this pins that post-drop counts the same way)",
      _note_head not in _post_drop_prompt, _note_head)

# Break-and-restore for Group 1: temporarily disable the actual removal in
# `_drop_failed_module` (the mutation these checks depend on) and confirm
# the drop-dependent checks above go red, then restore.
_real_drop_failed_module = starter_harness._drop_failed_module


def _inert_drop_failed_module(available, name, persona):
    return None  # the removal never happens -- simulates the pre-T17 bug


starter_harness._drop_failed_module = _inert_drop_failed_module
_broken_available = list(AVAILABLE)
starter_harness._drop_failed_module(_broken_available, "hold_vs_gun", PERSONA)
_broken_brief = plays.playbook_brief(_broken_available)
_broken_rules = plays.format_rules(_broken_available)
_broken_prompt = starter_harness.build_system_prompt(PERSONA, _broken_available)
_break_ok = (
    "hold_vs_gun" in _broken_brief          # would have PASSED as "not in" -> now fails
    and '"hold_vs_gun"' in _broken_rules    # ditto
    and f"exactly {len(AVAILABLE) - 1} plays" not in _broken_brief
    and _note_head in _broken_prompt
)
starter_harness._drop_failed_module = _real_drop_failed_module
check("prompt freshness self-test: breaking `_drop_failed_module` (no-op "
      "removal) flips the 4 drop-dependent checks above to FAIL, proving "
      "they discriminate rather than passing unconditionally",
      _break_ok, f"broken_brief names dropped play={'hold_vs_gun' in _broken_brief}")

# Group 2: the WIRING -- assert against the source, not the prose. `run()`
# and `_live_loop()` must call `build_system_prompt(persona, available)`
# fresh at the model-call site, never through a variable snapshotted
# earlier (the exact shape of the T19 bug: a `prompt` local computed once
# and threaded, unchanged, into every later call).
import inspect as _inspect

_run_src = _inspect.getsource(starter_harness.run)
_loop_src = _inspect.getsource(starter_harness._live_loop)
check("prompt wiring: run()'s opening-call site builds the prompt fresh "
      "from `available` (not a pre-drop snapshot)",
      "_persona_prompt(build_system_prompt(persona, available))" in _run_src,
      "call site not found in run()'s source")
check("prompt wiring: run() never threads a stale cached `prompt` variable "
      "into `_persona_prompt` (the T19 bug's exact shape)",
      "_persona_prompt(prompt)" not in _run_src, "stale pattern present")
check("prompt wiring: _live_loop()'s re-call site builds the prompt fresh "
      "from `available` on every re-call",
      "_persona_prompt(build_system_prompt(persona, available))" in _loop_src,
      "call site not found in _live_loop()'s source")
check("prompt wiring: _live_loop() never threads a stale cached `prompt` "
      "variable into `_persona_prompt` (the T19 bug's exact shape)",
      "_persona_prompt(prompt)" not in _loop_src, "stale pattern present")
check("prompt wiring: _live_loop()'s signature no longer accepts a "
      "`prompt` parameter at all (regression guard -- a reintroduced "
      "cached prompt would have to be threaded back in as a parameter)",
      "prompt" not in _inspect.signature(starter_harness._live_loop).parameters,
      str(list(_inspect.signature(starter_harness._live_loop).parameters)))

# Break-and-restore for Group 2: this is done OUT-OF-PROCESS against the
# real file (not simulated here) because the checks above assert against
# `inspect.getsource`, which reads the actual function bodies -- see the
# lane report for the sed-revert / rerun / restore transcript. Reverting
# `run()`'s and `_live_loop()`'s call sites to `with _persona_prompt(prompt):`
# (the pre-fix text) and rerunning this file flips all 4 wiring checks
# above to FAIL; restoring the fix flips them back to PASS.

# ── MONET_FORCE_UPLOAD_FAIL: the local-only fault-injection hook used to ──
# make the T17 drop-set fix EVALUABLE in smoke (the real engine-side
# manifestProbe rejection can't be induced from the client and only hits
# ~22% of modules on a live round). A test hook that can fire in
# production is a liability, so this pins it OFF unless explicitly armed,
# and scoped to exactly the module named when it is.
import os as _os
_saved_force_fail = _os.environ.pop("MONET_FORCE_UPLOAD_FAIL", None)
try:
    check("upload fault-injection hook is OFF by default (no env var set)",
          not starter_harness.poc_policy._forced_upload_failure(
              "hold_vs_gun"))
    check("upload fault-injection hook stays off for every real module "
          "when unset (not just the one probed above)",
          all(not starter_harness.poc_policy._forced_upload_failure(n)
              for n in AVAILABLE))
    _os.environ["MONET_FORCE_UPLOAD_FAIL"] = "hold_vs_gun"
    check("upload fault-injection hook fires for the exact named module "
          "when armed",
          starter_harness.poc_policy._forced_upload_failure("hold_vs_gun"))
    check("upload fault-injection hook is scoped to the named module only "
          "(arming one module does not blanket-fail the others)",
          not starter_harness.poc_policy._forced_upload_failure("scatter"))
finally:
    _os.environ.pop("MONET_FORCE_UPLOAD_FAIL", None)
    if _saved_force_fail is not None:
        _os.environ["MONET_FORCE_UPLOAD_FAIL"] = _saved_force_fail

# ── upload-burst order: restored controllers-first, alphabetical (T20) ───
# REVERTS cc07e054's value-ranked reorder, per that commit's own
# pre-registered revert clause. See _load_playbook's docstring for the full
# refutation writeup and era stamp (league_b8fa9b35, r4034-4043, n=33). These
# checks pin the ACTUAL resulting order -- a test that would still pass with
# the revert undone (e.g. only checking membership, not sequence) is
# worthless here, since the sequence IS the change.
import tempfile as _tempfile

with _tempfile.TemporaryDirectory() as _pb_dir:
    _pb_path = pathlib.Path(_pb_dir)
    for _name in AVAILABLE:
        (_pb_path / f"{_name}.wasm").write_bytes(b"x")
    _order_a = [n for n, _ in starter_harness._load_playbook(_pb_path, AVAILABLE)]
    _order_b = [n for n, _ in starter_harness._load_playbook(_pb_path,
                                                              list(reversed(AVAILABLE)))]

_RESTORED_UPLOAD_ORDER = [
    "bodyguard", "crossfire", "edge_ride", "fire_superiority", "hold_vs_gun",
    "jackal", "loot", "medic", "ring_walker", "scatter", "supply_run",
    "pact", "target_law",
]
check("playbook order: matches the restored controllers-first, "
      "alphabetical sequence exactly (upload_id 1..13) -- the pre-cc07e054 "
      "order",
      _order_a == _RESTORED_UPLOAD_ORDER, str(_order_a))
check("playbook order: all 11 controllers precede both overlays "
      "(the truncated-run ladder-driver invariant -- predates cc07e054, "
      "not part of what was reverted)",
      all(plays.PLAYS[n]["class"] == "controller" for n in _order_a[:11])
      and all(plays.PLAYS[n]["class"] != "controller" for n in _order_a[11:]),
      str(_order_a))
check("playbook order: each class block is independently alphabetical "
      "(the value-ranking apparatus is gone -- no head/tail edge "
      "protection, no controller/overlay value tables)",
      _order_a[:11] == sorted(_order_a[:11])
      and _order_a[11:] == sorted(_order_a[11:]),
      str(_order_a))
check("playbook order: deterministic -- independent of the incoming "
      "`available` list's order (reversed input gives the identical "
      "output sequence)",
      _order_a == _order_b, f"{_order_a} vs {_order_b}")
check("playbook order: total -- every one of the 13 baked plays appears "
      "exactly once (no ties resolved by dict/set iteration order)",
      sorted(_order_a) == sorted(AVAILABLE) and len(set(_order_a)) == 13,
      str(_order_a))

# ── positional-flake theory: TESTED AT POWER AND REFUTED (T20) ────────────
# cc07e054 pre-registered a revert clause: if manifestProbe failures turned
# out content-bound rather than positional, the value-ranked reorder above
# must come back out, at a threshold of ~28 failure events. At n=33 (era:
# league_b8fa9b35 Paintbot Season 2, rounds r4034-4043, build 0.7.334
# throughout, 120 seat-logs, read 2026-09-05T15:06-15:35Z) that clause
# fired. These checks pin the refutation itself so the positional theory,
# and its value-ranking apparatus, cannot be silently re-introduced without
# a new falsifier being written down first.
check("positional theory: the value-rank tables that backed the reverted "
      "reorder are gone from starter_harness, not just unused",
      not hasattr(starter_harness, "_CONTROLLER_VALUE_RANK")
      and not hasattr(starter_harness, "_OVERLAY_VALUE_RANK")
      and not hasattr(starter_harness, "_protect_edges"),
      "one or more value-ranking symbols still present on starter_harness")
_load_playbook_doc = starter_harness._load_playbook.__doc__ or ""
check("positional theory: _load_playbook's docstring records the "
      "refutation's era stamp (league_b8fa9b35, r4034-4043, n=33)",
      "r4034-4043" in _load_playbook_doc
      and "league_b8fa9b35" in _load_playbook_doc
      and "n=33" in _load_playbook_doc,
      _load_playbook_doc)
check("positional theory: _load_playbook's docstring records the "
      "deterministic out-of-band refutation (15/33 failures outside the "
      "old risky band) and the inner-quartet discriminator (p=5.1e-5)",
      "15/33" in _load_playbook_doc and "5.1e-5" in _load_playbook_doc,
      _load_playbook_doc)
check("positional theory: _load_playbook's docstring names ring_walker's "
      "36.4% concentration and states its mechanism is NOT known (an open "
      "lead, not a claim)",
      "36.4%" in _load_playbook_doc and "ring_walker" in _load_playbook_doc
      and "NOT known" in _load_playbook_doc,
      _load_playbook_doc)

# ── T21: PLAN_WASTE -- the real instrument v27's tautological metric left
# missing (see the module comment above PLAN_WASTE in starter_harness.py).
# `available` here simulates a live drop: hold_vs_gun is a real baked play
# _drop_failed_module would have removed; totally_bogus_play never existed
# in the manifest at all -- the two not-in-available sub-cases the audit
# needs told apart. One raw entry list is built to hit every existing
# strip/skip reason in build_call's repair loop exactly once (twice for
# ladder-cap, whose size is asserted below), in an order that does not let
# one bucket mask another (the overlay-cap check runs BEFORE the required-
# param check, so the missing-partners pact entry is placed before the
# overlay slots fill up, or it would count as overlay-cap instead).
_WASTE_AVAILABLE = [p for p in plays.PLAYS if p != "hold_vs_gun"]
_waste_raw_entries = [
    "not-a-dict",                                                  # malformed-entry
    {"play": "hold_vs_gun", "entry_id": "a"},                      # not-in-available (dropped)
    {"play": "totally_bogus_play", "entry_id": "b"},               # not-in-available (hallucinated)
    {"play": "pact", "entry_id": "z", "params": {}},               # missing-required-param
    {"play": "pact", "entry_id": "c",
     "params": {"partners": ["seat:19"]}},                         # overlay 1/2, valid
    {"play": "target_law", "entry_id": "d", "params": {}},         # overlay 2/2, valid
    {"play": "pact", "entry_id": "e",
     "params": {"partners": ["seat:19"]}},                         # overlay-cap
] + [{"play": "edge_ride", "entry_id": f"ride{i}"} for i in range(20)]
_waste_decision = {"call": {"entries": _waste_raw_entries}}

_pw_before = dict(starter_harness.PLAN_WASTE)
_waste_payload, _waste_entries = starter_harness.build_call(
    _waste_decision, _WASTE_AVAILABLE)
_pw_after = dict(starter_harness.PLAN_WASTE)
_pw_delta = {k: _pw_after.get(k, 0) - _pw_before.get(k, 0)
             for k in set(_pw_after) | set(_pw_before)}

check("PLAN_WASTE: a malformed (non-dict) raw entry is counted as "
      "malformed-entry",
      _pw_delta.get("malformed-entry", 0) == 1, str(_pw_delta))
check("PLAN_WASTE: a play the drop-set removed and a play name the model "
      "invented are BOTH counted under not-in-available, exactly once each",
      _pw_delta.get("not-in-available", 0) == 2, str(_pw_delta))
check("PLAN_WASTE: an overlay entry sent without its required param is "
      "counted as missing-required-param",
      _pw_delta.get("missing-required-param", 0) == 1, str(_pw_delta))
check("PLAN_WASTE: a THIRD overlay entry (MAX_ACTIVE_OVERLAYS=2) is "
      "counted as overlay-cap",
      _pw_delta.get("overlay-cap", 0) == 1, str(_pw_delta))
check("PLAN_WASTE: raw entries beyond MAX_LADDER_ENTRIES that the loop's "
      "break never even reaches are still counted, as ladder-cap",
      _pw_delta.get("ladder-cap", 0) == 6, str(_pw_delta))
check("PLAN_WASTE: the five reasons are never collapsed into one number "
      "(CLEAN_DROPS' original sin) -- exactly five distinct keys fired",
      len(_pw_delta) == 5, str(_pw_delta))

_waste_samples = starter_harness.WASTE_SAMPLES.get("not-in-available", [])
check("WASTE_SAMPLES: captures the DROPPED play's own name, tagged as a "
      "known play since dropped (not confused with a hallucinated name)",
      any("hold_vs_gun" in s and "known play, since dropped" in s
          for s in _waste_samples),
      str(_waste_samples))
check("WASTE_SAMPLES: captures a hallucinated play name, tagged as not a "
      "play name in this manifest (not confused with a real dropped play)",
      any("totally_bogus_play" in s
          and "not a play name in this manifest" in s
          for s in _waste_samples),
      str(_waste_samples))

# Surgical, not just membership: the counter firing must not be a
# substitute for the actual strip. Pin the EXACT surviving (play, entry_id)
# sequence, so a bug that counts "overlay-cap" or "missing-required-param"
# correctly while forgetting the `continue` that makes it real (the
# counter-without-the-strip failure mode this task's gate calls out) is
# caught here even though it would not move any PLAN_WASTE number.
_expected_waste_entries = (
    [("pact", "c"), ("target_law", "d")]
    + [("edge_ride", f"ride{i}") for i in range(14)])
check("PLAN_WASTE: the exact surviving entries match -- entry 'z' (missing "
      "partners) and 'e' (3rd overlay) are gone, 'a'/'b' (not-in-available) "
      "are gone, and the ladder cap holds at 16",
      [(e["play"], e["entry_id"]) for e in _waste_entries]
      == _expected_waste_entries,
      str([(e["play"], e["entry_id"]) for e in _waste_entries]))

# WASTE_SAMPLES cap: a model that spams distinct hallucinated names must not
# blow up the log (same guarantee REJECTED_SAMPLES gives above).
for _i in range(10):
    starter_harness.build_call(
        {"call": {"entries": [
            {"play": f"never-seen-{_i}", "entry_id": f"x{_i}"}]}},
        _WASTE_AVAILABLE)
_waste_samples_capped = starter_harness.WASTE_SAMPLES.get(
    "not-in-available", [])
check("WASTE_SAMPLES: capped at a small number of distinct samples even "
      "after many distinct not-in-available plays are proposed",
      len(_waste_samples_capped) <= starter_harness._WASTE_SAMPLE_COUNT_CAP,
      f"len={len(_waste_samples_capped)} "
      f"cap={starter_harness._WASTE_SAMPLE_COUNT_CAP}")

# ── PLAN_WASTE must be BEHAVIOUR-NEUTRAL on the play path (T21 gate): the
# counter increments only in branches that previously did nothing (a bare
# `continue`/`break`). Prove it directly rather than merely asserting it:
# silence _record_waste into a no-op and confirm the wire payload for the
# exact same input is byte-identical to the instrumented run above.
_real_record_waste = starter_harness._record_waste
starter_harness._record_waste = lambda *a, **k: None
try:
    _silent_payload, _silent_entries = starter_harness.build_call(
        _waste_decision, _WASTE_AVAILABLE)
finally:
    starter_harness._record_waste = _real_record_waste
check("PLAN_WASTE is behaviour-neutral: the wire payload is byte-identical "
      "whether or not the counter fires",
      _silent_payload == _waste_payload,
      f"instrumented={_waste_payload!r} silent={_silent_payload!r}")
check("PLAN_WASTE is behaviour-neutral: the returned entries list is "
      "identical too, not just the encoded bytes",
      _silent_entries == _waste_entries,
      str((_silent_entries, _waste_entries)))

print()
if failures:
    print(f"SELF-CHECK FAILED: {len(failures)} failing check(s)")
    sys.exit(1)
print("SELF-CHECK PASSED")
