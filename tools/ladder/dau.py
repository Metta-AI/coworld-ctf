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
    EDAU(d) = |{ u : d - t_last(u) <= max(tau, 1d) }|
    sigma   = DAU / WAU                           (stickiness)

THE UNATTENDED-LOOP PROBLEM, and why this reports TWO numbers. An AI
auto-improvement loop left running uploads policies with no human present. Two
independent defenses bound the damage, and real data proved both are needed:

  - the per-day CAP stops volume inflating magnitude. Measured on Paintbot, one
    player opened 229 memberships in a single day; min(229, 3) makes that one
    user-day, not 229.
  - the MACHINE-CADENCE gate catches the loop itself. That same player's median
    inter-upload gap was 2.1 MINUTES with 75% of gaps under five, all on one
    policy. No human hand sustains that. Every other player in the league sat at
    a >=60-minute median, so the test separates cleanly.
  - the CV gate catches the other shape: a slow metronome (a cron at a fixed
    interval) whose gaps are too regular to be a person.

What NO volume-based test can decide is whether an unattended loop that is
still running represents an engaged user or a forgotten cron — a working loop is
arguably the most invested user on the platform. Volume is not the discriminating
variable; PROGRESS is. So this script never merges the two: it reports DAU
(attended) and DAU (unattended) separately and leaves the judgment visible.

WHAT THIS SCRIPT CAN AND CANNOT SEE. The public API exposes exactly one human
event class: a league-policy-membership row, i.e. a policy version SUBMITTED to
the league. Replay downloads, authenticated standings reads, and observatory
page views are not in any endpoint we can reach, so the attended number is a
LOWER BOUND (`w_commit` only). Wire the platform event log in and the other
classes light up without changing the formula.

