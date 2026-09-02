"""The shared starter-policy harness: the PoC's proven machinery plus a
persona seam.

This module does not re-implement the protocol layer. It imports the PoC's
``wire`` (packet codec + canonical JSON), ``brain`` (model backends: hosted
sidecar, OpenRouter, canned) and ``poc_policy`` (the ``PlaySeat`` protocol
bookkeeping and the scalar/seat-set param cleaners) directly from
``policies/poc_llm_policy/`` and adds only what makes three starter policies
behave differently:

* a :class:`Persona` -- the prompt, the canned decisions, the re-call
  schedule, and two hooks (``adjust_entries``, ``extra_chat``) that are each
  policy's "harness delta",
* a system prompt GENERATED from the plays manifest (``plays.py``) filtered
  to the plays actually baked in the playbook, so the model is never told
  about a play it cannot call,
* persona-aware match summaries (kill feed for the hunter, partner state
  first for the duo player),
* a live loop that keeps the seat connected for the WHOLE match and re-calls
  the model when the game changes (zone phase, own hp, partner lost, being
  shot at, a periodic fallback) under a per-match call budget -- instead of
  the PoC's fixed re-call schedule that left the seat ~30 s into a ~3 min
  match, riding its last ladder with nobody home,
* a common game-state block in every summary (position, hp, zone geometry,
  visible enemies and items, aggressors) so the model decides on facts the
  live view already carries rather than on the map name and the tick,
* harness-side ladder gating and maintenance: the rungs whose play holds
  when idle (supply_run, loot, bodyguard, jackal, crossfire) are put on the
  ladder only while their condition holds in the live view, the persona's
  ``base_play`` is the always-on rung, and the gated ladder is re-sent
  without a model call whenever that changes (see ``layer_ladder``).

The layout contract: this file lives at ``policies/starters/common/`` and the
PoC at ``policies/poc_llm_policy/``, both locally and inside the images.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import pathlib
import sys
import time
from dataclasses import dataclass, field
from typing import Callable

_COMMON = pathlib.Path(__file__).resolve().parent
_POC_DIR = _COMMON.parents[1] / "poc_llm_policy"
for entry in (str(_COMMON), str(_POC_DIR)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

from websockets.sync.client import connect          # noqa: E402
from websockets.exceptions import (ConnectionClosed,   # noqa: E402
                                   WebSocketException)

import brain        # noqa: E402  (poc_llm_policy)
import plays        # noqa: E402  (starters/common)
import poc_policy   # noqa: E402  (poc_llm_policy)
import wire         # noqa: E402  (poc_llm_policy)


# ── The persona seam ──────────────────────────────────────────────────────


@dataclass
class Persona:
    """Everything that makes one starter policy behave unlike the others."""

    name: str
    prompt_intro: str
    #: persona-flavored guidance per play NAME; only the notes whose play is
    #: actually baked in the playbook reach the prompt (drift guard).
    play_notes: dict = field(default_factory=dict)
    #: fixed decisions for offline/CI runs, one per model turn (last repeats).
    #: Each policy's canned turns exercise ITS persona, so the three policies
    #: demonstrably differ even with no model anywhere.
    canned_turns: list = field(default_factory=list)
    #: Live-loop schedule. ``recall_seconds`` is the MINIMUM spacing between
    #: model calls; a re-call fires when a trigger (zone phase, hp drop,
    #: partner lost, aggressor, kill) lands past that spacing, or
    #: unconditionally after ``periodic_seconds`` (None = 3x recall_seconds).
    #: ``max_calls`` caps model calls per match, opening call included --
    #: the seat stays connected and pumping after the budget is spent.
    #: ``recall_count`` is retained for the offline/CI runner (--canned
    #: turns) and as the cap on how many canned turns a persona scripts.
    recall_count: int = 1
    recall_seconds: float = 6.0
    periodic_seconds: float | None = None
    max_calls: int = 6
    #: The always-on base controller appended when the gated ladder has no
    #: unguarded rung. "edge_ride" (default) rides the zone margin; None
    #: leaves the base empty so the ENGINE default (rotate toward the next
    #: zone in 192 px steps, plus the zone-escape reflex) drives instead --
    #: an experiment knob, because locally the engine default out-survived
    #: an actively riding edge_ride against the continuous S2 shrink.
    base_play: str | None = "edge_ride"
    include_kill_feed: bool = False
    partner_focus: bool = False
    #: (entries, context, view) -> entries. Runs after the generic repair and
    #: is itself re-repaired, so a hook can only ever narrow, never break.
    adjust_entries: Callable | None = None
    #: (context, turn) -> str | None. An additional deliberate chat line per
    #: turn (the collaborative policy's coordination channel).
    extra_chat: Callable | None = None


class PersonaCannedBrain:
    """Per-persona fixed responses; the offline proof that the three starter
    policies do different things. Turns past the scripted list repeat the
    last one."""

    def __init__(self, persona: Persona) -> None:
        self.persona = persona
        self.name = f"canned-{persona.name}"
        self.turn = 0
        self.calls = 0

    def decide(self, summary: str) -> dict:
        turns = self.persona.canned_turns
        if not turns:
            raise brain.BrainError(f"persona {self.persona.name} has no "
                                   "canned turns")
        decision = turns[min(self.turn, len(turns) - 1)]
        self.turn += 1
        return json.loads(json.dumps(decision))  # never hand out the original


def build_system_prompt(persona: Persona, available: list[str]) -> str:
    """Persona intro + manifest-generated playbook brief + reply contract.

    ``available`` is what :func:`plays.scan_playbook` found baked; a persona
    note for an unbaked play is silently dropped, so the prompt can never
    promise a play the seat cannot call.
    """
    parts = [persona.prompt_intro.strip(), "",
             plays.playbook_brief(available)]
    notes = [note for name, note in persona.play_notes.items()
             if name in available]
    if notes:
        parts.append("How YOU use this playbook:")
        parts.extend(f"- {note}" for note in notes)
        parts.append("")
    parts.append(plays.format_rules(available))
    return "\n".join(parts)


@contextlib.contextmanager
def _persona_prompt(prompt: str):
    """Swap the PoC brain module's system prompt for one model call.

    ``brain.OpenAiChatBrain`` / ``BedrockInvokeBrain`` read the module-level
    ``SYSTEM_PROMPT``; scoping the swap here keeps the PoC file untouched
    (the PM owns it tonight) while every backend -- sidecar, OpenRouter,
    Bedrock fallback -- gets the persona prompt.
    """
    original = brain.SYSTEM_PROMPT
    brain.SYSTEM_PROMPT = prompt
    try:
        yield
    finally:
        brain.SYSTEM_PROMPT = original


# ── Seat: the PoC's protocol bookkeeping plus the view worth reasoning over ─


class StarterSeat(poc_policy.PlaySeat):
    """The PoC seat, additionally retaining the latest 0xB1 view payload and
    an accumulated kill feed (the PoC parses only the control half)."""

    def __init__(self, connection, slot: int) -> None:
        super().__init__(connection, slot)
        self.view: dict = {}
        self.kill_feed: list[dict] = []
        self._kills_seen: set = set()
        #: the model's full ladder before gating (see layer_ladder)
        self.wanted_entries: list = []

    def _file(self, packet: dict) -> None:
        super()._file(packet)
        if packet["kind"] != "play_view":
            return
        try:
            view = json.loads(packet["view"])
        except (json.JSONDecodeError, KeyError):
            return
        if not isinstance(view, dict):
            return
        self.view = view
        for kill in view.get("kill_feed", []):
            if not isinstance(kill, dict):
                continue
            key = (kill.get("tick"), kill.get("victim_seat"))
            if key not in self._kills_seen:
                self._kills_seen.add(key)
                self.kill_feed.append(kill)


# ── Persona-aware summaries ───────────────────────────────────────────────


def _partner_lines(seat: StarterSeat, partner: int) -> list[str]:
    label = poc_policy.seat_label(seat.context, partner)
    lines = [f"PARTNER STATUS FIRST -- your duo partner is {label}."]
    if any(kill.get("victim_seat") == partner for kill in seat.kill_feed):
        lines.append(f"Your partner {label} has been ELIMINATED. "
                     "You are alone now.")
        return lines
    track = next((t for t in seat.view.get("tracks", [])
                  if t.get("seat") == partner), None)
    if track is None:
        lines.append(f"No fresh track on {label} -- close the distance "
                     "until you can see each other.")
    else:
        lines.append(f"{label} last seen at {track.get('pos')} "
                     f"(tick {track.get('fresh_tick')}"
                     + (f", hp {track['hp']}" if "hp" in track else "")
                     + ").")
    return lines


def _vital_lines(seat: StarterSeat) -> list[str]:
    lines = []
    self_row = seat.view.get("self") or {}
    if self_row:
        hp_frac = self_row.get("hp_frac")
        if isinstance(hp_frac, (int, float)):
            lines.append(f"Your health: {round(hp_frac * 100)}% "
                         f"({'alive' if self_row.get('alive', True) else 'DOWN'}).")
    world = seat.view.get("world") or {}
    zone = world.get("zone") or {}
    if zone:
        lines.append(f"Zone phase {zone.get('phase', '?')}, "
                     f"dps {zone.get('dps', '?')}, "
                     f"{zone.get('ticks_to_shrink', '?')} ticks to shrink.")
    alive_teams = world.get("alive_teams")
    if alive_teams is not None:
        lines.append(f"Teams still alive: {alive_teams}.")
    return lines


def _kill_feed_lines(seat: StarterSeat, limit: int = 5) -> list[str]:
    if not seat.kill_feed:
        return ["Kill feed: quiet so far. Nobody has died. Find them."]
    lines = ["Kill feed (most recent last):"]
    for kill in seat.kill_feed[-limit:]:
        victim = poc_policy.seat_label(seat.context, kill.get("victim_seat"))
        lines.append(f"  tick {kill.get('tick', '?')}: {victim} eliminated "
                     f"by team {kill.get('killer_team', '?')}.")
    return lines


def _dist(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _bearing(src, dst) -> str:
    """Compass word from src to dst in map pixels (y grows DOWN the map, so
    +dy is south)."""
    dx, dy = dst[0] - src[0], dst[1] - src[1]
    if abs(dx) < 1 and abs(dy) < 1:
        return "here"
    ns = "S" if dy > 0 else "N"
    ew = "E" if dx > 0 else "W"
    if abs(dy) > 2 * abs(dx):
        return ns
    if abs(dx) > 2 * abs(dy):
        return ew
    return ns + ew


def _rect_center(rect):
    return (rect[0] + rect[2] / 2.0, rect[1] + rect[3] / 2.0)


def _inside(pos, rect) -> bool:
    return (rect[0] <= pos[0] <= rect[0] + rect[2]
            and rect[1] <= pos[1] <= rect[1] + rect[3])


def _is_pos(value) -> bool:
    return (isinstance(value, (list, tuple)) and len(value) == 2
            and all(isinstance(v, (int, float)) for v in value))


def _state_lines(seat: StarterSeat) -> list[str]:
    """The live facts every persona reasons over: where you are relative to
    the zone, who and what you can see, who is shooting at you. Everything
    here is read straight off the latest 0xB1 view; nothing is inferred.
    Empty before the first view (the lobby turn)."""
    view = seat.view or {}
    if not view:
        return []
    context = seat.context or {}
    my_seat = context.get("self", {}).get("seat", seat.slot)
    my_team = context.get("self", {}).get("team")
    partner = context.get("self", {}).get("duo_partner")
    me = view.get("self") or {}
    pos = me.get("pos") if _is_pos(me.get("pos")) else None
    tick = view.get("tick", seat.last_view_tick)
    lines = ["Live state (tick %s):" % tick]
    if pos is not None:
        lines.append(f"  You are at ({int(pos[0])}, {int(pos[1])}), "
                     f"hp {me.get('hp', '?')}"
                     + (f" ({round(me['hp_frac'] * 100)}%)"
                        if isinstance(me.get("hp_frac"), (int, float))
                        else "") + ".")
    world = view.get("world") or {}
    zone = world.get("zone") or {}
    cur, nxt = zone.get("current"), zone.get("next")
    if isinstance(cur, list) and len(cur) == 4 and pos is not None:
        where = "INSIDE" if _inside(pos, cur) else "OUTSIDE (taking zone damage)"
        lines.append(f"  Zone phase {zone.get('phase', '?')}: current safe "
                     f"rect x{cur[0]}..{cur[0] + cur[2]} y{cur[1]}..{cur[1] + cur[3]}; "
                     f"you are {where}.")
        if isinstance(nxt, list) and len(nxt) == 4:
            c = _rect_center(nxt)
            lines.append(f"  Next zone rect x{nxt[0]}..{nxt[0] + nxt[2]} "
                         f"y{nxt[1]}..{nxt[1] + nxt[3]}, center "
                         f"{int(_dist(pos, c))} px to the {_bearing(pos, c)}; "
                         f"you are {'already inside' if _inside(pos, nxt) else 'NOT yet inside'} it; "
                         f"shrink in {zone.get('ticks_to_shrink', '?')} ticks "
                         f"(24 ticks = 1 s), zone dps {zone.get('dps', '?')}.")
    alive_teams = world.get("alive_teams")
    if alive_teams is not None:
        lines.append(f"  Teams still alive: {alive_teams}.")

    enemies, partner_track = [], None
    for track in view.get("tracks", []):
        if not isinstance(track, dict) or not _is_pos(track.get("pos")):
            continue
        if track.get("seat") == partner:
            partner_track = track
            continue
        if track.get("seat") == my_seat or (my_team and track.get("team") == my_team):
            continue
        enemies.append(track)
    if pos is not None:
        enemies.sort(key=lambda t: _dist(pos, t["pos"]))
    if enemies:
        lines.append(f"  Enemies tracked: {len(enemies)} (nearest first):")
        for track in enemies[:4]:
            age = (tick - track["fresh_tick"]) if isinstance(track.get("fresh_tick"), int) else "?"
            seen = f"{int(_dist(pos, track['pos']))} px {_bearing(pos, track['pos'])}" if pos else str(track["pos"])
            lines.append(f"    {poc_policy.seat_label(context, track.get('seat'))} "
                         f"team {track.get('team', '?')}, {seen}, hp {track.get('hp', '?')}, "
                         f"seen {age} ticks ago"
                         + (", BOUNTY" if track.get("bounty") else "") + ".")
    else:
        lines.append("  Enemies tracked: none in view.")
    if partner is not None:
        if partner_track is not None and pos is not None:
            lines.append(f"  Partner {poc_policy.seat_label(context, partner)}: "
                         f"{int(_dist(pos, partner_track['pos']))} px "
                         f"{_bearing(pos, partner_track['pos'])}, hp {partner_track.get('hp', '?')}.")
    items = [i for i in view.get("items", [])
             if isinstance(i, dict) and i.get("present", True) and _is_pos(i.get("pos"))]
    if pos is not None:
        items.sort(key=lambda i: _dist(pos, i["pos"]))
    if items:
        lines.append("  Items in view: " + ", ".join(
            f"{i.get('kind', '?')} {int(_dist(pos, i['pos']))} px {_bearing(pos, i['pos'])}"
            if pos else str(i.get("kind")) for i in items[:5]) + ".")
    recent = [a for a in view.get("aggressors", [])
              if isinstance(a, dict) and isinstance(a.get("tick"), int)
              and tick - a["tick"] <= 240]
    if recent:
        who = ", ".join(poc_policy.seat_label(context, a.get("seat"))
                        if a.get("seat") is not None else "an unseen shooter"
                        for a in recent[-3:])
        lines.append(f"  You were SHOT AT in the last 10 s by: {who}.")
    hazards = view.get("hazards") or {}
    grenades = hazards.get("grenades") if isinstance(hazards, dict) else None
    if grenades:
        lines.append(f"  Live grenades near you: {len(grenades)}.")
    return lines


def match_phase(seat: StarterSeat) -> str:
    """A phase label derived from the view (the PoC hardcoded its two)."""
    view = seat.view or {}
    if not view:
        return "lobby, before the drop"
    world = view.get("world") or {}
    zone = world.get("zone") or {}
    teams = world.get("alive_teams")
    phase = zone.get("phase")
    if isinstance(teams, int) and teams <= 3:
        return f"ENDGAME, {teams} teams left, zone phase {phase}"
    if isinstance(phase, int) and phase <= 1:
        return f"early match, {teams} teams alive, zone phase {phase}"
    return f"mid-match, {teams} teams alive, zone phase {phase}, the zone is closing"


def summarize(seat: StarterSeat, phase: str, persona: Persona,
              standing: bytes | None = None,
              notes: list[str] | None = None) -> str:
    """The PoC summary, wrapped with what this persona cares about, plus the
    common live-state block and any ``notes`` about what changed since the
    last call."""
    lines: list[str] = []
    partner = (seat.context or {}).get("self", {}).get("duo_partner")
    if persona.partner_focus and partner is not None:
        lines.extend(_partner_lines(seat, partner))
        lines.append("")
    lines.append(poc_policy.summarize(seat, phase, standing))
    vitals = _vital_lines(seat)
    if vitals:
        lines.append("")
        lines.extend(vitals)
    state = _state_lines(seat)
    if state:
        lines.append("")
        lines.extend(state)
    if persona.include_kill_feed:
        lines.append("")
        lines.extend(_kill_feed_lines(seat))
    if notes:
        lines.append("")
        lines.append("Since your last call: " + "; ".join(notes) + ".")
    return "\n".join(lines)


# ── Repair: the PoC's cleaning, extended with the wave-A param kinds ──────
# poc_policy.build_call hardcodes its two-play world (and pact's required
# partners), so the starters carry their own manifest-driven copy of the same
# flow. The scalar/seat-set cleaning is still the PoC's -- only the two kinds
# its vocabulary lacks (bodyguard's `seat_ref` ward and `int_pair` leash) and
# the generic required-param rule are new.


def _clean_seat_ref(value):
    """One "seat:<N>" reference. `duo:<team>` is never emitted (it needs a
    server-configured duo, and bodyguard rejects it outright)."""
    if isinstance(value, int) and not isinstance(value, bool):
        value = f"seat:{value}"
    if not isinstance(value, str) or not value.startswith("seat:"):
        return None
    digits = value[len("seat:"):]
    if not digits.isdigit() or int(digits) > poc_policy.MAX_SEAT:
        return None
    return f"seat:{int(digits)}"


def _clean_int_pair(value, spec):
    """[lo, hi] JSON integers within the spec range, lo <= hi enforced."""
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    item_spec = {"kind": "int", "min": spec["min"], "max": spec["max"]}
    cleaned = [poc_policy._clamp_number(item, item_spec) for item in value]
    if any(item is None for item in cleaned):
        return None
    lo, hi = cleaned
    return [min(lo, hi), max(lo, hi)]


def _clean_union(value, spec):
    """An object carrying exactly ONE of the spec's integer arms (jackal's
    exitAfter). Anything else -- extra keys, unknown arm, bad value -- drops
    the param so the play's own default applies."""
    if not isinstance(value, dict) or len(value) != 1:
        return None
    (arm, raw), = value.items()
    arm_spec = spec["arms"].get(arm)
    if arm_spec is None:
        return None
    cleaned = poc_policy._clamp_number(
        raw, {"kind": "int", "min": arm_spec["min"],
              "max": arm_spec.get("max", 2**31 - 1)})
    if cleaned is None:
        return None
    return {arm: cleaned}


