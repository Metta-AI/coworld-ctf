#!/usr/bin/env python3
"""GLORY GRADIENT Step A pre-read / post-read snapshot (read-only audit tooling).

One command produces a timestamped markdown snapshot of the Step A surface for
league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7 (Paintbot Season 2, "Competition"
division): the league settings doc (if a non-elevated bearer can read it), the
full standings table, the latest-COMPLETED-round anchor, and for every raw
standing S the precomputed ``sign(S)*log2(1+|S|)`` (runbook check 2's target)
plus its inverse round-trip (runbook check 3's expected "Typical episode" value).

Runbook: ~/.ctf/knowledge/glory-gradient/00r-MORNING-RUNBOOK-2026-09-09.md #5.
Spec:    ~/.ctf/knowledge/glory-gradient/00q-post-body-spec-2026-09-09.md

READ-ONLY, public-API-only (plus one documented operator GET):
  - GET /divisions/{division_id}/leaderboard  -- anonymous-tolerant public
    standings (rounds.py:OPTIONAL_COMMISSIONER_OR_SUBMITTER_AUTH); this is the
    same surface softmax.com/watch reads with no session at all.
  - GET /rounds?division_id=...               -- anonymous-tolerant public
    round list (Corpus scope, "anonymous explorer may list every visible
    round with no filter"). division_id is the ONLY filter that actually
    works server-side (league_id and offset are silently ignored) --
    ctf-rounds-endpoint-filter-and-offset-traps. Deeper pages use the opaque
    `cursor` param (requests percent-encodes it correctly; a raw `+` 422s).
  - GET /leagues/{league_id}/settings          -- "Anyone who can see the
    league can read its settings" (metta leagues.py:2696, docstring quoted
    verbatim), gated by COMMISSIONER_OR_SUBMITTER_AUTH: a plain SUBMITTER
    bearer (no team-member flag, no elevation) is already inside that surface
    for a PUBLIC league. This script sends a bearer if one can be found and
    NOTHING else -- no `X-Use-Elevated-Privileges` header, ever (that header
    is the documented elevation mechanism in
    ctf-league-admin-key-is-the-elevation-header and is out of scope here).
    If no bearer is found, or the read is refused, the settings section is
    skipped and the reason is recorded -- this script never goes looking for
    a better credential.

No POST/PUT/PATCH/DELETE, no /internal/*, no kubectl, no elevated headers, no
other league. This is intentionally a strict subset of what 00k/00m did (those
used an elevated header and a DB replica via kubectl -- both forbidden here).

The QUERY_SPEC below (endpoints + fixed params) must be identical between a
Step-A-pre and a Step-A-post run -- that is what lets step_a_diff.py treat the
two snapshots as a diff instead of two independent measurements. Only --label
(the output filename) and time change between such a pair; QUERY_SPEC is
fingerprinted into every snapshot so a diff can assert the two reads actually
used the same query.

Usage:
    python3 tools/glory/step_a_read.py --label rehearsal
    python3 tools/glory/step_a_read.py --label A-pre
    python3 tools/glory/step_a_read.py --label A-post
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
from datetime import datetime, timezone

import requests

API_BASE = "https://softmax.com/api/observatory/v2"
LEAGUE_ID = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
DIVISION_ID = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"  # "Competition" -- 00m header + traps memory
OUT_DIR_DEFAULT = os.path.expanduser("~/.ctf/knowledge/glory-gradient")

# Cloudflare 403s (error code 1010) a bare urllib/default-requests UA on
# softmax.com and reads exactly like a rejected credential -- it is not one.
# A browser UA is not an elevation/admin header, just what any browser sends.
# See ctf-softmax-token-is-url-keyed / ctf-league-admin-key-is-the-elevation-header.
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

# Hard rule for this tool (owner-set access boundary, not a platform requirement):
# never send an elevation/admin header. Enforced by construction below -- no code
# path in this file ever sets one -- and re-asserted defensively in `Api.get`.
FORBIDDEN_HEADER_NAMES = {"x-use-elevated-privileges"}

# The exact, fixed query set this script issues every run. Keep this literal and
# sorted so the fingerprint is stable across a pre/post pair. Cursor pagination on
# /rounds is a mechanical detail of walking to the newest COMPLETED round within
# this spec, not a change to the spec itself.
QUERY_SPEC = [
    {
        "method": "GET",
        "path": "/divisions/{division_id}/leaderboard",
        "params": {"include_recent_rounds": "true"},
    },
    {
        "method": "GET",
        "path": "/rounds",
        "params": {"division_id": "{division_id}", "limit": 100},
    },
    {"method": "GET", "path": "/leagues/{league_id}/settings", "params": {}},
]


def query_fingerprint() -> str:
    canon = json.dumps(QUERY_SPEC, sort_keys=True)
    return hashlib.sha256(canon.encode()).hexdigest()[:16]


def load_softmax_token() -> str | None:
    """~/.softmax/credentials.yaml holds THREE url-keyed tokens with DIFFERENT
    values; select the entry whose KEY contains softmax.com, never by position
    (ctf-softmax-token-is-url-keyed -- picking by position silently authenticates
    as garbage, and reads pass anyway because GETs here are auth-optional, so the
    defect only surfaces on a write or an auth-gated read like /settings)."""
    path = os.path.expanduser("~/.softmax/credentials.yaml")
    try:
        with open(path) as f:
            src = f.read()
    except OSError:
        return None
    m = re.search(r"tokens:\s*\n((?:[ \t]+\S.*\n?)+)", src)
    if not m:
        return None
    for line in m.group(1).strip().split("\n"):
        if ":" not in line:
            continue
        key, _, tok = line.strip().rpartition(":")
        if "softmax.com" in key:
            return tok.strip()
    return None


def signed_log2(value: float) -> float:
    """sign(x) * log2(1+|x|) -- mirrors app_backend/v2/ladders/config.py exactly
    (origin/main, confirmed by direct read at prep time)."""
    if value == 0:
        return 0.0
    mag = math.log2(1 + abs(value))
    return mag if value > 0 else -mag


def inverse_signed_log2(value: float) -> float:
    """sign(x) * (2^|x| - 1) -- exact inverse of signed_log2."""
    if value == 0:
        return 0.0
    mag = 2.0**abs(value) - 1.0
    return mag if value > 0 else -mag


class Api:
    def __init__(self, token: str | None):
        self.token = token
        self.session = requests.Session()
        self.session.headers["User-Agent"] = UA
        if token:
            self.session.headers["Authorization"] = f"Bearer {token}"

    def get(self, path: str, params: dict | None = None) -> requests.Response:
        bad = FORBIDDEN_HEADER_NAMES & {h.lower() for h in self.session.headers}
        assert not bad, f"refusing to send forbidden header(s): {bad}"
        return self.session.get(f"{API_BASE}{path}", params=params, timeout=60)


def fetch_standings(api: Api, division_id: str) -> list[dict]:
    r = api.get(f"/divisions/{division_id}/leaderboard", params={"include_recent_rounds": "true"})
    r.raise_for_status()
    rows = r.json()
    return rows or []


def fetch_completed_rounds(api: Api, division_id: str, max_pages: int = 5) -> list[dict]:
    """Walk the division's /rounds list (newest-first per RoundListPublic;
    division_id is the only working server-side filter --
    ctf-rounds-endpoint-filter-and-offset-traps; walk `cursor` pages, never
    `next_cursor=` as a literal param name, never rely on `offset`) and
    return every status=="completed" entry seen, up to max_pages*100 rounds
    (~500 rounds / several days at the observed ~600s cadence -- see
    00n-cadence-*.md). This is DIVISION-WIDE, unlike each subject's
    `recent_rounds` (a small trailing per-player window that can miss a
    round entirely for a subject who did not play it) -- it is the source
    for both the single-round anchor (latest_completed_round) and Step A
    deliverable 4's round-start attribution in step_a_diff.py, which needs
    every round that completed in a time window, not just each subject's
    own last-scored one.

    NOTE (observed, not assumed -- ctf-cohort-boundary-is-observed-never-inferred):
    every entry's `started_at` has been observed null across all rounds
    walked (RoundExecutionBackend.dispatch / scheduled_by=ladder rounds never
    populate it -- confirmed against metta origin/main
    v2/orchestration/workflows.py: LeagueLadderWorkflow paces off
    `latest_round_created_at`, not started_at). `created_at` is therefore the
    only observed, populated start-proxy and is what round-start
    classification uses -- each entry keeps `started_at` too so a future run
    where it IS populated is used automatically (see `round_start_at` in
    step_a_diff.py)."""
    cursor = None
    completed: list[dict] = []
    for _ in range(max_pages):
        params = {"division_id": division_id, "limit": 100}
        if cursor:
            params["cursor"] = cursor
        r = api.get("/rounds", params=params)
        r.raise_for_status()
        body = r.json()
        entries = body.get("entries") or []
        for e in entries:
            if e.get("status") == "completed":
                completed.append(
                    {
                        "round_number": e.get("round_number"),
                        "id": e.get("id"),
                        "status": e.get("status"),
                        "created_at": e.get("created_at"),
                        "started_at": e.get("started_at"),
                        "completed_at": e.get("completed_at"),
                    }
                )
        cursor = body.get("next_cursor")
        if not cursor:
            break
    completed.sort(key=lambda x: x.get("round_number") or 0)
    return completed


def latest_completed_round(api: Api, division_id: str, max_pages: int = 5) -> dict | None:
    """Highest-round_number entry from fetch_completed_rounds -- the newest
    COMPLETED round within the paged window walked (the newest round in the
    list may still be running/scheduled, hence filtering to completed)."""
    completed = fetch_completed_rounds(api, division_id, max_pages=max_pages)
    return completed[-1] if completed else None


def fetch_settings(api: Api) -> tuple[dict | None, str]:
    """Returns (settings_json_or_None, reason). Never retries with a different
    credential or header -- a refusal here is reported, not escalated."""
    if not api.token:
        return None, "no softmax.com-keyed bearer found in ~/.softmax/credentials.yaml"
    try:
        r = api.get(f"/leagues/{LEAGUE_ID}/settings")
    except requests.RequestException as e:
        return None, f"request error: {type(e).__name__}: {e}"
    if r.status_code == 200:
        return r.json(), "200 via COMMISSIONER_OR_SUBMITTER_AUTH surface, plain bearer, no elevation header"
    return None, f"HTTP {r.status_code} (not escalating; banking public reads only)"


def subject_last_scored_round(entry: dict) -> dict | None:
    rr = [x for x in (entry.get("recent_rounds") or []) if x.get("status") == "completed"]
    if not rr:
        return None
    rr.sort(key=lambda x: x.get("round_number") or 0)
    last = rr[-1]
    return {"round_number": last.get("round_number"), "completed_at": last.get("completed_at")}


def build_rows(standings: list[dict]) -> list[dict]:
    rows = []
    for e in standings:
        raw = float(e["score"])
        pre = round(signed_log2(raw), 6)
        inv = round(inverse_signed_log2(pre), 6)
        last_round = subject_last_scored_round(e)
        rows.append(
            {
                "rank": e.get("rank"),
                "subject_id": e.get("player_id"),
                "display_name": e.get("player_name"),
                "raw_standing": raw,
                "score_label": e.get("score_label", "Score"),
                "rounds_played": e.get("rounds_played"),
                "last_scored_round_number": (last_round or {}).get("round_number"),
                "last_scored_round_completed_at": (last_round or {}).get("completed_at"),
                "precomputed_signed_log2_6dp": pre,
                "inverse_check_6dp": inv,
            }
        )
    rows.sort(key=lambda r: (r["rank"] if r["rank"] is not None else 1 << 30))
    return rows


def render_markdown(snapshot: dict) -> str:
    h = snapshot["header"]
    lines = []
    lines.append(f"# GLORY GRADIENT Step A read — {h['label']} — {h['timestamp_utc']}")
    lines.append("")
    lines.append(
        "Read-only, public /v2 endpoints only (plus one documented operator GET). "
        "No POST/PUT/PATCH/DELETE, no /internal/*, no kubectl, no elevated headers."
    )
    lines.append("")
    lines.append(f"- league_id: `{h['league_id']}`")
    lines.append(f"- division_id: `{h['division_id']}` (Competition)")
    lines.append(f"- timestamp_utc: `{h['timestamp_utc']}`")
    lines.append(f"- QUERY FINGERPRINT: `{h['query_fingerprint']}`")
    lines.append(f"  - endpoints: {h['query_spec_summary']}")
    lines.append(f"- settings_readable: **{h['settings_readable']}** ({h['settings_reason']})")
    lines.append("")

    lines.append("## League settings")
    if snapshot["settings"] is not None:
        s = snapshot["settings"]
        try:
            ranking = s["settings"]["ladder"]["ranking"]
            transform = ranking.get("season_leg_transform")
            rated_k = ranking.get("rated_k")
        except (KeyError, TypeError):
            transform = None
            rated_k = None
        lines.append(f"- `ladder.ranking.season_leg_transform` = **{transform!r}**")
        lines.append(f"- `ladder.ranking.rated_k` = **{rated_k!r}**")
        lines.append("")
        lines.append("Full settings JSON (config only, nothing redacted):")
        lines.append("```json")
        lines.append(json.dumps(s, indent=2, sort_keys=True))
        lines.append("```")
    else:
        lines.append(f"NOT READ: {h['settings_reason']}")
    lines.append("")

    a = snapshot["anchor_round"]
    lines.append("## Anchor: latest COMPLETED round")
    if a:
        lines.append(f"- round_number: **{a.get('round_number')}**")
        lines.append(f"- round id: `{a.get('id')}`")
        lines.append(f"- completed_at: `{a.get('completed_at')}`")
        lines.append(f"- status: `{a.get('status')}`")
    else:
        lines.append("NOT FOUND within the paged window walked.")
    lines.append("")

    crs = snapshot.get("completed_rounds_seen") or []
    lines.append("## Completed rounds seen (division-wide, this read's paged window)")
    if crs:
        lines.append(
            f"- {len(crs)} completed round(s), r{crs[0]['round_number']}..r{crs[-1]['round_number']}"
        )
        lines.append(
            "- `started_at` observed null on every round walked (see fetch_completed_rounds "
            "docstring); `created_at` is the start-proxy step_a_diff.py's --post-at "
            "classification uses. Full per-round table is in the raw JSON block below."
        )
    else:
        lines.append("NOT FOUND within the paged window walked.")
    lines.append("")

    lines.append("## Standings (full table)")
    lines.append(
        "`raw_standing` is whatever the public leaderboard's `score` field carries "
        "right now (`score_label` says whether that is pre-arm `Score` or post-arm "
        "`Typical episode`). `precomputed_signed_log2_6dp` = runbook check 2's "
        "target for the NEW internal raw standing after arming (sign(S)*log2(1+|S|), "
        "6dp) -- not independently re-readable from the public API post-arm, banked "
        "here for whoever has the DB-level read. `inverse_check_6dp` = "
        "inverse_signed_log2(precomputed_signed_log2_6dp); by construction this is a "
        "pure round-trip of raw_standing and therefore also runbook check 3's exact "
        "expected value for the post-arm `Typical episode` display. `rounds_played` "
        "is already SUBJECT-keyed (one_row_per_player on the server; player_id IS the "
        "subject id) -- see ctf-rated-standing-decays-per-subject."
    )
    lines.append("")
    lines.append(
        "| rank | subject_id | display_name | raw_standing | score_label | rounds_played "
        "| last_scored_round | precomputed_signed_log2_6dp | inverse_check_6dp |"
    )
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for r in snapshot["rows"]:
        last = r["last_scored_round_number"]
        last_at = r["last_scored_round_completed_at"]
        last_str = f"r{last} ({last_at})" if last is not None else "—"
        lines.append(
            f"| {r['rank']} | {r['subject_id']} | {r['display_name']} | {r['raw_standing']:.4f} "
            f"| {r['score_label']} | {r['rounds_played']} | {last_str} "
            f"| {r['precomputed_signed_log2_6dp']:.6f} | {r['inverse_check_6dp']:.6f} |"
        )
    lines.append("")

    lines.append(
        "## Raw data (machine-readable; step_a_diff.py parses this block, not the table above)"
    )
    lines.append("```json")
    lines.append(json.dumps(snapshot, indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="pre-post-read", help="filename label, e.g. rehearsal / A-pre / A-post")
    ap.add_argument("--out-dir", default=OUT_DIR_DEFAULT)
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    ts_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ts_file = now.strftime("%Y%m%dT%H%M%SZ")

    token = load_softmax_token()
    api = Api(token)

    standings = fetch_standings(api, DIVISION_ID)
    completed_rounds_seen = fetch_completed_rounds(api, DIVISION_ID)
    anchor = completed_rounds_seen[-1] if completed_rounds_seen else None
    settings, settings_reason = fetch_settings(api)

    rows = build_rows(standings)

    query_spec_summary = "; ".join(
        f"{q['method']} {q['path'].format(division_id=DIVISION_ID, league_id=LEAGUE_ID)}"
        + (f"?{ '&'.join(f'{k}={v}' for k, v in q['params'].items()) }" if q["params"] else "")
        for q in QUERY_SPEC
    )

    snapshot = {
        "header": {
            "label": args.label,
            "purpose": "GLORY GRADIENT Step A pre/post-read — read-only audit of the season_leg_transform arm",
            "league_id": LEAGUE_ID,
            "division_id": DIVISION_ID,
            "timestamp_utc": ts_iso,
            "query_fingerprint": query_fingerprint(),
            "query_spec_summary": query_spec_summary,
            "settings_readable": settings is not None,
            "settings_reason": settings_reason,
            "access_path": (
                "public Observatory v2 API (softmax.com/api/observatory/v2), plain bearer "
                "(no elevation header), browser UA to clear Cloudflare; settings GET uses the "
                "same plain bearer under COMMISSIONER_OR_SUBMITTER_AUTH. No DB replica, no "
                "kubectl -- contrast with 00m/00k which used STATS_DB_READ_ONLY_URI via "
                "kubectl exec, out of scope here."
            ),
        },
        "settings": settings,
        "anchor_round": anchor,
        "rows": rows,
        # Division-wide, newest-first-walked completed rounds (round_number, id,
        # created_at, started_at, completed_at) -- NOT just each subject's own
        # last-scored round. Feeds step_a_diff.py's --post-at round-start
        # attribution (deliverable 4): "every round that completed between the
        # two snapshots" is computed from the union of this list across both
        # snapshot files, filtered to the (a.timestamp_utc, b.timestamp_utc]
        # window, not by re-querying the API. Older snapshots (pre this field)
        # simply contribute nothing to that union -- step_a_diff.py degrades
        # gracefully, never KeyErrors on a missing field.
        "completed_rounds_seen": completed_rounds_seen,
    }

    out_dir = os.path.expanduser(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"00n-{args.label}-{ts_file}.md")
    with open(out_path, "w") as f:
        f.write(render_markdown(snapshot))

    print(f"wrote {out_path}")
    print(f"query fingerprint: {snapshot['header']['query_fingerprint']}")
    print(f"settings_readable: {snapshot['header']['settings_readable']} ({settings_reason})")
    if anchor:
        print(f"anchor round: r{anchor.get('round_number')} id={anchor.get('id')} completed_at={anchor.get('completed_at')}")
    else:
        print("anchor round: NOT FOUND")
    print(f"completed_rounds_seen: {len(completed_rounds_seen)}")
    print(f"rows: {len(rows)}")
    for r in rows[:5]:
        print(
            f"  rank={r['rank']} subject={r['subject_id']} name={r['display_name']} "
            f"raw={r['raw_standing']:.4f} label={r['score_label']} rounds_played={r['rounds_played']} "
            f"log2={r['precomputed_signed_log2_6dp']:.6f} inv_check={r['inverse_check_6dp']:.6f}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
