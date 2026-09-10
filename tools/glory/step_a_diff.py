#!/usr/bin/env python3
"""GLORY GRADIENT Step A diff — compare two step_a_read.py snapshots.

Given two markdown snapshots produced by `step_a_read.py`, reports:
  - whether the two reads used the SAME query (fingerprint match) -- a diff
    across different queries is not a diff, it's noise;
  - ranks-identical yes/no (leaderboard order, by subject_id);
  - per-subject raw_before / raw_after / expected_after / |delta|.
    expected_after is always raw_before: runbook check 3 says the post-arm
    "Typical episode" display must equal the pre-arm raw standing EXACTLY
    (signed_log2 / inverse_signed_log2 are exact inverses), so whatever the
    second read's raw_standing/score is, the pre-arm value it is compared
    against as "expected" is always what the first read banked;
  - "Typical episode" vs raw-before equality (exact), reported per subject
    only when the SECOND snapshot's score_label is actually "Typical episode"
    (i.e. the transform was armed between the two reads) -- otherwise N/A;
  - subjects whose rounds_played changed between reads, to attribute any
    nonzero delta to rounds that scored in the gap rather than to a defect.

Usage:
    python3 tools/glory/step_a_diff.py SNAPSHOT_A.md SNAPSHOT_B.md [--out PATH]

Run against the SAME file twice (rehearsal vs rehearsal) as a self-test --
must report IDENTICAL.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

RAW_JSON_MARKER = "## Raw data"
EPS = 1e-6


def load_snapshot(path: str) -> dict:
    with open(path) as f:
        text = f.read()
    idx = text.find(RAW_JSON_MARKER)
    if idx == -1:
        raise ValueError(f"{path}: no '{RAW_JSON_MARKER}' marker found -- not a step_a_read.py snapshot")
    m = re.search(r"```json\n(.*?)\n```", text[idx:], re.DOTALL)
    if not m:
        raise ValueError(f"{path}: found the marker but no fenced json block after it")
    return json.loads(m.group(1))


def rows_by_subject(snapshot: dict) -> dict[str, dict]:
    return {r["subject_id"]: r for r in snapshot["rows"]}


def rank_order(snapshot: dict) -> list[str]:
    return [r["subject_id"] for r in sorted(snapshot["rows"], key=lambda r: r["rank"])]


def diff(a: dict, b: dict) -> dict:
    fp_a = a["header"]["query_fingerprint"]
    fp_b = b["header"]["query_fingerprint"]
    fingerprint_match = fp_a == fp_b

    ra, rb = rank_order(a), rank_order(b)
    ranks_identical = ra == rb

    subs_a, subs_b = rows_by_subject(a), rows_by_subject(b)
    all_subjects = sorted(set(subs_a) | set(subs_b))

    per_subject = []
    rounds_played_changed = []
    only_in_a, only_in_b = [], []
    max_abs_delta = 0.0

    for sid in all_subjects:
        ra_row = subs_a.get(sid)
        rb_row = subs_b.get(sid)
        if ra_row is None:
            only_in_b.append(sid)
            continue
        if rb_row is None:
            only_in_a.append(sid)
            continue

        raw_before = ra_row["raw_standing"]
        raw_after = rb_row["raw_standing"]
        expected_after = raw_before  # runbook check 3
        abs_delta = abs(raw_after - expected_after)
        max_abs_delta = max(max_abs_delta, abs_delta)

        if rb_row["score_label"] == "Typical episode":
            typical_check = "PASS" if abs_delta < EPS else "FAIL"
        else:
            typical_check = "N/A (second read not armed: score_label={!r})".format(rb_row["score_label"])

        per_subject.append(
            {
                "subject_id": sid,
                "display_name": rb_row.get("display_name") or ra_row.get("display_name"),
                "raw_before": raw_before,
                "raw_after": raw_after,
                "expected_after": expected_after,
                "abs_delta": abs_delta,
                "typical_episode_vs_raw_before": typical_check,
            }
        )

        if ra_row["rounds_played"] != rb_row["rounds_played"]:
            rounds_played_changed.append(
                {
                    "subject_id": sid,
                    "display_name": rb_row.get("display_name") or ra_row.get("display_name"),
                    "rounds_played_before": ra_row["rounds_played"],
                    "rounds_played_after": rb_row["rounds_played"],
                }
            )

    settings_a = a.get("settings")
    settings_b = b.get("settings")
    settings_identical = settings_a == settings_b

    identical = (
        fingerprint_match
        and ranks_identical
        and not only_in_a
        and not only_in_b
        and max_abs_delta < EPS
        and not rounds_played_changed
        and settings_identical
    )

    return {
        "fingerprint_match": fingerprint_match,
        "fingerprint_a": fp_a,
        "fingerprint_b": fp_b,
        "ranks_identical": ranks_identical,
        "rank_order_a": ra,
        "rank_order_b": rb,
        "per_subject": per_subject,
        "only_in_a": only_in_a,
        "only_in_b": only_in_b,
        "rounds_played_changed": rounds_played_changed,
        "settings_identical": settings_identical,
        "max_abs_delta": max_abs_delta,
        "identical": identical,
    }


def render_markdown(a_path: str, b_path: str, a: dict, b: dict, d: dict) -> str:
    lines = []
    lines.append(f"# GLORY GRADIENT Step A diff — {a['header']['label']} vs {b['header']['label']}")
    lines.append("")
    lines.append(f"- snapshot A: `{a_path}` ({a['header']['timestamp_utc']})")
    lines.append(f"- snapshot B: `{b_path}` ({b['header']['timestamp_utc']})")
    lines.append(f"- query fingerprint match: **{d['fingerprint_match']}** (`{d['fingerprint_a']}` vs `{d['fingerprint_b']}`)")
    lines.append(f"- ranks identical: **{d['ranks_identical']}**")
    lines.append(f"- settings identical: **{d['settings_identical']}**")
    lines.append(f"- max |delta| across all subjects: **{d['max_abs_delta']:.6f}**")
    lines.append(f"- rounds_played changed for {len(d['rounds_played_changed'])} subject(s)")
    lines.append("")
    lines.append(f"## VERDICT: {'IDENTICAL' if d['identical'] else 'DIFFERENT'}")
    lines.append("")

    if not d["ranks_identical"]:
        lines.append("### Rank order A")
        lines.append(", ".join(d["rank_order_a"]))
        lines.append("")
        lines.append("### Rank order B")
        lines.append(", ".join(d["rank_order_b"]))
        lines.append("")

    if d["only_in_a"] or d["only_in_b"]:
        lines.append("### Roster changes")
        if d["only_in_a"]:
            lines.append(f"- only in A ({len(d['only_in_a'])}): {', '.join(d['only_in_a'])}")
        if d["only_in_b"]:
            lines.append(f"- only in B ({len(d['only_in_b'])}): {', '.join(d['only_in_b'])}")
        lines.append("")

    lines.append("## Per-subject raw before/after")
    lines.append("| subject_id | display_name | raw_before | raw_after | expected_after | |delta| | Typical episode check |")
    lines.append("|---|---|---|---|---|---|---|")
    for row in sorted(d["per_subject"], key=lambda r: -r["abs_delta"]):
        lines.append(
            f"| {row['subject_id']} | {row['display_name']} | {row['raw_before']:.4f} | {row['raw_after']:.4f} "
            f"| {row['expected_after']:.4f} | {row['abs_delta']:.6f} | {row['typical_episode_vs_raw_before']} |"
        )
    lines.append("")

    lines.append("## Subjects whose rounds_played changed between reads")
    if d["rounds_played_changed"]:
        lines.append("(attribute any nonzero delta above to these subjects scoring rounds in the gap)")
        lines.append("")
        lines.append("| subject_id | display_name | rounds_played_before | rounds_played_after |")
        lines.append("|---|---|---|---|")
        for row in d["rounds_played_changed"]:
            lines.append(
                f"| {row['subject_id']} | {row['display_name']} | {row['rounds_played_before']} "
                f"| {row['rounds_played_after']} |"
            )
    else:
        lines.append("none")
    lines.append("")

    lines.append("## Raw diff (machine-readable)")
    lines.append("```json")
    lines.append(json.dumps(d, indent=2, sort_keys=True))
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("snapshot_a")
    ap.add_argument("snapshot_b")
    ap.add_argument("--out", default=None, help="write markdown report here (default: print only)")
    args = ap.parse_args()

    a = load_snapshot(args.snapshot_a)
    b = load_snapshot(args.snapshot_b)
    d = diff(a, b)
    report = render_markdown(args.snapshot_a, args.snapshot_b, a, b, d)

    if args.out:
        with open(args.out, "w") as f:
            f.write(report)
        print(f"wrote {args.out}")

    print(f"VERDICT: {'IDENTICAL' if d['identical'] else 'DIFFERENT'}")
    print(f"fingerprint_match={d['fingerprint_match']} ranks_identical={d['ranks_identical']} "
          f"settings_identical={d['settings_identical']} max_abs_delta={d['max_abs_delta']:.6f} "
          f"rounds_played_changed={len(d['rounds_played_changed'])} "
          f"only_in_a={len(d['only_in_a'])} only_in_b={len(d['only_in_b'])}")
    return 0 if d["identical"] or args.out else 0


if __name__ == "__main__":
    sys.exit(main())
