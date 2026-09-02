#!/usr/bin/env python3
"""Aggregate the MONET-vs-starters multi-seed A/B series produced by
run_series.sh into a per-persona scoreboard: RESULTS.md under OUT_ROOT.

Reads, per seed directory OUT_ROOT/seed<i>/:
  - persona_map.json   {"<team>": "<persona>"}          (written by run_series.sh)
  - outcome.json        br_outcome_probe's one JSON row   (placements/kills/elimTick)
  - meta.txt             seed value, call_accepted validity count
  - seat*.log            each persona client's own log; unioned across all 32
                          seats this gives (tick, victim_seat, killer_team) kill
                          events -- kill_feed is the server-authoritative,
                          non-fogged BR feed every seat receives identically, so
                          the union across seats (each polling at different
                          moments) reconstructs the elimination sequence more
                          completely than any single seat's sampled view.

Usage: policies/monet/aggregate_series.py [OUT_ROOT]
"""
from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

PERSONAS = ["monet", "aggressive", "cautious", "collaborative"]
TEAM_COUNT = 16

KILL_LINE_RE = re.compile(
    r"tick (\d+): seat (\d+) eliminated by team (-?\d+)\.")


def load_seed(seed_dir: Path) -> dict | None:
    outcome_path = seed_dir / "outcome.json"
    map_path = seed_dir / "persona_map.json"
    if not outcome_path.exists() or not map_path.exists():
        return None
    try:
        outcome = json.loads(outcome_path.read_text().strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return None
    persona_map = json.loads(map_path.read_text())

    meta_text = (seed_dir / "meta.txt").read_text() if (seed_dir / "meta.txt").exists() else ""
    accepted = None
    m = re.search(r"seats_with_call_accepted=(\d+) / 32", meta_text)
    if m:
        accepted = int(m.group(1))
    timed_out = "TIMEOUT" in meta_text

    # Union the kill feed across every seat's own log: dedupe by
    # (tick, victim_seat) since many seats will report the same kill.
    kills: dict[tuple[int, int], int] = {}
    for seat_log in sorted(seed_dir.glob("seat*.log")):
        text = seat_log.read_text(errors="replace")
        for tick_s, victim_s, killer_s in KILL_LINE_RE.findall(text):
            key = (int(tick_s), int(victim_s))
            kills[key] = int(killer_s)

    return {
        "outcome": outcome,
        "persona_map": persona_map,
        "accepted": accepted,
        "timed_out": timed_out,
        "kills": kills,  # {(tick, victim_seat): killer_team}
    }


def persona_of(persona_map: dict, team: int) -> str:
    return persona_map.get(str(team), "?")


def main() -> int:
    out_root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/monet-series")
    seed_dirs = sorted(out_root.glob("seed*"),
                        key=lambda p: int(p.name[4:]) if p.name[4:].isdigit() else 0)

    seeds_data = []  # list of (idx, seed_value, data)
    for d in seed_dirs:
        if not d.name[4:].isdigit():
            continue
        idx = int(d.name[4:])
        data = load_seed(d)
        if data is None:
            print(f"WARNING: seed{idx} has no usable outcome.json/persona_map.json "
                  f"-- skipping", file=sys.stderr)
            continue
        seed_val = data["outcome"].get("seed")
        seeds_data.append((idx, seed_val, data))

    if not seeds_data:
        print("no seed outcomes found under", out_root, file=sys.stderr)
        return 1

    # --- per-persona rows across all seeds ---
    per_persona_rows: dict[str, list[dict]] = {p: [] for p in PERSONAS}
    per_seed_placement_lines = []
    zone_centers = []
    validity_lines = []

    for idx, seed_val, data in seeds_data:
        outcome = data["outcome"]
        pm = data["persona_map"]
        zone_centers.append((seed_val, outcome.get("zoneCenterX"), outcome.get("zoneCenterY")))
        acc = data["accepted"]
        validity_lines.append(
            f"seed{idx} (seed={seed_val}): call_accepted {acc}/32"
            + (" -- BELOW 30/32, RIG FAILURE, rerun recommended" if acc is not None and acc < 30 else "")
            + (" -- TIMED OUT (12min cap)" if data["timed_out"] else ""))

        row_by_persona = {}
        for g in outcome.get("groups", []):
            team = g["team"]
            persona = persona_of(pm, team)
            row = {
                "seed_idx": idx, "seed": seed_val, "team": team, "persona": persona,
                "placement": g["placement"], "kills": g["kills"], "damage": g["damage"],
                "elimTick": g["elimTick"], "elimByCombat": g["elimByCombat"],
            }
            per_persona_rows.setdefault(persona, []).append(row)
            row_by_persona.setdefault(persona, []).append(row)

        placements_str = "; ".join(
            f"{p}={sorted(r['placement'] for r in row_by_persona.get(p, []))}"
            for p in PERSONAS)
        winner_team = outcome.get("winnerTeam", -1)
        winner_persona = persona_of(pm, winner_team) if winner_team >= 0 else "DRAW/unfinished"
        per_seed_placement_lines.append(
            f"seed{idx} (seed={seed_val}, ticks={outcome.get('ticks')}, "
            f"finished={outcome.get('finished')}, byTimeout={outcome.get('byTimeout')}, "
            f"winner=team{winner_team}/{winner_persona}): {placements_str}")

    ticks_total_by_seed = {idx: data["outcome"].get("ticks", 0)
                            for idx, _, data in seeds_data}

    # --- scoreboard ---
    scoreboard = []
    for persona in PERSONAS:
        rows = per_persona_rows.get(persona, [])
        if not rows:
            continue
        placements = [r["placement"] for r in rows]
        wins = sum(1 for r in rows if r["placement"] == 1)
        survival = []
        for r in rows:
            total_ticks = ticks_total_by_seed.get(r["seed_idx"], r["elimTick"])
            survival.append(r["elimTick"] if r["elimTick"] >= 0 else total_ticks)
        kills = [r["kills"] for r in rows]
        scoreboard.append({
            "persona": persona,
            "n_duos": len(rows),
            "mean_placement": statistics.mean(placements),
            "wins": wins,
            "mean_survival_ticks": statistics.mean(survival),
            "mean_kills": statistics.mean(kills),
        })
    scoreboard.sort(key=lambda r: r["mean_placement"])

    # --- MONET diagnosis: for every seed MONET did not win, find who
    # eliminated each monet duo and when, and whether the killer is the
    # neighboring duo MONET's pact/truce was aimed at. ---
    diagnosis_lines = []
    combat_n = zone_n = survived_n = 0
    for idx, seed_val, data in seeds_data:
        pm = data["persona_map"]
        outcome = data["outcome"]
        monet_teams = [t for t in range(TEAM_COUNT) if persona_of(pm, t) == "monet"]
        for g in outcome.get("groups", []):
            if g["team"] not in monet_teams:
                continue
            if g["elimTick"] < 0:
                survived_n += 1
            elif g["elimByCombat"]:
                combat_n += 1
            else:
                zone_n += 1
    diagnosis_lines.append(
        f"cause-of-elimination tally across all {combat_n + zone_n + survived_n} monet duo-episodes: "
        f"{combat_n} combat kills, {zone_n} zone attrition, {survived_n} survived to game end.")
    for idx, seed_val, data in seeds_data:
        pm = data["persona_map"]
        outcome = data["outcome"]
        monet_teams = [t for t in range(TEAM_COUNT) if persona_of(pm, t) == "monet"]
        winner_team = outcome.get("winnerTeam", -1)
        if winner_team in monet_teams:
            diagnosis_lines.append(f"seed{idx}: MONET WON (team {winner_team}).")
            continue
        for g in outcome.get("groups", []):
            team = g["team"]
            if team not in monet_teams:
                continue
            elim_tick = g["elimTick"]
            if elim_tick < 0:
                diagnosis_lines.append(
                    f"seed{idx}: monet team{team} survived to game end, "
                    f"placement {g['placement']}, {g['kills']} kills.")
                continue
            seats = (team, team + TEAM_COUNT)
            killer_teams = sorted({data["kills"][(t, v)]
                                    for (t, v) in data["kills"]
                                    if v in seats and abs(t - elim_tick) <= 200})
            cause = "COMBAT" if g["elimByCombat"] else "ZONE attrition (no gun credited)"
            killer_desc = ", ".join(
                f"team{kt}/{persona_of(pm, kt)}" for kt in killer_teams) if killer_teams else (
                "identity unavailable -- the wire play_view.kill_feed never populated in this "
                "rig (see rig caveat), so seat logs carry no killer_team line to attribute")
            neighbor = (team + 1) % TEAM_COUNT
            truce_note = ""
            if killer_teams:
                if neighbor in killer_teams:
                    truce_note = " -- KILLED BY ITS OWN TRUCE TARGET (neighboring duo)"
                else:
                    truce_note = f" -- truce target was team{neighbor}/{persona_of(pm, neighbor)}, not the killer"
            diagnosis_lines.append(
                f"seed{idx}: monet team{team} eliminated at tick {elim_tick} by {cause} "
                f"(placement {g['placement']}, {g['kills']} kills banked); killer {killer_desc}"
                f"{truce_note}.")

    # --- write RESULTS.md ---
    lines = []
    lines.append("# MONET vs starters -- multi-seed A/B series\n")
    lines.append(f"Seeds run: {[s for _, s, _ in seeds_data]}\n")
    lines.append("## Scoreboard (lower mean placement is better; 1=winner duo, 16=first out)\n")
    lines.append("| persona | duos (n) | wins | mean placement | mean survival ticks | mean kills/duo |")
    lines.append("|---|---|---|---|---|---|")
    for r in scoreboard:
        lines.append(f"| {r['persona']} | {r['n_duos']} | {r['wins']} | "
                      f"{r['mean_placement']:.2f} | {r['mean_survival_ticks']:.0f} | "
                      f"{r['mean_kills']:.2f} |")
    lines.append("")
    lines.append("## Per-seed placements (list = each persona's 4 duo placements that seed)\n")
    for line in per_seed_placement_lines:
        lines.append(f"- {line}")
    lines.append("")
    lines.append("## Zone center per seed (confirms the seed knob actually moves the episode)\n")
    for seed_val, zx, zy in zone_centers:
        lines.append(f"- seed={seed_val}: zoneCenter=({zx}, {zy})")
    distinct_centers = len({(zx, zy) for _, zx, zy in zone_centers})
    lines.append(f"\n{distinct_centers}/{len(zone_centers)} seeds produced a DISTINCT zone center "
                 f"-- {'seed knob CONFIRMED live' if distinct_centers > 1 else 'seed knob DID NOT change the episode -- SUSPECT'}.")
    lines.append("")
    lines.append("## MONET diagnosis\n")
    for line in diagnosis_lines:
        lines.append(f"- {line}")
    lines.append("")
    lines.append("## Validity checks\n")
    for line in validity_lines:
        lines.append(f"- {line}")
    lines.append("- Persona process differentiation: confirmed by construction "
                 "(each persona is a distinct policy.py with distinct canned_turns; "
                 "see policies/monet/policy.py vs policies/starters/*/policy.py).")
    lines.append("")
    lines.append("## Rig-doctrine caveat\n")
    lines.append("This measures CANNED ladders (fixed per-persona scripted turns replayed "
                 "through the same repair/adjust_entries path), not live model judgment -- "
                 "no OpenRouter/model credentials were used (`--canned` / POC_CANNED=1 "
                 "throughout). It is a fair, deterministic-per-turn comparison of each "
                 "persona's STRUCTURAL doctrine (adjust_entries hooks, ladder shape, "
                 "recall cadence) under real 32-seat BR play, not of any model's live "
                 "reasoning.\n"
                 "\n"
                 "Second caveat, discovered while building this rig: every seat's "
                 "`play_view` packet arrived with an EMPTY view payload for the whole "
                 "series (`self`/`world`/`kill_feed` never populated -- see "
                 "starter_harness.StarterSeat._file), so no seat log ever carries a "
                 "`killer_team` line and the diagnosis below cannot name killers. This "
                 "did NOT affect the scoring or the canned decisions themselves: canned "
                 "turns are fixed regardless of what the harness shows the model "
                 "(PersonaCannedBrain.decide ignores its summary argument), and the "
                 "engine-side WASM ladder execution that actually produces combat/zone "
                 "outcomes runs server-side off the last accepted call, independent of "
                 "what the client socket ever receives back. It only starves the "
                 "wire-level kill-feed diagnostic channel -- placements/kills/damage/"
                 "elimTick/elimByCombat below come from tools/br_outcome_probe.nim "
                 "re-simulating the recorded replay, which is unaffected.")

    out_path = out_root / "RESULTS.md"
    out_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {out_path}")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
