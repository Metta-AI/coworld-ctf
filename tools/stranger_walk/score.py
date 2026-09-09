#!/usr/bin/env python3
"""
tools/stranger_walk/score.py <run-id> [runs-parent]

Scores a completed Stranger Walk run from its transcript.jsonl + meta.json
(written by run.sh). Writes <run-dir>/score.json and prints one markdown
table row to stdout.

Protocol v2 (2026-09-09, owner ruling): the stranger prompt no longer hands
out the eight milestones or asks for `BELIEF:`/`MILESTONE:` lines — doing so
was hand-holding, priming the stranger to go looking for exactly the eight
things being measured. This script now computes ONLY what's mechanically
derivable from the transcript with no cooperation from the stranger: tool
call counts, digs (cross-host WebFetch/WebSearch transitions), and stuck
episodes (>=10-minute gaps between consecutive assistant turns). It leaves
`milestones` and `beliefs` as empty scaffolding for the judge to fill in by
hand, per judge.md's "post-hoc extraction" section: the judge reads the
plain think-aloud transcript, decides where each M1-M8 was actually reached
and what beliefs were stated, and grades each belief true/false/partly/
unknowable using outside knowledge the stranger didn't have — all in one
pass, since there's no separate self-reported claim to grade against.

Re-running this script is safe: if `milestones`/`beliefs` already have
judge-authored content in an existing score.json, that content is preserved
across a re-run (only the mechanical fields are recomputed) — so a judge can
score.py once for the mechanical skeleton, hand-edit score.json to fill in
milestones/beliefs, and re-run this script later (e.g. after a scoring
methodology tweak) without losing that work.

The one exception to "no cooperation from the stranger": `WAITING: ` is kept
in prompt.md (see its Protocol v2 note) because it's not milestone
scaffolding — it's the literal handshake resume.sh needs to pause a run on a
human-relayed signup/verification code. This script still finds those lines
and tags the gap that follows as `owner_latency` (real time spent blocked on
a human, not the stranger running out of ideas) rather than genuine stuck
time.

Definitions:
  - tool_call_count at a point in time = number of tool_use blocks seen in
    earlier assistant turns.
  - a "dig" = a transition to a different host/surface via WebFetch (by URL
    netloc) or WebSearch (treated as a "web-search" pseudo-host), collapsing
    immediate repeats. dig_count = distinct transitions in that collapsed
    sequence.
  - a "stuck episode" = a gap >= 10 minutes between consecutive assistant
    turns (or from run start to the first turn), with the tool calls
    attempted during the gap attached for the judge to read and explain in
    one line (a missing link, a confusing label, a slow page, a dead end).

CAVEAT (measured empirically against Protocol v1 transcripts, 2026-09-09):
this per-turn-gap definition is coarser than it sounds. A stranger that's
genuinely waiting on a slow qualification round tends to check in every
30-300s (a poll loop, a `browser_wait_for`, a quick status re-check) rather
than falling silent for a single unbroken 10+ minute stretch — so a real
~15-20 minute wait can show up here as several turn-gaps that individually
never cross the 10-minute line, and this script will under-report it. Tool-
name/keyword heuristics to stitch those check-ins into one episode were
tried and rejected: they either missed real waits (requiring literal
`sleep`/`wait_for` primitives) or produced runaway false positives (a
200+ minute "episode" once a keyword like "round"/"standing" matched
ordinary research tool calls for long stretches of a run). The judge's own
read of `stuck_episodes[].tool_calls_during` — and of the surrounding
transcript generally — is the authoritative account of what blocked
progress; treat `stuck_minutes_total` as a lower bound, not a measurement.
"""
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlparse

WAITING_PREFIX = "WAITING:"

STUCK_THRESHOLD_S = 10 * 60


def iso_to_epoch(ts):
    ts = ts.rstrip("Z")
    fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in ts else "%Y-%m-%dT%H:%M:%S"
    return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc).timestamp()


