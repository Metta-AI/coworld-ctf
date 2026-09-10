#!/usr/bin/env python3
"""Per-marker count/mean/total ms from a Fluffy trace. Durations nest
(rebuildScheduledDanger contains the danger.* markers); never add them."""
import json, sys
t = json.load(open(sys.argv[1])); names = {}
for e in t["traceEvents"]:
    if e.get("name") and e.get("dur") is not None:
        names.setdefault(e["name"], []).append(e["dur"])
for n in sorted(names, key=lambda k: -sum(names[k])):
    v = names[n]
    print(f"{n:32s} count={len(v):7d} mean_us={sum(v)/len(v):10.3f} total_ms={sum(v)/1000:10.3f}")
