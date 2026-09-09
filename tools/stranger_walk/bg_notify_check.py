#!/usr/bin/env python3
"""
tools/stranger_walk/bg_notify_check.py <run-dir>

Protocol v1.1 fix (2026-09-09, sonnet-a finding): interactively, a background
shell command finishing re-invokes the agent with a notification. In `-p`
mode nothing does — the CLI process exits at end_turn and the harness kills
any still-running background tasks as a side effect of that exit. A stranger
that backgrounds something it needs to see the result of (sonnet-a
backgrounded its own `coworld upload-policy` and said "I'll wait for the
notification") silently loses that follow-through, through no fault of its
own reasoning.

This script looks at every transcript line AFTER the run's last `result`
event for `type=system, subtype=task_notification` — the harness still
writes these even though no new turn consumes them — reads each task's
output file (best effort, tail only), and prints ONE combined message to
stdout suitable to hand back to the SAME session via `claude -p --resume`,
mimicking (as closely as -p mode allows) the notification an interactive
session would have delivered. Prints nothing (exit 0) if there's nothing to
relay, which is the common case.

Note: the underlying task was KILLED by the process exit, not necessarily
completed — its output may be partial. The message says so; it does not
claim false certainty that the command finished.
"""
import json
import os
import sys


def main():
    if len(sys.argv) < 2:
        return
    run_dir = sys.argv[1]
    transcript = os.path.join(run_dir, "transcript.jsonl")
    if not os.path.exists(transcript):
        return
    lines = open(transcript).readlines()

    last_result_idx = None
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "result":
            last_result_idx = i
    if last_result_idx is None:
        return

    notifs = []
    for line in lines[last_result_idx + 1:]:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "task_notification":
            notifs.append(ev)
    if not notifs:
        return

    parts = []
    for n in notifs:
        task_id = n.get("task_id", "?")
        summary = n.get("summary", "")
        status = n.get("status", "?")
        tail = ""
        out_file = n.get("output_file")
        if out_file and os.path.exists(out_file):
            try:
                with open(out_file, "r", errors="replace") as f:
                    content = f.read()
                tail = content[-2000:]
            except OSError:
                tail = "(could not read output file)"
        parts.append(
            f"background command {task_id} ({summary}) - status: {status}. "
            f"Its process was interrupted when your last turn ended before it "
            f"finished naturally (non-interactive sessions here don't resume a "
            f"backgrounded task across turns the way an interactive one would). "
            f"Output captured before interruption:\n{tail}"
        )
    print("\n\n".join(parts))
    print(
        "\n\nThat may not have actually finished - verify its real effect (e.g. "
        "re-check status) before treating it as done, and avoid backgrounding a "
        "command you need to see the result of before your turn ends. Continue "
        "from here."
    )


if __name__ == "__main__":
    main()