def _clean_enum_list(value, spec):
    """An ordered list of enum tags: unknowns dropped, duplicates removed
    (first occurrence wins), capped at max_items. Empty -> None, so the
    param is omitted and the play default applies."""
    if not isinstance(value, list):
        return None
    seen: list = []
    for item in value:
        if item in spec["of"] and item not in seen:
            seen.append(item)
    return seen[:spec["max_items"]] or None


def _clean_params(play: str, params) -> dict | None:
    """Clean one entry's params against the manifest; None drops the entry
    (a required param did not survive)."""
    specs = plays.PLAYS[play]["params"]
    cleaned = {}
    if isinstance(params, dict):
        for key, value in params.items():
            spec = specs.get(key)
            if spec is None:
                continue  # unknown params are rejected by name; drop here
            kind = spec["kind"]
            if kind in ("int", "float"):
                value = poc_policy._clamp_number(value, spec)
            elif kind == "bool":
                value = value if isinstance(value, bool) else None
            elif kind == "enum":
                value = value if value in spec["of"] else None
            elif kind == "seat_set":
                value = poc_policy._clean_partners(value)
            elif kind == "seat_ref":
                value = _clean_seat_ref(value)
            elif kind == "int_pair":
                value = _clean_int_pair(value, spec)
            elif kind == "union":
                value = _clean_union(value, spec)
            elif kind == "enum_list":
                value = _clean_enum_list(value, spec)
            else:
                value = None
            if value is not None:
                cleaned[key] = value
    for key, spec in specs.items():
        if spec.get("required") and key not in cleaned:
            return None
    return cleaned


