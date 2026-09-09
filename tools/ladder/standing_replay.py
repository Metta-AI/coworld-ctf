#!/usr/bin/env python3
"""Season 2 standing stability sweep — pull the Paintbot ladder ledger,
reproduce the SERVED standing exactly, then replay it under alternate
rated_k / rated_clamp_multiple / sum_top_k / episode-cadence settings.

Read-only against the platform. Never POSTs, never mutates league settings.

## The served update rule (as of 2026-09-08)

`GET /v2/leagues/{PAINTBOT_LEAGUE}/settings` (elevated) -> `effective_ladder_config`:

    {"algorithm": "score", "round_scoring_rule": "sum", "sum_top_k": 12,
     "standing_aggregation": "rated", "rated_k": 0.05,
     "rated_clamp_multiple": 150.0, "initial_standing": 0.0}

Standing subject is the PLAYER (not the policy_version) — round_config's
`entrant_attributions` and the leaderboard both key by `player_id`; a policy
version bump does not reset the EMA.

Update rule (round_score already has sum_top_k applied server-side on the
*reported* score; we recompute it ourselves from raw legs so top_k is
sweepable):

    round_score  = sum(sorted(per_episode_scores, desc)[:top_k])
    clipped      = round_score                      if standing == 0 (first round for this player)
                 = clip(round_score, s/M, s*M)       otherwise, M = rated_clamp_multiple (None = no clamp)
    standing    <- standing + rated_k * (clipped - standing)

⚠️ NOT re-derivable from `file:line` in the local ~/projects/metta checkout:
`app_backend/src/metta/app_backend/v2/ladders/rankings/score.py` and
`.../ladders/config.py` (`ScoreRankingConfig`, `standing_aggregation:
Literal["ewma","mean","max"]`, `half_life_hours` in HOURS) implement a
DIFFERENT, wall-clock-hours EWMA with no `rated`/`rated_k`/`rated_clamp_
multiple`/`sum_top_k` fields at all — grepped clean, zero hits. Whatever
backend build actually serves Paintbot S2 is ahead of (or diverged from)
that local source tree. The formula above is instead taken directly from
the LIVE served settings (fetched read-only, see above) and independently
corroborated by memory `ctf-standing-is-an-ema-not-a-max.md` (regression
fit to 16 live leaderboard rows, ~1e-4% average relative error) and
`ctf-rated-clamp-sizing-post-gv57.md` (clamp M=150 sizing). Flagged as
RECONSTRUCTED-FROM-LIVE-CONFIG, not source-cited, per the task's own
fallback instruction.

Usage:
    python3 standing_replay.py pull [--since N] [--until N]
    python3 standing_replay.py reproduce
    python3 standing_replay.py sweep
    python3 standing_replay.py fixture   # write the small committed fixture
"""
from __future__ import annotations

import json
import os
import random
import statistics
import sys
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# `ctfapi` needs the coworld player package (network/auth), which most
# consumers of this module (replay/sweep/chart code, tests) don't have and
# don't need — import it lazily, only where a live API call actually happens.
ctfapi = None


def _ctfapi():
    global ctfapi
    if ctfapi is None:
        import ctfapi as _m
        ctfapi = _m
    return ctfapi


PAINTBOT_LEAGUE = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
PAINTBOT_DIV = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"

CACHE_DIR = "/tmp/standing-sweep/cache"
LEDGER_PATH = "/tmp/standing-sweep/ledger.json"
FIXTURE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "testdata", "standing_fixture.json")

# Served config as of 2026-09-08 (see module docstring).
CURRENT = dict(rated_k=0.05, clamp_M=150.0, top_k=12, transform="raw",
               episode_mode="current")


# --------------------------------------------------------------------------
# Pull
# --------------------------------------------------------------------------

def _cache_path(round_id, kind):
    os.makedirs(CACHE_DIR, exist_ok=True)
    return os.path.join(CACHE_DIR, f"{round_id}_{kind}.json")


def _cached_detail(round_id):
    p = _cache_path(round_id, "detail")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    d = _ctfapi().round_detail(round_id)
    with open(p, "w") as f:
        json.dump(d, f)
    return d


