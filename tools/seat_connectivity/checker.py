#!/usr/bin/env python3
"""seat_connectivity/checker.py — "did my seat actually enter the match?"

For a given entrant (player name) and round range, walks round -> episodes
-> that seat's policy log, and classifies each appearance as one of:
  HANDSHAKE-COMPLETE / NO-PLAYCONTEXT / NEVER-JOINED / NOT-STARTED / UNKNOWN
(see classify.py for the exact rule for each). Prints a compact per-episode
table plus totals.

This is a READ-ONLY tool: it only issues GET requests against public
round/episode data and the caller's own policy logs. It never writes,
never submits, and never touches league-scoped data outside the requesting
entrant's own policy.

Usage:
    export SEATCHECK_TOKEN=...   # your own API token — see README.md
    python3 checker.py --entrant softmaxwell --rounds 40

Any entrant can run this against their OWN token/policy name — nothing here
requires our internal tooling or credentials.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter

import api
from classify import classify_seat_appearance

# Episode error strings sometimes name a specific seat, e.g. "player slot 12
# never joined the lobby within 7200 lobby ticks (~300s)". Confirmed live
# 2026-09-07 (round 4360): several of these episodes named a DIFFERENT slot
# than our own participant's `position` in that same episode — feeding that
# text straight into the classifier would misattribute a stranger's no-show
# to our own seat. Only let error text drive our seat's classification when
# it either names no slot at all (a platform-wide message) or names OUR OWN
# slot specifically.
_SLOT_RE = re.compile(r"slot\s+(\d+)", re.IGNORECASE)


def scan(entrant: str, num_rounds: int, division_id: str):
    headers = api.auth_headers()
    rounds = api.list_rounds(limit=max(num_rounds, 20), division_id=division_id,
                              headers=headers)
    # Newest-first from the API; keep only the requested count, oldest last
    # so the printed table reads chronologically.
    rounds = sorted(rounds, key=lambda r: r.get("round_number", 0))[-num_rounds:]

    rows = []
    engine_builds = set()
    for rnd in rounds:
        rid = rnd.get("id")
        rnum = rnd.get("round_number")
        try:
            episodes = api.list_episodes(rid, headers=headers)
        except RuntimeError as exc:
            print(f"  ! round {rnum} ({rid}): {exc}", file=sys.stderr)
            continue

        for ep in episodes:
            seat = api.find_seat(ep, entrant)
            if seat is None:
                continue  # entrant did not play this episode at all
            build = ep.get("coworld_version")
            if build:
                engine_builds.add(build)

            error_type = ep.get("error_type") or seat.get("error_type")
            error = ep.get("error") or seat.get("error")

            # See _SLOT_RE above: don't let an error naming a DIFFERENT
            # seat's slot drive our own seat's classification. The raw text
            # still shows in the printed note either way (transparency).
            attributable_error_type, attributable_error = error_type, error
            m = _SLOT_RE.search(f"{error_type or ''} {error or ''}")
            if m and int(m.group(1)) != seat.get("position"):
                attributable_error_type, attributable_error = None, None

            # Always fetch OUR OWN seat's policy log, whatever the
            # episode-level outcome was. The whole point of this tool is
            # "did MY seat complete the handshake" — that is a fact about
            # our own seat's log, independent of whether the platform
            # attributes any episode-level failure to a DIFFERENT seat
            # (`failed_agent_index` naming someone else does not mean our
            # seat is exempt from checking; it may have handshaked fine
            # before an unrelated seat's crash voided the whole episode).
            log_text, fetch_status = api.get_policy_log(ep, seat, headers=headers)

            cls = classify_seat_appearance(log_text,
                                            error_type=attributable_error_type,
                                            error=attributable_error,
                                            log_fetch_status=fetch_status)
            eid = ep.get("episode_id") or ep.get("id")  # episode_id is null
                                                          # on episodes that
                                                          # never registered;
                                                          # fall back to the
                                                          # episode_request id
            rows.append((rnum, eid, cls, (error or error_type or "")[:60]))
    return rows, sorted(engine_builds)


def print_report(entrant: str, rows, engine_builds):
    print(f"seat-connectivity check for entrant={entrant!r}\n")
    if not rows:
        print("No episodes found for this entrant in the requested window.")
        return
    print(f"{'round':>6}  {'episode_id':<38}  {'class':<20}  note")
    print("-" * 100)
    for rnum, eid, cls, note in rows:
        print(f"{rnum!s:>6}  {eid!s:<38}  {cls:<20}  {note}")

    totals = Counter(cls for _, _, cls, _ in rows)
    print("\nTotals:")
    for cls in ("HANDSHAKE-COMPLETE", "NO-PLAYCONTEXT", "NEVER-JOINED",
                "NOT-STARTED", "UNKNOWN"):
        print(f"  {cls:<20} {totals.get(cls, 0)}")
    print(f"  {'TOTAL':<20} {len(rows)}")
    if engine_builds:
        print(f"\nEngine builds observed: {', '.join(engine_builds)}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--entrant", required=True,
                    help="player name to check (your own league player name)")
    p.add_argument("--rounds", type=int, default=40,
                    help="how many of the most recent rounds to scan (default 40)")
    p.add_argument("--division", default=api.PAINTBOT_DIV,
                    help="division id to scan (default: Paintbot S2 Competition)")
    args = p.parse_args()

    rows, engine_builds = scan(args.entrant, args.rounds, args.division)
    print_report(args.entrant, rows, engine_builds)


if __name__ == "__main__":
    main()