# ── Ladder layering: the harness gates the rungs ─────────────────────────
# The engine steps the FIRST live controller whose guard passes; a controller
# that has emitted nothing hands the seat to the DEFAULT play, never to the
# next rung. So a controller with nothing to do (a healthy supply_run, a
# bodyguard whose ward is fine, a loot with no item in reach) must be kept
# OFF the ladder or it pins the seat with its idle hold / yields the seat to
# the default -- which is exactly what the v3/v4 starters did: cautious seats
# holding under supply_run, collaborative seats under bodyguard, while the
# zone walked over them.
#
# The wire has `when` guards for this, but for play seats the engine
# evaluates them against `noGuardContext()` (src/shell/episode.nim:484 --
# every path reads 0.0 / false), so a guard like `self.hp_frac < 0.8` is
# always true and `partner.alive` is always false. Until that is populated,
# the harness evaluates the same conditions itself from the live 0xB1 view
# and re-sends the ladder (no model call) whenever the gate state changes.

MAX_HP_FALLBACK = 6  # a full seat; refined from the live view when we have one
TRACK_FRESH_TICKS = 240  # a track older than this no longer counts as "seen"
LOOT_CLEAR_PX = 500      # loot only with no fresh enemy track closer than this


def _max_hp(view: dict) -> float:
    me = (view or {}).get("self") or {}
    hp, frac = me.get("hp"), me.get("hp_frac")
    if isinstance(hp, int) and isinstance(frac, (int, float)) and frac > 0:
        return max(1.0, hp / frac)
    return float(MAX_HP_FALLBACK)


