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
* a re-call loop that runs ``recall_count`` times at ``recall_seconds``
  intervals instead of the PoC's fixed single re-call.

The layout contract: this file lives at ``policies/starters/common/`` and the
PoC at ``policies/poc_llm_policy/``, both locally and inside the images.
"""

from __future__ import annotations

import argparse
import contextlib
import json
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
from websockets.exceptions import WebSocketException  # noqa: E402

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
    recall_count: int = 1
    recall_seconds: float = 6.0
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
    lines = [f"PARTNER STATUS FIRST -- your duo partner is seat {partner}."]
    if any(kill.get("victim_seat") == partner for kill in seat.kill_feed):
        lines.append(f"Your partner seat {partner} has been ELIMINATED. "
                     "You are alone now.")
        return lines
    track = next((t for t in seat.view.get("tracks", [])
                  if t.get("seat") == partner), None)
    if track is None:
        lines.append(f"No fresh track on seat {partner} -- close the distance "
                     "until you can see each other.")
    else:
        lines.append(f"Seat {partner} last seen at {track.get('pos')} "
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
        lines.append(f"  tick {kill.get('tick', '?')}: seat "
                     f"{kill.get('victim_seat', '?')} eliminated by team "
                     f"{kill.get('killer_team', '?')}.")
    return lines


def summarize(seat: StarterSeat, phase: str, persona: Persona,
              standing: bytes | None = None) -> str:
    """The PoC summary, wrapped with what this persona cares about."""
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
    if persona.include_kill_feed:
        lines.append("")
        lines.extend(_kill_feed_lines(seat))
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
            else:
                value = None
            if value is not None:
                cleaned[key] = value
    for key, spec in specs.items():
        if spec.get("required") and key not in cleaned:
            return None
    return cleaned


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
    if persona.adjust_entries is None:
        return payload, entries
    adjusted = persona.adjust_entries(
        json.loads(json.dumps(entries)), seat.context or {}, seat.view or {})
    # Re-run the generic repair over the hook's output: whatever a persona
    # does, the result is still clamped, sorted, deduplicated and capped.
    return build_call({"call": {"entries": adjusted}}, available)


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


def run(persona: Persona, args) -> int:
    playbook_dir = pathlib.Path(args.playbook)
    available = plays.scan_playbook(playbook_dir)
    playbook = _load_playbook(playbook_dir, available)
    _log(persona, "playbook: "
         + ", ".join(f"{n} ({len(b)}B)" for n, b in playbook))

    prompt = build_system_prompt(persona, available)
    engine, why = brain.build_brain(args.canned, args.model)
    if isinstance(engine, brain.CannedBrain):
        engine = PersonaCannedBrain(persona)
        why += f"; persona-canned turns for {persona.name}"
    _log(persona, f"model backend: {engine.name} ({why})")

    url = (f"ws://{args.host}:{args.port}/player"
           f"?slot={args.slot}&token={args.token}")
    _log(persona, f"connecting to {url}")

    failures: list[str] = []
    with connect(url, max_size=None, open_timeout=args.connect_timeout) as ws:
        seat = StarterSeat(ws, args.slot)

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
            failures.append("no 0xB2 broadcast echo for our opening chat")
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

        # Re-call loop: the persona's schedule, not the PoC's fixed one.
        for turn in range(2, 2 + max(0, args.recall_count)):
            _log(persona, f"holding {args.recall_seconds:.0f}s before "
                 f"re-call {turn - 1}/{args.recall_count}")
            held = time.monotonic() + args.recall_seconds
            while time.monotonic() < held:
                seat.pump()
                seat.drain(0.5)

            summary = summarize(seat, "mid-match, the zone is closing",
                                persona, standing=payload)
            _log(persona, "model input:\n" + summary)
            with _persona_prompt(prompt):
                decision = engine.decide(summary)
            _log(persona,
                 f"model output: {json.dumps(decision, sort_keys=True)}")

            # Mid-match chat is best-effort: the lobby window may have closed,
            # and a refused line must not fail the run.
            recall_text = str(decision.get("chat", "")).strip()
            if recall_text:
                seat.send(wire.encode_lobby_chat(recall_text))
            _send_coordination(persona, seat, turn=turn, await_echo=False)

            payload, _ = repair_call(decision, persona, seat, available)
            recall = seat.call(payload, f"re-call {turn - 1}")
            if recall is None or recall["kind"] != "call_accepted":
                failures.append(f"re-call {turn - 1} was not accepted")

        seat.drain(1.0)

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


def main(persona: Persona, argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=f"starter policy: {persona.name}")
    parser.add_argument("--host",
                        default=os.environ.get("POC_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("POC_PORT", "21815")))
    parser.add_argument("--slot", type=int,
                        default=int(os.environ.get("POC_SLOT", "0")))
    parser.add_argument("--token", default=os.environ.get("POC_TOKEN", ""))
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
    parser.add_argument("--connect-timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    try:
        return run(persona, args)
    except (WebSocketException, OSError) as error:
        _log(persona, f"FAILED: transport error: {error}")
        return 1
    except (wire.WireError, brain.BrainError) as error:
        _log(persona, f"FAILED: {error}")
        return 1
