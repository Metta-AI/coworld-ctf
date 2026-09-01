"""The plays manifest: the single source of truth for every play a starter
policy can bake and speak about.

Three things derive from this table, so prompt and playbook cannot drift:

* the validator specs the harness repairs model output against
  (:func:`validator_specs`, fed to ``poc_policy.build_call``),
* the playbook brief inside the system prompt (:func:`playbook_brief`),
  generated ONLY for plays actually present in the baked playbook,
* the startup check (:func:`scan_playbook`) that refuses to run if a baked
  ``.wasm`` has no manifest entry here -- a rebuilt playbook with a new play
  fails loudly until this table describes it, instead of shipping a prompt
  that does not know the play exists.

Entries are transcribed from the reference manifests
(``tests/fixtures/shell/manifest_edge_ride.golden.json``,
``manifest_pact.golden.json``) and the play descriptions in
``docs/designs/BR_PLAYS.md``. When lane C lands more reference plays
(target_law, bodyguard, jackal, supply_run, crossfire), add a row here and
rebuild the playbook; nothing else has to change.
"""

from __future__ import annotations

import pathlib

PLAYS = {
    "edge_ride": {
        "class": "controller",
        "params": {
            "margin": {"kind": "int", "min": 40, "max": 600, "default": 220},
            "enterLead": {"kind": "int", "min": 0, "max": 600, "default": 120},
            "coverBias": {"kind": "float", "min": 0.0, "max": 1.0,
                          "default": 0.8},
        },
        "brief": (
            '"edge_ride" (class: controller). Rides the inside margin of the '
            "safe zone, biased through cover; enters the next ring as late as "
            "safety allows. Params:\n"
            "     - margin: integer 40..600, default 220. Distance inside the "
            "zone edge to sit at. Smaller = tighter, more exposed edge play.\n"
            "     - enterLead: integer 0..600, default 120. How early to start "
            "rotating before the zone shrinks. Larger = earlier, safer "
            "rotations.\n"
            "     - coverBias: number 0.0..1.0, default 0.8. Higher = detour "
            "further to stay in cover."
        ),
    },
    "pact": {
        "class": "overlay",
        "params": {
            "partners": {"kind": "seat_set", "min_items": 1, "max_items": 8},
            "protect": {"kind": "bool", "default": False},
            "onBetrayal": {"kind": "enum", "of": ["disengage", "returnFire"],
                           "default": "returnFire"},
        },
        "brief": (
            '"pact" (class: overlay). A negotiated alliance: never target the '
            "partners, dissolve at the endgame. Params:\n"
            '     - partners: REQUIRED list of 1..8 seat references, each of '
            'the exact form "seat:<N>" with N from 0 to 31. No other form is '
            "legal.\n"
            "     - protect: boolean, default false. Also body-block and peel "
            "for partners.\n"
            '     - onBetrayal: one of "returnFire" or "disengage", default '
            '"returnFire". What to do if a partner shoots us first.'
        ),
    },
}

LADDER_RULES = """\
A ladder is an ordered list of entries; the first non-overlay entry is the
controller that drives the seat, and overlays modify it. At most 2 overlays.
"""


def validator_specs() -> dict:
    """The manifest reduced to the shape ``poc_policy.build_call`` repairs
    against: class plus the kind/range fields, briefs and defaults stripped."""
    specs = {}
    for name, play in PLAYS.items():
        params = {}
        for key, spec in play["params"].items():
            params[key] = {k: v for k, v in spec.items() if k != "default"}
        specs[name] = {"class": play["class"], "params": params}
    return specs


def scan_playbook(directory: pathlib.Path) -> list[str]:
    """Return the manifest-known play names baked in `directory`.

    Refuses to run when a baked module has no manifest entry: the prompt would
    not know the play exists, which is exactly the drift this file prevents.
    """
    if not directory.is_dir():
        raise SystemExit(f"playbook directory not found: {directory}")
    baked = sorted(path.stem for path in directory.glob("*.wasm"))
    if not baked:
        raise SystemExit(f"no .wasm modules in {directory}")
    unknown = [name for name in baked if name not in PLAYS]
    if unknown:
        raise SystemExit(
            f"baked plays with no entry in plays.py: {', '.join(unknown)} -- "
            "add manifest rows (specs + brief) before shipping a prompt that "
            "does not know them")
    return baked


def playbook_brief(available: list[str]) -> str:
    """The prompt section describing exactly the plays in the baked playbook."""
    count = {1: "one play", 2: "exactly two plays"}.get(
        len(available), f"exactly {len(available)} plays")
    lines = [f"Your playbook has {count}, already uploaded to the server.", ""]
    for index, name in enumerate(available, start=1):
        lines.append(f"{index}. {PLAYS[name]['brief']}")
        lines.append("")
    lines.append(LADDER_RULES)
    return "\n".join(lines)


def format_rules(available: list[str]) -> str:
    """The reply-format contract, with the legal play names inlined."""
    names = " or ".join(f'"{name}"' for name in available)
    controller = next(
        (name for name in available if PLAYS[name]["class"] == "controller"),
        available[0])
    return f"""\
Reply with a single JSON object and nothing else:

{{
  "chat": "one short line of lobby chat, under 200 characters",
  "call": {{
    "entries": [
      {{"play": "{controller}", "entry_id": "ride", "params": {{"margin": 240}}}}
    ]
  }}
}}

Rules: every "play" must be {names}. Every "entry_id" must be
unique within the call and made of letters, digits, underscores or hyphens.
Only use parameters named above, within their stated ranges. Include at least
one entry.
"""