def _view_facts(view: dict, context: dict, kill_feed: list) -> dict:
    """The handful of facts the gates read, computed once per evaluation."""
    me = (view or {}).get("self") or {}
    pos = me.get("pos") if _is_pos(me.get("pos")) else None
    tick = (view or {}).get("tick", 0) or 0
    my_seat = (context or {}).get("self", {}).get("seat")
    my_team = (context or {}).get("self", {}).get("team")
    partner = (context or {}).get("self", {}).get("duo_partner")
    enemies, partner_track = [], None
    for t in (view or {}).get("tracks", []):
        if not isinstance(t, dict) or not _is_pos(t.get("pos")):
            continue
        if t.get("seat") == partner:
            partner_track = t
            continue
        if t.get("seat") == my_seat or (my_team and t.get("team") == my_team):
            continue
        age = tick - t["fresh_tick"] if isinstance(t.get("fresh_tick"), int) else 0
        if age <= TRACK_FRESH_TICKS:
            enemies.append(t)
    items = [i for i in (view or {}).get("items", [])
             if isinstance(i, dict) and i.get("present", True) and _is_pos(i.get("pos"))]
    partner_dead = partner is not None and any(
        k.get("victim_seat") == partner for k in kill_feed)
    nearest_enemy = (min(_dist(pos, t["pos"]) for t in enemies)
                     if pos is not None and enemies else None)
    return dict(
        pos=pos, hp_frac=me.get("hp_frac"), enemies=enemies, items=items,
        nearest_enemy=nearest_enemy,
        partner=partner, partner_dead=partner_dead, partner_track=partner_track,
        partner_dist=(_dist(pos, partner_track["pos"])
                      if pos is not None and partner_track is not None else None),
    )


def _item_within(facts: dict, max_px: float, kinds=None, exclude=()) -> bool:
    pos = facts["pos"]
    if pos is None:
        return False
    for item in facts["items"]:
        kind = item.get("kind")
        if kinds is not None and kind not in kinds:
            continue
        if kind in exclude:
            continue
        if _dist(pos, item["pos"]) <= max_px:
            return True
    return False


def gate_open(entry: dict, facts: dict) -> bool:
    """Should this controller be on the ladder right now? Mirrors the guards
    the wire would carry if the engine evaluated them for play seats."""
    play = entry.get("play")
    params = entry.get("params") or {}
    if play == "supply_run":
        hp_below = params.get("whenHpBelow", plays.PLAYS["supply_run"]["params"]["whenHpBelow"]["default"])
        detour = params.get("detourMax", plays.PLAYS["supply_run"]["params"]["detourMax"]["default"])
        frac = facts["hp_frac"]
        wounded = isinstance(frac, (int, float)) and frac * facts.get("max_hp", MAX_HP_FALLBACK) < hp_below
        return bool(wounded and _item_within(facts, detour, kinds=("medkit",)))
    if play == "loot":
        detour = params.get("detourMax", plays.PLAYS["loot"]["params"]["detourMax"]["default"])
        exclude = () if params.get("medkits") else ("medkit",)
        # "No enemy tracked at all" almost never holds in a 16-seat match, so
        # the gate is distance-based: nobody fresh within LOOT_CLEAR_PX.
        return (facts["nearest_enemy"] is None or facts["nearest_enemy"] > LOOT_CLEAR_PX) \
            and _item_within(facts, detour, exclude=exclude)
    if play == "bodyguard":
        leash = params.get("leash") or plays.PLAYS["bodyguard"]["params"]["leash"]["default"]
        leash_max = leash[1] if isinstance(leash, list) and len(leash) == 2 else 220
        if facts["partner"] is None or facts["partner_dead"] or facts["partner_track"] is None:
            return False
        d = facts["partner_dist"]
        return d is not None and d > leash_max
    if play == "jackal":
        return bool(facts["enemies"])
    if play == "crossfire":
        return (facts["partner"] is not None and not facts["partner_dead"]
                and facts["partner_track"] is not None and bool(facts["enemies"]))
    return True


