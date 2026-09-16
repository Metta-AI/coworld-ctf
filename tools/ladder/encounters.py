#!/usr/bin/env python3
"""encounters — combat-encounter tempo from our tier-2 event stream.

Measures fight TEMPO: an encounter is a run of combat-damage rows between one
unordered seat pair, split into separate encounters by a tick gap; the rate is
encounters per minute of playing time. Contact volume is the confirmed #1
driver of the ffa4 gap, and this makes it a first-class, cheap metric over the
tier-2 event files — ~/.ctf/scout/events/*.jsonl, produced by bin/extract_events
/ scout.py's `fetch` step (tools/extract_events.nim). Those files are the free,
already-paid-for corpus scout.py builds; this tool reads them, it does not fetch.

Definitions:
  combat damage   a `damage` row with a non-negative `source` AND a
                  non-negative `target` where source != target. Our engine
                  records self/environmental damage (currently only paint
                  puddles, sim.nim:updatePuddles) with source=-1, and a rare
                  own-grenade self-hit with source==target — both already
                  excluded by this check alone. HAZARD_WEAPONS below is a
                  second, belt-and-suspenders filter for any future weapon
                  token shaped like the reference's ring/isolation/puddle
                  hazards (e.g. if maxwell/br-zone's ring lands on main).
  encounter       a run of combat-damage rows between one UNORDERED pair of
                  seats; a gap longer than --encounter-gap ticks starts a new
                  encounter. Rate is encounters per minute of PLAYING time
                  (from the "playing" phase event to the final tick — the
                  same window scout.py's attrition buckets use).
  opponent split  attributes each encounter to "us" vs a named rival using
                  the roster the episode itself recorded (summary.
                  slot_address / slot_team) — the same base-name technique
                  scout.py's `tally()` uses, never an assumed seat parity.
                  An encounter between two of our own seats is "friendly
                  fire"; an encounter between two non-us seats (e.g. two
                  rivals fighting each other in an FFA we're also in) is
                  "third party" and is not charged to any one opponent.

Tick rate: OUR engine runs 1/30s ticks (see tools/ladder/scout.py's own
"Ticks are 1/30s" note), not the reference's 24/s — --encounter-gap's default
(300) is 10s of no combat contact, scaled from their 240-tick/10s default.

Parsing is DEFENSIVE by construction: every row is read with dict.get() and
matched against known `kind` strings by name (never against an enumerated
"every kind we've ever seen" list), so an event file containing a kind this
script has never heard of (e.g. a sibling branch's Achievement/GloryDeed/
LevelUp rows, or an extra field on any row) is silently ignored rather than
crashing or mis-parsing. tools/ladder/test_encounters.py exercises this with
a fixture line carrying a fabricated unknown kind.

Env/lever-arming taint: N/A. Our tier-2 event rows (src/ctf/events.nim)
carry tick/kind/source/target/weapon/amount/hp/blocked/x/y/action_id/
heading_brads/distance/item/content/damages, and the summary row carries
type/ticks/events/gameVersion/finished/draw/winner/slot_*. None of that is an
env-var snapshot or a lever-arming flag — there is nothing here to surface,
and a taint block patterned on "unmeasured arms" would be fabricated. If a
future summary row gains an env/lever snapshot, teach `integrity_of()` to
read it; until then this is the honest answer, not a placeholder.

Usage:
  encounters.py [--events GLOB] [--player NAME] [--vs NAME]
                [--encounter-gap N] [--limit N] [--json]

Examples:
  encounters.py --limit 200
  encounters.py --vs relh --encounter-gap 300
  encounters.py --events '/tmp/fixture/*.jsonl' --json
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import sys

TICKS_PER_SEC = 30  # tools/ladder/scout.py: "Ticks are 1/30s."
DEFAULT_EVENTS_GLOB = os.path.expanduser("~/.ctf/scout/events/*.jsonl")
DEFAULT_PLAYER = "softmaxwell"  # tools/ladder/ctfapi.py: OUR_PLAYER
# Belt-and-suspenders only: on today's main every damage row that is not a
# player-vs-player hit already carries source=-1 (verified: sampled 40 real
# extractions, 5747 damage rows, weapons {gun, spray, grenade, puddle}; every
# "puddle" row and every negative-source "grenade" self-hit had source<0).
HAZARD_WEAPONS = {"puddle", "ring", "isolation"}


def load_events(path: str) -> tuple[list[dict], dict]:
    """Returns (events, summary) for one extraction. Tolerant of any row
    shape: unknown keys and unknown `kind`/`type` values pass through as
    plain dicts and are simply never matched by a specific check below."""
    events: list[dict] = []
    summary: dict = {}
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("type") == "summary":
                summary = row
            else:
                events.append(row)
    return events, summary


def playing_tick(events: list[dict]) -> int:
    for event in events:
        if event.get("kind") == "phase" and event.get("weapon") == "playing":
            return int(event["tick"])
    return 0


def is_combat_damage(event: dict) -> bool:
    if event.get("kind") != "damage":
        return False
    if event.get("weapon", "") in HAZARD_WEAPONS:
        return False
    try:
        source, target = int(event.get("source", -1)), int(event.get("target", -1))
    except (TypeError, ValueError):
        return False
    return source >= 0 and target >= 0 and source != target


def pair_key(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a <= b else (b, a)


def encounters_by_pair(
    events: list[dict], gap: int
) -> dict[tuple[int, int], int]:
    """{unordered seat pair: number of encounters}, splitting a pair's runs
    of combat damage wherever consecutive ticks are more than `gap` apart."""
    ticks_by_pair: dict[tuple[int, int], list[int]] = collections.defaultdict(list)
    for event in events:
        if not is_combat_damage(event):
            continue
        pair = pair_key(int(event["source"]), int(event["target"]))
        ticks_by_pair[pair].append(int(event["tick"]))
    out: dict[tuple[int, int], int] = {}
    for pair, ticks in ticks_by_pair.items():
        ticks.sort()
        count = 1
        for previous, current in zip(ticks, ticks[1:]):
            if current - previous > gap:
                count += 1
        out[pair] = count
    return out


def playing_minutes(events: list[dict], summary: dict) -> float:
    start = playing_tick(events)
    ticks = int(summary.get("ticks", 0) or 0)
    playing_ticks = max(1, ticks - start)
    return playing_ticks / (TICKS_PER_SEC * 60)


def side_of_seats(summary: dict, player: str) -> dict[int, str | None]:
    """seat -> "me" | opponent base name | None (seat never joined).

    Same base-name technique as scout.py's `tally()`: hosted replays record
    "<player>" and "<player> (2)".."(8)" for repeated fillers, so the base
    name (before " (") is the identity that matters.
    """
    addr = summary.get("slot_address") or []
    side: dict[int, str | None] = {}
    for i, a in enumerate(addr):
        base = (a or "").split(" (")[0]
        side[i] = "me" if base == player else (base or None)
    return side


def episode_id_of(path: str) -> str:
    return os.path.splitext(os.path.basename(path))[0]


class EpisodeStats:
    __slots__ = (
        "episode_id", "seats", "playing_sec", "total_encounters",
        "encounters_per_min", "my_encounters", "my_encounters_per_min",
        "friendly_fire_encounters", "third_party_encounters",
        "opponents_faced", "per_opponent", "missing_summary", "game_version",
    )


def analyze_file(path: str, player: str, gap: int) -> EpisodeStats | None:
    events, summary = load_events(path)
    stats = EpisodeStats()
    stats.episode_id = episode_id_of(path)
    stats.missing_summary = not summary
    stats.game_version = summary.get("gameVersion")
    if stats.missing_summary:
        # A truncated file (see events.nim's own docstring on why the
        # trailing summary row exists) — report it, don't silently drop it
        # from the aggregate as if it were a clean zero.
        stats.seats = 0
        stats.playing_sec = 0.0
        stats.total_encounters = 0
        stats.encounters_per_min = 0.0
        stats.my_encounters = 0
        stats.my_encounters_per_min = 0.0
        stats.friendly_fire_encounters = 0
        stats.third_party_encounters = 0
        stats.opponents_faced = 0
        stats.per_opponent = {}
        return stats

    minutes = playing_minutes(events, summary)
    by_pair = encounters_by_pair(events, gap)
    side = side_of_seats(summary, player)

    per_opponent: collections.Counter[str] = collections.Counter()
    friendly_fire = 0
    third_party = 0
    for (a, b), count in by_pair.items():
        sa, sb = side.get(a), side.get(b)
        if sa is None or sb is None:
            continue  # an empty seat can't be in a combat-damage row, but
            # stay defensive rather than assume the roster is complete.
        if sa == "me" and sb == "me":
            friendly_fire += count
        elif sa == "me" or sb == "me":
            opponent = sb if sa == "me" else sa
            per_opponent[opponent] += count
        else:
            third_party += count

    total = sum(by_pair.values())
    stats.seats = len(summary.get("slot_address") or [])
    stats.playing_sec = round(minutes * 60, 1)
    stats.total_encounters = total
    stats.encounters_per_min = round(total / minutes, 3) if minutes else 0.0
    stats.my_encounters = sum(per_opponent.values()) + friendly_fire
    stats.my_encounters_per_min = (
        round(stats.my_encounters / minutes, 3) if minutes else 0.0)
    stats.friendly_fire_encounters = friendly_fire
    stats.third_party_encounters = third_party
    stats.opponents_faced = len(per_opponent)
    stats.per_opponent = dict(per_opponent)
    return stats


def run(events_glob: str, player: str, vs: str | None, gap: int, limit: int | None):
    paths = sorted(glob.glob(events_glob))
    if limit:
        paths = paths[:limit]
    rows: list[EpisodeStats] = []
    failed = 0
    for path in paths:
        try:
            stats = analyze_file(path, player, gap)
        except (json.JSONDecodeError, OSError, KeyError, ValueError) as e:
            print(f"  skip {os.path.basename(path)}: {e}", file=sys.stderr)
            failed += 1
            continue
        if stats is None:
            failed += 1
            continue
        if vs and vs not in stats.per_opponent:
            continue
        rows.append(stats)
    return rows, failed, len(paths)


def print_report(rows: list, failed: int, total_files: int, player: str,
                  gap: int, events_glob: str):
    print(f"encounters over {len(rows)}/{total_files} episode(s) "
          f"({failed} unreadable/empty) from {events_glob}")
    print(f"player={player}  encounter-gap={gap} ticks "
          f"({gap / TICKS_PER_SEC:.1f}s @ {TICKS_PER_SEC}/s)\n")
    if not rows:
        print("no episodes matched.")
        return

    missing = sum(1 for r in rows if r.missing_summary)
    usable = [r for r in rows if not r.missing_summary]
    gvs = collections.Counter(r.game_version for r in usable)

    hdr = (f"  {'episode':38} {'seats':>5} {'playing':>8} {'enc':>4} "
           f"{'enc/min':>8} {'mine':>5} {'mine/min':>9} {'ff':>3} {'3rd':>4} "
           f"{'opps':>5}")
    print(hdr)
    for r in usable:
        print(f"  {r.episode_id[:38]:38} {r.seats:>5} {r.playing_sec:>7.1f}s "
              f"{r.total_encounters:>4} {r.encounters_per_min:>8.3f} "
              f"{r.my_encounters:>5} {r.my_encounters_per_min:>9.3f} "
              f"{r.friendly_fire_encounters:>3} {r.third_party_encounters:>4} "
              f"{r.opponents_faced:>5}")

    total_enc = sum(r.total_encounters for r in usable)
    total_min = sum(r.playing_sec for r in usable) / 60.0
    my_enc = sum(r.my_encounters for r in usable)
    ff_enc = sum(r.friendly_fire_encounters for r in usable)
    tp_enc = sum(r.third_party_encounters for r in usable)
    pooled = total_enc / total_min if total_min else 0.0
    mean_per_ep = (
        sum(r.encounters_per_min for r in usable) / len(usable) if usable else 0.0)
    print(f"\n  AGGREGATE over {len(usable)} episode(s), "
          f"{total_min:.1f} playing-minutes:")
    print(f"    encounters/min  pooled={pooled:.3f}  "
          f"mean-of-episodes={mean_per_ep:.3f}")
    print(f"    total encounters={total_enc}  "
          f"ours={my_enc} ({100 * my_enc / total_enc:.1f}%)  "
          f"friendly-fire={ff_enc}  third-party={tp_enc}"
          if total_enc else "    total encounters=0")

    per_opp: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])  # eps, enc
    per_opp_min = collections.defaultdict(float)
    for r in usable:
        for opp, n in r.per_opponent.items():
            per_opp[opp][0] += 1
            per_opp[opp][1] += n
            per_opp_min[opp] += r.playing_sec / 60.0
    if per_opp:
        print(f"\n  {'opponent':22} {'eps':>4} {'encounters':>10} "
              f"{'enc/min (pooled)':>17}")
        for opp, (eps, n) in sorted(per_opp.items(), key=lambda kv: -kv[1][1]):
            rate = n / per_opp_min[opp] if per_opp_min[opp] else 0.0
            print(f"  {opp[:21]:22} {eps:>4} {n:>10} {rate:>17.3f}")

    if missing:
        print(f"\n  ⚠️  {missing} file(s) had no summary row (truncated "
              "extraction) — excluded from the aggregate above.")
    if gvs:
        print(f"\n  GameVersion(s) seen: "
              + ", ".join(f"GV{gv}={n}" for gv, n in gvs.most_common()))


def print_json(rows: list, player: str, gap: int):
    out = []
    for r in rows:
        out.append({
            "episode_id": r.episode_id,
            "seats": r.seats,
            "playing_sec": r.playing_sec,
            "total_encounters": r.total_encounters,
            "encounters_per_min": r.encounters_per_min,
            "my_encounters": r.my_encounters,
            "my_encounters_per_min": r.my_encounters_per_min,
            "friendly_fire_encounters": r.friendly_fire_encounters,
            "third_party_encounters": r.third_party_encounters,
            "per_opponent": r.per_opponent,
            "missing_summary": r.missing_summary,
            "game_version": r.game_version,
        })
    print(json.dumps({
        "player": player, "encounter_gap_ticks": gap, "episodes": out,
    }, indent=2, sort_keys=True))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog="Env/lever-arming taint: N/A for this event schema (see "
               "module docstring) — nothing is faked here.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--events", default=DEFAULT_EVENTS_GLOB,
                    help=f"glob of tier-2 event .jsonl files "
                         f"(default {DEFAULT_EVENTS_GLOB})")
    ap.add_argument("--player", default=DEFAULT_PLAYER,
                    help=f"our entrant name (default {DEFAULT_PLAYER})")
    ap.add_argument("--vs", help="only episodes where this opponent appears")
    ap.add_argument("--encounter-gap", type=int, default=300,
                    help="ticks of no combat damage between one pair before "
                         "a new encounter starts (default 300 = 10s @ 30/s)")
    ap.add_argument("--limit", type=int, help="cap number of event files read")
    ap.add_argument("--json", action="store_true", help="emit JSON, not a table")
    args = ap.parse_args()

    rows, failed, total_files = run(
        args.events, args.player, args.vs, args.encounter_gap, args.limit)

    if args.json:
        print_json(rows, args.player, args.encounter_gap)
    else:
        print_report(rows, failed, total_files, args.player,
                     args.encounter_gap, args.events)


if __name__ == "__main__":
    main()
