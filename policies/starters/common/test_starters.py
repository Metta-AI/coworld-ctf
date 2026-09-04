"""Smoke tests for the SDK-27c4a368 perception adaptation: crate perception
(gun/hopper ground items) and partner held-state (has_gun/has_hopper) flow
through the common harness into every starter's playbook brief, live-state
summary, and gated ladder -- with NO new kind-specific conditioning added.
Crate routing stays FREE behavior: `loot`'s wasm-side `itemUsable` is
`case kind ... else: true` (play_sdk/reference/loot.nim) and the harness's
`gate_open("loot", ...)` filters only `medkit`, so a gun/hopper crate rides
the same path as a grenade or shield by construction.

Run:
    python3 policies/starters/common/test_starters.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types

_COMMON = pathlib.Path(__file__).resolve().parent
_STARTERS = _COMMON.parent
for entry in (str(_COMMON), str(_STARTERS.parent / "poc_llm_policy")):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import plays              # noqa: E402  (starters/common)
import starter_harness    # noqa: E402  (starters/common)


def _load_persona(name: str):
    """Import one starter's policy.py in isolation (all three are literally
    named policy.py, so a plain `import policy` would collide)."""
    spec = importlib.util.spec_from_file_location(
        f"_test_{name}_policy", _STARTERS / name / "policy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.PERSONA


def _fake_seat(persona, *, partner_has_gun=False, partner_has_hopper=False):
    """A seat mid-match (well past every persona's spawn phase), no enemy
    tracked, a duo partner, and a gun crate plus a hopper crate in view."""
    my_seat, partner_seat, my_team = 1, 9, "blue"
    view = {
        "tick": 5000,
        "self": {"pos": [1000, 1000], "hp": 8, "hp_frac": 1.0, "alive": True},
        "world": {"alive_teams": 5, "zone": {
            "phase": 2, "current": [0, 0, 2000, 2000],
            "next": [200, 200, 1600, 1600],
            "ticks_to_shrink": 100, "dps": 2}},
        "tracks": [{
            "seat": partner_seat, "team": my_team, "pos": [1010, 1000],
            "fresh_tick": 5000, "hp": 6,
            **({"has_gun": True} if partner_has_gun else {}),
            **({"has_hopper": True} if partner_has_hopper else {}),
        }],
        "items": [
            {"kind": "gun", "pos": [1050, 1000], "fresh_tick": 5000,
             "present": True},
            {"kind": "hopper", "pos": [960, 1000], "fresh_tick": 5000,
             "present": True},
        ],
        "aggressors": [], "hazards": {}, "kill_feed": [],
    }
    context = {
        "self": {"seat": my_seat, "team": my_team,
                 "duo_partner": partner_seat},
        # Deliberately UNRELATED names: a duo partner is not a same-entrant
        # clone, and ally_clones's name matching should leave it alone.
        "roster": [
            {"seat": my_seat, "team": my_team, "name": "solo-x"},
            {"seat": partner_seat, "team": my_team, "name": "buddy-y"},
            {"seat": 12, "team": "black", "name": "rival"},
        ],
    }
    return types.SimpleNamespace(
        slot=0, last_view_tick=5000, chat=[], view=view, context=context,
        kill_feed=[], wanted_entries=[], base_play=persona.base_play,
        spawn_phase_ticks=persona.spawn_phase_ticks, first_view_tick=0,
    )


def main() -> None:
    # 1. The manifest brief no longer undersells `loot`: it names the new
    #    crate kinds, so the generated playbook section does too.
    assert "gun" in plays.PLAYS["loot"]["brief"]
    assert "hopper" in plays.PLAYS["loot"]["brief"]

    available = list(plays.PLAYS.keys())
    for name in ("aggressive", "cautious", "collaborative"):
        persona = _load_persona(name)

        # 2. The persona's own system prompt mentions the new crates -- the
        #    model is told loot fetches them, in this persona's own voice.
        prompt = starter_harness.build_system_prompt(persona, available)
        assert "gun" in prompt.lower() and "hopper" in prompt.lower(), \
            f"{name}: playbook brief silent on gun/hopper crates"

        # 3. Crate-routing smoke: the opening canned call, once repaired and
        #    gated against a view with no tracked enemy and a visible gun
        #    crate, still carries `loot` -- FREE routing, no kind filter
        #    added anywhere in this change.
        seat = _fake_seat(persona)
        decision = persona.canned_turns[0]
        _, entries = starter_harness.repair_call(
            decision, persona, seat, available)
        assert any(e.get("play") == "loot" for e in entries), \
            f"{name}: loot did not survive gating with a visible crate: {entries}"

        # 4. The live-state block names the crates generically -- items are
        #    listed by kind as-is, no special-casing needed.
        summary = starter_harness.summarize(
            seat, starter_harness.match_phase(seat), persona)
        assert "gun" in summary and "hopper" in summary, \
            f"{name}: crates missing from the live-state summary"

        print(f"{name}: playbook brief + crate-routing smoke: OK "
              f"({len(entries)} ladder entries, loot included)")

    # 5. Partner held-state: a partner carrying a gun (not a hopper) shows in
    #    the summary; a partner with neither flag set stays silent (the wire
    #    only emits has_gun/has_hopper when true, so false and "flag is
    #    dark" are indistinguishable -- honest silence, not a claimed
    #    "unarmed").
    collab = _load_persona("collaborative")
    armed_seat = _fake_seat(collab, partner_has_gun=True)
    armed_summary = starter_harness.summarize(
        armed_seat, starter_harness.match_phase(armed_seat), collab)
    assert "carrying gun" in armed_summary, armed_summary
    assert "carrying gun+hopper" not in armed_summary, armed_summary

    dark_seat = _fake_seat(collab)  # neither has_gun nor has_hopper
    dark_summary = starter_harness.summarize(
        dark_seat, starter_harness.match_phase(dark_seat), collab)
    assert "carrying" not in dark_summary, dark_summary
    print("partner held-state: armed shows, dark stays silent: OK")


if __name__ == "__main__":
    main()
