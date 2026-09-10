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

Re-running this script is safe: every judge-owned field already sitting in
an existing score.json — milestones, beliefs, furthest_milestone, judged,
judge_version_blob_sha, judge_version_blob_sha_prior, judged_by,
stuck_episodes (with any per-episode .cause note, see judge.md), and
stuck_minutes_total/owner_latency_minutes_total — is preserved
byte-for-byte across a re-run; only the mechanical fields (timings, tool/
dig counts) are unconditionally recomputed. This is implemented as an
allowlist of mechanical keys merged over a full copy of whatever was
already on disk, not a blocklist of judge fields to avoid — so a judge can
score.py once for the mechanical skeleton, hand-edit score.json to fill in
milestones/beliefs/judge_version_blob_sha/judged_by, and re-run this
script as many times as needed (e.g. after a scoring methodology tweak, or
to pick up a later transcript) without losing that work.

`stuck_episodes` is a special case of the same rule, not an exception to
it: this script's own fresh mechanical read of the transcript is always
computed and published as `detector_stuck_episodes` (and
`detector_stuck_minutes_total`/`detector_owner_latency_minutes_total`),
but it only ever becomes `stuck_episodes` itself — the judge-facing record
— when there's nothing on disk yet (first run) or when it exactly
reproduces the same set of gaps already there (safe to refresh
mechanical sub-fields like `tool_calls_during` while carrying forward
`cause`/`note` per matching span). If the detector's fresh read disagrees
with what's on disk — including finding *zero* spans where the judge
recorded real ones, which is exactly what a 2026-09-10 transcript-shape
bug did — `stuck_episodes` is left untouched and only
`detector_stuck_episodes` reflects the disagreement, so the machine's
(possibly still-imperfect) view can never silently erase the judge's.

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

TIMESTAMP FALLBACK (found 2026-09-10 against three real Claude Code
transcripts): `type=="assistant"` events in this transcript format never
carry their own `timestamp` — only the `type=="user"` tool_result echo
does. resolve_event_epochs() resolves each assistant event's epoch, in
priority order, from: its own `timestamp` if present (older/synthetic
transcripts) -> the paired tool_result's timestamp (by tool_use id) ->
forward-fill from the next later event that resolved one (for a
thinking/text-only fragment emitted before the tool_use that ends its
logical turn) -> backward-fill from the nearest earlier one as a last
resort. Without this, every assistant-only-timestamp read returns None
and the detector silently finds zero spans — see the module-level note
above on how `stuck_episodes` vs `detector_stuck_episodes` guards against
that turning into data loss.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_prompt  # noqa: E402 — Protocol v2 contamination gate, reused below

WAITING_PREFIX = "WAITING:"

STUCK_THRESHOLD_S = 10 * 60


def prompt_contamination_status(run_dir):
    """Re-run the Protocol v2 contamination gate (check_prompt.py) against
    THIS RUN's own saved prompt.rendered.md — the actual text that specific
    run's stranger saw, not today's prompt.md — so a run made under an
    older, contaminated prompt (e.g. any Walk 1 run, whose prompt handed out
    the milestone list) is flagged and can never quietly get compared to a
    clean Protocol v2 baseline. Returns (status, reasons)."""
    rendered_path = os.path.join(run_dir, "prompt.rendered.md")
    if not os.path.exists(rendered_path):
        return "unknown (no prompt.rendered.md saved for this run)", []
    from pathlib import Path
    reasons = check_prompt.check_body(
        check_prompt.render_body(Path(rendered_path)), "prompt.rendered.md")
    if reasons:
        return "PROMPT-CONTAMINATED", reasons
    return "v2-clean", []


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


