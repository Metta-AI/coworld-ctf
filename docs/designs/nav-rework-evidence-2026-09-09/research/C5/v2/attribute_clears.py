#!/usr/bin/env python3
"""C5 v2: attribute every danger.clear (one per changed rebuild) and every
danger.* marker to its harness row and tick index using timestamp
containment: bench.tickRow:<roster>:<scenario> contains shell.danger events
(one per episode.step), which contain rebuildScheduledDanger and the
danger.* markers. Tick index 0 is the initial step, 1..warmups are
warmups, the rest are measured samples. Durations are attribution only.
Usage: attribute_clears.py <trace.json> [warmups=5]"""
import json, sys
from collections import defaultdict
trace = json.load(open(sys.argv[1]))
warmups = int(sys.argv[2]) if len(sys.argv) > 2 else 5
ev = [e for e in trace["traceEvents"] if e.get("dur") is not None]
ev.sort(key=lambda e: (e["ts"], -e["dur"]))
rows = [e for e in ev if e["name"].startswith("bench.tickRow:")]
danger_ticks = [e for e in ev if e["name"] == "shell.danger"]
markers = [e for e in ev if e["name"].startswith("danger.") or e["name"] == "rebuildScheduledDanger"]
def inside(e, c): return c["ts"] <= e["ts"] and e["ts"] + e["dur"] <= c["ts"] + c["dur"]
out = []
for row in rows:
    ticks = [t for t in danger_ticks if inside(t, row)]
    ticks.sort(key=lambda t: t["ts"])
    per_tick = []
    for i, t in enumerate(ticks):
        phase = "initial" if i == 0 else ("warmup" if i <= warmups else "measured")
        inner = [m for m in markers if inside(m, t)]
        counts = defaultdict(int); dur = defaultdict(float)
        for m in inner:
            counts[m["name"]] += 1; dur[m["name"]] += m["dur"]
        per_tick.append({"tick_index": i, "phase": phase, "sample_index": (i - warmups - 1) if i > warmups else None,
                         "shell_danger_us": t["dur"], "counts": dict(counts), "marker_us": {k: round(v, 1) for k, v in dur.items()}})
    clears = [p for p in per_tick if p["counts"].get("danger.clear", 0) > 0]
    summary = {"row": row["name"], "ticks": len(ticks),
               "ticks_with_clear": len(clears),
               "clears_by_phase": {ph: sum(p["counts"].get("danger.clear", 0) for p in clears if p["phase"] == ph) for ph in ("initial", "warmup", "measured")},
               "measured_tick_indices_with_clear": [p["tick_index"] for p in clears if p["phase"] == "measured"],
               "measured_sample_indices_with_clear": [p["sample_index"] for p in clears if p["phase"] == "measured"],
               "max_shell_danger_us_measured_with_clear": max([p["shell_danger_us"] for p in clears if p["phase"] == "measured"], default=0),
               "max_shell_danger_us_measured_without_clear": max([p["shell_danger_us"] for p in per_tick if p["phase"] == "measured" and p["counts"].get("danger.clear", 0) == 0], default=0),
               "per_tick": per_tick}
    out.append(summary)
print(json.dumps({"warmups": warmups, "rows": out}, indent=1))
