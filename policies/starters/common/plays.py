"""The plays manifest: the single source of truth for every play a starter
policy can bake and speak about.

Three things derive from this table, so prompt and playbook cannot drift:

* the param specs the harness repairs model output against
  (``starter_harness.build_call`` reads :data:`PLAYS` directly),
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

# Param spec kinds the harness repair understands:
#   int, float, bool, enum, seat_set  -- the PoC's vocabulary
#   int_pair  -- [lo, hi] JSON integers, lo <= hi enforced (bodyguard leash)
#   seat_ref  -- one "seat:<N>" reference; "duo:<team>" is deliberately never
#                emitted (needs a server-configured duo; see PoC README #7,
#                and bodyguard rejects it outright)
#   union     -- an object with exactly ONE key from "arms", each arm an
#                integer range (jackal's exitAfter)
# "required": True marks a param whose absence drops the whole entry.
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
            "partners": {"kind": "seat_set", "min_items": 1, "max_items": 8,
                         "required": True},
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
    # Wave A (landed 2026-09-01). Specs transcribed from the landed manifests
    # (tests/fixtures/shell/manifest_supply_run.golden.json,
    # manifest_bodyguard.golden.json) and lane C's ledger notes -- NOT from
    # BR_PLAYS.md, which differs on whenHpBelow semantics and ward defaulting.
    "supply_run": {
        "class": "controller",
        "params": {
            "whenHpBelow": {"kind": "int", "min": 0, "max": 64, "default": 3},
            "detourMax": {"kind": "int", "min": 0, "max": 4096,
                          "default": 500},
            "contested": {"kind": "enum", "of": ["avoid", "race"],
                          "default": "avoid"},
        },
        "brief": (
            '"supply_run" (class: controller). Detours to reachable medkits '
            "when wounded; avoids or races contested pickups. It only knows "
            "items currently in view (no memory). Params:\n"
            "     - whenHpBelow: integer 0..64, default 3. ABSOLUTE hp units "
            "(hp values are small integers, NOT a percentage or fraction): "
            "run for a medkit when your hp drops below this.\n"
            "     - detourMax: integer 0..4096, default 500. Maximum detour "
            "in px to reach an item.\n"
            '     - contested: one of "avoid" or "race", default "avoid". '
            "What to do when someone else is also heading for the item."
        ),
    },
    "bodyguard": {
        "class": "controller",
        "params": {
            "ward": {"kind": "seat_ref"},
            "leash": {"kind": "int_pair", "min": 0, "max": 4096,
                      "default": [80, 220]},
            "interpose": {"kind": "bool", "default": True},
            "peelHp": {"kind": "int", "min": 0, "max": 64, "default": 2},
        },
        "brief": (
            '"bodyguard" (class: controller). Ward-relative movement: hold a '
            "leash to the ward, interpose between ward and nearest threat, "
            "peel attackers off a wounded ward. Ward knowledge comes from "
            "fog tracks; if the ward's track is stale it holds at the last "
            "known position. Params:\n"
            '     - ward: one seat reference of the exact form "seat:<N>". '
            "Optional -- when omitted it defaults to your duo partner. "
            'No "duo:<team>" form.\n'
            "     - leash: [min, max] integers 0..4096 px with min <= max, "
            "default [80, 220]. The distance band to hold around the ward.\n"
            "     - interpose: boolean, default true. Step between the ward "
            "and the nearest threat.\n"
            "     - peelHp: integer 0..64, default 2. ABSOLUTE hp units: "
            "when the ward's hp is below this, engage their attacker."
        ),
    },
    # Wave B (landed 2026-09-01, main 65d8f64b). Specs from the landed
    # manifests; degradations from lane C's ledger. Both plays are
    # fog-honest: the briefs must not promise information the play cannot
    # see, or the model will reason from omniscience it does not have.
    "crossfire": {
        "class": "controller",
        "params": {
            "spacing": {"kind": "int_pair", "min": 0, "max": 600,
                        "default": [120, 320]},
            "minAngle": {"kind": "int", "min": 0, "max": 128, "default": 32},
        },
        "brief": (
            '"crossfire" (class: controller). Keeps you and your duo partner '
            "inside a spacing band and off a shared firing axis, so both "
            "guns bear without friendly-fire geometry. It knows the partner "
            "only through YOUR OWN fog tracks (no live duo telemetry; a "
            "stale track means last-known position, never-seen means hold), "
            "and the shared target is the nearest enemy visible to YOU. "
            "Params:\n"
            "     - spacing: [min, max] integers 0..600 px, default "
            "[120, 320]. The distance band to hold around the partner.\n"
            "     - minAngle: integer 0..128 brads, default 32. Minimum "
            "angular separation of the two guns on the shared target."
        ),
    },
    "jackal": {
        "class": "controller",
        "params": {
            "earshot": {"kind": "int", "min": 100, "max": 1200,
                        "default": 500},
            "joinWhen": {"kind": "enum", "of": ["afterKill", "bothWeakened"],
                         "default": "afterKill"},
            "exitAfter": {"kind": "union",
                          "arms": {"kills": {"min": 1, "max": 4},
                                   "hpFloor": {"min": 0, "max": 3}},
                          "default": {"kills": 1}},
        },
        "brief": (
            '"jackal" (class: controller). Loiters at earshot of an active '
            "fight, joins only when it is cheap, and leaves with the "
            "profit. BE HONEST ABOUT WHAT IT SEES: the public kill feed "
            "only SIGNALS that a fight happened -- it carries no location, "
            "so the play navigates purely by your own fog tracks; "
            '"bothWeakened" fires only when 2+ enemies with known hp inside '
            "earshot are ALL weak; exit-kill counting uses your own team's "
            "kill-feed rows while engaged. Params:\n"
            "     - earshot: integer 100..1200 px, default 500. Loiter "
            "distance from the fight.\n"
            '     - joinWhen: "afterKill" or "bothWeakened", default '
            '"afterKill". When it is cheap enough to join.\n'
            '     - exitAfter: an object with EXACTLY ONE of "kills" '
            '(integer 1..4) or "hpFloor" (integer 0..3 absolute hp units), '
            'default {"kills": 1}. When to leave with the profit.'
        ),
    },
}

LADDER_RULES = """\
A ladder is an ordered list of entries; the first non-overlay entry is the
controller that drives the seat, and overlays modify it. At most 2 overlays.
"""


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
