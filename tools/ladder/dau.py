"""Daily Active Users for a coworld — the count that does NOT move on its own.

WHY THIS EXISTS: a coworld's episodes run autonomously. A policy submitted once
keeps playing every round forever, so "users whose policy played today" is
constant, never falls, and is really `lifetime_submitters` wearing a DAU
costume. And "users who shipped today" is the opposite error: it reads zero for
a top-of-ladder user who is watching replays daily and ships weekly.

So DAU counts HUMAN-ATTRIBUTABLE acts only, gated against machine traffic, and
normalized by the coworld's own loop period so two coworlds are comparable.

    A(u,d)  = h(u) * SUM_k  w_k * min(n_k(u,d), cap_k)
    DAU(d)  = |{ u : A(u,d) >= theta }|
    tau     = median inter-ship interval          (the coworld's loop period)
    EDAU(d) = |{ u : d - t_last(u) <= tau }|      (users inside their loop)
    sigma   = DAU / EDAU                          (burstiness)

WHAT THIS SCRIPT CAN AND CANNOT SEE. The public API exposes exactly one human
event class: a league-policy-membership row, i.e. a policy version SUBMITTED to
the league. Replay downloads, authenticated standings reads, and observatory
page views are not in any endpoint we can reach, so every number here is a
LOWER BOUND on true DAU (`w_commit` only). Wire the platform event log in and
the other classes light up without changing the formula.

Usage:
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  PYTHONPATH=. $PY dau.py [--league <id>] [--days 14]
"""
import argparse
import collections
import datetime as dt
import statistics

import ctfapi

PAINTBOT = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
PAINTBOT_DIV = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"

DAY = dt.timedelta(days=1)

# Machine-traffic gate. A cron loop has near-zero dispersion in its inter-event
# gaps; a human cannot hold a metronome. Needs enough events to be meaningful.
CV_FLOOR = 0.35
CV_MIN_EVENTS = 8

# Per-class daily cap: one repeated cheap act must not manufacture a user-day.
CAP_COMMIT = 3


