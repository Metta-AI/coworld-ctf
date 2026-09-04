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
#                integer range; "max" may be absent for an unbounded arm
#                (jackal's exitAfter, target_law's holdTrigger)
#   enum_list -- an ORDERED list of enum tags, deduplicated, capped at
#                "max_items" (target_law's prefer)
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
    "scatter": {
        "class": "controller",
        "params": {
            "distance": {"kind": "int", "min": 60, "max": 1200,
                         "default": 320},
            "ticks": {"kind": "int", "min": 24, "max": 2400, "default": 300},
        },
        "brief": (
            '"scatter" (class: controller). Gets off the spawn cluster: for '
            "the opening ticks it walks away from the nearest tracked enemy "
            "(toward the zone centre when nobody is tracked), then yields. "
            "The harness makes it the base rung for the first seconds of "
            "every match. Params:\n"
            "     - distance: integer 60..1200, default 320. How far to walk "
            "per leg.\n"
            "     - ticks: integer 24..2400, default 300. How long after the "
            "drop to keep scattering (24 ticks = 1 s)."
        ),
    },
    "loot": {
        "class": "controller",
        "params": {
            "detourMax": {"kind": "int", "min": 0, "max": 4096,
                          "default": 400},
            "contested": {"kind": "enum", "of": ["avoid", "race"],
                          "default": "avoid"},
            "medkits": {"kind": "bool", "default": False},
        },
        "brief": (
            '"loot" (class: controller). Fetches the nearest reachable '
            "pickup of any kind -- grenade, shield, spray can, barrier, and "
            "(PERCEPTION glory-2 §17) the gun and hopper weapon crates now "
            "visible on the ground -- when it is safe to. Fetching is "
            "unconditional on kind (a crate is a crate); only medkits are "
            "special-cased below. The harness gates it so it only runs "
            "while no fresh enemy track is within 500 px and an item is "
            "within reach; otherwise your base play keeps driving. Params:\n"
            "     - detourMax: integer 0..4096, default 400. Maximum detour "
            "in px to reach an item.\n"
            '     - contested: one of "avoid" or "race", default "avoid". '
            "What to do when someone else is also heading for the item.\n"
            "     - medkits: boolean, default false. Also fetch medkits "
            "(normally supply_run's job)."
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
    # Wave C (landed 2026-09-01, main d682b6d2) -- the menu is complete.
    # Specs from the landed golden manifest; semantics from lane C's ledger:
    # prefer is LIVE (engine-side scoring through the combat-policy prefer
    # channel), and a released hold LATCHES -- state both truthfully.
    "target_law": {
        "class": "overlay",
        "params": {
            "never": {"kind": "seat_set", "min_items": 0, "max_items": 8},
            "prefer": {"kind": "enum_list", "max_items": 4,
                       "of": ["bounty", "isolated", "revenge", "weakened"]},
            "holdTrigger": {"kind": "union",
                            "arms": {"aliveTeams": {"min": 2, "max": 16},
                                     "zonePhase": {"min": 1, "max": 8},
                                     "tick": {"min": 0}}},
        },
        "brief": (
            '"target_law" (class: overlay). The standing targeting filter '
            "under every other play: who never to shoot, who to prefer, and "
            "when to hold first fire. Params:\n"
            '     - never: list of 0..8 seat references ("seat:<N>"), '
            "default []. Do-not-shoot list.\n"
            '     - prefer: ordered list of up to 4 of "weakened", '
            '"isolated", "revenge", "bounty", default []. LIVE target '
            "scoring bias, applied engine-side.\n"
            '     - holdTrigger: optional object with EXACTLY ONE of '
            '"aliveTeams" (integer 2..16), "zonePhase" (integer 1..8), or '
            '"tick" (integer >= 0). Hold ALL fire until the condition; '
            "omit it to fire at will. THE HOLD IS A COMMITMENT: once "
            "released it stays released for the rest of your life -- a "
            "later re-call can change never/prefer but can never re-arm a "
            "released hold."
        ),
    },
    # MONET custom play (2026-09-01, compiled from
    # policies/monet/plays/hold_vs_gun.nim by the monet Dockerfile). Spec
    # transcribed from the play's own wasm-carried manifest -- it validated
    # module_ready + call_accepted against the live shell on 2026-09-01
    # (sha256 cd92cffd...). Baking this wasm WITHOUT this row trips
    # scan_playbook's drift guard by design.
    "hold_vs_gun": {
        "class": "controller",
        "params": {
            "calmTicks": {"kind": "int", "min": 12, "max": 120, "default": 48},
            "coverMax": {"kind": "int", "min": 0, "max": 600, "default": 260},
            "engageDist": {"kind": "int", "min": 100, "max": 1200,
                           "default": 500},
        },
        "brief": (
            '"hold_vs_gun" (class: controller). Never turn your back on a '
            "live gun: while fire is incoming it stands its ground facing "
            "the threat (your body keeps aiming and returning fire) and "
            "moves only to nearby cover that still faces the gun -- never "
            "directly away from it. With an enemy merely in view it shadows "
            "them from cover without advancing across the open; on a calm "
            "field it holds in place. Meant for a GUARDED ladder rung "
            "(proximity guard) above your rotation, so it owns movement "
            "only under threat. Params:\n"
            "     - calmTicks: integer 12..120, default 48. How fresh "
            "incoming fire must be (in ticks) to count as a live threat.\n"
            "     - coverMax: integer 0..600, default 260. Maximum px to a "
            "cover point; 0 = never reposition, pure stand-ground.\n"
            "     - engageDist: integer 100..1200, default 500. Enemy-track "
            "distance that switches from calm to shadowing from cover."
        ),
    },
    # MONET custom play #2 (2026-09-01, compiled from
    # policies/monet/plays/fire_superiority.nim by the monet Dockerfile).
    # Picasso's SEAL lever #9, press-vs-break. Spec transcribed from the
    # play's own wasm-carried manifest.
    "fire_superiority": {
        "class": "controller",
        "params": {
            "breakDeficit": {"kind": "int", "min": 1, "max": 8, "default": 2},
            "coverMax": {"kind": "int", "min": 0, "max": 600, "default": 260},
            "engageDist": {"kind": "int", "min": 100, "max": 1200,
                           "default": 600},
            "finishRange": {"kind": "int", "min": 40, "max": 260,
                            "default": 140},
            "pressRange": {"kind": "int", "min": 60, "max": 500,
                           "default": 220},
            "woundedPct": {"kind": "int", "min": 0, "max": 100,
                           "default": 50},
        },
        "brief": (
            '"fire_superiority" (class: controller). Press-vs-break: it '
            "counts only guns it can SEE (fresh tracks within engageDist; "
            "an enemy whose hp it never read counts as HEALTHY). When your "
            "side outnumbers them -- or matches them with enough of them "
            "known-wounded -- it PRESSES: advances on the weakest visible "
            "enemy and holds a range band, never melting into point-blank "
            "against a target that can still fight back. EXCEPTION: a "
            "target already KNOWN wounded (hp at or under 2) is worth "
            "closing to finishRange for -- the accuracy inversion is a risk "
            "against a live gun, not a finishing tag on someone already this "
            "close to done. When outnumbered by breakDeficit or more it "
            "BREAKS to facing cover, never moving through the enemy "
            "bearing. Even or no contact: holds at cover. Call it on a "
            "guarded rung (enemy contact guard); a draw pays nobody, so "
            "finish winning fights. Params:\n"
            "     - breakDeficit: integer 1..8, default 2. Enemy-gun margin "
            "that forces the break.\n"
            "     - coverMax: integer 0..600, default 260. Maximum px to a "
            "cover point; 0 = never reposition.\n"
            "     - engageDist: integer 100..1200, default 600. Range within "
            "which a fresh enemy track counts as a live gun.\n"
            "     - finishRange: integer 40..260, default 140. The tighter "
            "band to close to ONLY against a target already known wounded "
            "-- keep this well under pressRange, never above it.\n"
            "     - pressRange: integer 60..500, default 220. The band in px "
            "to hold off a healthy or unknown-hp target while pressing.\n"
            "     - woundedPct: integer 0..100, default 50. Percent of "
            "counted enemies that must be known-wounded to press when "
            "numbers are merely even."
        ),
    },
    # MONET custom play #3 (2026-09-02, compiled from
    # policies/monet/plays/ring_walker.nim by the monet Dockerfile). The
    # anti-corner play from the owner field report: we died to the ring by
    # cornering ourselves in building pockets. Spec transcribed from the
    # play's own wasm-carried manifest.
    "ring_walker": {
        "class": "controller",
        "params": {
            "inset": {"kind": "int", "min": 16, "max": 256, "default": 64},
            "leadTicks": {"kind": "int", "min": 24, "max": 720,
                          "default": 240},
        },
        "brief": (
            '"ring_walker" (class: controller). The ring is a schedule, not '
            "a surprise: when you are outside the current safe zone, or "
            "outside the NEXT zone rect with the shrink closer than "
            "leadTicks, it walks you to a point inside the next rect "
            "(inset from the edge, biased toward the center) -- always via "
            "the engine's reachability query, so the target is in YOUR "
            "connected pocket of the map, never a beeline into a wall. "
            "Inside the schedule it holds and should be off the ladder. "
            "Params:\n"
            "     - inset: integer 16..256, default 64. How deep inside the "
            "rect edge to aim.\n"
            "     - leadTicks: integer 24..720, default 240. Start the walk "
            "when the shrink is this close and you are not yet inside the "
            "next rect."
        ),
    },
    # MONET custom play #4 (2026-09-02, compiled from
    # policies/monet/plays/medic.nim by the monet Dockerfile). Revive scout
    # verified: pure-proximity revive (DownedTagRange 40px, sim.nim
    # updateDowned), partner pos+downed on a never-fogged grant row. Spec
    # transcribed from the play's own wasm-carried manifest.
    "medic": {
        "class": "controller",
        "params": {
            "abortHpFloor": {"kind": "int", "min": 0, "max": 6, "default": 1},
            "zoneReach": {"kind": "int", "min": 0, "max": 600,
                          "default": 220},
        },
        "brief": (
            '"medic" (class: controller). Picks your downed partner back '
            "up: walks to their exact granted position (the duo partner is "
            "always visible to you, downed or not) and STANDS with them -- "
            "revive is pure proximity, about two seconds of adjacency, and "
            "your gun stays free the whole time. Two honest refusals: at "
            "or below abortHpFloor hp it will not walk into an enemy "
            "camped on the ghost, and it will not chase a ghost deeper "
            "than zoneReach px outside the safe zone. Params:\n"
            "     - abortHpFloor: integer 0..6, default 1. At or below "
            "this hp, refuse a camped revive.\n"
            "     - zoneReach: integer 0..600, default 220. Maximum px "
            "outside the safe zone worth walking for the pickup."
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
one entry. In "chat", address other players by the NAME the roster gives
them (they see yours); inside "call", a seat is always written seat:<N>.
"""
