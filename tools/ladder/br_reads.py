#!/usr/bin/env python3
"""br_reads — BR launch pre-registered day-one reads (docs/designs/BR_MAPGEN.md
§3.1/§3.4, LAUNCH_PLAN.md §4). Read-only against the platform, always.

WHY THIS EXISTS
The BR launch plan's bootstrap order (BR_MAPGEN.md §7.1) is: draw a family,
run it UNGATED, derive the fairness floor from the resulting corpus, then gate
retroactively. None of the four reads below are pass/fail gates at launch —
they are the instrument that later derivation runs on. Until the `br16`
league exists this tool must still be exercisable, so every command takes
`--league`/`--variant`/`--groups` rather than hard-coding BR's shape: point it
at the live Paintbot league's `4-team free-for-all` (ffa4) corpus today
(`--groups 4`) to smoke-test the MECHANISM, then re-point at the BR league
(`--groups 16`, `--variant br16`) once it exists. A 4-group smoke run is not a
BR fairness measurement — see each report's own caveats.

FOUR READS, MATCHING LAUNCH_PLAN.md §4 1-4
  fairness    Per-spawn win-share -> the corpus floor (p2.5 at >=5 wins/spawn,
              the house method). Explicitly does NOT port CTF's 0.140 (that
              floor sits ABOVE a 16-group uniform of 0.0625; porting it would
              fail every map ever drawn — BR_MAPGEN.md §3.1's own warning).
  engagement  Per-policy attacks/damage/placement, clustered on the
              TEAM-Episode, bootstrap CI — the post-launch calibration feed.
  loot        Zone-vs-combat death ratio (BR_MAPGEN.md §6.6/§7.3) and
              item-pickup rate per POOL (medkit/shield/grenade/spray — the
              four wire items, BR_MAPGEN.md §4.9), from the same event pass.
  (rollback / smoke checklist live in br_smoke.py, not here.)

PIPELINE (delegates the expensive parts to scout.py so caching is shared)
  index   ctfapi -> scout.index()                          [JSON cache]
  fetch   replay_url -> events, via scout.fetch_all()       [S3 + tier-2 sink]
  <report> re-reads cached events, builds one row per (episode, team) —
           the TEAM-EPISODE cluster every bootstrap CI here resamples over —
           optionally caching that row table so re-runs are near-free.

USAGE
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  cd tools/ladder

  # smoke-test the mechanism against the LIVE Paintbot ffa4 corpus:
  $PY br_reads.py index --rounds 40
  $PY br_reads.py fetch  --variant "4-team free-for-all" --groups 4 --rounds 40
  $PY br_reads.py fairness   --variant "4-team free-for-all" --groups 4 --rounds 40
  $PY br_reads.py engagement --variant "4-team free-for-all" --groups 4 --rounds 40
  $PY br_reads.py loot       --variant "4-team free-for-all" --groups 4 --rounds 40

  # once the BR league exists:
  CTF_LEAGUE=league_<br16-id> $PY br_reads.py fetch --variant br16 --groups 16 --rounds 20
  CTF_LEAGUE=league_<br16-id> $PY br_reads.py fairness --variant br16 --groups 16 --rounds 20

  $PY br_reads.py selfcheck   # offline, no network — the fixture defenses

TRAPS BAKED IN AS DEFENSES (each one has already cost real time elsewhere in
this toolkit — see scout.py / encounters.py's own docstrings)
  * `is_filler` marks a SEAT, not a policy. The scripted control is identified
    by `slot_address == "Baseline"` on the REPLAY's own roster, never by
    `is_filler` or the displayed `player_name` (which lies on filler seats).
  * /v2/rounds/{id}/episodes defaults to limit=50; ctfapi.episodes() always
    passes limit=1000 (this file never calls the endpoint directly).
  * Event files are named for the REPLAY uuid, not `episode_id` — this file
    only ever gets there through scout.py's own `episode -> event_path`
    lookup, never a hand-rolled join.
  * Builds are NEVER summed: every report is broken out by `coworld_version`,
    read from the episode API record, never from the summary row's
    `gameVersion` (that field is the EXTRACTOR's own version and is constant
    for every file we could extract at all — circular, see gloryscore.py's
    docstring for the same trap in a sibling tool).
  * A geometry assertion (`len(distinct teams) == --groups`) gates every row,
    the same class of defense ffa4score.py uses to exclude ffa8 from ffa4.
    The exclusion count is always printed, never silently dropped.
  * `death` events carry the KILLER in `target` and the VICTIM in `source`
    (opposite of `kill`, which is source=killer/target=victim) and NO weapon
    (always ""). Death CAUSE is reconstructed from the most recent preceding
    `damage` event on that same victim slot — verified against a live sample
    (820 deaths, 803 kills; every `death` row's own weapon field was empty).
  * A CI that crosses the null / a floor with <5 wins in a spawn prints
    "thin" or "no measurable signal", never a confident number.
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ctfapi                                                  # noqa: E402
import scout                                                   # noqa: E402

HOME = os.path.expanduser("~")
CACHE = f"{HOME}/.ctf/scout/br_reads"
ROW_SCHEMA = 2          # bump to invalidate every cached rows_*.json
BOOT = 1000
SEED = 20260825
MIN_WINS_TO_GRADE = 5   # BR_MAPGEN.md §3.1: "p2.5 ... at >=5 wins per spawn"
FLOOR_PCT = 0.025        # p2.5

# The four items the engine actually serves on the wire (BR_MAPGEN.md §4.9:
# "The engine serves four map items on the wire (medkit, grenade, shield,
# spray)"). `barrier` is a fifth, unrelated pickup (a placeable cardboard
# wall) and is excluded — verified live: emitPickup call sites are
# {"grenade", "med_kit", "shield", "spray_can", "barrier"}.
ITEM_POOLS = ("med_kit", "shield", "grenade", "spray_can")

# Weapon vocabulary observed live (sampled 20 files / 2959 damage rows):
# {gun, spray, grenade, puddle}. `puddle` is an EXISTING CTF hazard (paint
# puddles), unrelated to BR's shrinking zone. `ring`/`zone` are the labels
# BR_MAPGEN.md's zone mechanic is expected to use once maxwell/br-zone lands
# (§3.3: "needs a zone-damage-source label on the wire, which lives on the
# unmerged maxwell/br-zone branch, not yet in this checkout") — reserved
# here, not invented; if the corpus never shows them the `loot` report says
# BLOCKED rather than silently reporting a confident 0%.
COMBAT_WEAPONS = {"gun", "spray", "grenade"}
ZONE_WEAPONS = {"ring", "zone"}
HAZARD_OTHER_WEAPONS = {"puddle", "isolation"}


def classify_weapon(weapon: str) -> str:
    if weapon in COMBAT_WEAPONS:
        return "combat"
    if weapon in ZONE_WEAPONS:
        return "zone"
    if weapon in HAZARD_OTHER_WEAPONS:
        return "hazard_other"
    return "unknown"


# ------------------------------------------------------------------ helpers


def base_name(addr: str) -> str:
    """'relh (3)' -> 'relh'. Hosted replays record '<player>' then
    '<player> (2)'..'(N)' for repeated fillers. Same technique as
    encounters.py / ffa4score.py — the ONLY reliable Baseline tell is this
    stripped-to-base slot_address, never `is_filler` or `player_name`."""
    a = (addr or "").strip()
    if a.endswith(")") and " (" in a:
        head, tail = a.rsplit(" (", 1)
        if tail[:-1].isdigit():
            return head
    return a


def slug(text: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in text.strip().lower())


# ------------------------------------------------------------- row building


EXCLUSION_REASONS = collections.Counter()


def build_row(rnd: int, ep: dict, groups: int):
    """One row per completed, geometry-matching episode: {team_label -> stats}
    plus episode-level metadata. Returns None (and tallies why) on any
    episode this instrument cannot safely attribute."""
    events, summary = scout.load_events(ep)
    if not summary:
        EXCLUSION_REASONS["no_extraction"] += 1
        return None
    if not summary.get("finished"):
        EXCLUSION_REASONS["unfinished"] += 1
        return None

    addr = summary.get("slot_address") or []
    teams_arr = summary.get("slot_team") or []
    if not addr or not teams_arr or len(addr) != len(teams_arr):
        EXCLUSION_REASONS["malformed_roster"] += 1
        return None

    distinct_teams = sorted(set(teams_arr))
    if len(distinct_teams) != groups:
        EXCLUSION_REASONS[f"geometry_{len(distinct_teams)}_teams"] += 1
        return None

    participants = ep.get("participants") or []
    pv_by_pos = {p["position"]: p for p in participants}
    pos_team = {i: t for i, t in enumerate(teams_arr)}

    team_positions = collections.defaultdict(list)
    for i, t in enumerate(teams_arr):
        team_positions[t].append(i)

    winner = summary.get("winner")
    teams = {}
    for t, positions in team_positions.items():
        pvs = collections.Counter()
        for i in positions:
            p = pv_by_pos.get(i)
            if p and p.get("policy_version_id"):
                pvs[p["policy_version_id"]] += 1
        policy_version_id = pvs.most_common(1)[0][0] if pvs else None
        policy_name = None
        for i in positions:
            p = pv_by_pos.get(i)
            if p and p.get("policy_version_id") == policy_version_id:
                policy_name = p.get("policy_name")
                break
        is_control = any(base_name(addr[i]) == "Baseline"
                          for i in positions if i < len(addr))
        empty_seats = sum(1 for i in positions
                           if i < len(addr) and not addr[i])
        teams[t] = {
            "policy_version_id": policy_version_id,
            "policy_name": policy_name,
            "mixed_policy": len(pvs) > 1,
            "is_control": is_control,
            "empty_seats": empty_seats,
            "n_seats": len(positions),
            "won": (winner == t),
            "kills": 0, "deaths": 0,
            "dmg_dealt": 0, "dmg_taken": 0,
            "shots": 0, "hits": 0,
            "pickups": collections.Counter(),
            "deaths_combat": 0, "deaths_zone": 0,
            "deaths_hazard_other": 0, "deaths_unknown": 0,
        }

    fired = summary.get("slot_shots_fired") or []
    hitv = summary.get("slot_shots_hit") or []
    for i, t in pos_team.items():
        if i < len(fired):
            teams[t]["shots"] += fired[i] or 0
        if i < len(hitv):
            teams[t]["hits"] += hitv[i] or 0

    last_damage_weapon: dict[int, str] = {}
    evs = sorted(events, key=lambda e: e.get("tick", 0))
    playing_tick = 0
    for ev in evs:
        k = ev.get("kind")
        if k == "phase" and ev.get("weapon") == "playing":
            playing_tick = int(ev.get("tick", 0))
            continue
        src, tgt = ev.get("source"), ev.get("target")
        st, tt = pos_team.get(src), pos_team.get(tgt)

        if k == "damage":
            # Damage: source = attacker (or -1 for environmental/hazard),
            # target = victim. Track the victim's most recent damage weapon
            # regardless of attacker attribution — that is what a later
            # `death` row needs to reconstruct CAUSE.
            if tt is not None:
                teams[tt]["dmg_taken"] += ev.get("amount") or 0
                if tgt is not None:
                    last_damage_weapon[tgt] = ev.get("weapon") or ""
            if st is not None and src is not None and src >= 0 and src != tgt:
                teams[st]["dmg_dealt"] += ev.get("amount") or 0
        elif k == "kill":
            # Kill: source = killer, target = victim (mirrors recordKill).
            if st is not None:
                teams[st]["kills"] += 1
        elif k == "death":
            # Death: source = VICTIM, target = killer. No weapon field ever
            # (verified live: 820/820 death rows carried weapon="") — cause
            # comes from the last damage event on this victim, above.
            if st is not None:
                teams[st]["deaths"] += 1
                weapon = last_damage_weapon.get(src, "")
                cls = classify_weapon(weapon)
                teams[st][f"deaths_{cls}"] += 1
        elif k == "item_pickup":
            if st is not None:
                item = ev.get("item") or "?"
                teams[st]["pickups"][item] += 1

    return {
        "replay": scout.event_path(ep).rsplit("/", 1)[-1][:-len(".jsonl")],
        "round": rnd,
        "coworld_version": ep.get("coworld_version") or "?",
        "variant": ep.get("variant_name"),
        "ticks": int(summary.get("ticks") or 0),
        "playing_tick": playing_tick,
        "winner": winner,
        "n_groups": len(distinct_teams),
        "teams": teams,
    }


# --------------------------------------------------------------- rows cache


def rows_cache_path(variant: str, groups: int) -> str:
    os.makedirs(CACHE, exist_ok=True)
    return f"{CACHE}/rows_{slug(variant)}_g{groups}_s{ROW_SCHEMA}.json"


def _row_to_json(row):
    out = dict(row)
    out["teams"] = {
        t: {**v, "pickups": dict(v["pickups"])} for t, v in row["teams"].items()
    }
    return out


def _row_from_json(row):
    row = dict(row)
    row["teams"] = {
        t: {**v, "pickups": collections.Counter(v["pickups"])}
        for t, v in row["teams"].items()
    }
    return row


def collect_rows(eps, variant: str, groups: int, use_cache=True, verbose=True):
    """[(round, ep)] -> [row, ...], for episodes matching `variant` whose
    events are already cached (run `fetch` first). Caches the built rows by
    replay name so a re-run over an unchanged corpus is near-free."""
    path = rows_cache_path(variant, groups)
    cached = {}
    if use_cache and os.path.exists(path):
        with open(path) as f:
            cached = {r["replay"]: r for r in json.load(f)}

    EXCLUSION_REASONS.clear()
    variant_mismatch = 0
    out = {}
    for rnd, ep in eps:
        if ep.get("variant_name") != variant:
            variant_mismatch += 1
            continue
        replay = (ep.get("replay_url") or "").rsplit("/", 1)[-1].replace(".replay", "")
        if replay and replay in cached:
            out[replay] = _row_from_json(cached[replay])
            continue
        row = build_row(rnd, ep, groups)
        if row:
            out[row["replay"]] = row

    if use_cache:
        with open(path, "w") as f:
            json.dump([_row_to_json(r) for r in out.values()], f)

    if verbose:
        print(f"  {len(out)} usable {variant!r} rows "
              f"({variant_mismatch} other-variant skipped; "
              f"exclusions: {dict(EXCLUSION_REASONS)})", file=sys.stderr)
    return list(out.values())


# ------------------------------------------------------------------ stats


def percentile_interp(xs, p):
    """Linear-interpolation percentile (numpy 'linear' method)."""
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return float("nan")
    if n == 1:
        return xs[0]
    idx = p * (n - 1)
    lo, hi = int(math.floor(idx)), int(math.ceil(idx))
    if lo == hi:
        return xs[lo]
    frac = idx - lo
    return xs[lo] * (1 - frac) + xs[hi] * frac


def boot_mean(xs, reps=BOOT, seed=SEED):
    """(point, lo95, hi95, n) resampling a list of per-cluster values."""
    xs = [x for x in xs if x is not None and x == x]
    n = len(xs)
    if n == 0:
        return float("nan"), None, None, 0
    pt = sum(xs) / n
    if n < 3:
        return pt, None, None, n
    rng = random.Random(seed)
    outs = sorted(sum(rng.choices(xs, k=n)) / n for _ in range(reps))
    return pt, outs[int(0.025 * reps)], outs[int(0.975 * reps) - 1], n


def boot_ratio(pairs, reps=BOOT, seed=SEED):
    """(point, lo95, hi95, n_clusters, denom) for a pooled num/den ratio over
    (num, den) per-cluster pairs."""
    pairs = [p for p in pairs if p is not None]
    n = len(pairs)
    den = sum(p[1] for p in pairs)
    if not n or not den:
        return float("nan"), None, None, n, den
    pt = sum(p[0] for p in pairs) / den
    if n < 3:
        return pt, None, None, n, den
    rng = random.Random(seed)
    outs = []
    for _ in range(reps):
        s = rng.choices(pairs, k=n)
        d = sum(p[1] for p in s)
        if d:
            outs.append(sum(p[0] for p in s) / d)
    outs.sort()
    if not outs:
        return pt, None, None, n, den
    return pt, outs[int(0.025 * len(outs))], outs[int(0.975 * len(outs)) - 1], n, den


def boot_floor(per_spawn_shares: dict, min_wins: int, reps=BOOT, seed=SEED):
    """Resample GRADED spawns (clusters) with replacement, recompute p2.5 of
    their win-share on each replicate. Returns (point, lo95, hi95, n_graded,
    n_thin). `per_spawn_shares` is {spawn: (wins, episodes)}."""
    graded = {s: w / e for s, (w, e) in per_spawn_shares.items()
              if w >= min_wins and e > 0}
    thin = len(per_spawn_shares) - len(graded)
    if not graded:
        return float("nan"), None, None, 0, thin
    vals = list(graded.values())
    pt = percentile_interp(vals, FLOOR_PCT)
    if len(vals) < 4:
        return pt, None, None, len(vals), thin
    rng = random.Random(seed)
    outs = sorted(
        percentile_interp(rng.choices(vals, k=len(vals)), FLOOR_PCT)
        for _ in range(reps)
    )
    return pt, outs[int(0.025 * reps)], outs[int(0.975 * reps) - 1], len(vals), thin


# ------------------------------------------------------------ 1. fairness


def fairness_report(rows, groups: int, spawn_key: str, min_wins: int):
    print(f"\n{'='*70}\nREAD 1 — FAIRNESS FLOOR BOOTSTRAP "
          f"(BR_MAPGEN.md §3.1, LAUNCH_PLAN.md §4.1)\n{'='*70}")
    print(f"bootstrap order: draw a family -> run UNGATED -> derive the floor "
          f"from the corpus -> gate RETROACTIVELY. Nothing below is a gate.")
    uniform = 1.0 / groups if groups else float("nan")
    print(f"groups={groups}  uniform reference={uniform:.4f} "
          f"({100*uniform:.2f}%)  spawn-key={spawn_key!r}")
    print(f"  ⚠️  do NOT port CTF's 0.140 floor: that sits ABOVE this "
          f"corpus's uniform of {uniform:.4f} for groups={groups} unless "
          f"groups<=7 — porting it would fail every map ever drawn.")

    if spawn_key != "team":
        print(f"  spawn-key {spawn_key!r} not implemented yet — falling back "
              f"to 'team' (see module docstring: BR needs a grid-index label "
              f"on the wire before per-episode spawn rotation is readable).",
              file=sys.stderr)

    by_build = collections.defaultdict(list)
    for r in rows:
        by_build[r["coworld_version"]].append(r)

    for build, brows in sorted(by_build.items()):
        print(f"\n-- coworld build {build} ({len(brows)} episodes) "
              f"-- builds are never pooled --")
        per_spawn = collections.defaultdict(lambda: [0, 0])  # spawn -> [wins, eps]
        for r in brows:
            for team_label, t in r["teams"].items():
                spawn = team_label  # spawn-key == "team": the map-relative
                # starting position/color, NOT the occupying policy. This is
                # the correct proxy for ffa4 (a fixed starting corner per
                # color) but BR_MAPGEN.md §6.6 says BR itself ROTATES
                # team->grid-point binding per episode seed — once that
                # grid-index label exists on the wire, point spawn-key at it
                # instead; 'team' would then read as noise, not a spawn.
                per_spawn[spawn][0] += int(t["won"])
                per_spawn[spawn][1] += 1

        pt, lo, hi, n_graded, n_thin = boot_floor(
            {k: tuple(v) for k, v in per_spawn.items()}, min_wins)
        print(f"  spawns observed: {len(per_spawn)}  graded (>= {min_wins} "
              f"wins): {n_graded}  thin (<{min_wins} wins): {n_thin}")
        for spawn, (w, e) in sorted(per_spawn.items(),
                                     key=lambda kv: kv[1][0] / max(kv[1][1], 1)):
            share = w / e if e else float("nan")
            grade = "graded" if w >= min_wins else f"THIN (n_wins={w}<{min_wins})"
            print(f"    {spawn:12} wins={w:4} eps={e:4} "
                  f"win-share={share:6.3f} [{grade}]")
        if math.isnan(pt):
            print(f"  FLOOR: no graded spawns yet — cannot derive a floor "
                  f"from this corpus. Not a failure; budget more episodes "
                  f"(BR_MAPGEN.md §3.5: 16 spawns need >=5 wins EACH, "
                  f"i.e. >= ~80 resolved episodes minimum for BR's own "
                  f"16-group shape; a {groups}-group smoke corpus needs "
                  f"proportionally fewer but is still thin below "
                  f"~{groups * min_wins} total wins).")
        else:
            ci = f"[{lo:.3f}, {hi:.3f}]" if lo is not None else "n/a (too few graded spawns for a CI)"
            print(f"  FLOOR (p{FLOOR_PCT*100:.1f} of graded per-spawn "
                  f"win-share) = {pt:.4f}  95% CI {ci}  "
                  f"(n_graded_spawns={n_graded})")
            if n_graded < groups:
                print(f"  ⚠️  only {n_graded}/{groups} spawns are graded — "
                      f"this floor is PROVISIONAL, not the whole family's "
                      f"answer yet.")


# ---------------------------------------------------------- 2. engagement


def engagement_report(rows):
    """Per-policy attacks/damage/placement, clustered on the TEAM-Episode —
    LAUNCH_PLAN.md §4.4's post-launch calibration feed, expressed as a
    league read rather than a one-off local script.

    'Placement' here is exactly what the episode's own RESULT carries: a
    binary win / eliminated, from `summary.winner` — NOT a full N-way rank.
    The platform's `scores`/`participant_scores` fields are the same binary
    signal (verified live: -1.0 for every eliminated seat, one positive
    value for the winning team's seats; no intermediate rank). A true BR
    1st..16th placement needs a reconstructed elimination ORDER (last-team-
    standing tick per BR_MAPGEN.md §6.6's tiebreak: living > last-death tick
    > kills > damage > slot) — out of scope for this read; `loot`'s
    death-tick data is the building block for that if it's ever needed.
    """
    print(f"\n{'='*70}\nREAD 2 — ENGAGEMENT DISTRIBUTIONS "
          f"(LAUNCH_PLAN.md §4.4)\n{'='*70}")
    print("attacks (shots/hits), damage dealt/taken, and placement "
          "(win vs eliminated) per POLICY VERSION, clustered on the "
          "TEAM-Episode (one team's seats in one Episode = one sample).\n")

    by_build = collections.defaultdict(list)
    for r in rows:
        by_build[r["coworld_version"]].append(r)

    for build, brows in sorted(by_build.items()):
        print(f"-- coworld build {build} ({len(brows)} episodes) --")
        by_policy = collections.defaultdict(list)  # pv_id -> [team dict, ...]
        names = {}
        control_id = None
        mixed = 0
        for r in brows:
            for t in r["teams"].values():
                if t["mixed_policy"]:
                    mixed += 1
                    continue
                pv = t["policy_version_id"]
                if pv is None:
                    continue
                by_policy[pv].append(t)
                if t["policy_name"]:
                    names[pv] = t["policy_name"]
                if t["is_control"]:
                    control_id = pv
        if mixed:
            print(f"  ⚠️  {mixed} team-Episode(s) fielded more than one "
                  f"policy_version_id in one team's seats — excluded "
                  f"(cannot attribute to a single policy).")

        hdr = (f"  {'policy':30} {'eps':>4} {'win%':>17} {'kills':>7} "
               f"{'deaths':>7} {'dmg+':>18} {'dmg-':>8} {'acc%':>17}")
        print(hdr)
        for pv, ts in sorted(by_policy.items(), key=lambda kv: -len(kv[1])):
            n = len(ts)
            wins = [int(t["won"]) for t in ts]
            wpt, wlo, whi, _ = boot_mean(wins)
            kd = sum(t["kills"] for t in ts) / n
            dd = sum(t["deaths"] for t in ts) / n
            dpt, dlo, dhi, _, _ = boot_ratio(
                [(t["dmg_dealt"], 1) for t in ts])
            dmg_taken = sum(t["dmg_taken"] for t in ts) / n
            acc_pairs = [(t["hits"], t["shots"]) for t in ts if t["shots"]]
            apt, alo, ahi, an, _ = boot_ratio(acc_pairs)
            label = (names.get(pv, "?") or "?")[:22]
            ctl = " [CONTROL]" if pv == control_id else ""
            wci = f"[{100*wlo:.1f},{100*whi:.1f}]" if wlo is not None else "n/a"
            aci = f"[{100*alo:.1f},{100*ahi:.1f}]" if alo is not None else "n/a"
            print(f"  {(label+ctl)[:30]:30} {n:>4} "
                  f"{100*wpt:>5.1f}% {wci:>11} {kd:>7.2f} {dd:>7.2f} "
                  f"{dpt:>8.1f}/ep {dmg_taken:>8.1f} "
                  f"{100*apt if apt==apt else float('nan'):>5.1f}% {aci:>11}")
        if not by_policy:
            print("  no attributable team-Episodes in this build.")
        else:
            thinnest = min(len(ts) for ts in by_policy.values())
            if thinnest < 20:
                print(f"  ⚠️  thinnest policy cell has only {thinnest} "
                      f"team-Episode(s) — directional only below ~20.")
        print()


# ---------------------------------------------------------------- 3. loot


def loot_report(rows):
    print(f"\n{'='*70}\nREAD 3 — ZONE-VS-COMBAT DEATHS + ITEM-PICKUP RATE "
          f"PER POOL (BR_MAPGEN.md §6.6/§7.3/§4.9)\n{'='*70}")

    by_build = collections.defaultdict(list)
    for r in rows:
        by_build[r["coworld_version"]].append(r)

    for build, brows in sorted(by_build.items()):
        print(f"\n-- coworld build {build} ({len(brows)} episodes) --")

        # --- zone-vs-combat deaths -----------------------------------
        combat = zone = hazard_other = unknown = 0
        for r in brows:
            for t in r["teams"].values():
                combat += t["deaths_combat"]
                zone += t["deaths_zone"]
                hazard_other += t["deaths_hazard_other"]
                unknown += t["deaths_unknown"]
        total = combat + zone + hazard_other + unknown
        print(f"  deaths: combat={combat} zone={zone} "
              f"hazard_other(puddle etc)={hazard_other} "
              f"unknown={unknown}  (total={total})")
        if total == 0:
            print("  no deaths in this cell — cannot report a ratio.")
        elif zone == 0:
            print(f"  zone-death ratio = 0/{total} = 0.0000 — "
                  f"⚠️  BLOCKED, not measured-zero: no event in this corpus "
                  f"ever carried a zone-damage weapon label "
                  f"({sorted(ZONE_WEAPONS)}). BR_MAPGEN.md §3.3/§7.3: the "
                  f"zone-damage-source label lives on the unmerged "
                  f"maxwell/br-zone branch, not in this extraction. Re-run "
                  f"once that branch (or its label) is on the checkout the "
                  f"extractor is built from.")
        else:
            print(f"  zone-death ratio = {zone}/{total} = {zone/total:.4f} "
                  f"(combat {combat/total:.4f}, "
                  f"hazard_other {hazard_other/total:.4f}, "
                  f"unknown {unknown/total:.4f})")
            if unknown / total > 0.05:
                print(f"  ⚠️  {100*unknown/total:.1f}% of deaths had no "
                      f"preceding damage event to classify (e.g. the first "
                      f"tick of an extraction, or a kind this tool doesn't "
                      f"parse yet) — treat the ratio as a lower bound.")

        # --- item-pickup rate per pool ---------------------------------
        print(f"\n  item-pickup rate per pool, per team-Episode "
              f"(mean, bootstrap CI) and pooled per 1000 episode-ticks:")
        n_eps = len(brows)
        print(f"  ⚠️  denominator is EPISODE ticks (playing-phase to end), "
              f"not a reconstructed per-agent ALIVE-tick track — a coarser "
              f"proxy than ffa4score.py's med-kit metric; a team that dies "
              f"early is not penalized for the ticks it wasn't alive for.")
        for pool in ITEM_POOLS:
            per_team = []  # (count, 1) per team-Episode
            per_team_rate = []  # count per 1000 ticks, per team-Episode
            total_n = 0
            for r in brows:
                ticks = max(1, r["ticks"] - r["playing_tick"])
                for t in r["teams"].values():
                    c = t["pickups"].get(pool, 0)
                    per_team.append(c)
                    per_team_rate.append(c * 1000.0 / ticks)
                    total_n += 1
            pt, lo, hi, n = boot_mean(per_team_rate)
            total_pickups = sum(per_team)
            share = total_pickups / max(1, sum(
                sum(t["pickups"].values()) for r in brows for t in r["teams"].values()))
            ci = f"[{lo:.3f}, {hi:.3f}]" if lo is not None else "n/a"
            print(f"    {pool:10} total={total_pickups:5}  "
                  f"share-of-all-pickups={100*share:5.1f}%  "
                  f"rate/1000-ticks: mean={pt:.4f} 95%CI {ci}  (n={n})")
        if n_eps < 20:
            print(f"  ⚠️  only {n_eps} episodes in this build — item rates "
                  f"below ~20 episodes are directional only.")


# ------------------------------------------------------------- fetch/index


def do_index(args):
    scout.OUR_GV = scout.our_game_version()
    ctfapi.whoami()
    eps = scout.index(args.rounds, args.since, args.until)
    rnds = sorted({r for r, _ in eps})
    lo, hi = (min(rnds), max(rnds)) if rnds else (0, 0)
    print(f"{len(eps)} completed episodes over {len(rnds)} rounds "
          f"(r{lo}-r{hi})")
    by_variant = collections.Counter(e.get("variant_name") for _, e in eps)
    for v, n in by_variant.most_common():
        print(f"  {v!r:34} {n:>5}")
    return eps


def do_fetch(args):
    scout.OUR_GV = scout.our_game_version()
    ctfapi.whoami()
    eps = scout.index(args.rounds, args.since, args.until)
    want = [(r, e) for r, e in eps if e.get("variant_name") == args.variant]
    if args.limit:
        want = want[:args.limit]
    print(f"fetching + extracting {len(want)}/{len(eps)} "
          f"{args.variant!r} episodes...")
    ok = scout.fetch_all(want)
    print(f"{ok}/{len(want)} extracted cleanly")
    return want


# ------------------------------------------------------------------ selfcheck


def selfcheck():
    """Offline, no network: the pure-function defenses this instrument
    depends on, as executable assertions. `test_br_reads.py` covers the
    same ground with a hand-built fixture and exact expected numbers; this
    is the quick version runnable as a subcommand."""
    ok = True
    print("selfcheck — br_reads.py's own trap defenses\n")

    good = classify_weapon("gun") == "combat" and classify_weapon("puddle") == "hazard_other" \
        and classify_weapon("ring") == "zone" and classify_weapon("mystery") == "unknown"
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] weapon classification: combat "
          f"{sorted(COMBAT_WEAPONS)}, zone(reserved) {sorted(ZONE_WEAPONS)}, "
          f"hazard_other {sorted(HAZARD_OTHER_WEAPONS)}, else unknown")

    good = base_name("relh (3)") == "relh" and base_name("Baseline") == "Baseline" \
        and base_name("") == ""
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] base_name strips the "
          f"'<player> (N)' filler suffix; Baseline is read from "
          f"slot_address, never is_filler/player_name")

    import inspect
    src = inspect.getsource(ctfapi.episodes)
    good = "limit=1000" in src
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] ctfapi.episodes() passes "
          f"limit=1000 (endpoint defaults to 50 and truncates silently)")

    good = ctfapi.LEAGUE != ctfapi.DEAD_CTF_LEAGUE
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] ctfapi.LEAGUE does not default "
          f"to the dead Ctf league (currently {ctfapi.LEAGUE})")

    shares = {"a": (6, 10), "b": (2, 10), "c": (5, 5)}
    pt, lo, hi, ng, nt = boot_floor(shares, min_wins=5)
    good = ng == 2 and nt == 1 and abs(pt - percentile_interp([0.6, 1.0], 0.025)) < 1e-9
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] boot_floor grades only spawns "
          f"with >=min_wins (fixture: 3 spawns, 1 thin -> {ng} graded, "
          f"{nt} thin, point={pt:.4f})")

    print(f"\n{'ALL CHECKS PASS' if ok else 'SOME CHECKS FAILED'}")
    return 0 if ok else 1


# ------------------------------------------------------------------- cli


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=[
        "index", "fetch", "fairness", "engagement", "loot", "run", "selfcheck"])
    ap.add_argument("--rounds", type=int, default=40,
                     help="how many recent completed rounds (default 40)")
    ap.add_argument("--since", type=int, help="all rounds >= this number")
    ap.add_argument("--until", type=int, help="pin an exact window with --since")
    ap.add_argument("--variant", help="exact variant_name to filter to, e.g. "
                                       "'4-team free-for-all' or 'br16'")
    ap.add_argument("--groups", type=int,
                     help="expected distinct team/group count for the "
                          "geometry assertion (4 for ffa4 smoke-test, "
                          "16 for BR)")
    ap.add_argument("--spawn-key", default="team", choices=["team"],
                     help="spawn-position proxy for the fairness read "
                          "(default 'team' — see module docstring)")
    ap.add_argument("--min-wins", type=int, default=MIN_WINS_TO_GRADE,
                     help=f"wins/spawn required to grade it (default "
                          f"{MIN_WINS_TO_GRADE}, per BR_MAPGEN.md §3.1)")
    ap.add_argument("--limit", type=int, help="cap episodes fetched")
    ap.add_argument("--no-cache", action="store_true",
                     help="ignore the cached rows table, rebuild from events")
    args = ap.parse_args()

    if args.cmd == "selfcheck":
        sys.exit(selfcheck())

    if args.cmd == "index":
        do_index(args)
        return

    if not args.variant or not args.groups:
        sys.exit("--variant and --groups are required for fetch/fairness/"
                  "engagement/loot/run (there is no safe default — see "
                  "the module docstring's ffa4-smoke-test vs BR examples)")

    if args.cmd == "fetch":
        do_fetch(args)
        return

    ctfapi.whoami()
    eps = scout.index(args.rounds, args.since, args.until)
    rows = collect_rows(eps, args.variant, args.groups,
                         use_cache=not args.no_cache)
    if not rows:
        print(f"no usable {args.variant!r} rows with groups={args.groups} — "
              f"run `fetch --variant {args.variant!r} --groups {args.groups}` "
              f"first, or widen --rounds.")
        return

    if args.cmd in ("fairness", "run"):
        fairness_report(rows, args.groups, args.spawn_key, args.min_wins)
    if args.cmd in ("engagement", "run"):
        engagement_report(rows)
    if args.cmd in ("loot", "run"):
        loot_report(rows)


if __name__ == "__main__":
    main()