def parse_ts(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def load_events(league):
    """One row per (player, policy version) submitted to the league.

    Dedupes on the policy-version id: a single ship can open memberships in
    several divisions, and that is one human act, not several.
    """
    ms = ctfapi.get(f"/v2/league-policy-memberships?league_id={league}&limit=1000")
    lg = ctfapi.get(f"/v2/leagues/{league}")
    filler = set(lg.get("filler_policy_version_ids") or [])

    seen, out = set(), []
    for m in ms:
        pv = m.get("policy_version") or {}
        player = m.get("player") or {}
        pvid = pv.get("id")
        if pvid in filler:
            continue  # platform-owned anchor seat, not a user
        key = (player.get("id"), pvid)
        if key in seen:
            continue
        seen.add(key)
        ts = parse_ts(m.get("created_at"))
        if ts is None:
            continue
        out.append({
            "t": ts,
            "user": player.get("name") or player.get("id"),
            "uid": player.get("id"),
            "label": pv.get("label"),
            "status": m.get("status"),
        })
    out.sort(key=lambda e: e["t"])
    return out, lg


def gaps_by_user(events):
    by = collections.defaultdict(list)
    for e in events:
        by[e["user"]].append(e["t"])
    return {u: [(ts[i + 1] - ts[i]).total_seconds()
                for i in range(len(ts) - 1)]
            for u, ts in by.items()}


def human_gate(events):
    """h(u) in {0,1}: 0 for metronomic submitters and declared test accounts."""
    gaps = gaps_by_user(events)
    verdict = {}
    for u, g in gaps.items():
        why = None
        if u.startswith("seedtest-"):
            why = "declared test account"
        elif len(g) + 1 >= CV_MIN_EVENTS and statistics.mean(g) > 0:
            cv = statistics.pstdev(g) / statistics.mean(g)
            if cv < CV_FLOOR:
                why = f"CV={cv:.2f} < {CV_FLOOR} over {len(g)+1} ships"
        verdict[u] = (why is None, why)
    return verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--league", default=PAINTBOT)
    ap.add_argument("--div", default=PAINTBOT_DIV)
    ap.add_argument("--days", type=int, default=14)
    a = ap.parse_args()

    events, lg = load_events(a.league)
    print(f"=== COWORLD: {lg.get('name')} ({a.league[:22]}…) ===")
    print(f"    paused={lg.get('rounds_paused_at')}  "
          f"game_of_week={lg.get('is_game_of_week')}  "
          f"filler_anchors={len(lg.get('filler_policy_version_ids') or [])}")
    if not events:
        print("no submission events — check the league id before believing this")
        return
    t0, t1 = events[0]["t"], events[-1]["t"]
    print(f"    {len(events)} ship events, {t0:%Y-%m-%d} → {t1:%Y-%m-%d} "
          f"({(t1-t0).days + 1}d), {len(set(e['user'] for e in events))} distinct players")

    # --- h(u): the human gate -------------------------------------------
    gate = human_gate(events)
    excluded = {u for u, (ok, _) in gate.items() if not ok}
    print(f"\n=== HUMAN GATE h(u) — {len(excluded)} of {len(gate)} players excluded ===")
    for u in sorted(excluded):
        print(f"  ✗ {u:28} {gate[u][1]}")
    if not excluded:
        print("  (none — no metronomic or declared-test submitter found)")
    live = [e for e in events if gate[e["user"]][0]]

    # --- tau: the coworld's loop period ---------------------------------
    per_user_median = []
    for u, g in gaps_by_user(live).items():
        if g:
            per_user_median.append(statistics.median(g))
    tau_s = statistics.median(per_user_median) if per_user_median else 0
    tau = dt.timedelta(seconds=tau_s)
    print(f"\n=== LOOP PERIOD tau ===")
    print(f"  median inter-ship interval, over {len(per_user_median)} players "
          f"with >1 ship: {tau_s/3600:.1f}h ({tau_s/86400:.2f}d)")

    # --- DAU(d) ----------------------------------------------------------
    end = max(t1, dt.datetime.now(dt.timezone.utc)).date()
    days = [end - dt.timedelta(days=i) for i in range(a.days - 1, -1, -1)]
    per_day = collections.defaultdict(collections.Counter)
    for e in live:
        per_day[e["t"].date()][e["user"]] += 1

    # theta = the weight of the cheapest genuine act. With commit as the only
    # observable class, w_commit = 1 and theta = 1: one real ship counts.
    theta, w_commit = 1.0, 1.0
    print(f"\n=== DAU(d) — ship-class only, w_commit={w_commit}, "
          f"cap={CAP_COMMIT}/day, theta={theta} ===")
    print(f"  {'date':12} {'DAU':>4} {'ships':>6}  who")
    dau_series = []
    for d in days:
        c = per_day.get(d, collections.Counter())
        qual = [u for u, n in c.items()
                if w_commit * min(n, CAP_COMMIT) >= theta]
        dau_series.append(len(qual))
        who = ", ".join(sorted(qual)[:6]) + ("…" if len(qual) > 6 else "")
        print(f"  {d.isoformat():12} {len(qual):>4} {sum(c.values()):>6}  {who}")

    # --- EDAU + stickiness ------------------------------------------------
    # The tau-window must never be SHORTER than the reporting period, or EDAU
    # counts a strict subset of DAU and sigma comes out > 1. A coworld whose
    # loop is sub-daily needs no normalization at all: DAU is already the
    # comparable number and sigma pins to 1.0 by construction.
    last = {}
    for e in live:
        last[e["user"]] = max(last.get(e["user"], e["t"]), e["t"])
    now = dt.datetime.now(dt.timezone.utc)
    window = max(tau, DAY)
    edau = [u for u, t in last.items() if now - t <= window]
    wau = {u for u, t in last.items() if now - t <= 7 * DAY}
    eligible = len(last)
    mean_dau = sum(dau_series) / len(dau_series)

    print(f"\n=== EDAU / stickiness ===")
    if tau < DAY:
        print(f"  tau ({tau_s/3600:.1f}h) is SUB-DAILY → this coworld iterates faster "
              f"than the reporting period.")
        print(f"  No tau-normalization needed; DAU is natively comparable. "
              f"EDAU window falls back to 1d.")
    print(f"  EDAU (window {window.total_seconds()/3600:.0f}h)  {len(edau):>4}   "
          f"{', '.join(sorted(edau))}")
    print(f"  WAU (trailing 7d)     {len(wau):>4}")
    print(f"  sigma = DAU/WAU       {mean_dau/len(wau) if wau else 0:>6.2f}   "
          f"(classic stickiness: fraction of the week's users present on a day)")
    print(f"  eligible base         {eligible:>4}   (ever shipped, gate-passing)")
    print(f"  activation DAU/base  {mean_dau/eligible*100 if eligible else 0:>5.1f}%")

    # --- the comparators, MEASURED not assumed ---------------------------
    rows = ctfapi.leaderboard(include_recent_rounds=1, div=a.div)
    rs = ctfapi.get(f"/v2/rounds?league_id={a.league}&limit=8")
    rs = rs if isinstance(rs, list) else (rs.get("entries") or rs.get("data") or [])
    done = [r for r in rs if r.get("status") == "completed"]
    fielded, rnum, neps = set(), None, 0
    if done:
        rnum = done[0].get("round_number")
        eps = ctfapi.episodes(done[0]["id"])
        neps = len(eps)
        for e in eps:
            for p in (e.get("participants") or e.get("players") or []):
                n = p.get("player_name") or p.get("name")
                if n:
                    fielded.add(n)

    print(f"\n=== WHAT THE NAIVE COUNTS WOULD HAVE SAID ===")
    print(f"  players fielded in ONE round (r{rnum}, {neps} episodes) "
          f"{len(fielded):>4}   ← MEASURED; plays every round with no human present")
    print(f"  leaderboard entrants  {len(rows):>4}   ← flat, ignores humans entirely")
    print(f"  lifetime submitters   {len(gate):>4}   ← monotonic, only goes up")
    infl = (len(fielded) / mean_dau) if mean_dau else float("inf")
    print(f"\n  ⭐ naive 'policy played today' inflates DAU by {infl:.1f}x "
          f"({len(fielded)} vs {mean_dau:.1f}) — and never falls.")


if __name__ == "__main__":
    main()