def build_tool_result_epochs(events):
    """Map each tool_use id to the epoch of its paired tool_result.

    Found empirically (2026-09-10) against three real Stranger Walk
    transcripts: `type=="assistant"` events in this transcript format never
    carry their own `timestamp` -- only the `type=="user"` event that
    echoes a tool's result does, keyed to the call via
    message.content[].tool_use_id. That echo is the earliest reliable
    clock reading near an assistant turn, so it's the primary fallback
    source (see resolve_event_epochs)."""
    epochs = {}
    for event in events:
        if event.get("type") != "user":
            continue
        ts = event.get("timestamp")
        if not ts:
            continue
        epoch = iso_to_epoch(ts)
        content = event.get("message", {}).get("content", []) or []
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                tool_use_id = block.get("tool_use_id")
                if tool_use_id:
                    epochs[tool_use_id] = epoch
    return epochs


def resolve_event_epochs(events):
    """Best-available epoch per event (parallel list, file order).

    Priority per event:
      1. its own `timestamp` field, if present (covers synthetic/older
         transcripts where assistant events do carry a real timestamp).
      2. for an `assistant` event whose content includes `tool_use`
         block(s): the timestamp of the paired `tool_result` echo (see
         build_tool_result_epochs) -- the only clock reading real Claude
         Code transcripts attach anywhere near an assistant turn.
      3. still unresolved (a thinking/text-only assistant fragment with no
         tool_use of its own, emitted as its own JSONL row before the
         tool_use that ends its logical turn): forward-filled to the next
         later event in the stream that resolved a timestamp under 1-2 --
         the closest real clock reading to when the fragment happened,
         consistent with this script's documented bias toward
         under-reporting rather than over-reporting stuck time.
      4. still unresolved after that (trailing events with nothing left to
         look forward to, e.g. a final text-only turn with no more tool
         calls): backward-filled from the nearest earlier resolved epoch.
    """
    tool_result_epoch = build_tool_result_epochs(events)
    resolved = [None] * len(events)
    for i, event in enumerate(events):
        ts = event.get("timestamp")
        if ts:
            resolved[i] = iso_to_epoch(ts)
            continue
        if event.get("type") != "assistant":
            continue
        content = event.get("message", {}).get("content", []) or []
        if not isinstance(content, list):
            continue
        found = [
            tool_result_epoch[block["id"]]
            for block in content
            if isinstance(block, dict) and block.get("type") == "tool_use"
            and block.get("id") in tool_result_epoch
        ]
        if found:
            resolved[i] = max(found)

    next_known = None
    for i in range(len(events) - 1, -1, -1):
        if resolved[i] is not None:
            next_known = resolved[i]
        elif next_known is not None:
            resolved[i] = next_known

    prev_known = None
    for i in range(len(events)):
        if resolved[i] is not None:
            prev_known = resolved[i]
        elif prev_known is not None:
            resolved[i] = prev_known

    return resolved


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

    # Preserve every judge-owned field already sitting in an existing
    # score.json (see module docstring): milestones, beliefs,
    # furthest_milestone, judged, judge_version_blob_sha,
    # judge_version_blob_sha_prior, judged_by, and any per-episode
    # stuck_episodes[].cause note (judge.md). Implemented below as an
    # allowlist of MECHANICAL keys this script is allowed to refresh,
    # merged over a full copy of whatever was already on disk — so any
    # judge-owned key, including one this script doesn't know the name of
    # yet, survives a re-run untouched instead of needing its own
    # preserve-rule.
    existing_path = os.path.join(run_dir, "score.json")
    prior = {}
    if os.path.exists(existing_path):
        try:
            prior = json.load(open(existing_path)) or {}
        except (json.JSONDecodeError, OSError):
            prior = {}

    events = list(load_jsonl(os.path.join(run_dir, "transcript.jsonl")))
    event_epochs = resolve_event_epochs(events)

    tool_call_count = 0
    waiting_events = []
    turn_events = []  # (epoch, turn_had_waiting)
    dig_sequence = []  # (epoch, host)
    tool_calls_log = []  # (epoch, tool_name, input)

    for idx, event in enumerate(events):
        if event.get("type") != "assistant":
            continue
        ts = event.get("timestamp")
        epoch = event_epochs[idx]
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
                            "elapsed_s": (epoch - start_epoch) if epoch is not None else None,
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

    # --- stuck-episode reconciliation: detector output vs judge output ---
    # `stuck_episodes` just computed above is the DETECTOR's own mechanical
    # read of the transcript this run -- always as accurate as the
    # timestamp-fallback logic in resolve_event_epochs can make it, but it
    # is a SEPARATE record from whatever a judge already hand-annotated
    # into an existing score.json. The detector must never silently
    # overwrite or blank out the judge's record just because it disagrees
    # with (or can't currently re-derive) it.
    #
    # Postmortem (2026-09-10): a transcript shape where assistant events
    # carry no `timestamp` at all (only the paired tool_result echo does)
    # made the OLD detector compute zero spans and wipe five real
    # judge-authored episodes on re-run, because `stuck_episodes` was
    # unconditionally replaced with whatever the (broken) detector found.
    MECHANICAL_EPISODE_KEYS = {
        "from_epoch", "to_epoch", "duration_min", "tool_calls_during", "owner_latency",
    }

    def span_key(ep):
        return (ep.get("from_epoch"), ep.get("to_epoch"))

    detector_stuck_episodes = stuck_episodes
    prior_stuck_episodes = prior.get("stuck_episodes")

    if prior_stuck_episodes is None:
        # Nothing on disk yet (first run, or a score.json predating this
        # field) -- seed from the detector's own read, same as every other
        # judge-owned field's first-run default below.
        final_stuck_episodes = detector_stuck_episodes
    else:
        prior_spans = {span_key(ep) for ep in prior_stuck_episodes if isinstance(ep, dict)}
        detector_spans = {span_key(ep) for ep in detector_stuck_episodes}
        if prior_spans == detector_spans:
            # The detector can fully re-derive what's on disk (identical
            # set of gaps) -- safe to refresh the mechanical sub-fields
            # (duration, tool calls attempted during the gap) while
            # carrying forward any judge-added key (cause, note, ...) per
            # matching span, same behavior as before this fix.
            prior_by_span = {
                span_key(ep): ep for ep in prior_stuck_episodes if isinstance(ep, dict)
            }
            final_stuck_episodes = []
            for ep in detector_stuck_episodes:
                merged = dict(ep)
                prior_ep = prior_by_span.get(span_key(ep))
                if prior_ep:
                    for k, v in prior_ep.items():
                        if k not in MECHANICAL_EPISODE_KEYS:
                            merged[k] = v
                final_stuck_episodes.append(merged)
        else:
            # Detector disagrees with what's on disk (fewer spans, more
            # spans, or different boundaries than the judge's record --
            # e.g. a transcript shape it previously couldn't read
            # timestamps from at all). It cannot re-derive the judge's
            # record, so it must not touch it: keep the judge's
            # stuck_episodes byte-for-byte and publish the differing
            # machine view under its own name (detector_stuck_episodes)
            # instead of merging the two silently.
            final_stuck_episodes = prior_stuck_episodes

    prompt_status, prompt_contamination_reasons = prompt_contamination_status(run_dir)

    # Start from a full copy of whatever was already on disk (judge-owned
    # fields and all), then refresh ONLY the mechanical keys below via
    # .update() — an allowlist of what may change, not a blocklist of what
    # may not. Anything already in `prior` that isn't named in the
    # .update() call — milestones, furthest_milestone, beliefs, judged,
    # judge_version_blob_sha, judge_version_blob_sha_prior, judged_by, and
    # any future judge-owned key this script doesn't know about — passes
    # through byte-for-byte. First-run defaults (no existing score.json)
    # are seeded via setdefault, matching judge.md's expected shape:
    # milestones is {mid: {timestamp, elapsed_s, tool_call_count,
    # sentence}}, beliefs is a list of {text, timestamp, elapsed_s,
    # tool_call_count, verdict, source, note}.
    result = dict(prior)
    result.setdefault("milestones", {})
    result.setdefault("furthest_milestone", None)
    result.setdefault("beliefs", [])
    result.setdefault("judged", bool(result["milestones"] or result["beliefs"]))

    result.update({
        "run_id": run_id,
        "model": meta.get("model"),
        "prompt_sha256": meta.get("prompt_sha256"),
        # PROMPT-CONTAMINATED means THIS run's own saved prompt.rendered.md
        # (checked fresh every score.py run — never cached) mentions a
        # milestone/belief/etc. it should never have been handed (see
        # check_prompt.py). A contaminated run is not comparable to a clean
        # Protocol v2 baseline no matter what milestones/beliefs a judge
        # later fills in below — every Walk 1 run is expected to land here.
        "prompt_status": prompt_status,
        "prompt_contamination_reasons": prompt_contamination_reasons,
        "entry_url_resolved": meta.get("entry_url_resolved"),
        "wall_clock_seconds": meta.get("wall_clock_seconds"),
        "total_tool_calls": tool_call_count,
        "dig_count": dig_count,
        "dig_hosts_in_order": collapsed,
        # Mechanical count derived from the (preserved) beliefs list above
        # — recomputed so it can never drift from len(beliefs), even if a
        # judge hand-edits beliefs without touching this key.
        "belief_count": len(result["beliefs"]),
        # The DETECTOR's own current mechanical read — always refreshed,
        # never the thing a judge edits. See the reconciliation block
        # above for how this relates to (and can diverge from)
        # `stuck_episodes` below.
        "detector_stuck_episodes": detector_stuck_episodes,
        "detector_stuck_minutes_total": round(
            sum(s["duration_min"] for s in detector_stuck_episodes if not s["owner_latency"]), 1),
        "detector_owner_latency_minutes_total": round(
            sum(s["duration_min"] for s in detector_stuck_episodes if s["owner_latency"]), 1),
        "waiting_events": waiting_events,
        "resume_count": len(meta.get("resumes", [])),
        "resume_kinds": [r.get("kind", "owner_relay") for r in meta.get("resumes", [])],
    })

    # `stuck_episodes` itself is judge territory once a judge has reviewed
    # it (see the reconciliation block above: it's either the detector's
    # first-run seed, a mechanical refresh of an unchanged span set, or the
    # judge's own untouched record). `stuck_minutes_total` and
    # `owner_latency_minutes_total` are the totals a judge sees next to
    # that record, so they get the same unconditional-preservation
    # treatment as every other judge-owned field above (setdefault, not
    # update) — never silently recomputed out from under a judge once they
    # exist on disk, even if the detector's own view (above) disagrees.
    result["stuck_episodes"] = final_stuck_episodes
    result.setdefault("stuck_minutes_total", round(
        sum(s["duration_min"] for s in final_stuck_episodes
            if isinstance(s, dict) and not s.get("owner_latency")), 1))
    result.setdefault("owner_latency_minutes_total", round(
        sum(s["duration_min"] for s in final_stuck_episodes
            if isinstance(s, dict) and s.get("owner_latency")), 1))

    out_path = os.path.join(run_dir, "score.json")
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    wall_s = meta.get("wall_clock_seconds") or 0
    hours = wall_s / 3600
    md = (
        f"| {run_id} | {meta.get('model')} | {prompt_status} | "
        f"{result['furthest_milestone'] or 'UNJUDGED'} | "
        f"{hours:.2f}h | {tool_call_count} | {dig_count} | "
        f"{result['stuck_minutes_total']}m | {result['owner_latency_minutes_total']}m | "
        f"{result['belief_count']} | {'yes' if result['judged'] else 'no (run judge.md)'} |"
    )
    print(md)
    print(f"# wrote {out_path}", file=sys.stderr)
    if prompt_status == "PROMPT-CONTAMINATED":
        print(
            f"# WARNING: {run_id}'s own saved prompt.rendered.md is PROMPT-CONTAMINATED "
            f"({len(prompt_contamination_reasons)} hit(s)) — this run cannot be cited as a "
            "Protocol v2 baseline no matter what milestones/beliefs get filled in below. "
            "See prompt_contamination_reasons in score.json.",
            file=sys.stderr,
        )
    if not result["judged"]:
        print(
            f"# NOTE: {run_id} has no judge-authored milestones/beliefs yet — "
            "apply judge.md's post-hoc extraction and re-save score.json before "
            "using this run in a report.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
