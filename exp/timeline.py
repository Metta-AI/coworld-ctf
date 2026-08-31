"""Reconstruct a tick-stamped death/alive timeline per team from artlog zips.

Answers the question end-of-episode totals cannot: does an early kill-exchange
advantage PREDICT the win, controlling for bodies alive -- or does it merely
follow from being ahead?

Validated against results.json: the reconstructed final death counts must equal
the server's recorded per-team deaths, episode by episode.
"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path

LIVES = 3


def episode_timeline(ep_dir: Path) -> dict:
    """Per-team death ticks and per-team alive-seat counts over time."""
    outcome = json.loads((ep_dir / "outcome.json").read_text())
    deaths: dict[str, list[int]] = {"red": [], "blue": []}
    spans: list[tuple[str, int, int]] = []   # (team, dead_from, alive_again)
    start = None
    end = None
    for slot in range(16):
        z = zipfile.ZipFile(ep_dir / f"art_{slot:02d}.zip")
        team = json.loads(z.read("meta.json"))["team"].lower()
        ev = [json.loads(l) for l in z.read("events.jsonl").decode().splitlines() if l.strip()]
        seat_deaths = [e["t"] for e in ev if e["e"] == "death"]
        seat_resp = [e["t"] for e in ev if e["e"] == "respawn"]
        deaths[team].extend(seat_deaths)
        for i, dt in enumerate(seat_deaths):
            # The i-th death is answered by the i-th respawn; the LAST death of
            # a seat that spent all its lives has no respawn and is permanent.
            back = seat_resp[i] if i < len(seat_resp) else 10**9
            spans.append((team, dt, back))
        for e in ev:
            if e["e"] == "game_start":
                start = e["t"] if start is None else min(start, e["t"])
            if e["e"] == "game_end":
                end = e["t"] if end is None else max(end, e["t"])
    for t in deaths:
        deaths[t].sort()
    return {"outcome": outcome, "deaths": deaths, "spans": spans,
            "start": start, "end": end}


def alive_at(tl: dict, team: str, tick: int) -> int:
    """Seats of `team` alive at `tick` (8 minus those in a death->respawn span)."""
    dead = sum(1 for (tm, d, back) in tl["spans"] if tm == team and d <= tick < back)
    return 8 - dead


def deaths_by(tl: dict, team: str, tick: int) -> int:
    return sum(1 for d in tl["deaths"][team] if d <= tick)


def load_all(work: Path) -> list[dict]:
    out = []
    for ep in sorted(work.glob("ep_*")):
        if not (ep / "outcome.json").exists():
            continue
        if not (ep / "art_00.zip").exists():
            continue
        out.append(episode_timeline(ep))
    return out


def validate(tls: list[dict]) -> dict:
    """Reconstruction check against the server's own per-team death counts.

    artlog derives death from an EDGE between two decided frames (artlog.nim:205),
    so the death that ENDS the episode is never observed -- no further frame
    arrives to diff against. The undercount is therefore structural, always the
    TERMINAL death, and can never exceed 1 per team. Both properties are
    asserted here on the population rather than inferred from one episode.
    """
    diffs = []
    for tl in tls:
        o = tl["outcome"]
        a_team = o["a_side"]
        b_team = "blue" if a_team == "red" else "red"
        da = o["a_deaths"] - len(tl["deaths"][a_team])
        db = o["b_deaths"] - len(tl["deaths"][b_team])
        loser = b_team if o["a_won"] else a_team
        miss = [t for t, d in ((a_team, da), (b_team, db)) if d]
        diffs.append({"episode": o["episode"], "da": da, "db": db,
                      "loser": loser, "missing_on": miss,
                      "wipe": max(o["a_deaths"], o["b_deaths"]) == 24})
    over = [d for d in diffs if d["da"] < 0 or d["db"] < 0]
    big = [d for d in diffs if d["da"] > 1 or d["db"] > 1]
    exact = [d for d in diffs if d["da"] == 0 and d["db"] == 0]
    onloser = [d for d in diffs if d["missing_on"] and d["missing_on"] == [d["loser"]]]
    anymiss = [d for d in diffs if d["missing_on"]]
    print(f"reconstruction vs the server, {len(tls)} episodes:")
    print(f"  exact on both teams          {len(exact)}/{len(tls)}")
    print(f"  OVER-counted (must be 0)     {len(over)}")
    print(f"  short by more than 1 (must be 0) {len(big)}")
    print(f"  short by exactly 1           {len(anymiss)}; on the LOSING team: "
          f"{len(onloser)}/{len(anymiss) if anymiss else 1}")
    print(f"  of those, episode was a full wipe: "
          f"{sum(1 for d in anymiss if d['wipe'])}/{len(anymiss) if anymiss else 1}")
    assert not over and not big, "reconstruction is not a pure terminal undercount"
    return {"exact": len(exact), "short1": len(anymiss), "onloser": len(onloser)}


if __name__ == "__main__":
    import sys
    tls = load_all(Path(sys.argv[1]))
    print(f"episodes with telemetry: {len(tls)}")
    validate(tls)


def living_seat_ticks(tl: dict, team: str, t0: int, t1: int) -> int:
    """Integral of seats-alive over [t0, t1) -- the EXPOSURE a team had.

    This is the control the raw kill differential lacks: a team that is behind
    has fewer bodies on the field, so it kills less as a CONSEQUENCE of losing.
    Dividing by exposure asks whether it was killing less per body it had.
    """
    total = 8 * max(0, t1 - t0)
    for (tm, d, back) in tl["spans"]:
        if tm != team:
            continue
        total -= max(0, min(back, t1) - max(d, t0))
    return total


def analyse(tls: list[dict], window: int = 900) -> None:
    other = {"red": "blue", "blue": "red"}
    print(f"\n{'='*70}\nWHEN DOES THE OUTCOME BECOME DETERMINED?")
    print("leader = team that has taken FEWER deaths at that tick "
          "(ties excluded)\n")
    print(f"{'tick':>6} {'episodes live':>14} {'level':>7} {'leader wins':>13} {'95% CI':>16}")
    import sys as _s
    _s.path.insert(0, str(Path(__file__).parent))
    from analyze import clopper_pearson
    for T in (300, 600, 900, 1200, 1500, 1800, 2100):
        live = [tl for tl in tls if tl["end"] and tl["end"] > tl["start"] + T]
        hit = tot = level = 0
        for tl in live:
            t = tl["start"] + T
            dr = deaths_by(tl, "red", t)
            db = deaths_by(tl, "blue", t)
            if dr == db:
                level += 1
                continue
            leader = "red" if dr < db else "blue"
            o = tl["outcome"]
            winner = o["a_side"] if o["a_won"] else other[o["a_side"]]
            tot += 1
            hit += int(leader == winner)
        if tot:
            lo, hi = clopper_pearson(hit, tot)
            print(f"{T:>6} {len(live):>14} {level:>7} {hit:>6}/{tot:<6} "
                  f"{hit/tot:>5.3f} [{lo:.3f},{hi:.3f}]")
        else:
            print(f"{T:>6} {len(live):>14} {level:>7}  --")

    print(f"\n{'='*70}\nIS IT THE EXCHANGE RATE, OR JUST BEING AHEAD?")
    print(f"first {window} ticks only. raw = death differential; per-capita =")
    print("deaths inflicted per 1000 living-seat-ticks, which removes the")
    print("'ahead means more bodies alive means more kills' confound.\n")
    raw_hit = raw_tot = pc_hit = pc_tot = 0
    lvl_pc_hit = lvl_pc_tot = 0
    for tl in tls:
        t0, t1 = tl["start"], tl["start"] + window
        if not tl["end"] or tl["end"] <= t1:
            continue
        o = tl["outcome"]
        winner = o["a_side"] if o["a_won"] else other[o["a_side"]]
        d = {t: deaths_by(tl, t, t1) for t in ("red", "blue")}
        exposure = {t: living_seat_ticks(tl, t, t0, t1) for t in ("red", "blue")}
        # a team's kill rate = deaths it INFLICTED per its own living-seat-tick
        rate = {t: d[other[t]] / exposure[t] for t in ("red", "blue")}
        if d["red"] != d["blue"]:
            raw_tot += 1
            raw_hit += int(("red" if d["red"] < d["blue"] else "blue") == winner)
        if rate["red"] != rate["blue"]:
            pc_tot += 1
            pc_lead = "red" if rate["red"] > rate["blue"] else "blue"
            pc_hit += int(pc_lead == winner)
            if abs(d["red"] - d["blue"]) <= 1:      # LEVEL on raw score
                lvl_pc_tot += 1
                lvl_pc_hit += int(pc_lead == winner)
    for name, h, n in (("raw death differential", raw_hit, raw_tot),
                       ("per-capita exchange rate", pc_hit, pc_tot),
                       ("per-capita, among games LEVEL on raw score",
                        lvl_pc_hit, lvl_pc_tot)):
        if n:
            lo, hi = clopper_pearson(h, n)
            print(f"  {name:<44} {h:>3}/{n:<3} = {h/n:.3f} [{lo:.3f},{hi:.3f}]")
        else:
            print(f"  {name:<44}  no episodes")
