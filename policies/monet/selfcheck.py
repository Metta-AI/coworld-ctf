#!/usr/bin/env python3
"""Offline self-check for the MONET persona: no server, no model.

Drives every canned turn through the harness's OWN repair path
(``repair_call`` = generic clean -> ``adjust_entries`` -> re-clean) against
the full seven-play manifest, and asserts the three structural clamps hold:
truce honor, fire discipline, conversion. Run from anywhere:

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
FAKE_SEAT = types.SimpleNamespace(
    context={"self": {"seat": 3, "duo_partner": 19}}, view={})
PARTNER_REF = "seat:19"
NEIGHBOR_REFS = {"seat:4", "seat:20"}

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
check("all 7 play notes reach the full-playbook prompt", not missing_notes,
      str(missing_notes))

# ── canned turns through the real repair path ─────────────────────────────
for i, turn in enumerate(PERSONA.canned_turns, start=1):
    label = f"turn {i}"
    chat = turn.get("chat", "")
    check(f"{label}: chat under the model cap", len(chat) < 200,
          f"{len(chat)} chars")

    submitted = [e["play"] for e in turn["call"]["entries"]]
    payload, entries = starter_harness.repair_call(
        turn, PERSONA, FAKE_SEAT, AVAILABLE)
    kept = [e["play"] for e in entries]

    check(f"{label}: no submitted entry dropped",
          all(p in kept for p in submitted),
          f"submitted {submitted} kept {kept}")
    check(f"{label}: conversion rung guaranteed", "supply_run" in kept, str(kept))
    check(f"{label}: payload under cap", len(payload) <= 4096,
          f"{len(payload)} bytes")

    pacts = [e for e in entries if e["play"] == "pact"]
    laws = [e for e in entries if e["play"] == "target_law"]
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

# turn count matches the model-turn budget (opening + recall_count re-calls)
check("canned turns cover every model turn",
      len(PERSONA.canned_turns) == 1 + PERSONA.recall_count,
      f"{len(PERSONA.canned_turns)} turns vs recall_count {PERSONA.recall_count}")

# ── extra chat ────────────────────────────────────────────────────────────
for t in (1, 2, 3, 4):
    line = PERSONA.extra_chat(FAKE_SEAT.context, t)
    check(f"extra_chat turn {t} exists and fits the lobby cap",
          isinstance(line, str) and len(line.encode()) < 512,
          repr(line))
line1 = PERSONA.extra_chat(FAKE_SEAT.context, 1)
check("turn-1 truce offer addresses the neighboring duo",
      "seats 4 and 20" in (line1 or ""), repr(line1))

# ── the team-0 edge: the placeholder IS our own duo and must be re-aimed ──
team0_seat = types.SimpleNamespace(
    context={"self": {"seat": 0, "duo_partner": 16}}, view={})
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