GATED_PLAYS = ("supply_run", "loot", "bodyguard", "jackal", "crossfire")


def layer_ladder(entries: list, view: dict, context: dict | None = None,
                 kill_feed: list | None = None,
                 base_play: str | None = "edge_ride") -> list:
    """The ladder to actually send: overlays first (they all fold), then the
    gated controllers whose gate is open right now, then the unguarded
    controllers (edge_ride) as the always-on base. Never emits `when`."""
    facts = _view_facts(view or {}, context or {}, kill_feed or [])
    facts["max_hp"] = _max_hp(view or {})
    overlays, gated, base = [], [], []
    for entry in entries:
        play = entry.get("play")
        if play not in plays.PLAYS:
            continue
        entry = dict(entry)
        entry.pop("when", None)
        if plays.PLAYS[play]["class"] == "overlay":
            overlays.append(entry)
        elif play == base_play:
            base.append(entry)  # the persona's always-on rung, never gated
        elif play in GATED_PLAYS:
            if gate_open(entry, facts):
                gated.append(entry)
        elif base_play is None:
            continue  # experiment: no base controller, the engine default drives
        else:
            base.append(entry)
    if (base_play is not None and base_play in plays.PLAYS
            and not any(e.get("play") == base_play for e in base)):
        # Every ladder needs a rung that always passes, or a tick on which no
        # gate is open hands the seat to the engine default (a 192 px rotate
        # step) instead of to the persona's own base play. Which play is the
        # base is the persona's call: edge_ride rides the margin; jackal holds
        # in place until a fight is heard (and hold + the zone reflex has
        # out-survived active riding in every measurement so far).
        defaults = {name: spec["default"]
                    for name, spec in plays.PLAYS[base_play]["params"].items()
                    if "default" in spec}
        base.append({"play": base_play, "entry_id": "base_" + base_play,
                     "params": defaults})
    # The persona's base play outranks any other unguarded controller the
    # model listed (first-match-wins), so "jackal base" means jackal decides
    # unless it yields, not "jackal after edge_ride".
    base.sort(key=lambda e: e.get("play") != base_play)
    if base_play is None and not overlays and not gated and "target_law" in plays.PLAYS:
        # An empty ladder is rejected (call_validation: 1..MaxLadderEntries),
        # and build_call's bare-controller fallback would reintroduce a
        # controller. A parameterless target_law is the honest no-op: an
        # overlay with no hold, no never-list, no preference.
        overlays.append({"play": "target_law", "entry_id": "noop"})
    return overlays + gated + base


def build_call(decision: dict, available: list[str]) -> tuple[bytes, list]:
    """Repair a model reply into a canonical ladder call over the BAKED plays.

    The same contract as ``poc_policy.build_call``: unusable entries are
    dropped rather than sent, and if nothing survives, a bare controller
    stands in so the seat still declares something.
    """
    raw_entries = []
    call = decision.get("call")
    if isinstance(call, dict):
        candidate = call.get("entries") or call.get("plays")
        if isinstance(candidate, list):
            raw_entries = candidate

    entries = []
    seen_ids: set = set()
    overlays = 0
    for index, raw in enumerate(raw_entries):
        if not isinstance(raw, dict):
            continue
        play = raw.get("play")
        if play not in available:
            continue
        is_overlay = plays.PLAYS[play]["class"] == "overlay"
        if is_overlay and overlays >= wire.MAX_ACTIVE_OVERLAYS:
            continue
        params = _clean_params(play, raw.get("params"))
        if params is None:
            continue
        if is_overlay:
            overlays += 1
        entry = {
            "play": play,
            "entry_id": poc_policy._clean_entry_id(
                raw.get("entry_id"), play, index, seen_ids),
        }
        if params:
            entry["params"] = params
        # `when` is deliberately NOT forwarded: for play seats the engine
        # evaluates guards against noGuardContext() (all zeros), so a guard
        # can only misfire. The harness gates rungs itself (layer_ladder).
        entries.append(entry)
        if len(entries) >= wire.MAX_LADDER_ENTRIES:
            break

    if not entries:
        fallback = next(
            (n for n in available if plays.PLAYS[n]["class"] == "controller"),
            available[0])
        entries = [{"play": fallback, "entry_id": "ride"}]

    payload = wire.canonical_json({"plays": entries}).encode("utf-8")
    if len(payload) > wire.MAX_CALL_BYTES:
        raise wire.WireError(f"call is {len(payload)} bytes; cap is "
                             f"{wire.MAX_CALL_BYTES}")
    return payload, entries


def repair_call(decision: dict, persona: Persona, seat: StarterSeat,
                available: list[str]) -> tuple[bytes, list]:
    payload, entries = build_call(decision, available)
    adjusted = json.loads(json.dumps(entries))
    if persona.adjust_entries is not None:
        adjusted = persona.adjust_entries(
            adjusted, seat.context or {}, seat.view or {})
    # The full wanted ladder (before gating) is what maintenance re-derives
    # from as the view changes; the gated ladder is what goes on the wire.
    seat.wanted_entries = json.loads(json.dumps(adjusted))
    return gate_and_build(seat, available)


def _base_name(name) -> str:
    """'James Botts (2)' -> 'James Botts': the roster de-duplicates one
    entrant's seats with a ' (N)' suffix."""
    if not isinstance(name, str):
        return ""
    stripped = name.rstrip()
    if stripped.endswith(")") and " (" in stripped:
        head, _, tail = stripped.rpartition(" (")
        if tail[:-1].isdigit():
            return head
    return stripped


