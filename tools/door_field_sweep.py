#!/usr/bin/env python3
"""⭐ ENTRY-Y ACROSS THE REAL PARTNERED-BOARD POPULATION (one-door break).

The mirror on generated maps could not score the one-door funnel: its BEFORE
entry-y stdev is 140-205px where the field defect shows 5-31px. But the defect
does not need a mirror — every league replay is public, re-simulable, and
hash-checked, so the BEFORE arm can be read straight off the field.

What this sweeps is not "episodes vs daveey" (there are two) but the STRUCTURAL
population: every episode where the league deals us only teamSeats 0..3 and the
other four seats of our own team are `daveey · paintbot-baseline` league filler.
On that board `roleForSeat`'s prefix is the whole deal we ever get.

⚠️ DENOMINATOR TRAP: `variant_name` does NOT determine seat count. 100 of these
140 episodes are labelled "1v1 (8 per team)" while dealing us four bots, and 40
are labelled "2v2". Group by the OBSERVED seat set, never the label.

⚠️ Reads the ~/.ctf/scout round cache and public S3 only. It never touches the
league API and never writes into coworld-ctf.

  tools/door_field_sweep.py --list          # population census, no re-sim
  tools/door_field_sweep.py --run  [--limit N]
"""
import argparse
import collections
import concurrent.futures as futures
import json
import glob
import math
import os
import re
import subprocess
import sys
import urllib.request

ROUNDS = os.path.expanduser("~/.ctf/scout/rounds")
REPLAYS = os.path.expanduser("~/.ctf/scout/replays")
OURS = "softmaxwell"
FILLER_POLICY = "paintbot-baseline"
ENTRY_BIN = "/tmp/door_entry.out"


def census():
    """Every cached episode we are in, bucketed by the OBSERVED seat set."""
    out = collections.defaultdict(list)
    for f in sorted(glob.glob(f"{ROUNDS}/r*_round_*.json")):
        rnum = int(re.match(r"r(\d+)_", os.path.basename(f)).group(1))
        try:
            eps = json.load(open(f))
        except (OSError, ValueError):
            continue
        for i, e in enumerate(eps):
            parts = e.get("participants") or []
            mine = sorted(p["position"] for p in parts
                          if p["player_name"] == OURS)
            if not mine:
                continue
            n = len(parts)
            if n == 16 and len(mine) == 8:
                shape = "h2h (all 8 seats)"
            elif n == 16 and len(mine) == 4 and mine[1] - mine[0] == 2:
                shape = "partnered 2-team (teamSeats 0-3)"
            elif n == 16 and len(mine) == 4 and mine[1] - mine[0] == 4:
                shape = "ffa4 (teamSeats 0-3)"
            else:
                shape = f"other (slots={n}, ours={len(mine)})"
            out[shape].append((rnum, i, e, mine))
    return out


def opponent(e, mine):
    """The opposing team's REAL policy (not the league's filler baseline)."""
    par = mine[0] % 2
    bypol = collections.defaultdict(list)
    for p in e.get("participants") or []:
        bypol[(p["player_name"], p.get("policy_name"))].append(p["position"])
    for k, v in bypol.items():
        if k[1] != FILLER_POLICY and k[0] != OURS and all(x % 2 != par for x in v):
            return f"{k[0]} · {k[1]}"
    return "?"


def fetch(e):
    if not e.get("replay_url"):
        return None
    name = e["replay_url"].split("/")[-1]
    p = f"{REPLAYS}/{name}"
    if os.path.exists(p) and os.path.getsize(p) > 0:
        return p
    try:
        with urllib.request.urlopen(e["replay_url"], timeout=90) as r:
            data = r.read()
        with open(p + ".part", "wb") as f:
            f.write(data)
        os.replace(p + ".part", p)
        return p
    except Exception as ex:  # noqa: BLE001 — a dead URL must not kill the sweep
        print(f"  download failed {name[:8]}: {ex}", file=sys.stderr)
        return None


ROW = re.compile(
    r"depth\s+(\d+)\s+(OURS|THEIRS)\s+n=(\d+)\s+ENTRY-Y mean\s+(-?[\d.]+?)\s+"
    r"STDEV\s+(-?[\d.]+?)\s+span")

# ⚠️ ENGINE HORIZON. A replay only re-simulates on its recording GameVersion,
# and door_replay_entry opens with mismatchQuit=true — a foreign build ABORTS
# rather than returning a plausible wrong number. Read off the cached replay
# headers: every 0.7.228/0.7.229 recording is GV43, and the next-newest cached
# build is GV40. This checkout is GV43 (src/ctf/sim_types.nim), so the
# re-simulable corpus is exactly these two coworld builds.
GV43_BUILDS = {"0.7.228", "0.7.229"}


