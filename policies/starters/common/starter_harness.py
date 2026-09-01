"""The shared starter-policy harness: the PoC's proven machinery plus a
persona seam.

This module does not re-implement the protocol layer. It imports the PoC's
``wire`` (packet codec + canonical JSON), ``brain`` (model backends: hosted
sidecar, OpenRouter, canned) and ``poc_policy`` (the ``PlaySeat`` protocol
bookkeeping and the ``build_call`` output repair) directly from
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


# ── Repair: generic clamp, then the persona hook, then the clamp again ────


def repair_call(decision: dict, persona: Persona,
                seat: StarterSeat) -> tuple[bytes, list]:
    payload, entries = poc_policy.build_call(decision)
    if persona.adjust_entries is None:
        return payload, entries
    adjusted = persona.adjust_entries(
        json.loads(json.dumps(entries)), seat.context or {}, seat.view or {})
    # Re-run the generic repair over the hook's output: whatever a persona
    # does, the result is still clamped, sorted, deduplicated and capped.
    return poc_policy.build_call({"call": {"entries": adjusted}})


# ── The run ───────────────────────────────────────────────────────────────


def _log(persona: Persona, message: str) -> None:
    print(f"[{persona.name}] {message}", flush=True)


def run(persona: Persona, args) -> int:
    playbook_dir = pathlib.Path(args.playbook)
    available = plays.scan_playbook(playbook_dir)
    # Repair against exactly the baked plays: a manifest play that is not in
    # this playbook is dropped by build_call rather than sent and refused.
    poc_policy.PLAY_SPECS = {
        name: spec for name, spec in plays.validator_specs().items()
        if name in available}
    playbook = poc_policy.load_playbook(playbook_dir)
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
        if persona.extra_chat is not None:
            extra = persona.extra_chat(seat.context or {}, 1)
            if extra:
                _log(persona, f"0xA3 coordination: {extra!r}")
                seat.send(wire.encode_lobby_chat(extra))

        for name, blob in playbook:
            if not seat.upload(name, blob):
                failures.append(f"module {name} never reached module_ready")
            seat.pump()
            seat.drain(0.3)

        payload, _ = repair_call(decision, persona, seat)
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
            if persona.extra_chat is not None:
                extra = persona.extra_chat(seat.context or {}, turn)
                if extra:
                    _log(persona, f"0xA3 coordination: {extra!r}")
                    seat.send(wire.encode_lobby_chat(extra))

            payload, _ = repair_call(decision, persona, seat)
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
