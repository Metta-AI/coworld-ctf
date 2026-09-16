#!/usr/bin/env python3
"""GLORY GRADIENT S1 ADDENDUM: decompose the census's recut product into its
deed-contribution vs achievement-contribution factors, per seat-episode.

Reuses the SAME population, SAME cached extraction as
`tools/glory/census_decode.py` / `census_analyze.py` (era: GloryVersion 15,
coworld_version 0.7.361-0.7.367, rounds r4515-r4539, 305 episodes, 4,880
seat-episodes) -- it does not re-download or re-extract anything. It reads:

  1. `--rows` (census_decode.py's output, e.g. seat_episode_rows_final.json)
     for the validated `reported`/`recon_final`/`win` fields per seat-episode
     -- the population list and the reconciliation ground truth.
  2. `--cache-dir` (census_decode.py's replay/jsonl cache) to re-walk each
     episode's already-extracted event stream and split the SAME product
     fold `census_decode.analyze_episode` performs into two running
     factors -- `deed_product` (glory_deed events, amount>1, excluding the
     dTeamKill division) and `ach_product` (achievement events, amount>1)
     -- plus a per-(tree,tier) mint ledger read directly off each
     achievement event's `weapon` (tree name) and `hp` (tier index 0-4)
     fields, verified against src/ctf/sim.nim's `claimAchievement` emitter
     (`emitEvent(Achievement, weapon = $tree, hp = tier, blocked =
     ord(effectiveFirst), amount = factor)`).

No sim/scoring code is touched; this only re-reads already-produced replay
extractions and the committed row file.

Usage:
  python3 census_achievements.py --rows seat_episode_rows_final.json \\
      --cache-dir ~/.ctf/scout/glory_census_replays \\
      --out /tmp/glory-achv/achievement_rows.json
"""
import argparse
import json
import math
import os
import statistics
from collections import Counter, defaultdict

CAP = 2 ** 24

TREES = [
    "treeGun", "treeSpray", "treeGrenade", "treeShield", "treeMedKit",
    "treeCarrier", "treeDefender", "treeSquad",
]
TIER_NAMES = ["I", "II", "III", "IV", "V"]
RECUT_TIER_CLASS = [1, 1, 2, 2, 4]  # src/ctf/glory.nim:2555


def decompose_episode(jsonl_path):
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        return None
    n = len(summary["slot_team"])

    deed_product = {s: 1 for s in range(n)}
    ach_product = {s: 1 for s in range(n)}
    ff = {s: 0 for s in range(n)}
    ach_mints = defaultdict(list)  # seat -> [(tree, tier, amount, first)]

    for e in lines:
        kind = e.get("kind")
        if kind not in ("glory_deed", "achievement"):
            continue
        t = e.get("target")
        if t is None or t < 0 or t >= n:
            continue
        weapon = e.get("weapon", "")
        amt = e.get("amount") or 0
        if kind == "glory_deed":
            if weapon == "dTeamKill":
                ff[t] += 1
            elif amt and amt > 1:
                deed_product[t] *= amt
        else:  # achievement
            tier = e.get("hp")
            first = bool(e.get("blocked"))
            ach_mints[t].append((weapon, tier, amt, first))
            if amt and amt > 1:
                ach_product[t] *= amt

    rows = []
    for s in range(n):
        rows.append(dict(
            episode_id=None, slot=s,
            deed_product=deed_product[s], ach_product=ach_product[s],
            ff_halvings=ff[s], ach_mints=ach_mints[s],
        ))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", required=True,
                     help="census_decode.py output (validated ground truth)")
    ap.add_argument("--cache-dir", default=os.path.expanduser(
        "~/.ctf/scout/glory_census_replays"))
    ap.add_argument("--out", default="/tmp/glory-achv/achievement_rows.json")
    args = ap.parse_args()

    with open(args.rows) as f:
        census_rows = json.load(f)
    by_ep_slot = {(r["episode_id"], r["slot"]): r for r in census_rows}
    episode_ids = sorted(set(r["episode_id"] for r in census_rows))

    all_rows = []
    mismatches = []
    for eid in episode_ids:
        jp = os.path.join(args.cache_dir, f"{eid}.jsonl")
        if not os.path.exists(jp):
            print(f"MISSING jsonl for {eid}", flush=True)
            continue
        decomposed = decompose_episode(jp)
        if decomposed is None:
            continue
        for d in decomposed:
            key = (eid, d["slot"])
            census = by_ep_slot.get(key)
            if census is None:
                continue
            d["episode_id"] = eid
            d["round_number"] = census["round_number"]
            d["win"] = census["win"]
            d["reported"] = census["reported"]
            d["recon_final"] = census["recon_final"]
            # cross-check: deed_product * ach_product, ff-halved, win-multiplied,
            # capped, must equal the ALREADY-VALIDATED recon_final. This is not
            # a new reconciliation against the platform -- census_decode.py did
            # that -- it only confirms this script's split recombines to the
            # SAME number census_decode.py's single combined product produced.
            combined = d["deed_product"] * d["ach_product"]
            recon = combined >> d["ff_halvings"] if d["ff_halvings"] else combined
            win_mult = 8 if d["win"] else 1
            recon = min(recon * win_mult, CAP)
            if census["recon_final"] is not None and recon != census["recon_final"]:
                mismatches.append((eid, d["slot"], recon, census["recon_final"]))
            all_rows.append(d)

    print(f"decomposed {len(all_rows)} seat-episodes across {len(episode_ids)} episodes")
    print(f"split-vs-combined mismatches: {len(mismatches)}")
    for m in mismatches[:10]:
        print("  MISMATCH", m)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(all_rows, f)
    print(f"wrote {len(all_rows)} rows to {args.out}")


if __name__ == "__main__":
    main()
