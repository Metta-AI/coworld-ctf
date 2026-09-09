#!/usr/bin/env python3
"""Walk a division's completed rounds backward and map each distinct
coworld_version to its source commit, so a scoring-era cohort (matching
GloryVersion, not just build number) can be picked out by hand with `git
diff` on src/ctf/{glory,sim,sim_types}.nim between candidate commits.

Usage (needs the cogherence player's venv, which holds the working login):
  ~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python \\
      discover_cohort.py --division div_... --scan-rounds 600 \\
      --out-scan /tmp/glory-census/cohort_scan.log \\
      --out-versions /tmp/glory-census/version_to_sha.json

`/v2/rounds` pages via `cursor` (the `next_cursor` response field is NOT
also the request param name -- passing `next_cursor=` back silently gets
page 1 forever, which reads exactly like a platform paging bug). Division
leaderboard's `include_recent_rounds` is a BOOLEAN as of the current
openapi.json, not a count -- an int there 422s.
"""
import argparse
import json
import os
import sys
import concurrent.futures as cf

sys.path.insert(0, os.path.expanduser("~/projects/coworld-ctf/tools/ladder"))
import ctfapi  # noqa: E402


def list_rounds_desc(division_id, limit):
    out, cursor = [], None
    while len(out) < limit:
        q = f"/v2/rounds?division_id={division_id}&status=completed&limit=100"
        if cursor:
            q += f"&cursor={cursor}"
        r = ctfapi.get(q)
        entries = r.get("entries") or []
        out += entries
        cursor = r.get("next_cursor")
        if not cursor or not entries:
            break
    return out


def round_version(r):
    rid = r["id"]
    try:
        eps = ctfapi.episodes(rid, limit=1000)
    except Exception as e:  # noqa: BLE001
        return rid, r.get("round_number"), None, f"ERR:{e}"
    comp = [e for e in eps if e.get("status") == "completed"]
    vers = sorted(set(e.get("coworld_version") for e in comp if e.get("coworld_version")))
    ver = vers[0] if len(vers) == 1 else ("MIXED:" + ",".join(vers) if vers else None)
    return rid, r.get("round_number"), ver, len(comp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--division", required=True)
    ap.add_argument("--scan-rounds", type=int, default=600)
    ap.add_argument("--out-scan", default="/tmp/glory-census/cohort_scan.log")
    ap.add_argument("--out-versions", default="/tmp/glory-census/version_to_sha.json")
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out_scan), exist_ok=True)

    rs = list_rounds_desc(args.division, args.scan_rounds)
    rs.sort(key=lambda r: r.get("round_number") or 0, reverse=True)
    print(f"fetched {len(rs)} rounds, range r{rs[-1].get('round_number')}-"
          f"r{rs[0].get('round_number')}", file=sys.stderr)

    results = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(round_version, r): r for r in rs}
        for fut in cf.as_completed(futs):
            results.append(fut.result())
    results.sort(key=lambda x: x[1] or 0, reverse=True)

    with open(args.out_scan, "w") as f:
        for rid, rn, ver, n in results:
            f.write(f"{rn} {rid} {ver} {n}\n")
    print(f"wrote {args.out_scan}", file=sys.stderr)

    # one round id per distinct clean (non-MIXED) version -> coworld_id -> sha
    by_version_round = {}
    for rid, rn, ver, n in results:
        if not ver or ver.startswith("MIXED"):
            continue
        by_version_round.setdefault(ver, rid)

    version_to_sha = {}
    for ver, rid in by_version_round.items():
        try:
            eps = ctfapi.episodes(rid, limit=5)
            comp = [e for e in eps if e.get("status") == "completed"]
            if not comp:
                continue
            cid = comp[0].get("coworld_id")
            cw = ctfapi.get(f"/v2/coworlds/{cid}")
            url = cw.get("manifest", {}).get("game", {}).get("runnable", {}).get("source_url", "")
            sha = url.rstrip("/").split("/")[-1] if url else ""
            version_to_sha[ver] = sha
        except Exception as e:  # noqa: BLE001
            version_to_sha[ver] = f"ERR:{e}"

    with open(args.out_versions, "w") as f:
        json.dump(version_to_sha, f, indent=2)
    for ver, sha in sorted(version_to_sha.items()):
        print(ver, sha)


if __name__ == "__main__":
    main()