def resim(job):
    rnum, i, e, mine = job
    src = fetch(e)
    if not src:
        return None
    par = mine[0] % 2
    theirs = [x for x in range(8) if x % 2 != par]
    r = subprocess.run(
        [ENTRY_BIN, src, "--ours", ",".join(map(str, mine)),
         "--theirs", ",".join(map(str, theirs)), "--depth", "0,45,90,135",
         "--label", f"r{rnum} idx{i}"],
        capture_output=True, text=True)
    if r.returncode != 0:
        # A GameVersion mismatch lands here: openReplay runs mismatchQuit=true,
        # so a replay recorded on another engine ABORTS rather than returning a
        # plausible wrong number. That is the point — non-evidence, not data.
        return {"round": rnum, "idx": i, "error":
                (r.stdout + r.stderr).strip().splitlines()[-1:] or ["rc"]}
    res = {"round": rnum, "idx": i, "opp": opponent(e, mine),
           "variant": e.get("variant_name"), "cw": e.get("coworld_version"),
           "map": "", "depths": {}}
    for line in r.stdout.splitlines():
        if line.strip().startswith("map "):
            res["map"] = line.split()[1]
        m = ROW.search(line)
        if m:
            d, who, n, mean, sd = m.groups()
            res["depths"].setdefault(who, {})[int(d)] = {
                "n": int(n), "mean": float(mean), "stdev": float(sd)}
    return res


def stat(v):
    if not v:
        return (0.0, 0.0)
    m = sum(v) / len(v)
    if len(v) < 2:
        return (m, 0.0)
    return (m, math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shape", default="partnered 2-team (teamSeats 0-3)")
    ap.add_argument("--out", default="/tmp/door_field_sweep.json")
    a = ap.parse_args()

    buckets = census()
    print("=== POPULATION (cached rounds, grouped by OBSERVED seat set) ===")
    for k, v in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        cw = collections.Counter(e.get("coworld_version") for _, _, e, _ in v)
        print(f"  {len(v):5d}  {k:36s}  engines {cw.most_common(3)}")
    jobs = buckets[a.shape]
    var = collections.Counter(e.get("variant_name") for _, _, e, _ in jobs)
    print(f"\n=== {a.shape}: n={len(jobs)} ===")
    print("  variant_name labels (the DENOMINATOR TRAP — the label is not the "
          "seat count):")
    for k, v in var.most_common():
        print(f"    {v:5d}  {k!r}")
    opp = collections.Counter(opponent(e, m) for _, _, e, m in jobs)
    print("  opponents:", opp.most_common(8))
    if a.list:
        return

    skipped = [j for j in jobs if j[2].get("coworld_version") not in GV43_BUILDS]
    jobs = [j for j in jobs if j[2].get("coworld_version") in GV43_BUILDS]
    if skipped:
        cw = collections.Counter(e.get("coworld_version") for _, _, e, _ in skipped)
        print(f"  engine horizon: {len(skipped)} episode(s) recorded on a "
              f"pre-GV43 build are NON-EVIDENCE, not data: {cw.most_common(5)}")
    if a.limit:
        jobs = jobs[:a.limit]
    print(f"\nre-simulating {len(jobs)} episodes ...", file=sys.stderr)
    got = []
    with futures.ThreadPoolExecutor(max_workers=8) as pool:
        for r in pool.map(resim, jobs):
            if r:
                got.append(r)
    json.dump(got, open(a.out, "w"))
    ok = [r for r in got if "depths" in r]
    bad = [r for r in got if "error" in r]
    print(f"re-simulated OK {len(ok)}, engine-mismatch/failed {len(bad)}")

    print("\n=== ENTRY-Y BY DEPTH — OUR seats (teamSeats 0-3) ===")
    print("depth   eps   entries   mean stdev-of-y (per episode)   "
          "median   <=31px   >=100px")
    for d in (0, 45, 90, 135):
        sds, ns = [], 0
        for r in ok:
            row = r["depths"].get("OURS", {}).get(d)
            if row and row["n"] >= 3:
                sds.append(row["stdev"])
                ns += row["n"]
        if not sds:
            continue
        sds.sort()
        m, _ = stat(sds)
        med = sds[len(sds) // 2]
        tight = sum(1 for x in sds if x <= 31)
        wide = sum(1 for x in sds if x >= 100)
        print(f"{d:>5} {len(sds):>5} {ns:>9}   {m:>26.1f} {med:>8.1f} "
              f"{tight:>8} {wide:>9}")
    print("\n=== same, for the OPPOSING team's four seats (control) ===")
    for d in (0, 45, 90, 135):
        sds, ns = [], 0
        for r in ok:
            row = r["depths"].get("THEIRS", {}).get(d)
            if row and row["n"] >= 3:
                sds.append(row["stdev"])
                ns += row["n"]
        if not sds:
            continue
        sds.sort()
        m, _ = stat(sds)
        print(f"{d:>5} {len(sds):>5} {ns:>9}   {m:>26.1f} "
              f"{sds[len(sds)//2]:>8.1f}")


if __name__ == "__main__":
    main()
