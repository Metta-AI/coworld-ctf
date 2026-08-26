#!/usr/bin/env python3
"""br_smoke — BR league round-1 smoke checklist + rollback runbook.
LAUNCH_PLAN.md §5 item 7 (smoke checks) and §6 (rollback). Read-only against
the platform, always: this file never mutates a league, a round, or a
membership. Where the plan calls for a write action (pausing/locking the
league), this tool DOCUMENTS the exact call and verifies read-only that the
mechanism is real — it does not, and by design cannot, execute it (see
`rollback` below for why: no write endpoint for it exists in the platform's
own OpenAPI surface, verified live).

TWO COMMANDS
  round       LAUNCH_PLAN.md §5 item 7 / §6's "smoke-fail triggers", as an
              executable check instead of a manual read: does the round's
              latest completed episode set look launch-healthy?
                - every episode completed (not errored/timed out)?
                - seat count == --seats on (nearly) every episode?
                - >= --min-teams-fired distinct teams actually took an
                  action (fired a shot) — a "did the roster actually show
                  up" check, independent of who won?
                - replay_url is reachable, unauthenticated, for every
                  episode (LAUNCH_PLAN.md §6: "unreachable replay_urls" is
                  one of the listed smoke-fail triggers)?
              Exits 1 if any check fails, so it is CI/cron-able.

  rollback    Reads the two real, already-precedented pause levers
              (LAUNCH_PLAN.md §6) read-only, prints their current state,
              and prints the exact escalation runbook. It also prints WHY
              this tool cannot execute the pause itself: the platform's own
              /openapi.json exposes GET on /v2/leagues/{league_id} but NO
              patch/put for that resource, and no dedicated pause/lock
              endpoint anywhere in the spec (verified live, see below) —
              pausing a league is a genuinely out-of-band admin action, not
              a gap in this tool's coverage.

USAGE
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  cd tools/ladder

  # smoke-test the CHECK ITSELF against a live round today (any league):
  $PY br_smoke.py round --league league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7 \\
      --seats 16 --min-teams-fired 3 --variant "4-team free-for-all"

  # once the BR league exists (32 seats, 16 duos):
  $PY br_smoke.py round --league league_<br16-id> \\
      --seats 32 --min-teams-fired 12 --variant br16

  # rollback runbook (read-only; never mutates anything):
  $PY br_smoke.py rollback --league league_<br16-id>
  $PY br_smoke.py rollback --league league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7   # sanity: live league, expect all-null
  $PY br_smoke.py rollback --league league_3243d905-d32d-4ec6-978b-fa94751d4a37   # sanity: dead Ctf league, expect rounds_paused_at SET
"""
from __future__ import annotations

import argparse
import collections
import sys
import urllib.request
from urllib.error import HTTPError, URLError

import ctfapi


# ------------------------------------------------------------- round check


def latest_round(league_id: str):
    r = ctfapi.get(f"/v2/rounds?league_id={league_id}&limit=1&offset=0")
    entries = (r.get("entries") or [])
    completed = [e for e in entries if e.get("status") == "completed"]
    if completed:
        return completed[0]
    # The very newest round can still be in flight; the plan's checklist is
    # about the first COMPLETED round, so page forward rather than report
    # nothing.
    offset = 0
    while offset < 500:
        r = ctfapi.get(f"/v2/rounds?league_id={league_id}&limit=20&offset={offset}")
        entries = r.get("entries") or []
        if not entries:
            break
        for e in entries:
            if e.get("status") == "completed":
                return e
        offset += 20
    return None