def load_jsonl(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def host_of(url):
    try:
        return urlparse(url).netloc or url
    except Exception:
        return url


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    run_id = sys.argv[1]
    runs_parent = sys.argv[2] if len(sys.argv) > 2 else os.environ.get(
        "STRANGER_RUNS_PARENT", "/Users/maxwellstarr/projects/stranger-walk-runs")
    run_dir = os.path.join(runs_parent, run_id)
    meta = json.load(open(os.path.join(run_dir, "meta.json")))
    start_epoch = meta["start_epoch"]

    # Preserve any judge-authored milestones/beliefs already sitting in an
    # existing score.json (see module docstring) — this script never
    # overwrites hand-judged content, only the mechanical fields around it.
    existing_path = os.path.join(run_dir, "score.json")
    prior_milestones, prior_beliefs, prior_furthest = {}, [], None
    if os.path.exists(existing_path):
        try:
            prior = json.load(open(existing_path))
            prior_milestones = prior.get("milestones") or {}
            prior_beliefs = prior.get("beliefs") or []
            prior_furthest = prior.get("furthest_milestone")
        except (json.JSONDecodeError, OSError):
            pass

    tool_call_count = 0
    waiting_events = []
    turn_events = []  # (epoch, turn_had_waiting)
    dig_sequence = []  # (epoch, host)
    tool_calls_log = []  # (epoch, tool_name, input)

    for event in load_jsonl(os.path.join(run_dir, "transcript.jsonl")):
        if event.get("type") != "assistant":
            continue
        ts = event.get("timestamp")
        epoch = iso_to_epoch(ts) if ts else None
        content = event.get("message", {}).get("content", []) or []
        turn_had_waiting = False
        for block in content:
            btype = block.get("type")
            if btype == "text":
                for line in block.get("text", "").splitlines():
                    stripped = line.strip()
                    if stripped.startswith(WAITING_PREFIX):
                        waiting_events.append({
                            "text": stripped[len(WAITING_PREFIX):].strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        })
                        turn_had_waiting = True
            elif btype == "tool_use":
                tool_call_count += 1
                name = block.get("name")
                tin = block.get("input", {}) or {}
                tool_calls_log.append((epoch, name, tin))
                url = tin.get("url")
                query = tin.get("query")
                if name == "WebFetch" and url:
                    dig_sequence.append((epoch, host_of(url)))
                elif name == "WebSearch" and query is not None:
                    dig_sequence.append((epoch, "web-search"))
        if epoch is not None:
            turn_events.append((epoch, turn_had_waiting))

    collapsed = []
    for _, h in dig_sequence:
        if not collapsed or collapsed[-1] != h:
            collapsed.append(h)
    dig_count = max(0, len(collapsed) - 1)

    turn_events.sort(key=lambda e: e[0])
    stuck_episodes = []
    prev_epoch = start_epoch
    prev_had_waiting = False
    for epoch, turn_had_waiting in turn_events:
        gap = epoch - prev_epoch
        if gap >= STUCK_THRESHOLD_S:
            attempted = [
                {"tool": name, "input": tin}
                for (te, name, tin) in tool_calls_log
                if te is not None and prev_epoch <= te <= epoch
            ]
            stuck_episodes.append({
                "from_epoch": prev_epoch,
                "to_epoch": epoch,
                "duration_min": round(gap / 60, 1),
                "tool_calls_during": attempted,
                # True when the gap starts right after a turn containing a
                # WAITING: line — the stranger was blocked on a human (owner
                # relaying a code), not out of ideas. Report separately.
                "owner_latency": prev_had_waiting,
            })
        prev_epoch = epoch
        prev_had_waiting = turn_had_waiting

    result = {
        "run_id": run_id,
        "model": meta.get("model"),
        "prompt_sha256": meta.get("prompt_sha256"),
        "entry_url_resolved": meta.get("entry_url_resolved"),
        "wall_clock_seconds": meta.get("wall_clock_seconds"),
        "total_tool_calls": tool_call_count,
        "dig_count": dig_count,
        "dig_hosts_in_order": collapsed,
        # Filled in by the judge, post-hoc, from the plain transcript — see
        # judge.md "Post-hoc milestone & belief extraction (Protocol v2)".
        # Same shape as Protocol v1 so downstream tooling (e.g.
        # legibility_cut.py) doesn't need to change: milestones is
        # {mid: {timestamp, elapsed_s, tool_call_count, sentence}}, beliefs
        # is a list of {text, timestamp, elapsed_s, tool_call_count,
        # verdict, source, note}.
        "milestones": prior_milestones,
        "furthest_milestone": prior_furthest,
        "beliefs": prior_beliefs,
        "belief_count": len(prior_beliefs),
        "judged": bool(prior_milestones or prior_beliefs),
        "stuck_episodes": stuck_episodes,
        "stuck_minutes_total": round(
            sum(s["duration_min"] for s in stuck_episodes if not s["owner_latency"]), 1),
        "owner_latency_minutes_total": round(
            sum(s["duration_min"] for s in stuck_episodes if s["owner_latency"]), 1),
        "waiting_events": waiting_events,
        "resume_count": len(meta.get("resumes", [])),
        "resume_kinds": [r.get("kind", "owner_relay") for r in meta.get("resumes", [])],
    }

    out_path = os.path.join(run_dir, "score.json")
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    wall_s = meta.get("wall_clock_seconds") or 0
    hours = wall_s / 3600
    md = (
        f"| {run_id} | {meta.get('model')} | {result['furthest_milestone'] or 'UNJUDGED'} | "
        f"{hours:.2f}h | {tool_call_count} | {dig_count} | "
        f"{result['stuck_minutes_total']}m | {result['owner_latency_minutes_total']}m | "
        f"{result['belief_count']} | {'yes' if result['judged'] else 'no (run judge.md)'} |"
    )
    print(md)
    print(f"# wrote {out_path}", file=sys.stderr)
    if not result["judged"]:
        print(
            f"# NOTE: {run_id} has no judge-authored milestones/beliefs yet — "
            "apply judge.md's post-hoc extraction and re-save score.json before "
            "using this run in a report.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
