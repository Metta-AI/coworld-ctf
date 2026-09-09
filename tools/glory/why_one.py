#!/usr/bin/env python3
"""THE WHOLE / Phase 2b — "why #1 is #1".

Owner's favourite legibility idea (epic 16d081ab, task 49c180ac): an
expandable row under the standings leader. DEEDS come first (causal,
derivable now, from real replays — what this script does). The brain's
STYLE (heat/carry/ally-stack/enemy-ground tempo) is a v2 placeholder that
needs S3 risk bands first; see docs/designs/WHY_ONE.md.

Read-only against the live platform. Never POSTs, never writes to the
league. Reuses tools/ladder/{ctfapi,standing_replay}.py already in this
repo for API access, round-window pulls, and the served EMA math
(rated_k / rated_clamp_multiple / sum_top_k — see standing_replay.py's own
module doc for how that formula was recovered from the live served
config). The deed-level decode below is a SECOND pass alongside the now-
landed `tools/glory/census_decode.py` (PR #483, merged to main as of this
writing) -- it fold-and-reconciles the SAME way (seed 1, fold amount>1,
halve per friendly-fire, x8 on win, cap at 2^24) and cross-checks against
it directly (see `try_extract_and_decode`), but needs its OWN pass over
the raw events because census_decode's aggregate counters (`deed_counts`,
`ach_counts`) don't retain the per-mint detail this row needs: each deed's
own magnitude (not just a count) and each achievement's tier index +
first-claim flag (not just a tally). The achievements addendum (PR #488,
branch `maxwell/glory-achievements`) and the S1b attribution work (branch
`maxwell/glory-attribution`) are NOT yet merged; this tool has no
dependency on either. Full write-up: docs/designs/WHY_ONE.md.

WHAT THIS DOES NOT DO (v1 scope, deliberate — see WHY_ONE.md "style v2"):
it reports each deed's OWN folded `amount` (which already has ground/heat/
carry/ally-stack multipliers baked in by the sim at mint time) as ONE
number per deed. It does not peel those situational modifiers apart --
that decomposition exists (S1b `attribution_decompose.py`, branch
`maxwell/glory-attribution`) but needs a PRIVATE, ANALYSIS-ONLY
instrumented extractor binary that is not on this branch and is exactly
the "brain's style" half of the row, deferred to v2 per the owner's
5-whys decision.

Usage:
  python3 why_one.py --rank 1 --window 150 \\
      --extractor 0.7.361-0.7.367=~/.ctf/pipeline-loop/tools/census_gv59_gv15_build/bin/extract_events \\
      --extractor 0.7.361-0.7.367=~/.ctf/pipeline-loop/tools/census_gv60_build/bin/extract_events \\
      --out /tmp/why_one/rank1.json

With no --extractor given, the script tries the two well-known local
paths above (this census's own binaries) if they exist, and otherwise
still produces the recency/EMA/cap-hit section from platform data alone
(no replay decode needed for THAT part -- see below) and reports the
deed-decode as a named gap instead of guessing.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "ladder"))
import ctfapi  # noqa: E402
import standing_replay as sr  # noqa: E402
import census_decode  # noqa: E402 -- same directory, PR #483, merged to main

CAP = 2 ** 24
PAINTBOT_LEAGUE = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"

DEFAULT_EXTRACTORS = [
    os.path.expanduser("~/.ctf/pipeline-loop/tools/census_gv59_gv15_build/bin/extract_events"),
    os.path.expanduser("~/.ctf/pipeline-loop/tools/census_gv60_build/bin/extract_events"),
]

# Public tagging vocabulary (matches the shipped S1 cheatsheet's own words,
# docs/designs/season2-cheatsheet.html, plus the S2 placement-ladder /
# co-engagement deeds it predates). Internal Deed enum name -> public label.
# Never show the left column to a stranger; it exists here only so this
# tool's own output is auditable against src/ctf/glory.nim.
PUBLIC_DEED_LABEL = {
    "dFirstBlood": "FIRST!", "dHonorableKill": "TAG", "dSprayKill": "SPRAYED",
    "dGrenadeKill": "BOMBED", "dPointBlankKill": "POINT-BLANK",
    "dLongshotKill": "LONGSHOT", "dSplashMultiKill": "MULTI!",
    "dRevengeKill": "PAYBACK", "dRunDown": "CHASE", "dAceTag": "BOUNTY",
    "dFlagSteal": "STEAL", "dCapture": "CAPTURE", "dCarrierKill": "PEEL",
    "dDenial": "DENIED!", "dEscortKill": "ESCORT", "dAssist": "ASSIST",
    "dRescue": "RESCUE", "dShieldSoak": "SHIELD SOAK", "dWipe": "WIPEOUT",
    "dDuoDown": "DOWNED (DUO)",
    "dClosingTime": "CLOSING",   # survived a tick of the tightening zone
    "dLastLight": "LAST LIGHT",  # last one standing in the final circle
    "dJointAct": "CROSSFIRE",    # co-engagement with a pact partner
    "dFinal8": "FINAL 8", "dFinal4": "FINAL 4", "dFinal2": "FINAL 2",
    "dTeamKill": "OWN PAINT", "dLevelUp": None, "dClutchHeal": "CLUTCH HEAL",
}
# Per-tree tier names, I..V, verbatim from the shipped S1 cheatsheet
# (docs/designs/season2-cheatsheet.html) -- the only public names that
# exist for these achievements. treeShield/treeCarrier/treeDefender/
# treeMedKit are DEAD in 16-solo BR (see the scoring reference) so they
# never appear in a live decode and are omitted.
ACH_TIER_NAMES = {
    "treeGun": ["First Tag", "Marksman", "Bounty", "Sharpshooter", "Longshot"],
    "treeSpray": ["First Coat", "Full Coverage", "Repainted", "The Muralist", "Double Splash"],
    "treeGrenade": ["Delivery", "Splatterbomb", "Blast Radius", "Double Blast", "The Bombardier"],
    "treeSquad": ["Kitted", "Full Loadout", "Full Kit", "Clean Sheet", "Victory Lap"],
}


def resolve_division(league, name="Competition"):
    """GET /v2/divisions?league_id=... -- the generic (not hardcoded)
    league->division lookup; verified live against league_b8fa9b35."""
    rows = ctfapi.get(f"/v2/divisions?league_id={league}")
    if isinstance(rows, dict):
        rows = rows.get("entries") or rows.get("data") or []
    for r in rows:
        if r.get("name") == name:
            return r["id"]
    if rows:
        return rows[0]["id"]
    raise SystemExit(f"no division found for league {league}")


def get_leaderboard(division):
    r = ctfapi.get(f"/v2/divisions/{division}/leaderboard?include_recent_rounds=true")
    return r if isinstance(r, list) else (r.get("entries") or r.get("rows") or [])


def list_rounds_for_division(division):
    """Cursor-paginated /v2/rounds?division_id=..., deduped -- same method
    as standing_replay.list_division_rounds(), parameterized so this tool
    is not locked to one league."""
    cursor, seen, out = None, set(), []
    while True:
        path = f"/v2/rounds?division_id={division}&limit=100"
        if cursor:
            from urllib.parse import quote
            path += f"&cursor={quote(cursor, safe='')}"
        page = ctfapi.get(path)
        entries = page.get("entries") or []
        if not entries:
            break
        for e in entries:
            if e["id"] not in seen:
                seen.add(e["id"])
                out.append(e)
        cursor = page.get("next_cursor")
        if not cursor:
            break
    return out


def pull_window(division, window, verbose=True):
    """Last `window` completed rounds for this division, in the SAME shape
    as standing_replay.pull_ledger()'s `rounds` list (round_number,
    round_id, completed_at, coworld_version, reported{pid:...}, legs{pid:[...]}).
    Reuses standing_replay's own per-round caches (keyed by round_id, not
    division) so a repeat run against the same rounds is free."""
    all_rounds = list_rounds_for_division(division)
    completed = [r for r in all_rounds if r.get("status") == "completed"]
    completed.sort(key=lambda r: r.get("round_number") or -1)
    wanted = completed[-window:]
    if verbose:
        print(f"[why_one] {len(wanted)} completed rounds "
              f"(r{wanted[0]['round_number']}-r{wanted[-1]['round_number']}) "
              f"of {len(completed)} total in division", file=sys.stderr)

    rounds_out = []
    for i, r in enumerate(wanted):
        rid = r["id"]
        detail = sr._cached_detail(rid)
        eps = sr._cached_episodes(rid)
        reported = {}
        for row in detail.get("results") or []:
            player, pv = row.get("player") or {}, row.get("policy_version") or {}
            pid = player.get("id")
            if not pid:
                continue
            reported[pid] = {"score": row.get("score"), "rank": row.get("rank"),
                              "label": pv.get("label"), "pv_id": pv.get("id"),
                              "pv_version": pv.get("version"),
                              "player_name": player.get("name")}
        legs, versions = {}, []
        for ep in eps:
            if ep.get("status") != "completed":
                continue
            if ep.get("coworld_version"):
                versions.append(ep["coworld_version"])
            pos_to_player = {p.get("position"): p.get("player_id")
                              for p in (ep.get("participants") or [])
                              if not p.get("is_filler")}
            for ps in ep.get("participant_scores") or []:
                pid = pos_to_player.get(ps.get("position"))
                if pid is not None:
                    legs.setdefault(pid, []).append(ps.get("score"))
        import statistics
        rounds_out.append({
            "round_number": r["round_number"], "round_id": rid,
            "completed_at": r.get("completed_at"),
            "coworld_version": statistics.mode(versions) if versions else None,
            "reported": reported, "legs": legs,
        })
        if verbose and (i + 1) % 50 == 0:
            print(f"[why_one] {i+1}/{len(wanted)} rounds fetched", file=sys.stderr)
    return rounds_out


def ema_weighted_contributions(rounds, target_pid):
    """Replay the served EMA (standing_replay.replay, rated_k=0.05,
    clamp_M=150, top_k=12 as of 2026-09-08's live settings) over `rounds`,
    then estimate each round's SHARE of the final standing via the closed
    -form EMA weight rated_k*(1-rated_k)^(n-1-i) -- an approximation that
    ignores clamp interactions (label per house style: this is a labeled
    estimate, not exact, because a clamp can silently cap a round's
    contribution below its raw score). Returns (final_standing,
    sorted_weighted_rounds, reconstruction_note)."""
    history, contributions = sr.replay(rounds, rated_k=sr.CURRENT["rated_k"],
                                        clamp_M=sr.CURRENT["clamp_M"],
                                        top_k=sr.CURRENT["top_k"])
    if not history:
        return None, [], "no rounds in window"
    _, final_standing = history[-1]
    target_final = final_standing.get(target_pid)
    contribs = contributions.get(target_pid, [])
    n = len(contribs)
    weighted = []
    for i, (rn, clipped) in enumerate(contribs):
        w = sr.CURRENT["rated_k"] * (1 - sr.CURRENT["rated_k"]) ** (n - 1 - i)
        weighted.append((rn, clipped, w, w * clipped))
    total_est = sum(x[3] for x in weighted) or 1.0
    weighted.sort(key=lambda x: -x[3])
    rank1_streak = 0
    for rn, snap in reversed(history):
        order = sorted(snap.items(), key=lambda kv: -kv[1])
        if order and order[0][0] == target_pid:
            rank1_streak += 1
        else:
            break
    return target_final, [
        {"round_number": rn, "clipped_round_score": clipped, "ema_weight": w,
         "weighted_contribution": contrib, "share_of_reconstructed": contrib / total_est}
        for rn, clipped, w, contrib in weighted
    ], {"n_rounds_in_window": n, "rank1_streak_in_window": rank1_streak,
        "half_life_rounds": math.log(2) / sr.CURRENT["rated_k"]}


def find_episode_for_leg(round_id, player_id, leg_score):
    """Given a round + player + the exact leg score already known from
    `legs`, find which episode_id/replay_url produced it (legs alone don't
    carry episode_id)."""
    eps = ctfapi.episodes(round_id, limit=1000)
    for ep in eps:
        if ep.get("status") != "completed":
            continue
        pos_to_player = {p.get("position"): p.get("player_id")
                          for p in (ep.get("participants") or [])
                          if not p.get("is_filler")}
        for ps in ep.get("participant_scores") or []:
            if (pos_to_player.get(ps.get("position")) == player_id
                    and ps.get("score") == leg_score):
                return {"episode_id": ep.get("episode_id") or ep.get("id"),
                        "position": ps.get("position"),
                        "replay_url": ep.get("replay_url"),
                        "coworld_version": ep.get("coworld_version")}
    return None


def download(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    with urllib.request.urlopen(url, timeout=90) as r:
        data = r.read()
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return path


def try_extract_and_decode(replay_path, slot, reported_score, extractors, cache_dir,
                            episode_id=None, round_number=None, coworld_version=None):
    """Try each candidate extractor; TRUST a decode only if its
    reconstructed final score reconciles EXACTLY against the platform's
    own `reported_score` (same discipline as census_decode.py's own
    validation gate) -- never trust an unreconciled decode. As a second,
    independent check, also runs the now-landed `census_decode.
    analyze_episode` over the SAME extraction and requires it to compute
    the IDENTICAL `recon_final` -- two independently-written fold
    implementations agreeing is stronger evidence than either alone.
    Returns (deed_row, extractor_used) or (None, error_summary)."""
    errors = []
    for extractor in extractors:
        extractor = os.path.expanduser(extractor)
        if not os.path.exists(extractor):
            continue
        out = os.path.join(cache_dir, os.path.basename(replay_path) + "."
                            + os.path.basename(extractor) + ".jsonl")
        if not (os.path.exists(out) and os.path.getsize(out) > 0):
            r = subprocess.run([extractor, replay_path, "--out", out],
                                capture_output=True, text=True, timeout=60)
            if r.returncode != 0:
                errors.append(f"{extractor}: {(r.stderr or r.stdout).strip()[:200]}")
                continue
        try:
            row = decode_seat(out, slot)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{extractor}: decode error {e}")
            continue
        if reported_score is not None and row["recon_final"] != reported_score:
            errors.append(f"{extractor}: reconciliation MISMATCH "
                           f"(recon={row['recon_final']} reported={reported_score}) "
                           f"-- wrong scoring era for this binary, discarded")
            continue
        try:
            ep_stub = {"episode_id": episode_id, "round_number": round_number,
                       "coworld_version": coworld_version,
                       "participant_scores": [{"position": slot, "score": reported_score}]}
            census_rows, _ = census_decode.analyze_episode(ep_stub, out)
            census_row = next(r for r in census_rows if r["slot"] == slot)
            if census_row["recon_final"] != row["recon_final"]:
                errors.append(f"{extractor}: cross-check MISMATCH against "
                               f"census_decode.py (this tool={row['recon_final']} "
                               f"census_decode={census_row['recon_final']}) -- "
                               f"discarded, two independent folds must agree")
                continue
        except Exception as e:  # noqa: BLE001
            errors.append(f"{extractor}: census_decode cross-check errored: {e} "
                           f"-- discarded, could not independently confirm")
            continue
        return row, extractor
    return None, "; ".join(errors) if errors else "no extractor available locally"


def decode_seat(jsonl_path, slot):
    """Deed-level decode for ONE seat in ONE episode, from a standard
    (non-instrumented) extract_events .jsonl. Mirrors census_decode.py's
    exact product-fold method (PR #483, not merged -- re-derived standalone
    here): seed 1, fold every glory_deed/achievement event's `amount` when
    >1 into one running product, halve per dTeamKill (friendly fire),
    x8 at finalize if this seat won, cap at 2^24. v1 scope: each deed's
    `amount` is reported AS FOLDED (ground/heat/carry/stack already baked
    in by the sim) -- not decomposed further, see module docstring."""
    with open(jsonl_path) as f:
        lines = [json.loads(l) for l in f]
    summary = next((e for e in lines if e.get("type") == "summary"), None)
    if summary is None:
        raise ValueError("no summary event in extraction")
    slot_team = summary["slot_team"]
    winner_team = summary.get("winner")
    won = bool(winner_team) and slot_team[slot] == winner_team

    product, ff_halvings = 1, 0
    deed_amounts = defaultdict(list)   # weapon -> [amount, ...]
    ach_mints = []                     # (tree, tier_idx, amount, first)
    for e in lines:
        if e.get("kind") not in ("glory_deed", "achievement") or e.get("target") != slot:
            continue
        weapon, amt = e.get("weapon", ""), e.get("amount") or 0
        if e["kind"] == "glory_deed":
            if weapon == "dTeamKill":
                ff_halvings += 1
                continue
            deed_amounts[weapon].append(amt)
            if amt and amt > 1:
                product *= amt
        else:
            ach_mints.append((weapon, e.get("hp", -1), amt, bool(e.get("blocked"))))
            if amt and amt > 1:
                product *= amt

    recon_uncapped = (product >> ff_halvings) if ff_halvings else product
    recon_uncapped *= 8 if won else 1
    recon_final = min(recon_uncapped, CAP)

    return {"slot": slot, "won": won, "ff_halvings": ff_halvings,
            "deed_amounts": {k: v for k, v in deed_amounts.items()},
            "ach_mints": ach_mints, "recon_uncapped": recon_uncapped,
            "recon_final": recon_final, "capped": recon_uncapped >= CAP,
            "episode_ticks": summary.get("ticks")}


def public_deed_line(weapon, amounts):
    label = PUBLIC_DEED_LABEL.get(weapon, weapon)
    if label is None:
        return None
    total_log2 = sum(math.log2(a) for a in amounts if a and a > 1)
    n_no_op = sum(1 for a in amounts if not a or a <= 1)
    return {"deed": weapon, "public_label": label, "count": len(amounts),
            "count_no_magnitude": n_no_op, "amounts": amounts,
            "log2_magnitude": total_log2}


def public_ach_line(tree, tier_idx, amount, first):
    names = ACH_TIER_NAMES.get(tree)
    tier_name = names[tier_idx] if names and 0 <= tier_idx < len(names) else f"{tree}[{tier_idx}]"
    return {"tree": tree, "tier_index": tier_idx, "tier_name": tier_name,
            "amount": amount, "first_claim": first,
            "log2_magnitude": math.log2(amount) if amount and amount > 1 else 0.0}


def build_defining_episode_report(row, extractor_used, episode_meta, round_number):
    deed_lines = [d for d in (public_deed_line(w, a) for w, a in row["deed_amounts"].items())
                  if d is not None]
    ach_lines = [public_ach_line(*m) for m in row["ach_mints"]]
    win_log2 = 3.0 if row["won"] else 0.0
    total_log2 = (sum(d["log2_magnitude"] for d in deed_lines)
                  + sum(a["log2_magnitude"] for a in ach_lines) + win_log2)
    for d in deed_lines:
        d["share_of_episode"] = (d["log2_magnitude"] / total_log2) if total_log2 else 0.0
    for a in ach_lines:
        a["share_of_episode"] = (a["log2_magnitude"] / total_log2) if total_log2 else 0.0
    return {
        "round_number": round_number, "episode_id": episode_meta["episode_id"],
        "coworld_version": episode_meta["coworld_version"],
        "extractor_used": os.path.basename(extractor_used),
        "won": row["won"], "capped": row["capped"],
        "recon_final": row["recon_final"], "recon_uncapped": row["recon_uncapped"],
        "ff_halvings": row["ff_halvings"], "episode_ticks": row["episode_ticks"],
        "win_share_of_episode": (win_log2 / total_log2) if total_log2 else 0.0,
        "deeds": sorted(deed_lines, key=lambda d: -d["share_of_episode"]),
        "achievements": sorted(ach_lines, key=lambda a: -a["share_of_episode"]),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--league", default=PAINTBOT_LEAGUE)
    ap.add_argument("--rank", type=int, default=1)
    ap.add_argument("--window", type=int, default=150,
                     help="how many recent completed rounds to pull for the "
                          "EMA/cap-hit scan (default 150; half-life at "
                          "rated_k=0.05 is ~14 rounds, so 150 covers the "
                          "long recency tail with <1%% residual)")
    ap.add_argument("--top-episodes", type=int, default=3,
                     help="how many of the target's highest-scoring episodes "
                          "in the window to decode as 'defining episodes'")
    ap.add_argument("--extractor", action="append", default=[],
                     help="VERSION-RANGE=/path/to/extract_events (repeatable); "
                          "defaults to the two known local census binaries if present")
    ap.add_argument("--replay-cache", default=os.path.expanduser("~/.ctf/scout/why_one_replays"))
    ap.add_argument("--out", default="/tmp/why_one/report.json")
    args = ap.parse_args()

    extractors = [e.split("=", 1)[1] for e in args.extractor] or DEFAULT_EXTRACTORS
    os.makedirs(args.replay_cache, exist_ok=True)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    division = resolve_division(args.league)
    board = get_leaderboard(division)
    board.sort(key=lambda r: r.get("rank") or 999999)
    if len(board) < args.rank + 1:
        raise SystemExit(f"leaderboard only has {len(board)} rows, cannot get rank {args.rank}+1")
    target, rival = board[args.rank - 1], board[args.rank]
    target_pid, rival_pid = target["player_id"], rival["player_id"]
    print(f"[why_one] rank {args.rank}: player_id={target_pid} "
          f"label={target.get('policy_label')} score={target.get('score')}", file=sys.stderr)
    print(f"[why_one] rank {args.rank+1} (rival): player_id={rival_pid} "
          f"label={rival.get('policy_label')} score={rival.get('score')}", file=sys.stderr)

    rounds = pull_window(division, args.window)
    final_standing, weighted, ema_meta = ema_weighted_contributions(rounds, target_pid)

    # Rounds the target actually appears in, with their own top leg per round.
    target_rounds = [r for r in rounds if target_pid in r["legs"]]
    all_legs = []  # (round_number, round_id, coworld_version, leg_score, reported_round_score)
    for r in target_rounds:
        legs = r["legs"][target_pid]
        top_leg = max(legs) if legs else None
        all_legs.append((r["round_number"], r["round_id"], r["coworld_version"],
                          top_leg, r["reported"].get(target_pid, {}).get("score")))
    cap_hits_in_window = sum(1 for x in all_legs if x[3] is not None and x[3] >= CAP)

    # "Defining" = highest EMA-WEIGHTED contribution to the CURRENT standing,
    # not raw leg magnitude -- several rounds can tie at the exact product
    # cap (2^24), and a stale round from months ago that hit the cap once
    # explains today's lead far less than a recent one (`weighted` is
    # already sorted by weighted_contribution, i.e. recency-adjusted). Ties
    # at the cap are broken by recency this way, not round order.
    all_legs_by_round = {x[0]: x for x in all_legs}
    defining = []
    for w in weighted:
        entry = all_legs_by_round.get(w["round_number"])
        if entry is not None:
            defining.append(entry)
        if len(defining) >= args.top_episodes:
            break

    defining_reports, gaps = [], []
    for round_number, round_id, cv, leg_score, reported_round_score in defining:
        meta = find_episode_for_leg(round_id, target_pid, leg_score)
        if meta is None:
            gaps.append({"round_number": round_number, "reason": "episode lookup failed"})
            continue
        replay_path = os.path.join(args.replay_cache, f"{meta['episode_id']}.replay")
        try:
            download(meta["replay_url"], replay_path)
        except Exception as e:  # noqa: BLE001
            gaps.append({"round_number": round_number, "episode_id": meta["episode_id"],
                         "reason": f"download failed: {e}"})
            continue
        row, used_or_err = try_extract_and_decode(
            replay_path, meta["position"], leg_score, extractors, args.replay_cache,
            episode_id=meta["episode_id"], round_number=round_number,
            coworld_version=meta["coworld_version"])
        if row is None:
            gaps.append({"round_number": round_number, "episode_id": meta["episode_id"],
                         "coworld_version": meta["coworld_version"],
                         "reason": f"no local extractor reconciled: {used_or_err}"})
            continue
        defining_reports.append(build_defining_episode_report(row, used_or_err, meta, round_number))

    # pv_id/pv_version don't ride the leaderboard row itself (only
    # policy_label does) -- pull them from the most recent round in the
    # window where this player has a `reported` entry, per doctrine
    # "cite the pv id, never a name prefix" (ctf-no-source-attribution-in-public).
    def latest_pv(pid):
        for r in reversed(rounds):
            rep = r["reported"].get(pid)
            if rep and rep.get("pv_id"):
                return rep["pv_id"], rep["pv_version"]
        return None, None

    target_pv_id, target_pv_version = latest_pv(target_pid)
    rival_pv_id, rival_pv_version = latest_pv(rival_pid)

    report = {
        "era": {"note": "era-stamp the CALLER's own repo state, not the platform "
                         "(the platform's live coworld_version moves hourly)"},
        "league": args.league, "division": division, "rank": args.rank,
        "target": {"player_id": target_pid, "pv_id": target_pv_id,
                   "pv_version": target_pv_version,
                   "label_shown_today_on_the_live_board": target.get("policy_label"),
                   "leaderboard_score": target.get("score"),
                   "rounds_played": target.get("rounds_played")},
        "rival_next_rank": {"player_id": rival_pid, "pv_id": rival_pv_id,
                             "pv_version": rival_pv_version,
                             "label_shown_today_on_the_live_board": rival.get("policy_label"),
                             "leaderboard_score": rival.get("score")},
        "delta_vs_rival": {
            "absolute": (target.get("score") or 0) - (rival.get("score") or 0),
            "pct_of_target": (((target.get("score") or 0) - (rival.get("score") or 0))
                               / target["score"]) if target.get("score") else None,
        },
        "recency": {
            "served_ema": sr.CURRENT, "half_life_rounds": ema_meta.get("half_life_rounds")
                if isinstance(ema_meta, dict) else None,
            "rank1_streak_in_window": ema_meta.get("rank1_streak_in_window")
                if isinstance(ema_meta, dict) else None,
            "window_rounds": ema_meta.get("n_rounds_in_window")
                if isinstance(ema_meta, dict) else None,
            "reconstructed_standing_from_window": final_standing,
            "live_leaderboard_standing": target.get("score"),
            "reconstruction_note": "closed-form rated_k*(1-rated_k)^k weighting, "
                                    "ignores clamp interactions -- a LABELED "
                                    "ESTIMATE of each round's share, not exact",
            "top_weighted_rounds": weighted[:10],
        },
        "cap_hits_in_window": cap_hits_in_window,
        "top_episodes_scanned": len(all_legs),
        "defining_episodes": defining_reports,
        "gaps": gaps,
    }
    with open(args.out, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"[why_one] wrote {args.out}", file=sys.stderr)

    # Human-readable summary to stdout.
    print(f"\n=== WHY #{args.rank} IS #{args.rank} ===")
    print(f"pv_id: {target_pv_id} (v{target_pv_version})  "
          f"[label shown today on the live board: {target.get('policy_label')}]")
    print(f"standing: {target.get('score'):.0f}  "
          f"vs rank {args.rank+1} ({rival.get('policy_label')}): {rival.get('score'):.0f}  "
          f"(+{report['delta_vs_rival']['absolute']:.0f}, "
          f"{100*report['delta_vs_rival']['pct_of_target']:.1f}% of the lead's own standing)")
    print(f"window: last {len(rounds)} rounds; rank #{args.rank} held for the last "
          f"{ema_meta.get('rank1_streak_in_window') if isinstance(ema_meta, dict) else '?'} "
          f"of them; {cap_hits_in_window} of {len(all_legs)} scanned episodes hit the "
          f"product cap (2^24) outright")
    for w in weighted[:5]:
        print(f"  r{w['round_number']}: clipped_score={w['clipped_round_score']:.0f}  "
              f"~{100*w['share_of_reconstructed']:.1f}% of reconstructed standing")
    for d in defining_reports:
        print(f"\n-- defining episode: r{d['round_number']} {d['episode_id']} "
              f"(won={d['won']}, capped={d['capped']}, final={d['recon_final']:,}"
              f"{' [uncapped ' + format(d['recon_uncapped'], ',') + ']' if d['capped'] else ''}) --")
        if d["win_share_of_episode"]:
            print(f"  WIN            {100*d['win_share_of_episode']:5.1f}%")
        for line in d["deeds"]:
            print(f"  {line['public_label']:<14} {100*line['share_of_episode']:5.1f}%  "
                  f"x{line['count']} mint(s)")
        for a in d["achievements"]:
            tag = " (FIRST)" if a["first_claim"] else ""
            print(f"  {a['tier_name']:<14} {100*a['share_of_episode']:5.1f}%  "
                  f"({a['tree']}{tag})")
    if gaps:
        print(f"\n{len(gaps)} defining episode(s) could not be decoded locally "
              f"(era gap -- see 'gaps' in the JSON report):")
        for g in gaps:
            print(f"  r{g['round_number']}: {g['reason']}")


if __name__ == "__main__":
    main()