def clone_seats(context: dict) -> list[int]:
    """The other seats this same entrant is driving. The league seats an
    entrant's two (or more) seats as SEPARATE duos on different teams, often
    adjacent at spawn -- and to the body a clone is just an enemy. In the
    first competitive rounds 44 of 51 early aggressive deaths were gun kills
    by the other aggressive seat: the entrant was shooting its own score."""
    me = (context or {}).get("self", {})
    mine = _base_name(poc_policy.seat_name(context, me.get("seat")))
    if not mine:
        return []
    out = []
    for row in (context or {}).get("roster", []):
        if not isinstance(row, dict) or row.get("seat") == me.get("seat"):
            continue
        if _base_name(row.get("name")) == mine and isinstance(row.get("seat"), int):
            out.append(row["seat"])
    return sorted(out)


def ally_clones(entries: list, context: dict) -> list:
    """Never shoot yourself: pact with every clone seat (protect stays the
    persona's call) and keep them on target_law's never-list. Idempotent;
    the generic repair afterwards still clamps and caps everything."""
    clones = clone_seats(context)
    if not clones:
        return entries
    refs = [f"seat:{s}" for s in clones]
    pact = next((e for e in entries if e.get("play") == "pact"), None)
    if pact is None:
        pact = {"play": "pact", "entry_id": "clones", "params": {}}
        entries.insert(0, pact)
    params = pact.setdefault("params", {})
    partners = [p for p in params.get("partners", []) if isinstance(p, str)]
    params["partners"] = partners + [r for r in refs if r not in partners]
    law = next((e for e in entries if e.get("play") == "target_law"), None)
    if law is None:
        law = {"play": "target_law", "entry_id": "no_clone_fire", "params": {}}
        entries.append(law)
    lp = law.setdefault("params", {})
    never = [p for p in lp.get("never", []) if isinstance(p, str)]
    lp["never"] = never + [r for r in refs if r not in never]
    return entries


def gate_and_build(seat: StarterSeat, available: list[str]) -> tuple[bytes, list]:
    """Gate the seat's wanted ladder against the live view and canonicalize
    it. Re-runs the generic repair so the result is still clamped, sorted,
    deduplicated and capped whatever a persona hook did."""
    base_play = getattr(seat, "base_play", "edge_ride")
    if _in_spawn_phase(seat) and base_play != "edge_ride":
        # Spawn phase: whatever the persona's base is, get OFF the spawn.
        # A jackal (or anything else that holds when idle) parked at spawn
        # next to a hostile duo is the aggressive starter's top cause of
        # death: 15 of 60 seats dead inside 110 ticks in one 30-episode arm,
        # against 3-8% for the personas whose base moves at once.
        base_play = "edge_ride"
    gated = layer_ladder(seat.wanted_entries, seat.view or {},
                         seat.context or {}, seat.kill_feed,
                         base_play=base_play)
    gated = ally_clones(gated, seat.context or {})
    return build_call({"call": {"entries": gated}}, available)


SPAWN_PHASE_TICKS = 150


def _in_spawn_phase(seat: StarterSeat) -> bool:
    """True for the first SPAWN_PHASE_TICKS after the seat's first view (the
    views start when the match does), and before any view at all."""
    view = seat.view or {}
    tick = view.get("tick")
    if not isinstance(tick, int):
        return True
    first = getattr(seat, "first_view_tick", None)
    if first is None:
        seat.first_view_tick = tick
        first = tick
    return tick - first < SPAWN_PHASE_TICKS


# ── The run ───────────────────────────────────────────────────────────────


def _log(persona: Persona, message: str) -> None:
    print(f"[{persona.name}] {message}", flush=True)


def _send_coordination(persona: Persona, seat: StarterSeat, turn: int,
                       await_echo: bool) -> None:
    """Send the persona's extra coordination line, spaced past the chat rate
    limit.

    The server refuses a second line from the same seat within
    ``LobbyChatMinSpacingTicks`` (24 ticks, ~1s -- ``lobby_chat:lcrTooSoon``),
    and the model's own chat line has just gone out, so hold for a moment
    first. Delivery is best-effort: a refused line must never fail the run.
    """
    if persona.extra_chat is None:
        return
    extra = persona.extra_chat(seat.context or {}, turn)
    if not extra:
        return
    held = time.monotonic() + 1.5
    while time.monotonic() < held:
        seat.pump()
        seat.drain(0.3)
    _log(persona, f"0xA3 coordination: {extra!r}")
    seat.send(wire.encode_lobby_chat(extra))
    if await_echo:
        echo = seat.await_chat(extra, seconds=5.0)
        if echo is not None:
            _log(persona, f"coordination echoed at ordinal {echo['ordinal']}")


def _load_playbook(directory: pathlib.Path,
                   available: list[str]) -> list[tuple[str, bytes]]:
    """Read the baked wasm blobs, controllers first (uploads are one per seat
    per tick, so a truncated run still has a usable ladder driver)."""
    modules = [(name, (directory / f"{name}.wasm").read_bytes())
               for name in available]
    modules.sort(key=lambda item: (plays.PLAYS[item[0]]["class"] != "controller",
                                   item[0]))
    return modules


def _connect_with_retry(persona: Persona, url: str, args):
    """Open the play socket, retrying until ``connect_deadline`` seconds have
    passed.

    Hosted pods start with real skew against the game pod: in the v3 fleet
    the single 30 s ``connect()`` attempt was the top failure class ("FAILED:
    transport error: timed out", 15 of 114 seats in one 20-episode batch),
    and a pod that exits then is a seat nobody drives for the whole match.
    The lobby's own join allowance is ~300 s, so keep trying inside it.

    Keepalive: the client's default ping_timeout (20 s) closed live sockets
    with 1011 "keepalive ping timeout" while the seat was blocked in a model
    call, and a play seat cannot rebind mid-match. Pings still go out so
    the server sees a live peer, but a late pong no longer kills the seat.
    """
    deadline = time.monotonic() + float(args.connect_deadline)
    attempt = 0
    while True:
        attempt += 1
        try:
            return connect(url, max_size=None,
                           open_timeout=args.connect_timeout,
                           ping_interval=20, ping_timeout=None)
        except (OSError, WebSocketException) as error:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            _log(persona, f"connect attempt {attempt} failed ({error}); "
                          f"retrying, {remaining:.0f}s left")
            time.sleep(min(2.0, max(0.1, remaining)))