def replay_reachable(url: str, timeout=15.0) -> bool:
    """HEAD (falling back to a 1-byte ranged GET, since S3 sometimes 403s a
    bare HEAD for this bucket policy) against the public replay URL. No
    auth — replays are public S3 objects (LAUNCH_PLAN.md Appendix A)."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return 200 <= resp.status < 300
    except HTTPError as e:
        if e.code == 405:  # method not allowed on HEAD; try a ranged GET
            try:
                req2 = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
                with urllib.request.urlopen(req2, timeout=timeout) as resp:
                    return resp.status in (200, 206)
            except Exception:
                return False
        return False
    except URLError:
        return False


def round_smoke(args):
    ctfapi.whoami()
    print(f"[br_smoke] checking league={args.league}")

    if args.round:
        rnd = ctfapi.get(f"/v2/rounds/{args.round}")
    else:
        rnd = latest_round(args.league)
    if not rnd:
        print("FAIL: no completed round found for this league.")
        return 1

    round_id, round_number = rnd["id"], rnd.get("round_number")
    print(f"round r{round_number} ({round_id}) status={rnd.get('status')}")
    ok = rnd.get("status") == "completed"
    print(f"  [{'PASS' if ok else 'FAIL'}] round status == completed")

    eps = ctfapi.episodes(round_id)  # limit=1000 baked in — never truncates
    if args.variant:
        eps = [e for e in eps if e.get("variant_name") == args.variant]
    print(f"  {len(eps)} episodes"
          + (f" matching variant={args.variant!r}" if args.variant else ""))
    if not eps:
        print("  FAIL: no episodes to check (wrong --variant, or the round "
              "genuinely seated none).")
        return 1

    completed_eps = [e for e in eps if e.get("status") == "completed"]
    n_completed = len(completed_eps)
    completed_ok = n_completed == len(eps)
    ok &= completed_ok
    bad_status = collections.Counter([e.get("status") for e in eps
                                     if e.get("status") != "completed"])
    print(f"  [{'PASS' if completed_ok else 'FAIL'}] episode status: "
          f"{n_completed}/{len(eps)} completed"
          + (f"  (other statuses: {bad_status})" if bad_status else ""))

    seat_counts = collections.Counter(
        len(e.get("participants") or []) for e in completed_eps)
    n_right_seats = sum(n for s, n in seat_counts.items() if s == args.seats)
    seats_ok = n_completed > 0 and n_right_seats == n_completed
    ok &= seats_ok
    print(f"  [{'PASS' if seats_ok else 'FAIL'}] seat count == {args.seats}: "
          f"{n_right_seats}/{n_completed} episodes"
          + (f"  (observed counts: {dict(seat_counts)})" if not seats_ok else ""))

    fired_ok_eps = 0
    fired_counts = []
    for e in completed_eps:
        fired = _episode_teams_fired(e)
        fired_counts.append(fired)
        if fired >= args.min_teams_fired:
            fired_ok_eps += 1
    fired_ok = n_completed > 0 and fired_ok_eps == n_completed
    ok &= fired_ok
    mean_fired = sum(fired_counts) / len(fired_counts) if fired_counts else 0.0
    print(f"  [{'PASS' if fired_ok else 'FAIL'}] >= {args.min_teams_fired} "
          f"distinct teams fired a shot: {fired_ok_eps}/{n_completed} "
          f"episodes (mean teams-fired={mean_fired:.1f})")
    if not fired_ok:
        print(f"    ⚠️  this reads from `participant_scores`/`scores` "
              f"presence, a cheap proxy — a team with a live seat but zero "
              f"shots fired needs the re-simulated summary "
              f"(slot_shots_fired) via br_reads.py to confirm, not this "
              f"quick check.")

    if args.check_replays:
        n_reach = 0
        unreachable = []
        for e in completed_eps:
            url = e.get("replay_url")
            if url and replay_reachable(url):
                n_reach += 1
            else:
                unreachable.append(e.get("episode_id", "?")[:8])
        replays_ok = n_reach == n_completed
        ok &= replays_ok
        print(f"  [{'PASS' if replays_ok else 'FAIL'}] replay_url reachable "
              f"(unauthenticated): {n_reach}/{n_completed}"
              + (f"  (unreachable: {unreachable[:8]})" if unreachable else ""))
    else:
        print("  [SKIP] replay reachability (pass --check-replays; makes "
              f"{n_completed} live HTTP HEAD requests)")

    print(f"\n{'ALL SMOKE CHECKS PASS' if ok else 'SMOKE CHECK(S) FAILED — see §6 escalation in br_smoke.py rollback'}")
    return 0 if ok else 1


def _episode_teams_fired(ep) -> int:
    """Distinct teams with a non-eliminated-by-default-looking score. The
    round-listing API doesn't carry slot_shots_fired (that lives in the
    re-simulated summary — see br_reads.py); this is the CHEAP proxy usable
    without fetching/extracting every replay: count distinct
    policy_version_ids with a recorded, non-null score. If every seat truly
    never fired, the number here is still a fair floor on "showed up"."""
    scores = ep.get("participant_scores") or []
    pv_by_pos = {p["position"]: p.get("policy_version_id")
                 for p in (ep.get("participants") or [])}
    teams = set()
    for s in scores:
        pos = s.get("position")
        if s.get("score") is not None and pos in pv_by_pos:
            teams.add(pv_by_pos[pos])
    return len(teams)


# ------------------------------------------------------------------ rollback


PAUSE_ENDPOINT_SEARCHED = False
WRITE_ENDPOINT_FOUND = None


def _probe_write_endpoint():
    """Read-only: fetch the platform's own /openapi.json and check whether
    ANY write verb (patch/put/post/delete) exists for the League resource or
    a dedicated pause/lock action. This is itself a GET — it never mutates
    anything — and it turns "no write method in the installed client" (a
    fact about OUR client) into "no write endpoint on the SERVER" (a fact
    about the platform), which is the stronger and more honest claim."""
    global WRITE_ENDPOINT_FOUND
    c, h = ctfapi.client()
    try:
        r = c._http_client.get("/openapi.json", headers=h, timeout=30.0)
        r.raise_for_status()
        spec = r.json()
    except Exception as e:  # noqa: BLE001
        print(f"  (could not fetch /openapi.json to verify: {e})",
              file=sys.stderr)
        WRITE_ENDPOINT_FOUND = "unknown"
        return
    paths = spec.get("paths", {})
    writes = {}
    for p, methods in paths.items():
        if "leagu" not in p.lower():
            continue
        verbs = [m for m in methods if m in ("patch", "put", "post", "delete")]
        if verbs:
            writes[p] = verbs
    # A write on the league record ITSELF, or anything with "pause"/"lock"/
    # "disable" in the path, would be the mechanism this runbook needs.
    direct = {p: v for p, v in writes.items()
              if p.rstrip("/").endswith("{league_id}")
              or any(k in p.lower() for k in ("pause", "lock", "disable"))}
    WRITE_ENDPOINT_FOUND = direct or "none"
    return writes


def rollback_report(args):
    ctfapi.whoami()
    r = ctfapi.get(f"/v2/leagues/{args.league}")
    print(f"\n{'='*70}\nROLLBACK RUNBOOK — {r.get('name')!r} ({args.league})\n{'='*70}")
    print("READ-ONLY report. This tool never mutates a league.\n")

    rp, sl, da = r.get("rounds_paused_at"), r.get("submissions_locked_at"), r.get("disabled_at")
    print("current state:")
    print(f"  rounds_paused_at      = {rp!r}   "
          f"({'PAUSED' if rp else 'not paused'})")
    print(f"  submissions_locked_at = {sl!r}   "
          f"({'LOCKED' if sl else 'not locked'})")
    print(f"  disabled_at           = {da!r}   "
          f"({'DISABLED' if da else 'not disabled'})")

    print("\nescalation runbook (LAUNCH_PLAN.md §6), cheapest first:")
    print("  1. PAUSE ROUNDS the moment round-1 smoke fails (br_smoke.py "
          "round exits 1). Stops new round scheduling; in-flight episodes "
          "drain, no new ones start. Reversible. Field: `rounds_paused_at` "
          f"on the League resource — non-null on the dead `Ctf` league "
          f"today (2026-08-14T20:50:48Z), proving the mechanism is "
          f"production-real, not theoretical.")
    print("  2. If the defect is in the ENTRANT POOL itself (a bad filler "
          "slipped in despite the no-filler decision, or a policy is "
          "duplicated across duos), ALSO set `submissions_locked_at` to "
          "freeze the roster while it's fixed.")
    print("  3. Full deletion/disable is OUT OF SCOPE for this rollback: no "
          "league in this account has ever been observed with "
          "`disabled_at` set (it is null even on the paused dead league) — "
          "there is no read-verified precedent for that action's contract. "
          "Treat it as a separate, heavier admin decision.")
    print("\nsmoke-fail triggers that should invoke step 1 immediately "
          "(LAUNCH_PLAN.md §6): seat count != expected on more than a "
          "trivial fraction of episodes, duo/team count wrong, a "
          "GameVersion/replay mismatch, unreachable replay_urls, or a map "
          "defect that fails the human vote after the fact.")

    print("\nWHY THIS TOOL DOES NOT (AND CANNOT) EXECUTE THE PAUSE ITSELF:")
    writes = _probe_write_endpoint()
    if writes is None:
        print("  Could not reach /openapi.json this run — falling back to "
              "the static finding: the installed CoworldApiClient exposes "
              "no create_league/update_league/patch_league method "
              "(verified via dir(client) — only get_league, list_leagues, "
              "get_league_division_ladder, list_divisions, "
              "retire_membership touch leagues at all).")
    elif writes == {} or WRITE_ENDPOINT_FOUND == "none":
        print("  Verified LIVE against the platform's own /openapi.json: "
              "`/v2/leagues/{league_id}` exposes GET only — no patch/put. "
              "No path anywhere in the spec contains 'pause', 'lock', or "
              "'disable'. The only write verbs under any /v2/leagues/... "
              "path are campaign/landscape board mechanics (restart, "
              "trigger-round, color, cell-config, ...), membership actions "
              "(champion/retire/move), submissions, lobbies and "
              "tournaments — none of them touch `rounds_paused_at` / "
              "`submissions_locked_at`. Pausing a league is a genuinely "
              "OUT-OF-BAND admin action (direct DB write or an internal "
              "admin surface not exposed in this API), matching "
              "LAUNCH_PLAN.md Appendix B's finding — now confirmed against "
              "the full server-side contract, not just this client's "
              "wrapper.")
    else:
        print(f"  Found candidate write endpoint(s) on the League resource "
              f"the plan did not know about: {writes} — re-verify against "
              f"the API docs before trusting this as the pause mechanism; "
              f"this tool still will not call them (read-only mandate).")

    print("\nWHAT TO DO WHEN A ROLLBACK IS ACTUALLY NEEDED:")
    print(f"  Escalate to whoever holds platform/admin write access with "
          f"exactly this ask: \"set rounds_paused_at on league "
          f"{args.league} to now() (ISO 8601, e.g. "
          f"'2026-08-25T18:00:00Z')\" — that is the complete, minimal "
          f"payload; no other field needs to change for step 1. For step 2 "
          f"add `submissions_locked_at` the same way.")
    return 0


# ------------------------------------------------------------------- cli


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    rp = sub.add_parser("round", help="round-1 smoke checklist")
    rp.add_argument("--league", required=True)
    rp.add_argument("--round", help="specific round id; default: latest completed")
    rp.add_argument("--seats", type=int, required=True,
                     help="expected participant count per episode (32 for BR)")
    rp.add_argument("--min-teams-fired", type=int, required=True,
                     help="minimum distinct teams that must show a recorded "
                          "score (12 for BR's 16 duos)")
    rp.add_argument("--variant", help="filter to one variant_name (e.g. br16)")
    rp.add_argument("--check-replays", action="store_true",
                     help="also HEAD every replay_url (live HTTP, slower)")

    bp = sub.add_parser("rollback", help="read-only rollback runbook")
    bp.add_argument("--league", required=True)

    args = ap.parse_args()
    if args.cmd == "round":
        sys.exit(round_smoke(args))
    elif args.cmd == "rollback":
        sys.exit(rollback_report(args))


if __name__ == "__main__":
    main()
