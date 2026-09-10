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

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
