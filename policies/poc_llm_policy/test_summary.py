"""The model's text summary names people, not seat numbers.

James's ruling 2026-09-02 ("let them be identified"): the engine puts each
seat's display name into the PlayContext roster, and the summary the model
reasons over must use it for self, partner, the roster, and the heard
huddle — while the call keeps its seat:<N> references. Run:

    python3 policies/poc_llm_policy/test_summary.py
"""

from __future__ import annotations

import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import poc_policy  # noqa: E402


def fake_seat(chat=None, roster=None):
    return types.SimpleNamespace(
        slot=1, last_view_tick=62, chat=chat or [],
        context={
            "mode": "br",
            "map": {"name": "br-gen-24678", "width": 2271, "height": 1212},
            "gun_range": 1300,
            "self": {"seat": 1, "team": "blue", "duo_partner": 9},
            "roster": roster if roster is not None else [
                {"seat": 1, "team": "blue", "name": "soft-codexter-t1"},
                {"seat": 9, "team": "blue", "name": "soft-codexter-t1 (2)"},
                {"seat": 12, "team": "black"},
            ],
        })


def main() -> None:
    seat = fake_seat(chat=[
        {"seat": 12, "ordinal": 1, "text": "Setting up edge_ride."},
        {"seat": 9, "ordinal": 2, "text": "pact is live, protect on."},
    ])
    text = poc_policy.summarize(seat, "lobby, before the drop")
    assert "You are soft-codexter-t1 (seat 1) on team blue." in text, text
    assert "Your duo partner is soft-codexter-t1 (2) (seat 9)." in text, text
    assert "  soft-codexter-t1 (2) (seat 9) -- team blue" in text, text
    # An unnamed seat (older engine, or no name) keeps the seat form.
    assert "  seat 12 -- team black" in text, text
    assert "Huddle so far (most recent last):" in text, text
    assert "  seat 12: Setting up edge_ride." in text, text
    assert "  soft-codexter-t1 (2) (seat 9): pact is live, protect on." in text
    assert "seat:<N>" in text, text

    # No chat heard yet: no huddle block, and nothing else changes.
    quiet = poc_policy.summarize(fake_seat(), "lobby, before the drop")
    assert "Huddle so far" not in quiet, quiet

    # A roster without names degrades to the historical seat-only summary.
    bare = poc_policy.summarize(
        fake_seat(roster=[{"seat": 1, "team": "blue"},
                          {"seat": 9, "team": "blue"}]),
        "lobby, before the drop")
    assert "You are seat 1 on team blue." in bare, bare
    assert "Your duo partner is seat 9." in bare, bare

    # The huddle quote is bounded.
    many = fake_seat(chat=[{"seat": 9, "ordinal": i, "text": f"line {i}"}
                           for i in range(40)])
    quoted = poc_policy.huddle_lines(many)
    assert len(quoted) == 1 + poc_policy.HUDDLE_LINES, len(quoted)
    assert quoted[-1].endswith("line 39"), quoted[-1]
    print("summary names people: OK")


if __name__ == "__main__":
    main()