def run(persona: Persona, args) -> int:
    playbook_dir = pathlib.Path(args.playbook)
    available = plays.scan_playbook(playbook_dir)
    playbook = _load_playbook(playbook_dir, available)
    _log(persona, "playbook: "
         + ", ".join(f"{n} ({len(b)}B)" for n, b in playbook))

    prompt = build_system_prompt(persona, available)
    # The persona's canned turns are BOTH the offline/CI engine and the live
    # engine's degrade target: if the sidecar rejects the model (allowlist
    # 403) or any completions call fails, brain.ResilientBrain logs once and
    # this seat keeps playing its scripted persona instead of exiting 1.
    engine, why = brain.build_brain(args.canned, args.model,
                                    fallback=PersonaCannedBrain(persona))
    if isinstance(engine, PersonaCannedBrain):
        why += f"; persona-canned turns for {persona.name}"
    _log(persona, f"model backend: {engine.name} ({why})")

    url = (f"ws://{args.host}:{args.port}/player"
           f"?slot={args.slot}&token={args.token}")
    _log(persona, f"connecting to {url}")

    failures: list[str] = []
    with _connect_with_retry(persona, url, args) as ws:
        seat = StarterSeat(ws, args.slot)
        seat.base_play = (None if os.environ.get("POC_NO_BASE_PLAY") == "1"
                          else persona.base_play)

        for _ in range(40):
            seat.pump()
            seat.drain(0.5)
            if seat.context is not None:
                break
        if seat.context is None:
            _log(persona, "FAILED: no 0xB0 PlayContext from the server")
            return 1

        # Turn 1: opening decision, chat (echo required), playbook, call.
        summary = summarize(seat, "lobby, before the drop", persona)
        _log(persona, "model input:\n" + summary)
        with _persona_prompt(prompt):
            decision = engine.decide(summary)
        _log(persona, f"model output: {json.dumps(decision, sort_keys=True)}")

        chat_text = str(decision.get("chat", "")).strip() or "gl hf"
        _log(persona, f"0xA3 chat: {chat_text!r}")
        seat.send(wire.encode_lobby_chat(chat_text))
        echo = seat.await_chat(chat_text)
        if echo is None:
            # NOT a failure: a hosted pod that joins after lobbyChatTicks has
            # elapsed (or into a config with the window at 0) gets
            # lobby_chat refusals or silence by design — chat is decorative,
            # and killing the pod over it turned healthy hosted rounds into
            # exit-1 "crashes". Playbook upload and accepted calls below are
            # the correctness bar.
            _log(persona, "no 0xB2 echo for the opening chat "
                          "(lobby window closed or missed) -- continuing")
        else:
            _log(persona, f"chat echoed at ordinal {echo['ordinal']}")
        _send_coordination(persona, seat, turn=1, await_echo=True)

        for name, blob in playbook:
            if not seat.upload(name, blob):
                failures.append(f"module {name} never reached module_ready")
            seat.pump()
            seat.drain(0.3)

        payload, _ = repair_call(decision, persona, seat, available)
        opening = seat.call(payload, "opening call")
        if opening is None or opening["kind"] != "call_accepted":
            failures.append("opening call was not accepted")

        try:
            _live_loop(persona, seat, engine, prompt, available, payload,
                       args, failures)
        except ConnectionClosed as closed:
            # The server closes every play socket when the match ends; that
            # is the normal way out of the loop, not a transport failure.
            _log(persona, f"socket closed by the server ({closed}); "
                          "match over")

    _log(persona, "---- starter summary ----")
    _log(persona, f"persona: {persona.name}")
    _log(persona, f"model backend: {engine.name}")
    _log(persona, f"real model calls: {getattr(engine, 'calls', 0)}")
    _log(persona, f"statuses received: {len(seat.statuses)}")
    _log(persona, f"chat broadcasts received: {len(seat.chat)}")
    if failures:
        for failure in failures:
            _log(persona, f"FAILURE: {failure}")
        return 1
    _log(persona, "all starter steps passed")
    return 0


def _snapshot(seat: StarterSeat, partner) -> dict:
    """The facts a re-call trigger compares against."""
    view = seat.view or {}
    me = view.get("self") or {}
    world = view.get("world") or {}
    zone = world.get("zone") or {}
    aggressors = [a for a in view.get("aggressors", [])
                  if isinstance(a, dict) and isinstance(a.get("tick"), int)]
    return {
        "hp": me.get("hp"),
        "zone_phase": zone.get("phase"),
        "alive_teams": world.get("alive_teams"),
        "partner_dead": partner is not None and any(
            k.get("victim_seat") == partner for k in seat.kill_feed),
        "kills": len(seat.kill_feed),
        "last_aggressor_tick": max((a["tick"] for a in aggressors), default=-1),
    }


def _triggers(before: dict, now: dict) -> list[str]:
    """Human-readable reasons to re-call, from two snapshots."""
    reasons = []
    if (isinstance(before["hp"], int) and isinstance(now["hp"], int)
            and now["hp"] < before["hp"]):
        reasons.append(f"your hp fell {before['hp']} -> {now['hp']}")
    if before["zone_phase"] != now["zone_phase"] and now["zone_phase"] is not None:
        reasons.append(f"zone phase {before['zone_phase']} -> {now['zone_phase']}")
    if now["partner_dead"] and not before["partner_dead"]:
        reasons.append("your duo partner was ELIMINATED")
    if now["last_aggressor_tick"] > before["last_aggressor_tick"]:
        reasons.append("you were shot at")
    if (isinstance(before["alive_teams"], int) and isinstance(now["alive_teams"], int)
            and now["alive_teams"] < before["alive_teams"]):
        reasons.append(f"teams alive {before['alive_teams']} -> {now['alive_teams']}")
    elif now["kills"] > before["kills"]:
        reasons.append(f"{now['kills'] - before['kills']} new kill(s) in the feed")
    return reasons


MAINTENANCE_SECONDS = 2.0


def _entries_of(payload: bytes) -> list:
    try:
        return json.loads(payload.decode("utf-8")).get("plays", [])
    except (ValueError, AttributeError):
        return []


