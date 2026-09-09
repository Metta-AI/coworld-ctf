#!/usr/bin/env python3
"""GLORY GRADIENT step-1 CENSUS: decode episodes -> seat-episode rows.

Takes a JSON list of episodes (each: episode_id, coworld_version,
replay_url, participant_scores, round_number) and, for each, downloads the
replay, extracts it with a coworld_version-appropriate `extract_events`
binary, and reconstructs the recut product score per seat exactly as
sim.nim/glory.nim fold it -- see tools/glory/README.md for the method and
its validation (100% reconciliation against platform-reported scores on
the 2026-09-08 GloryVersion-15 cohort).

Usage:
  python3 census_decode.py --episodes gv15_episodes.json \\
      --version-extractor 0.7.361=/path/to/gv59_extract_events \\
      --version-extractor 0.7.365=/path/to/gv60_extract_events \\
      --out seat_episode_rows.json

A --version-extractor entry's key is matched by EXACT coworld_version
string; episodes whose version has no matching entry are skipped and
reported as errors (fail loud, never silently misdecode).
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request
import concurrent.futures as cf
from collections import Counter, defaultdict

CAP = 2 ** 24

HEAT_LADDER = [1, 2, 4, 8]
HEAT_THRESHOLDS = [1, 2, 4]
HEAT_EMBER_CAP = 11
HEAT_EMBER_DECAY = 2
HEAT_DECAY_TICKS = 270

# DeedDramaTable > 0 (paysHeat), verbatim from src/ctf/glory.nim.
# Re-verify this set against glory.nim if GloryVersion moves -- it is a
# hand copy, not a live read.
HEAT_PAYING_DEEDS = {
    "dFirstBlood", "dHonorableKill", "dSprayKill", "dGrenadeKill",
    "dPointBlankKill", "dLongshotKill", "dSplashMultiKill", "dRevengeKill",
    "dRunDown", "dAceTag", "dFlagSteal", "dCapture", "dCarrierKill",
    "dDenial", "dEscortKill", "dAssist", "dRescue", "dWipe", "dDuoDown",
}


def heat_rung(embers):
    r = 0
    for t in HEAT_THRESHOLDS:
        if embers >= t:
            r += 1
        else:
            break
    return r


def download_replay(url, episode_id, cache_dir):
    path = os.path.join(cache_dir, f"{episode_id}.replay")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    with urllib.request.urlopen(url, timeout=90) as r:
        data = r.read()
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return path


def extract(replay_path, extractor, episode_id, cache_dir):
    out = os.path.join(cache_dir, f"{episode_id}.jsonl")
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return out, None
    r = subprocess.run([extractor, replay_path, "--out", out],
                        capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return None, (r.stderr or r.stdout).strip()
    return out, None


def heat_occupancy_for_seat(events_for_seat, episode_ticks):
    """Walk heat-paying deed ticks for one seat across the FULL episode
    (not cut at the seat's own death -- see README.md's heat note: a
    downed-mode kill credit can mint after its own killer has died)."""
    end_tick = episode_ticks
    occ = defaultdict(int)
    embers = 0
    cursor = 0
    last_change = 0
    for tick, weapon in events_for_seat:
        if tick > end_tick:
            break
        t = last_change
        while embers > 0 and (tick - t) >= HEAT_DECAY_TICKS:
            next_t = t + HEAT_DECAY_TICKS
            occ[heat_rung(embers)] += next_t - cursor
            cursor = next_t
            embers = max(0, embers - HEAT_EMBER_DECAY)
            t = next_t
            last_change = next_t
        if tick > cursor:
            occ[heat_rung(embers)] += tick - cursor
            cursor = tick
        embers = min(HEAT_EMBER_CAP, embers + 1)
        last_change = tick
    t = last_change
    while embers > 0 and (end_tick - t) >= HEAT_DECAY_TICKS:
        next_t = t + HEAT_DECAY_TICKS
        if next_t > end_tick:
            break
        occ[heat_rung(embers)] += next_t - cursor
        cursor = next_t
        embers = max(0, embers - HEAT_EMBER_DECAY)
        t = next_t
    if end_tick > cursor:
        occ[heat_rung(embers)] += end_tick - cursor
    return occ


def analyze_episode(ep, jsonl_path):
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        return None
    n = len(summary["slot_team"])
    ticks = summary["ticks"]
    winner_team = summary.get("winner")
    slot_team = summary["slot_team"]
    winner_slots = ({i for i, t in enumerate(slot_team) if t == winner_team}
                     if winner_team else set())

    product = {s: 1 for s in range(n)}
    ff = {s: 0 for s in range(n)}
    deed_counts_per_seat = defaultdict(Counter)
    ach_counts_per_seat = defaultdict(Counter)
    heat_events_per_seat = defaultdict(list)
    closing_time_amt = defaultdict(int)
    jointact_amt = defaultdict(int)
    death_tick = {}

    for e in lines:
        kind = e.get("kind")
        if kind == "death":
            tgt = e.get("target")
            if tgt is not None and 0 <= tgt < n and tgt not in death_tick:
                death_tick[tgt] = e.get("tick")
        if kind not in ("glory_deed", "achievement"):
            continue
        t = e.get("target")
        if t is None or t < 0 or t >= n:
            continue
        weapon = e.get("weapon", "")
        amt = e.get("amount") or 0
        if kind == "glory_deed":
            deed_counts_per_seat[t][weapon] += 1
            if weapon in HEAT_PAYING_DEEDS:
                heat_events_per_seat[t].append((e.get("tick"), weapon))
            if weapon == "dTeamKill":
                ff[t] += 1
            elif amt and amt > 1:
                product[t] *= amt
            if weapon == "dClosingTime":
                closing_time_amt[t] = (closing_time_amt[t] or 1) * max(amt, 1)
            if weapon == "dJointAct":
                jointact_amt[t] = (jointact_amt[t] or 1) * max(amt, 1)
        else:  # achievement -- folds into the SAME product (see README)
            ach_counts_per_seat[t][weapon] += 1
            if amt and amt > 1:
                product[t] *= amt

    rows = []
    reported_map = {s["position"]: s["score"] for s in ep.get("participant_scores") or []}
    for s in range(n):
        p = product[s]
        h = ff[s]
        recon = p >> h if h else p
        win_mult = 8 if s in winner_slots else 1
        uncapped = recon * win_mult
        final = min(uncapped, CAP)
        heat_occ = heat_occupancy_for_seat(sorted(heat_events_per_seat[s]), ticks)
        rows.append(dict(
            episode_id=ep["episode_id"], round_number=ep["round_number"],
            coworld_version=ep["coworld_version"], slot=s,
            reported=reported_map.get(s), recon_final=final,
            win=(s in winner_slots), capped=(uncapped >= CAP),
            deed_counts=dict(deed_counts_per_seat[s]),
            ach_counts=dict(ach_counts_per_seat[s]),
            closing_time_amt=closing_time_amt.get(s, 0),
            jointact_amt=jointact_amt.get(s, 0),
            heat_occ=dict(heat_occ),
            alive_ticks=death_tick.get(s, ticks),
            episode_ticks=ticks,
        ))
    return rows, summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", required=True,
                     help="JSON list of episode dicts (see module docstring)")
    ap.add_argument("--version-extractor", action="append", required=True,
                     help="VERSION=/path/to/extract_events, repeatable")
    ap.add_argument("--cache-dir", default=os.path.expanduser(
        "~/.ctf/scout/glory_census_replays"))
    ap.add_argument("--out", default="/tmp/glory-census/seat_episode_rows.json")
    ap.add_argument("--workers", type=int, default=16)
    args = ap.parse_args()

    os.makedirs(args.cache_dir, exist_ok=True)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    ver_to_extractor = {}
    for spec in args.version_extractor:
        ver, path = spec.split("=", 1)
        ver_to_extractor[ver] = path

    with open(args.episodes) as f:
        episodes = json.load(f)
    print(f"loaded {len(episodes)} episodes", file=sys.stderr)

    def worker(ep):
        extractor = ver_to_extractor.get(ep["coworld_version"])
        if not extractor:
            return ep["episode_id"], None, f"no extractor for {ep['coworld_version']}"
        try:
            rp = download_replay(ep["replay_url"], ep["episode_id"], args.cache_dir)
        except Exception as e:  # noqa: BLE001
            return ep["episode_id"], None, f"download: {e}"
        jp, err = extract(rp, extractor, ep["episode_id"], args.cache_dir)
        if err:
            return ep["episode_id"], None, f"extract: {err}"
        return ep["episode_id"], jp, None

    jsonl_paths, errors = {}, []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(worker, ep): ep for ep in episodes}
        for fut in cf.as_completed(futs):
            eid, jp, err = fut.result()
            (errors.append((eid, err)) if err else jsonl_paths.__setitem__(eid, jp))

    print(f"decoded {len(jsonl_paths)} / {len(episodes)}; errors {len(errors)}",
          file=sys.stderr)
    for eid, err in errors[:20]:
        print(f"  ERR {eid}: {err}", file=sys.stderr)

    all_rows, bad_eps = [], []
    for ep in episodes:
        jp = jsonl_paths.get(ep["episode_id"])
        if not jp:
            continue
        try:
            rows, _summary = analyze_episode(ep, jp)
        except Exception as e:  # noqa: BLE001
            bad_eps.append((ep["episode_id"], str(e)))
            continue
        all_rows.extend(rows)

    print(f"analyzed episodes ok; bad: {len(bad_eps)}", file=sys.stderr)
    for eid, err in bad_eps[:20]:
        print(f"  BAD {eid}: {err}", file=sys.stderr)

    with open(args.out, "w") as f:
        json.dump(all_rows, f)
    print(f"wrote {len(all_rows)} seat-episode rows to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