def _cached_episodes(round_id):
    p = _cache_path(round_id, "episodes")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    eps = _ctfapi().episodes(round_id)
    with open(p, "w") as f:
        json.dump(eps, f)
    return eps


def list_division_rounds():
    """Cursor-paginated /v2/rounds?division_id=..., deduped by id.

    division_id is the only filter that works server-side on this route;
    league_id and offset are silently ignored (ctf-rounds-endpoint-filter-
    and-offset-traps.md). Pages can overlap, so dedupe by round id.
    """
    cursor, seen, out = None, set(), []
    while True:
        path = f"/v2/rounds?division_id={PAINTBOT_DIV}&limit=100"
        if cursor:
            path += f"&cursor={quote(cursor, safe='')}"
        page = _ctfapi().get(path)
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


def pull_ledger(since, until, verbose=True):
    """Build the round/leg ledger for round_number in [since, until].

    Ledger entry per round:
      {round_number, round_id, completed_at, coworld_version,
       reported: {player_id: {score, rank, label, pv_id, pv_version, player_name}},
       legs: {player_id: [per-episode score, ...]}}

    Filler seats are excluded (ctf-api-playername-lies-on-filler-seats.md):
    is_filler must be falsy, never matched by name alone.
    """
    all_rounds = list_division_rounds()
    wanted = [r for r in all_rounds
              if since <= (r.get("round_number") or -1) <= until
              and r.get("status") == "completed"]
    wanted.sort(key=lambda r: r["round_number"])
    if verbose:
        print(f"[pull] {len(wanted)} completed rounds in "
              f"[{since},{until}] out of {len(all_rounds)} fetched", file=sys.stderr)

    rounds_out = []
    for i, r in enumerate(wanted):
        rid = r["id"]
        detail = _cached_detail(rid)
        eps = _cached_episodes(rid)

        reported = {}
        for row in detail.get("results") or []:
            player = row.get("player") or {}
            pv = row.get("policy_version") or {}
            pid = player.get("id")
            if not pid:
                continue
            reported[pid] = {
                "score": row.get("score"),
                "rank": row.get("rank"),
                "label": pv.get("label"),
                "pv_id": pv.get("id"),
                "pv_version": pv.get("version"),
                "player_name": player.get("name"),
            }

        legs = {}
        versions = []
        for ep in eps:
            if ep.get("status") != "completed":
                continue
            cv = ep.get("coworld_version")
            if cv:
                versions.append(cv)
            pos_to_player = {}
            for p in ep.get("participants") or []:
                if p.get("is_filler"):
                    continue
                pos_to_player[p.get("position")] = p.get("player_id")
            for ps in ep.get("participant_scores") or []:
                pid = pos_to_player.get(ps.get("position"))
                if pid is None:
                    continue
                legs.setdefault(pid, []).append(ps.get("score"))

        coworld_version = statistics.mode(versions) if versions else None
        rounds_out.append({
            "round_number": r["round_number"],
            "round_id": rid,
            "completed_at": r.get("completed_at"),
            "coworld_version": coworld_version,
            "reported": reported,
            "legs": legs,
        })
        if verbose and (i + 1) % 25 == 0:
            print(f"[pull] {i+1}/{len(wanted)} rounds fetched "
                  f"(r{r['round_number']})", file=sys.stderr)

    ledger = {
        "meta": {
            "league": PAINTBOT_LEAGUE,
            "division": PAINTBOT_DIV,
            "since": since,
            "until": until,
            "served_config": CURRENT,
        },
        "rounds": rounds_out,
    }
    return ledger