def _live_loop(persona: Persona, seat: StarterSeat, engine, prompt: str,
               available: list[str], payload: bytes, args,
               failures: list[str]) -> None:
    """Stay in the match. Pump the socket, watch the view, and re-call the
    model when something changed -- spaced at least ``recall_seconds`` apart,
    at most ``max_calls`` per match, and unconditionally every
    ``periodic_seconds`` so a quiet seat still revisits its ladder.

    Returns when the seat is dead (nothing left to decide) or the budget is
    spent AND the socket closes; raises ConnectionClosed when the server ends
    the match, which the caller treats as the normal exit.
    """
    partner = (seat.context or {}).get("self", {}).get("duo_partner")
    min_gap = max(1.0, float(args.recall_seconds))
    periodic = (persona.periodic_seconds
                if persona.periodic_seconds is not None else 3.0 * min_gap)
    budget = max(1, int(args.max_calls))
    calls = 1  # the opening call
    last_call_at = time.monotonic()
    before = _snapshot(seat, partner)
    _log(persona, f"live loop: budget {budget} calls, min gap {min_gap:.0f}s, "
                  f"periodic {periodic:.0f}s")
    last_maintenance_at = 0.0
    maintained = 0
    while True:
        seat.pump()
        seat.drain(0.5)
        view = seat.view or {}
        me = view.get("self") or {}
        if view and me.get("alive") is False:
            _log(persona, f"seat is dead at tick {view.get('tick')}; "
                          f"{calls} model call(s), {maintained} maintenance call(s)")
            return
        if not view:
            continue
        # Ladder maintenance: the gates (supply_run when wounded with a kit in
        # reach, loot when nobody is tracked and an item is close, ...) are
        # re-evaluated against the live view; when the gated ladder differs
        # from what is standing, re-send it. No model involved, so this is
        # cheap and can run every couple of seconds.
        if time.monotonic() - last_maintenance_at >= MAINTENANCE_SECONDS:
            gated_payload, gated_entries = gate_and_build(seat, available)
            if gated_payload != payload:
                before_ids = [e.get("entry_id") for e in _entries_of(payload)]
                after_ids = [e.get("entry_id") for e in gated_entries]
                _log(persona, f"ladder maintenance at tick {view.get('tick')}: "
                              f"{before_ids} -> {after_ids}")
                outcome = seat.call(gated_payload, "maintenance")
                if outcome is not None and outcome["kind"] == "call_accepted":
                    payload = gated_payload
                    maintained += 1
                    before = _snapshot(seat, partner)
            last_maintenance_at = time.monotonic()
        if calls >= budget:
            continue
        elapsed = time.monotonic() - last_call_at
        if elapsed < min_gap:
            continue
        now = _snapshot(seat, partner)
        reasons = _triggers(before, now)
        if not reasons and elapsed >= periodic:
            reasons = [f"periodic check ({int(elapsed)} s since your last call)"]
        if not reasons:
            continue

        turn = calls + 1
        phase = match_phase(seat)
        summary = summarize(seat, phase, persona, standing=payload,
                            notes=reasons)
        _log(persona, f"re-call {turn - 1} trigger: {'; '.join(reasons)}")
        _log(persona, "model input:\n" + summary)
        with _persona_prompt(prompt):
            decision = engine.decide(summary)
        _log(persona, f"model output: {json.dumps(decision, sort_keys=True)}")
        # The lobby-chat window is closed once the match is playing, so a
        # mid-match line would only draw a lobby_chat:lcrClosed refusal.
        # Keep the model's line in the log for the reader, send nothing.
        chat = str(decision.get("chat", "")).strip()
        if chat:
            _log(persona, f"(mid-match, not sent) chat: {chat!r}")

        payload, _ = repair_call(decision, persona, seat, available)
        recall = seat.call(payload, f"re-call {turn - 1}")
        if recall is None or recall["kind"] != "call_accepted":
            failures.append(f"re-call {turn - 1} was not accepted")
        calls += 1
        last_call_at = time.monotonic()
        before = _snapshot(seat, partner)


def _hosted_ws_defaults() -> dict:
    """The platform's connection contract: the runner starts every policy pod
    with COWORLD_PLAYER_WS_URL (ws://host:port/player?slot=N&token=T). Parse it
    when present so hosted pods connect to the real server instead of the
    POC_* localhost defaults — the exact miss that made v1 filler pods exit 1
    on the tournament cluster."""
    url = os.environ.get("COWORLD_PLAYER_WS_URL", "")
    if not url:
        return {}
    from urllib.parse import urlsplit, parse_qs
    parts = urlsplit(url)
    query = parse_qs(parts.query)
    out = {}
    if parts.hostname:
        out["host"] = parts.hostname
    if parts.port:
        out["port"] = parts.port
    if query.get("slot"):
        out["slot"] = int(query["slot"][0])
    if query.get("token"):
        out["token"] = query["token"][0]
    return out


def main(persona: Persona, argv=None) -> int:
    hosted = _hosted_ws_defaults()
    parser = argparse.ArgumentParser(
        description=f"starter policy: {persona.name}")
    parser.add_argument("--host",
                        default=hosted.get("host",
                                           os.environ.get("POC_HOST",
                                                          "127.0.0.1")))
    parser.add_argument("--port", type=int,
                        default=hosted.get("port",
                                           int(os.environ.get("POC_PORT",
                                                              "21815"))))
    parser.add_argument("--slot", type=int,
                        default=hosted.get("slot",
                                           int(os.environ.get("POC_SLOT",
                                                              "0"))))
    parser.add_argument("--token",
                        default=hosted.get("token",
                                           os.environ.get("POC_TOKEN", "")))
    parser.add_argument("--playbook",
                        default=os.environ.get("POC_PLAYBOOK", "playbook"))
    parser.add_argument("--model",
                        default=os.environ.get("POC_MODEL",
                                               brain.DEFAULT_MODEL))
    parser.add_argument("--canned", action="store_true",
                        default=os.environ.get("POC_CANNED", "") == "1",
                        help="use this persona's fixed responses (offline/CI)")
    parser.add_argument("--recall-seconds", type=float,
                        default=float(os.environ.get("POC_RECALL_SECONDS",
                                                     persona.recall_seconds)))
    parser.add_argument("--recall-count", type=int,
                        default=int(os.environ.get("POC_RECALL_COUNT",
                                                   persona.recall_count)))
    parser.add_argument("--max-calls", type=int,
                        default=int(os.environ.get("POC_MAX_CALLS",
                                                   persona.max_calls)),
                        help="model calls per match, opening included")
    parser.add_argument("--connect-timeout", type=float, default=30.0,
                        help="seconds per connect attempt")
    parser.add_argument("--connect-deadline", type=float,
                        default=float(os.environ.get("POC_CONNECT_DEADLINE",
                                                     240.0)),
                        help="keep retrying the connect for this many seconds")
    args = parser.parse_args(argv)

    try:
        return run(persona, args)
    except (WebSocketException, OSError) as error:
        _log(persona, f"FAILED: transport error: {error}")
        return 1
    except (wire.WireError, brain.BrainError) as error:
        _log(persona, f"FAILED: {error}")
        return 1
