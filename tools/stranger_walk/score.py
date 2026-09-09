#!/usr/bin/env python3
"""
tools/stranger_walk/score.py <run-id> [runs-parent]

Scores a completed Stranger Walk run from its transcript.jsonl + meta.json
(written by run.sh). Writes <run-dir>/score.json and prints one markdown
table row to stdout.

This script extracts and times BELIEF:/MILESTONE:/GIVE-UP:/READY-TO-SUBMIT:/
WAITING:/BLOCKED-M6: lines and tool calls mechanically. It does NOT judge
whether a belief is true — that's judge.md, done by a human/agent with
internal knowledge after the run.

A run may span more than one `claude -p` invocation if it stopped on a
`WAITING: ` line (owner-relayed signup/verification code) and was continued
by resume.sh, which appends to the same transcript.jsonl. The gap between a
`WAITING: ` line and the next BELIEF/MILESTONE is real time spent blocked on
a human, not the stranger running out of ideas — those stuck episodes are
tagged `"owner_latency": true` and should be reported separately from
genuine dead-ends.

Definitions:
  - tool_call_count at a fact = number of tool_use blocks seen in EARLIER
    assistant turns (not counting any tool call in the same turn that
    produced the BELIEF/MILESTONE line itself).
  - a "dig" = a transition to a different host/surface via WebFetch (by URL
    netloc) or WebSearch (treated as a "web-search" pseudo-host), collapsing
    immediate repeats. dig_count = distinct transitions in that collapsed
    sequence.
  - a "stuck episode" = a gap >= 10 minutes between consecutive BELIEF/
    MILESTONE lines (or from run start to the first one), with the tool
    calls attempted during the gap attached for the judge to read.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone
from urllib.parse import urlparse

MILESTONE_RE = re.compile(r'^\s*MILESTONE:\s*(M[1-8])\b\s*(.*)$')
BELIEF_RE = re.compile(r'^\s*BELIEF:\s*(.*)$')
GIVEUP_RE = re.compile(r'^\s*GIVE-UP:\s*(.*)$')
READY_RE = re.compile(r'^\s*READY-TO-SUBMIT:\s*(.*)$')
WAITING_RE = re.compile(r'^\s*WAITING:\s*(.*)$')
BLOCKED_RE = re.compile(r'^\s*BLOCKED-M6:\s*(.*)$')

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

    tool_call_count = 0
    beliefs = []
    milestones = {}
    give_up = None
    ready_to_submit = None
    blocked_m6 = None
    waiting_events = []
    fact_events = []  # (epoch, kind, text)
    dig_sequence = []  # (epoch, host)
    tool_calls_log = []  # (epoch, tool_name, input)

    for event in load_jsonl(os.path.join(run_dir, "transcript.jsonl")):
        if event.get("type") != "assistant":
            continue
        ts = event.get("timestamp")
        epoch = iso_to_epoch(ts) if ts else None
        content = event.get("message", {}).get("content", []) or []
        for block in content:
            btype = block.get("type")
            if btype == "text":
                for line in block.get("text", "").splitlines():
                    m = MILESTONE_RE.match(line)
                    if m:
                        mid, sentence = m.group(1), m.group(2).strip()
                        if mid not in milestones:
                            milestones[mid] = {
                                "timestamp": ts,
                                "elapsed_s": (epoch - start_epoch) if epoch else None,
                                "tool_call_count": tool_call_count,
                                "sentence": sentence,
                            }
                        if epoch is not None:
                            fact_events.append((epoch, "MILESTONE", mid))
                        continue
                    b = BELIEF_RE.match(line)
                    if b:
                        beliefs.append({
                            "text": b.group(1).strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        })
                        if epoch is not None:
                            fact_events.append((epoch, "BELIEF", b.group(1).strip()))
                        continue
                    g = GIVEUP_RE.match(line)
                    if g and give_up is None:
                        give_up = {
                            "text": g.group(1).strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        }
                        continue
                    r = READY_RE.match(line)
                    if r and ready_to_submit is None:
                        ready_to_submit = {
                            "text": r.group(1).strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        }
                        continue
                    w = WAITING_RE.match(line)
                    if w:
                        entry = {
                            "text": w.group(1).strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        }
                        waiting_events.append(entry)
                        if epoch is not None:
                            fact_events.append((epoch, "WAITING", w.group(1).strip()))
                        continue
                    bl = BLOCKED_RE.match(line)
                    if bl and blocked_m6 is None:
                        blocked_m6 = {
                            "text": bl.group(1).strip(),
                            "timestamp": ts,
                            "elapsed_s": (epoch - start_epoch) if epoch else None,
                            "tool_call_count": tool_call_count,
                        }
                        if epoch is not None:
                            fact_events.append((epoch, "BLOCKED-M6", bl.group(1).strip()))
                        continue
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

    collapsed = []
    for _, h in dig_sequence:
        if not collapsed or collapsed[-1] != h:
            collapsed.append(h)
    dig_count = max(0, len(collapsed) - 1)

    fact_events.sort(key=lambda e: e[0])
    stuck_episodes = []
    prev_epoch = start_epoch
    prev_kind = "RUN-START"
    for epoch, kind, text in fact_events:
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
                "resumed_with": f"{kind}: {text}",
                # True when the gap starts right after a WAITING: line — the
                # stranger was blocked on a human (owner relaying a code),
                # not out of ideas. Report these separately from real stalls.
                "owner_latency": prev_kind == "WAITING",
            })
        prev_epoch = epoch
        prev_kind = kind

    furthest_milestone = None
    for mid in ["M8", "M7", "M6", "M5", "M4", "M3", "M2", "M1"]:
        if mid in milestones:
            furthest_milestone = mid
            break

    result = {
        "run_id": run_id,
        "model": meta.get("model"),
        "entry_url_resolved": meta.get("entry_url_resolved"),
        "wall_clock_seconds": meta.get("wall_clock_seconds"),
        "total_tool_calls": tool_call_count,
        "dig_count": dig_count,
        "dig_hosts_in_order": collapsed,
        "milestones": milestones,
        "furthest_milestone": furthest_milestone,
        "beliefs": beliefs,
        "belief_count": len(beliefs),
        "stuck_episodes": stuck_episodes,
        "stuck_minutes_total": round(
            sum(s["duration_min"] for s in stuck_episodes if not s["owner_latency"]), 1),
        "owner_latency_minutes_total": round(
            sum(s["duration_min"] for s in stuck_episodes if s["owner_latency"]), 1),
        "give_up": give_up,
        "ready_to_submit": ready_to_submit,
        "blocked_m6": blocked_m6,
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
        f"| {run_id} | {meta.get('model')} | {furthest_milestone or '-'} | "
        f"{hours:.2f}h | {tool_call_count} | {dig_count} | "
        f"{result['stuck_minutes_total']}m | {result['owner_latency_minutes_total']}m | "
        f"{len(beliefs)} | {'yes' if blocked_m6 else 'no'} |"
    )
    print(md)
    print(f"# wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