def save_ledger(ledger, path=LEDGER_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(ledger, f)
    print(f"[pull] wrote {len(ledger['rounds'])} rounds to {path}", file=sys.stderr)


def load_ledger(path=LEDGER_PATH):
    with open(path) as f:
        return json.load(f)


# --------------------------------------------------------------------------
# Replay
# --------------------------------------------------------------------------

def _transform(x, kind):
    if kind == "raw":
        return x
    if kind == "log2":
        import math
        return math.log2(1.0 + max(x, 0.0))
    raise ValueError(f"unknown transform {kind}")


# F1-style points for rank-points transform, extended flat below 10th.
_RANK_POINTS = [25, 18, 15, 12, 10, 8, 6, 4, 2, 1]


def _round_score(legs, top_k, transform):
    if not legs:
        return 0.0
    eff = "raw" if transform == "rank_points" else transform
    vals = sorted((_transform(x, eff) for x in legs), reverse=True)
    if top_k == "all":
        kept = vals
    else:
        kept = vals[:top_k]
    return sum(kept)


def _apply_episode_mode(legs, mode, rng):
    if mode == "current":
        return legs
    if mode == "half":
        n = max(1, len(legs) // 2)
        return rng.sample(legs, n) if len(legs) > n else list(legs)
    raise ValueError(f"episode_mode {mode} handled at round-pairing level")


def _round_scores_for_round(r, top_k, transform, episode_mode, rng):
    """Per-entrant round score for one round, dispatching the transform.

    `rank_points` is NOT a per-leg transform — it re-scores the whole round:
    each entrant's raw sum-of-top-k stands only as the ORDERING key, then
    F1-style points (25/18/15/12/10/8/6/4/2/1, 0 below 10th) replace the
    magnitude entirely. Every other transform (raw, log2) applies per-leg
    and keeps summing.
    """
    raw = {}
    for pid, legs in r["legs"].items():
        sampled = _apply_episode_mode(legs, episode_mode, rng)
        raw[pid] = _round_score(sampled, top_k, transform)
    if transform != "rank_points":
        return raw
    order = sorted(raw, key=lambda pid: -raw[pid])
    points = {}
    for i, pid in enumerate(order):
        points[pid] = _RANK_POINTS[i] if i < len(_RANK_POINTS) else 0
    return points


def replay(rounds, rated_k=0.05, clamp_M=150.0, top_k=12, transform="raw",
           episode_mode="current", seed=0):
    """Replay the EMA standing update over `rounds` (sorted by round_number).

    Returns (history, contributions) where:
      history = [(round_number, {player_id: standing_after}), ...]
      contributions = {player_id: [(round_number, clipped_round_score), ...]}
        (needed for the "share of standing from one round" metric)

    `episode_mode="double"` is handled by the caller pre-pairing rounds
    (see `_pair_rounds`) — this function only knows "current" / "half".
    """
    rng = random.Random(seed)
    standing = {}
    history = []
    contributions = {}

    for r in rounds:
        round_scores = _round_scores_for_round(r, top_k, transform, episode_mode, rng)

        for pid, score in round_scores.items():
            s = standing.get(pid)
            if s is None or s == 0.0:
                clipped = score
            elif clamp_M:
                lo, hi = s / clamp_M, s * clamp_M
                if lo > hi:
                    lo, hi = hi, lo
                clipped = min(max(score, lo), hi)
            else:
                clipped = score
            new_s = (clipped if s is None else s + rated_k * (clipped - s))
            standing[pid] = new_s
            contributions.setdefault(pid, []).append((r["round_number"], clipped))

        history.append((r["round_number"], dict(standing)))

    return history, contributions


def _pair_rounds(rounds):
    """episode-cadence 'double' emulation: concatenate consecutive round
    pairs' legs into one merged round (double episodes, half cadence)."""
    out = []
    for i in range(0, len(rounds) - 1, 2):
        a, b = rounds[i], rounds[i + 1]
        merged_legs = {}
        for pid, legs in a["legs"].items():
            merged_legs.setdefault(pid, []).extend(legs)
        for pid, legs in b["legs"].items():
            merged_legs.setdefault(pid, []).extend(legs)
        out.append({
            "round_number": b["round_number"],
            "round_id": b["round_id"],
            "completed_at": b["completed_at"],
            "coworld_version": b["coworld_version"],
            "reported": b["reported"],
            "legs": merged_legs,
        })
    return out


def replay_setting(rounds, rated_k=0.05, clamp_M=150.0, top_k=12,
                    transform="raw", episode_mode="current", seed=0):
    """Dispatch 'double' pairing before calling replay()."""
    if episode_mode == "double":
        return replay(_pair_rounds(rounds), rated_k=rated_k, clamp_M=clamp_M,
                       top_k=top_k, transform=transform, episode_mode="current",
                       seed=seed)
    return replay(rounds, rated_k=rated_k, clamp_M=clamp_M, top_k=top_k,
                   transform=transform, episode_mode=episode_mode, seed=seed)


# --------------------------------------------------------------------------
# Reproduction check
# --------------------------------------------------------------------------

def reproduce(ledger, live_top, k=1e-4):
    """Replay under CURRENT served settings and compare the final round's
    top-N order against a live leaderboard snapshot (list of player_id in
    rank order). Returns (matched_bool, our_order, live_order, rel_errors)."""
    history, _ = replay_setting(ledger["rounds"], **{
        "rated_k": CURRENT["rated_k"], "clamp_M": CURRENT["clamp_M"],
        "top_k": CURRENT["top_k"], "transform": CURRENT["transform"],
        "episode_mode": CURRENT["episode_mode"],
    })
    if not history:
        return False, [], live_top, {}
    _, final_standing = history[-1]
    our_order = [pid for pid, _ in
                 sorted(final_standing.items(), key=lambda kv: -kv[1])]
    return our_order[:len(live_top)] == live_top[:len(our_order)], \
        our_order, live_top, final_standing


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------

def _kendall_tau(order_a, order_b):
    """Kendall tau-b over the union of items appearing in both orders,
    restricted to items present in both (unranked items dropped)."""
    common = [x for x in order_a if x in order_b]
    if len(common) < 2:
        return None
    rank_b = {x: i for i, x in enumerate(order_b)}
    seq = [rank_b[x] for x in common]
    n = len(seq)
    concordant = discordant = 0
    for i in range(n):
        for j in range(i + 1, n):
            if seq[i] < seq[j]:
                concordant += 1
            else:
                discordant += 1
    total = concordant + discordant
    return (concordant - discordant) / total if total else None


def stability_metrics(history, top_n=16):
    """Kendall tau between consecutive rounds' top-N; #1 changes; leader's
    single-best-round share."""
    orders = []
    for rnum, standing in history:
        order = [pid for pid, _ in sorted(standing.items(), key=lambda kv: -kv[1])]
        orders.append(order[:top_n])

    taus = []
    for i in range(1, len(orders)):
        t = _kendall_tau(orders[i - 1], orders[i])
        if t is not None:
            taus.append(t)

    leader_changes = 0
    leaders = [o[0] for o in orders if o]
    for i in range(1, len(leaders)):
        if leaders[i] != leaders[i - 1]:
            leader_changes += 1
    per_50 = leader_changes / max(1, len(leaders)) * 50

    return {
        "tau_mean": statistics.mean(taus) if taus else None,
        "tau_p10": (sorted(taus)[max(0, int(len(taus) * 0.10) - 1)]
                    if taus else None),
        "leader_changes_per_50": per_50,
        "n_rounds": len(orders),
    }


def leader_best_round_share(history, contributions, rated_k=None):
    """`rated_k` must be the SAME rate the passed-in `history`/`contributions`
    were replayed with (falls back to CURRENT["rated_k"] only if the caller
    doesn't know its own rate) — decay weights computed at any other rate
    silently mis-score every non-CURRENT setting swept by callers like
    `_metrics_for_setting`."""
    if not history:
        return None
    _, final_standing = history[-1]
    if not final_standing:
        return None
    leader = max(final_standing, key=final_standing.get)
    final = final_standing[leader]
    if final <= 0:
        return None
    n = len(contributions.get(leader, []))
    k = CURRENT["rated_k"] if rated_k is None else rated_k
    best_share = 0.0
    for idx, (_, clipped) in enumerate(contributions.get(leader, [])):
        remaining = n - 1 - idx
        weight = k * ((1 - k) ** remaining) if idx < n - 1 else 1.0
        # the very first round sets standing directly (weight effectively 1
        # decayed by (1-k)^remaining too, since every later blend multiplies
        # the running standing by (1-k)); use the same decay form throughout.
        contrib = clipped * ((1 - k) ** remaining) * (k if idx < n else 1.0)
        best_share = max(best_share, contrib / final)
    return best_share


def spike_sensitivity(rounds, rated_k, clamp_M, top_k, transform, episode_mode):
    """Remove the single largest leg in the window and see whether #1 changes
    and by how many ranks."""
    history, _ = replay_setting(rounds, rated_k=rated_k, clamp_M=clamp_M,
                                 top_k=top_k, transform=transform,
                                 episode_mode=episode_mode)
    if not history:
        return None
    _, final = history[-1]
    order = [pid for pid, _ in sorted(final.items(), key=lambda kv: -kv[1])]
    if not order:
        return None
    top1 = order[0]

    best = (None, None, -1)  # (round_idx, player_id, value)
    for ri, r in enumerate(rounds):
        for pid, legs in r["legs"].items():
            if not legs:
                continue
            m = max(legs)
            if m > best[2]:
                best = (ri, pid, m)
    if best[0] is None:
        return None

    import copy
    rounds2 = copy.deepcopy(rounds)
    ri, pid, val = best
    legs = rounds2[ri]["legs"][pid]
    legs.remove(val)

    history2, _ = replay_setting(rounds2, rated_k=rated_k, clamp_M=clamp_M,
                                  top_k=top_k, transform=transform,
                                  episode_mode=episode_mode)
    _, final2 = history2[-1]
    order2 = [pid2 for pid2, _ in sorted(final2.items(), key=lambda kv: -kv[1])]
    new_rank_of_top1 = (order2.index(top1) + 1) if top1 in order2 else None
    return {
        "removed_from": pid, "removed_value": val,
        "round_number": rounds2[ri]["round_number"],
        "old_top1": top1, "old_top1_was_removed_from": pid == top1,
        "new_rank_of_old_top1": new_rank_of_top1,
        "new_top1": order2[0] if order2 else None,
    }


def responsiveness(rounds, rated_k, clamp_M, top_k, transform, episode_mode,
                    subject_pid, scale, from_round_idx, target="top3"):
    """Scale `subject_pid`'s legs by `scale` from `from_round_idx` onward;
    count rounds until it first satisfies (target=='top3': rank<=3) or
    (target=='out_of_top3': rank>3).

    `from_round_idx` is expressed in the ORIGINAL (un-paired) round index
    space, since "scale from calendar round N onward" is well-defined
    regardless of episode_mode. `episode_mode="double"` halves the number of
    *standing updates* (two calendar rounds become one merged step), so the
    scan threshold below must be halved too, or every entry in the shorter
    paired history satisfies `i < from_round_idx` and the scan never fires
    (returns a false None for every setting on this axis).
    """
    import copy
    rounds2 = copy.deepcopy(rounds)
    for r in rounds2[from_round_idx:]:
        if subject_pid in r["legs"]:
            r["legs"][subject_pid] = [x * scale for x in r["legs"][subject_pid]]

    history, _ = replay_setting(rounds2, rated_k=rated_k, clamp_M=clamp_M,
                                 top_k=top_k, transform=transform,
                                 episode_mode=episode_mode)
    scan_from = from_round_idx // 2 if episode_mode == "double" else from_round_idx
    unit = 2 if episode_mode == "double" else 1  # normalize to calendar rounds
    for i, (rnum, standing) in enumerate(history):
        if i < scan_from:
            continue
        order = [pid for pid, _ in sorted(standing.items(), key=lambda kv: -kv[1])]
        rank = order.index(subject_pid) + 1 if subject_pid in order else None
        if rank is None:
            continue
        if target == "top3" and rank <= 3:
            return (i - scan_from) * unit
        if target == "out_of_top3" and rank > 3:
            return (i - scan_from) * unit
    return None  # never reached within window


# --------------------------------------------------------------------------
# Sweep orchestration
# --------------------------------------------------------------------------

def _metrics_for_setting(rounds, setting, mid_subject, top_subject, from_idx,
                          n_half_draws=20):
    """One setting's full metric bundle. `setting` overrides CURRENT."""
    s = dict(CURRENT)
    s.update(setting)

    def _run(seed=0):
        return replay_setting(rounds, rated_k=s["rated_k"], clamp_M=s["clamp_M"],
                               top_k=s["top_k"], transform=s["transform"],
                               episode_mode=s["episode_mode"], seed=seed)

    if s["episode_mode"] == "half":
        stab_runs = [stability_metrics(_run(seed=i)[0]) for i in range(n_half_draws)]
        stab = {
            "tau_mean": statistics.mean(x["tau_mean"] for x in stab_runs if x["tau_mean"] is not None),
            "tau_p10": statistics.mean(x["tau_p10"] for x in stab_runs if x["tau_p10"] is not None),
            "leader_changes_per_50": statistics.mean(x["leader_changes_per_50"] for x in stab_runs),
            "n_rounds": stab_runs[0]["n_rounds"],
        }
        history, contributions = _run(seed=0)
    else:
        history, contributions = _run()
        stab = stability_metrics(history)

    share = leader_best_round_share(history, contributions, rated_k=s["rated_k"])
    spike = spike_sensitivity(rounds, s["rated_k"], s["clamp_M"], s["top_k"],
                               s["transform"], s["episode_mode"])

    n = len(rounds) if s["episode_mode"] != "double" else len(rounds) // 2
    up = responsiveness(rounds, s["rated_k"], s["clamp_M"], s["top_k"],
                         s["transform"], s["episode_mode"],
                         mid_subject, 1.5, from_idx, target="top3")
    down = responsiveness(rounds, s["rated_k"], s["clamp_M"], s["top_k"],
                           s["transform"], s["episode_mode"],
                           top_subject, 0.5, from_idx, target="out_of_top3")

    return {
        "setting": s,
        "tau_mean": stab["tau_mean"], "tau_p10": stab["tau_p10"],
        "leader_changes_per_50": stab["leader_changes_per_50"],
        "leader_best_round_share": share,
        "spike": spike,
        "rounds_to_top3_on_1.5x": up,
        "rounds_to_fall_out_of_top3_on_0.5x": down,
        "final_history": history,
    }


def run_sweep(ledger, verbose=True):
    rounds = ledger["rounds"]
    live_top = ledger.get("_live_top") or []

    # Subjects for the responsiveness experiments, chosen off the CURRENT
    # reproduction's final ranking: a real mid-table player (~rank 8) for the
    # "genuinely better" injection, and a real top-3 player (not #1, so the
    # drop is observable) for the "stops playing" injection.
    base_history, _ = replay_setting(rounds, **{k: CURRENT[k] for k in
                                                 ("rated_k", "clamp_M", "top_k",
                                                  "transform", "episode_mode")})
    _, final = base_history[-1]
    order = [pid for pid, _ in sorted(final.items(), key=lambda kv: -kv[1])]
    mid_subject = order[min(7, len(order) - 1)]
    top_subject = order[min(1, len(order) - 1)]
    from_idx = len(rounds) // 2

    if verbose:
        print(f"[sweep] mid-table subject rank {order.index(mid_subject)+1}, "
              f"top subject rank {order.index(top_subject)+1}, "
              f"injecting from round index {from_idx}/{len(rounds)}", file=sys.stderr)

    current = _metrics_for_setting(rounds, {}, mid_subject, top_subject, from_idx)

    axes = {
        "rated_k": [{"rated_k": v} for v in (0.02, 0.035, 0.05, 0.075, 0.1)],
        "clamp_M": [{"clamp_M": v} for v in (10, 30, 60, 150, None)],
        "transform": [{"transform": v} for v in ("raw", "log2", "rank_points")],
        "top_k": [{"top_k": v} for v in (6, 12, "all")],
        "episode_mode": [{"episode_mode": v} for v in ("half", "current", "double")],
    }

    results = {"current": current, "axes": {}}
    for axis, settings in axes.items():
        if verbose:
            print(f"[sweep] axis {axis}", file=sys.stderr)
        results["axes"][axis] = []
        for setting in settings:
            m = _metrics_for_setting(rounds, setting, mid_subject, top_subject, from_idx)
            m.pop("final_history")
            results["axes"][axis].append(m)

    # Top-3 combined candidates, picked from the single-axis sweep above:
    # log2 dominates every other single-axis lever on leader_best_round_share
    # (0.314 -> 0.043, an 86% cut) at a smaller stability/responsiveness cost
    # than tightening clamp_M or rated_k alone (see docs/designs/STANDING_SWEEP.md).
    # These three test whether pairing it with a clamp/k tweak helps further.
    combos = {
        "log2_only": {"transform": "log2"},
        "log2_clamp60": {"transform": "log2", "clamp_M": 60},
        "log2_k035": {"transform": "log2", "rated_k": 0.035},
    }
    if verbose:
        print("[sweep] combos", file=sys.stderr)
    results["combos"] = {}
    for name, setting in combos.items():
        m = _metrics_for_setting(rounds, setting, mid_subject, top_subject, from_idx)
        m.pop("final_history")
        results["combos"][name] = m

    current_summary = dict(current)
    current_summary.pop("final_history")
    results["current"] = current_summary
    results["subjects"] = {"mid_subject": mid_subject, "top_subject": top_subject,
                            "from_round_idx": from_idx}
    return results


# --------------------------------------------------------------------------
# Fixture
# --------------------------------------------------------------------------

def write_fixture(ledger, n_rounds=15):
    sub = {
        "meta": dict(ledger["meta"]),
        "rounds": ledger["rounds"][:n_rounds],
    }
    os.makedirs(os.path.dirname(FIXTURE_PATH), exist_ok=True)
    with open(FIXTURE_PATH, "w") as f:
        json.dump(sub, f, indent=2)
    print(f"[fixture] wrote {len(sub['rounds'])} rounds to {FIXTURE_PATH}")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    cmd = args[0]
    if cmd == "pull":
        since = int(args[args.index("--since") + 1]) if "--since" in args else 4257
        until = int(args[args.index("--until") + 1]) if "--until" in args else 10**9
        ledger = pull_ledger(since, until)
        save_ledger(ledger)
    elif cmd == "fixture":
        ledger = load_ledger()
        write_fixture(ledger)
    elif cmd == "reproduce":
        ledger = load_ledger()
        rows = _ctfapi().leaderboard(include_recent_rounds=0, div=PAINTBOT_DIV)
        # leaderboard keys by player_id, not exposed directly on modern rows;
        # match by player_name against round legs' player identity instead,
        # falling back to label substring — see docs/designs/STANDING_SWEEP.md.
        live_top_names = [r.get("player_name") for r in
                           sorted(rows, key=lambda r: r["rank"])]
        name_by_pid = {}
        for r in ledger["rounds"]:
            for pid, info in r["reported"].items():
                name_by_pid[pid] = info.get("player_name")
        live_top_pids = []
        for name in live_top_names:
            for pid, nm in name_by_pid.items():
                if nm == name and pid not in live_top_pids:
                    live_top_pids.append(pid)
                    break
        matched, our_order, live_order, final_standing = reproduce(ledger, live_top_pids)
        print(f"reproduction match (top-{len(live_top_pids)} order): {matched}")
        print("our order :", [name_by_pid.get(p) for p in our_order[:10]])
        print("live order:", [name_by_pid.get(p) for p in live_top_pids[:10]])
        with open("/tmp/standing-sweep/reproduce_result.json", "w") as f:
            json.dump({"matched": matched,
                       "our_order_names": [name_by_pid.get(p) for p in our_order],
                       "live_order_names": [name_by_pid.get(p) for p in live_top_pids],
                       "final_standing": {name_by_pid.get(p): v
                                          for p, v in final_standing.items()}},
                      f, indent=2)
    elif cmd == "sweep":
        ledger = load_ledger()
        results = run_sweep(ledger)
        with open("/tmp/standing-sweep/sweep_results.json", "w") as f:
            json.dump(results, f, indent=2, default=str)
        print("[sweep] wrote /tmp/standing-sweep/sweep_results.json")
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
