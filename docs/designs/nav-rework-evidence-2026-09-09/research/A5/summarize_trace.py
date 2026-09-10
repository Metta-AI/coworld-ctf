#!/usr/bin/env python3
"""Per-stage mean/total ms from a Fluffy trace (durations nest; do not add stages)."""
import json, sys
t = json.load(open(sys.argv[1])); names = {}
for e in t["traceEvents"]:
    if e.get("name") and e.get("dur") is not None:
        names.setdefault(e["name"], []).append(e["dur"])
for n in sorted(names, key=lambda k: -sum(names[k])):
    v = names[n]; print(f"{n:38s} count={len(v):5d} mean_ms={sum(v)/len(v)/1000:9.3f}")