Usage:
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  PYTHONPATH=. $PY dau.py [--league <id>] [--days 14] [--json out.json]
"""
import argparse
import collections
import datetime as dt
import json
import statistics

import ctfapi

PAINTBOT = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
PAINTBOT_DIV = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"

DAY = dt.timedelta(days=1)

# --- h(u), the machine gate -------------------------------------------------
# Two shapes of machine, two tests. FAST: an auto-improvement loop re-uploading
# a policy every couple of minutes. REGULAR: a cron on a fixed interval, whose
# gaps are too even to be a person. Both need enough events to be meaningful.
MIN_EVENTS = 8
FAST_GAP_MIN = 5.0     # minutes — below this, no human is typing
FAST_FRAC = 0.5        # ...for a majority of the user's uploads
CV_FLOOR = 0.35        # dispersion below this is a metronome, not a person

# Per-class daily cap: one repeated cheap act must not manufacture a user-day.
CAP_COMMIT = 3

HUMAN, AUTO, TEST = "human", "auto", "test"


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


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
            "label": pv.get("label"),
            "policy": (pv.get("label") or "").split(":")[0],
            "status": m.get("status"),
        })
    out.sort(key=lambda e: e["t"])
    return out, lg


def classify(events):
    """h(u): human / auto / test, with the evidence that decided it."""
    by = collections.defaultdict(list)
    for e in events:
        by[e["user"]].append(e)

    out = {}
    for u, es in by.items():
        es.sort(key=lambda e: e["t"])
        gaps = [(es[i + 1]["t"] - es[i]["t"]).total_seconds() / 60
                for i in range(len(es) - 1)]
        if u.startswith("seedtest-"):
            out[u] = (TEST, "declared test account")
            continue
        if len(es) >= MIN_EVENTS and gaps:
            fast = sum(1 for g in gaps if g < FAST_GAP_MIN) / len(gaps)
            if fast >= FAST_FRAC:
                pols = len({e["policy"] for e in es})
                out[u] = (AUTO, f"{fast:.0%} of {len(gaps)} gaps under "
                                f"{FAST_GAP_MIN:.0f}min (median "
                                f"{statistics.median(gaps):.1f}min), "
                                f"{len(es)} uploads on {pols} policy")
                continue
            if statistics.mean(gaps) > 0:
                cv = statistics.pstdev(gaps) / statistics.mean(gaps)
                if cv < CV_FLOOR:
                    out[u] = (AUTO, f"CV={cv:.2f} over {len(es)} uploads "
                                    f"— metronomic, not a person")
                    continue
        out[u] = (HUMAN, None)
    return out


def dau_series(events, days, klass, want):
    per_day = collections.defaultdict(collections.Counter)
    for e in events:
        if klass[e["user"]][0] == want:
            per_day[e["t"].date()][e["user"]] += 1
    series = []
    for d in days:
        c = per_day.get(d, collections.Counter())
        # theta = the cheapest genuine act. With commit the only observable
        # class, w_commit = 1 and theta = 1: one real ship counts, once.
        qual = sorted(u for u, n in c.items() if min(n, CAP_COMMIT) >= 1)
        series.append({"date": d.isoformat(), "dau": len(qual),
                       "ships": sum(c.values()), "who": qual})
    return series


def build(league=PAINTBOT, div=PAINTBOT_DIV, ndays=14):
    events, lg = load_events(league)
    klass = classify(events)
    human = [e for e in events if klass[e["user"]][0] == HUMAN]

    # tau: the coworld's own loop period, humans only.
    by = collections.defaultdict(list)
    for e in human:
        by[e["user"]].append(e["t"])
    medians = [statistics.median([(ts[i + 1] - ts[i]).total_seconds()
                                  for i in range(len(ts) - 1)])
               for ts in (sorted(v) for v in by.values()) if len(ts) > 1]
    tau = dt.timedelta(seconds=statistics.median(medians) if medians else 0)

    now = dt.datetime.now(dt.timezone.utc)
    end = max(events[-1]["t"].date(), now.date()) if events else now.date()
    days = [end - dt.timedelta(days=i) for i in range(ndays - 1, -1, -1)]

    att = dau_series(events, days, klass, HUMAN)
    una = dau_series(events, days, klass, AUTO)

    last = {}
    for e in human:
        last[e["user"]] = max(last.get(e["user"], e["t"]), e["t"])
    window = max(tau, DAY)
    mean_dau = sum(d["dau"] for d in att) / len(att) if att else 0

    # The comparators, MEASURED not assumed.
    rs = ctfapi.get(f"/v2/rounds?league_id={league}&limit=8")
    rs = rs if isinstance(rs, list) else (rs.get("entries") or rs.get("data") or [])
    done = [r for r in rs if r.get("status") == "completed"]
    fielded, rnum, neps = set(), None, 0
    if done:
        rnum, neps = done[0].get("round_number"), 0
        eps = ctfapi.episodes(done[0]["id"])
        neps = len(eps)
        for e in eps:
            for p in (e.get("participants") or e.get("players") or []):
                if p.get("player_name") or p.get("name"):
                    fielded.add(p.get("player_name") or p.get("name"))

    return {
        "league": {"id": league, "name": lg.get("name"),
                   "paused": lg.get("rounds_paused_at"),
                   "anchors": len(lg.get("filler_policy_version_ids") or [])},
        "generated_at": now.isoformat(),
        "span": {"first": events[0]["t"].isoformat() if events else None,
                 "last": events[-1]["t"].isoformat() if events else None,
                 "events": len(events)},
        "tau_hours": tau.total_seconds() / 3600,
        "tau_subdaily": tau < DAY,
        "attended": att,
        "unattended": una,
        "dau_today": att[-1]["dau"] if att else 0,
        "dau_mean": mean_dau,
        "auto_today": una[-1]["dau"] if una else 0,
        "edau": sorted(u for u, t in last.items() if now - t <= window),
        "wau": sorted(u for u, t in last.items() if now - t <= 7 * DAY),
        "eligible": len(last),
        "excluded": {u: v[1] for u, v in klass.items() if v[0] != HUMAN},
        "auto_players": sorted(u for u, v in klass.items() if v[0] == AUTO),
        "naive": {"fielded_one_round": len(fielded), "round": rnum,
                  "episodes": neps,
                  "leaderboard": len(ctfapi.leaderboard(1, div=div)),
                  "lifetime": len(klass)},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--league", default=PAINTBOT)
    ap.add_argument("--div", default=PAINTBOT_DIV)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--json", help="also write the report as JSON here")
    a = ap.parse_args()

    r = build(a.league, a.div, a.days)
    lg, sp, nv = r["league"], r["span"], r["naive"]

    print(f"=== COWORLD: {lg['name']} ({lg['id'][:22]}…) ===")
    print(f"    paused={lg['paused']}  anchor_seats={lg['anchors']}  "
          f"{sp['events']} ship events since {sp['first'][:10]}")

    print(f"\n=== h(u): THE MACHINE GATE — {len(r['excluded'])} players excluded ===")
    for u, why in sorted(r["excluded"].items()):
        print(f"  ✗ {u:24} {why}")

    print(f"\n=== LOOP PERIOD tau = {r['tau_hours']:.1f}h"
          + ("  (SUB-DAILY → DAU is natively comparable, no normalization)"
             if r["tau_subdaily"] else "") + " ===")

    print(f"\n=== DAU(d) — cap {CAP_COMMIT}/day, theta 1 ===")
    print(f"  {'date':12} {'DAU':>4} {'auto':>5} {'ships':>6}  who")
    for att, una in zip(r["attended"], r["unattended"]):
        who = ", ".join(att["who"][:5]) + ("…" if len(att["who"]) > 5 else "")
        print(f"  {att['date']:12} {att['dau']:>4} {una['dau']:>5} "
              f"{att['ships']:>6}  {who}")

    print(f"\n=== THE NUMBER ===")
    print(f"  DAU today (attended)   {r['dau_today']:>4}")
    print(f"  DAU mean over {a.days}d      {r['dau_mean']:>6.1f}")
    print(f"  unattended loops today {r['auto_today']:>4}   "
          f"{', '.join(r['auto_players']) or '(none running)'}")
    print(f"  WAU (trailing 7d)      {len(r['wau']):>4}")
    print(f"  sigma = DAU/WAU        "
          f"{r['dau_mean']/len(r['wau']) if r['wau'] else 0:>6.2f}")
    print(f"  eligible base          {r['eligible']:>4}")

    print(f"\n=== WHAT THE NAIVE COUNTS WOULD HAVE SAID ===")
    print(f"  fielded in ONE round (r{nv['round']}, {nv['episodes']} episodes) "
          f"{nv['fielded_one_round']:>3}  ← MEASURED; no human present")
    print(f"  leaderboard entrants   {nv['leaderboard']:>4}  ← flat")
    print(f"  lifetime submitters    {nv['lifetime']:>4}  ← only goes up")
    if r["dau_mean"]:
        print(f"\n  ⭐ the naive count inflates DAU by "
              f"{nv['fielded_one_round']/r['dau_mean']:.1f}x, and never falls.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(r, f, indent=1)
        print(f"\n  wrote {a.json}")


if __name__ == "__main__":
    main()
