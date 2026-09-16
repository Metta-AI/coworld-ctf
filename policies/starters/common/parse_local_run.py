"""Read a local `coworld run-episode` output directory's own artifacts and
turn them into the glossary-worded table `compare_local.py` prints.

There is no per-deed JSON in `results.json` today (it carries seat-level
totals only: scores, win, kills, deaths, achievements -- see
`coworld run-episode --help` and a real `results.json`). The deed-mint
lines this module parses come from `logs/game.stdout.log`, which the
engine already prints in plain words at mint time (`<team> <deed> +<N>`,
e.g. "red longshot tag +16", "ivory closing time +4") plus a
`clear_on_death` shell annotation carrying the tick a seat died. This is
the engine's own dev log, not a documented/stable wire API -- if a future
build changes or removes these lines, the functions below degrade to the
`results.json` columns only (glory, tags, win) rather than raising, and
`deeds` reads "-" instead of a breakdown.

Verified against one real local episode (`coworld run-episode
.../coworld_manifest.json --variant battle-royale-s2`, paintbot:0.7.367,
2026-09-09) -- see docs/wiki/your-first-policy.md for the exact command.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import TypedDict

_DEED_RE = re.compile(r"^(?P<team>[a-z]+) (?P<deed>[a-z]+(?: [a-z]+)*) \+(?P<amount>\d+)$")
_DEATH_RE = re.compile(r"^SHELL_ANNOTATION tick=(?P<tick>\d+) seat=(?P<seat>\d+) kind=clear_on_death")


class SeatRow(TypedDict):
    seat: int
    team: str
    rank: int
    glory: int
    tags: int
    survived: str
    deeds: list[tuple[str, int]]


def load_run(run_dir: str | Path) -> list[SeatRow]:
    """Return one row per seat, ranked by Glory (`results.json["scores"]`,
    descending -- the same raw score the door's leaderboard sorts by)."""
    run_dir = Path(run_dir)
    results = json.loads((run_dir / "results.json").read_text())
    teams: list[str] = results["team"]
    scores: list[int] = results["scores"]
    tags: list[int] = results["kills"]  # canonical word: a landed hit is a "tag"
    deaths: list[int] = results["deaths"]

    deed_by_team: dict[str, list[tuple[str, int]]] = {}
    death_tick_by_seat: dict[int, int] = {}
    stdout_log = run_dir / "logs" / "game.stdout.log"
    if stdout_log.exists():
        for line in stdout_log.read_text(errors="replace").splitlines():
            line = line.strip()
            m = _DEED_RE.match(line)
            if m:
                deed_by_team.setdefault(m["team"], []).append(
                    (m["deed"], int(m["amount"]))
                )
                continue
            m = _DEATH_RE.match(line)
            if m:
                death_tick_by_seat[int(m["seat"])] = int(m["tick"])

    order = sorted(range(len(scores)), key=lambda i: -scores[i])
    rank_by_seat = {seat: place + 1 for place, seat in enumerate(order)}

    rows: list[SeatRow] = []
    for seat, team in enumerate(teams):
        if deaths[seat] == 0:
            survived = "end"
        else:
            tick = death_tick_by_seat.get(seat)
            survived = f"tick {tick}" if tick is not None else "died (tick unknown)"
        rows.append(
            SeatRow(
                seat=seat,
                team=team,
                rank=rank_by_seat[seat],
                glory=scores[seat],
                tags=tags[seat],
                survived=survived,
                deeds=deed_by_team.get(team, []),
            )
        )
    return rows


def format_deeds(deeds: list[tuple[str, int]]) -> str:
    if not deeds:
        return "-"
    totals: dict[str, int] = {}
    for name, amount in deeds:
        totals[name] = totals.get(name, 0) + amount
    return ", ".join(f"{name}+{amount}" for name, amount in totals.items())


def render_table(label: str, rows: list[SeatRow], focus_seat: int, top_n: int = 3) -> str:
    """Top `top_n` rows by rank plus the focus seat, never all sixteen --
    the same rule Stop 2's endcard design uses."""
    by_rank = sorted(rows, key=lambda r: r["rank"])
    shown = by_rank[:top_n]
    focus = next(r for r in rows if r["seat"] == focus_seat)
    if focus not in shown:
        shown = shown + [focus]
    lines = [
        f"-- {label} (seed-matched) --",
        f"{'rank':>4} {'seat/team':<14} {'glory':>7} {'tags':>4} {'survived':>9}  deeds",
    ]
    for r in shown:
        mark = "  <- you" if r["seat"] == focus_seat else ""
        seat_team = f"{r['seat']}/{r['team']}"
        lines.append(
            f"{r['rank']:>4} {seat_team:<14} {r['glory']:>7} {r['tags']:>4} "
            f"{r['survived']:>9}  {format_deeds(r['deeds'])}{mark}"
        )
    return "\n".join(lines)
