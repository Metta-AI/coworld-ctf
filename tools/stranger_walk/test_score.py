#!/usr/bin/env python3
"""Fixture test for score.py's judge-field preservation (stdlib only, no
network). Run from anywhere: python3 tools/stranger_walk/test_score.py

Two judges found that re-running score.py after a judge hand-edited
score.json silently dropped judge_version_blob_sha/judge_version_blob_sha_
prior and judged_by (the module docstring's "never overwrite the judge's
fields" claim was only ever implemented for milestones/beliefs), and
separately dropped any per-episode stuck_episodes[].cause note a judge had
added (stuck_episodes is otherwise recomputed wholesale from the
transcript every run). This builds a synthetic run dir (meta.json +
transcript.jsonl + prompt.rendered.md) with an already-judged score.json
fixture, calls score.main() against a copy of it, and asserts every
judge-owned field round-trips byte-for-byte while a mechanical field
(total_tool_calls) actually gets refreshed.

A third judge (opus-before-1b, 2026-09-10) found a bigger version of the
same class of bug: real Claude Code transcripts carry `timestamp` only on
`type=="user"` tool_result events, never on `type=="assistant"` events, so
the stuck-episode detector's old ts = event.get("timestamp") always came
back None and silently computed zero spans -- which then wiped five real
judge-authored stuck_episodes (with .cause notes) on re-run, since
`stuck_episodes` was unconditionally replaced with whatever the detector
found. test_timestamp_fallback_detects_gap_from_tool_result_timestamps
and test_zero_detected_spans_never_wipe_judge_stuck_episodes below guard
the fix: a timestamp fallback (resolve_event_epochs, see score.py) that
reads the paired tool_result's timestamp, and an unconditional
preservation rule that only ever lets the detector's fresh read become
the judge-facing `stuck_episodes` when there's nothing on disk yet or the
detector's spans exactly match what's already there.
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import score  # noqa: E402

FAILURES = []


def check(name, cond):
    status = "ok" if cond else "FAIL"
    print(f"  [{status}] {name}")
    if not cond:
        FAILURES.append(name)


def epoch_iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S.%fZ")


# Judge-owned top-level keys per judge.md + score.py's own docstring: never
# computed by score.py, only ever carried forward from an existing
# score.json.
JUDGE_OWNED_KEYS = [
    "milestones", "furthest_milestone", "beliefs", "belief_count", "judged",
    "judge_version_blob_sha", "judge_version_blob_sha_prior", "judged_by",
]


def build_run_dir(root):
    """Write a synthetic Stranger Walk run dir: two assistant turns (a Read
    at t1, a Bash at t2) separated by an 11m40s gap -- long enough to
    produce exactly one mechanical stuck_episode spanning [t1, t2], which
    the judged score.json fixture below also carries a `cause` note for."""
    run_dir = os.path.join(root, "synthetic-run")
    os.makedirs(run_dir)

    start_epoch = 1700000000.0
    t1 = start_epoch + 30
    t2 = t1 + 700  # 11m40s >= score.py's 10-minute stuck threshold

    meta = {
        "start_epoch": start_epoch,
        "model": "sonnet",
        "prompt_sha256": "deadbeef",
        "entry_url_resolved": "200 https://example.test/",
        "wall_clock_seconds": t2 - start_epoch,
        "resumes": [],
    }
    with open(os.path.join(run_dir, "meta.json"), "w") as f:
        json.dump(meta, f)

    transcript = [
        {
            "type": "assistant",
            "timestamp": epoch_iso(t1),
            "message": {"content": [
                {"type": "text", "text": "Looking at the landing page."},
                {"type": "tool_use", "name": "Read", "input": {"file": "README.md"}},
            ]},
        },
        {
            "type": "assistant",
            "timestamp": epoch_iso(t2),
            "message": {"content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}},
            ]},
        },
    ]
    with open(os.path.join(run_dir, "transcript.jsonl"), "w") as f:
        for event in transcript:
            f.write(json.dumps(event) + "\n")

    # Clean body: no banned phrase/milestone-label check_prompt.py scans
    # for, and no '---' delimiter (render_body then treats the whole file
    # as body) -- so prompt_status comes out "v2-clean" and doesn't
    # distract from what this test is actually checking.
    with open(os.path.join(run_dir, "prompt.rendered.md"), "w") as f:
        f.write(
            "You are a competent developer who has never heard of Paintbot. "
            "Starting from https://example.test/, get a policy of your own "
            "live and make it improve over time. Think aloud as you go.\n"
        )

    judged_stuck_episode = {
        "from_epoch": t1,
        "to_epoch": t2,
        "duration_min": round((t2 - t1) / 60, 1),
        "tool_calls_during": [],
        "owner_latency": False,
        # Judge-authored per-episode note (judge.md: "write one line on
        # what actually blocked progress") -- not a key score.py computes.
        "cause": "a dead-end nav link, not a genuine wait",
    }

    fixture_score = {
        "run_id": "synthetic-run",
        "model": "sonnet",
        "prompt_sha256": "deadbeef",
        "prompt_status": "v2-clean",
        "prompt_contamination_reasons": [],
        "entry_url_resolved": "200 https://example.test/",
        "wall_clock_seconds": t2 - start_epoch,
        # Deliberately stale/wrong: the transcript above has exactly 2
        # tool_use blocks, so a correct re-run must overwrite this with 2,
        # proving the mechanical fields actually refresh.
        "total_tool_calls": 999,
        "dig_count": 0,
        "dig_hosts_in_order": [],
        "milestones": {
            "M1": {"reached": True, "elapsed_s": 12.0, "tool_call_count": 1,
                   "sentence": "States genre+objective in its own words."},
        },
        "furthest_milestone": "M1",
        "beliefs": [
            {"text": "Scoring is tag-based.", "elapsed_s": 12.0,
             "tool_call_count": 1, "verdict": "true",
             "source": "README.md:1", "note": None},
        ],
        "belief_count": 1,
        "judged": True,
        "judge_version_blob_sha": "abc123fixturesha",
        "judge_version_blob_sha_prior": "priorfixturesha",
        "judged_by": "test-score-fixture",
        "stuck_episodes": [judged_stuck_episode],
        "stuck_minutes_total": round((t2 - t1) / 60, 1),
        "owner_latency_minutes_total": 0.0,
        "waiting_events": [],
        "resume_count": 0,
        "resume_kinds": [],
    }
    with open(os.path.join(run_dir, "score.json"), "w") as f:
        json.dump(fixture_score, f, indent=2)

    return run_dir, fixture_score


# Top-level keys the reconciliation logic in score.py treats as judge
# territory once they exist on disk -- distinct from JUDGE_OWNED_KEYS
# above (which predates the stuck-episode fix and never covered
# stuck_episodes/stuck_minutes_total/owner_latency_minutes_total).
STUCK_EPISODE_JUDGE_KEYS = [
    "stuck_episodes", "stuck_minutes_total", "owner_latency_minutes_total",
]


def build_opus_shape_run_dir(root, run_name="opus-shape-run", with_prior_score=False):
    """Write a synthetic run dir shaped like a REAL Claude Code transcript
    (verified 2026-09-10 against sonnet-before-1b, sonnet-before-2b, and
    opus-before-1b under /Users/maxwellstarr/projects/stranger-walk-runs/):
    `type=="assistant"` events carry NO `timestamp` field at all; only the
    `type=="user"` event that echoes a tool_use's result does, linked back
    by `message.content[].tool_use_id`. A thinking/text-only assistant
    fragment (no tool_use of its own) sits between the two tool calls, the
    same way a real transcript splits one logical turn's thinking/text/
    tool_use content blocks into separate JSONL rows.

    Turn 1 (Read, resolves to t1 via its tool_result) -> text-only
    fragment (no timestamp of its own -- must forward-fill) -> Turn 2
    (Bash, resolves to t2 via its tool_result), with t2 - t1 = 700s
    (11.7min), comfortably over the 10-minute stuck threshold. A detector
    that can't read timestamps off tool_result echoes finds zero spans
    here; a correct one finds exactly one, (t1, t2).

    If with_prior_score, seeds run_dir/score.json as an already-judged
    record with `stuck_episodes: []` -- exactly what the OLD (broken)
    detector wrote for a real run under this transcript shape -- so the
    reconciliation test can assert that record survives a re-run
    untouched even though the FIXED detector now finds a real span.
    """
    run_dir = os.path.join(root, run_name)
    os.makedirs(run_dir)

    start_epoch = 1700100000.0
    t1 = start_epoch + 30
    t2 = t1 + 700  # 11m40s >= score.py's 10-minute stuck threshold

    meta = {
        "start_epoch": start_epoch,
        "model": "opus",
        "prompt_sha256": "cafef00d",
        "entry_url_resolved": "200 https://example.test/",
        "wall_clock_seconds": t2 - start_epoch,
        "resumes": [],
    }
    with open(os.path.join(run_dir, "meta.json"), "w") as f:
        json.dump(meta, f)

    transcript = [
        # Turn 1: assistant tool_use, no timestamp of its own.
        {
            "type": "assistant",
            "message": {"content": [
                {"type": "tool_use", "id": "toolu_01", "name": "Read",
                 "input": {"file": "README.md"}},
            ]},
        },
        # Its tool_result echo -- the ONLY place this transcript shape
        # carries a real timestamp near turn 1.
        {
            "type": "user",
            "timestamp": epoch_iso(t1),
            "message": {"content": [
                {"type": "tool_result", "tool_use_id": "toolu_01", "content": "ok"},
            ]},
        },
        # A text-only fragment of the NEXT logical turn, split into its
        # own row (as real transcripts do for thinking/text/tool_use),
        # with no timestamp and no tool_use to pair against -- must
        # forward-fill to turn 2's tool_result.
        {
            "type": "assistant",
            "message": {"content": [
                {"type": "text", "text": "Thinking about the next step."},
            ]},
        },
        # Turn 2: assistant tool_use, no timestamp of its own.
        {
            "type": "assistant",
            "message": {"content": [
                {"type": "tool_use", "id": "toolu_02", "name": "Bash",
                 "input": {"command": "ls"}},
            ]},
        },
        {
            "type": "user",
            "timestamp": epoch_iso(t2),
            "message": {"content": [
                {"type": "tool_result", "tool_use_id": "toolu_02", "content": "done"},
            ]},
        },
    ]
    with open(os.path.join(run_dir, "transcript.jsonl"), "w") as f:
        for event in transcript:
            f.write(json.dumps(event) + "\n")

    with open(os.path.join(run_dir, "prompt.rendered.md"), "w") as f:
        f.write(
            "You are a competent developer who has never heard of Paintbot. "
            "Starting from https://example.test/, get a policy of your own "
            "live and make it improve over time. Think aloud as you go.\n"
        )

    fixture_score = None
    if with_prior_score:
        fixture_score = {
            "run_id": run_name,
            "model": "opus",
            "prompt_sha256": "cafef00d",
            "prompt_status": "v2-clean",
            "prompt_contamination_reasons": [],
            "entry_url_resolved": "200 https://example.test/",
            "wall_clock_seconds": t2 - start_epoch,
            "total_tool_calls": 2,
            "dig_count": 0,
            "dig_hosts_in_order": [],
            "milestones": {
                "M1": {"reached": True, "elapsed_s": 12.0, "tool_call_count": 1,
                       "sentence": "States genre+objective in its own words."},
            },
            "furthest_milestone": "M1",
            "beliefs": [
                {"text": "Scoring is tag-based.", "elapsed_s": 12.0,
                 "tool_call_count": 1, "verdict": "true",
                 "source": "README.md:1", "note": None},
            ],
            "belief_count": 1,
            "judged": True,
            "judge_version_blob_sha": "abc123fixturesha",
            "judge_version_blob_sha_prior": "priorfixturesha",
            "judged_by": "test-score-fixture",
            # This is exactly what the OLD (broken) detector wrote for a
            # real run under this transcript shape: zero spans, because
            # every assistant-event timestamp read came back None.
            "stuck_episodes": [],
            "stuck_minutes_total": 0,
            "owner_latency_minutes_total": 0.0,
            "waiting_events": [],
            "resume_count": 0,
            "resume_kinds": [],
        }
        with open(os.path.join(run_dir, "score.json"), "w") as f:
            json.dump(fixture_score, f, indent=2)

    return run_dir, fixture_score


def test_timestamp_fallback_detects_gap_from_tool_result_timestamps():
    print("test_timestamp_fallback_detects_gap_from_tool_result_timestamps")
    with tempfile.TemporaryDirectory() as td:
        run_dir, _ = build_opus_shape_run_dir(td, with_prior_score=False)

        argv_orig = sys.argv
        try:
            sys.argv = ["score.py", "opus-shape-run", td]
            score.main()
        finally:
            sys.argv = argv_orig

        result = json.load(open(os.path.join(run_dir, "score.json")))

        detected = result.get("detector_stuck_episodes") or []
        check("exactly one span detected from tool_result timestamps alone",
              len(detected) == 1)
        if detected:
            check("detected span duration is 11.7min (700s gap)",
                  detected[0]["duration_min"] == 11.7)
        check("detector_stuck_minutes_total reflects the detected span",
              result.get("detector_stuck_minutes_total") == 11.7)
        # First run (no prior score.json) -- the judge-facing field is
        # seeded from the detector's own read.
        check("first-run stuck_episodes seeded from the detector's read",
              len(result.get("stuck_episodes") or []) == 1)
        check("first-run stuck_minutes_total seeded from the detector's read",
              result.get("stuck_minutes_total") == 11.7)


def test_zero_detected_spans_never_wipe_judge_stuck_episodes():
    print("test_zero_detected_spans_never_wipe_judge_stuck_episodes")
    with tempfile.TemporaryDirectory() as td:
        run_dir, fixture = build_opus_shape_run_dir(td, with_prior_score=True)

        argv_orig = sys.argv
        try:
            sys.argv = ["score.py", "opus-shape-run", td]
            score.main()
        finally:
            sys.argv = argv_orig

        result = json.load(open(os.path.join(run_dir, "score.json")))

        for key in JUDGE_OWNED_KEYS + STUCK_EPISODE_JUDGE_KEYS:
            check(f"{key!r} preserved byte-for-byte despite the detector "
                  f"now finding a real span",
                  result.get(key) == fixture.get(key))

        # The fixed detector DOES find the real gap this transcript shape
        # hides -- it just must not silently overwrite the judge's record
        # with it.
        detected = result.get("detector_stuck_episodes") or []
        check("detector's own view still finds the real span",
              len(detected) == 1)


def test_judge_fields_survive_rerun_byte_for_byte():
    print("test_judge_fields_survive_rerun_byte_for_byte")
    with tempfile.TemporaryDirectory() as td:
        run_dir, fixture = build_run_dir(td)

        argv_orig = sys.argv
        try:
            sys.argv = ["score.py", "synthetic-run", td]
            score.main()
        finally:
            sys.argv = argv_orig

        result = json.load(open(os.path.join(run_dir, "score.json")))

        for key in JUDGE_OWNED_KEYS:
            check(f"{key!r} preserved byte-for-byte",
                  result.get(key) == fixture.get(key))

        check("stuck_episodes[0]['cause'] preserved",
              result["stuck_episodes"][0].get("cause")
              == "a dead-end nav link, not a genuine wait")

        check("total_tool_calls refreshed away from the stale fixture value",
              fixture["total_tool_calls"] == 999 and result["total_tool_calls"] == 2)


def main():
    test_judge_fields_survive_rerun_byte_for_byte()
    test_timestamp_fallback_detects_gap_from_tool_result_timestamps()
    test_zero_detected_spans_never_wipe_judge_stuck_episodes()

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
