"""Evaluate preregistered C9 paired trace and regime limits."""
import json
import statistics
import sys
from pathlib import Path

folder = Path(sys.argv[1])
assert (folder / "DONE").exists()
traces = []
regimes = []
for parent in sorted(folder.glob("parent-*.json")):
    candidate = folder / parent.name.replace("parent-", "candidate-", 1)
    a = json.loads(parent.read_text())
    b = json.loads(candidate.read_text())
    if "regimes" in parent.name:
        for x, y in zip(a["rows"], b["rows"], strict=True):
            keys = ["map", "range_px", "regime", "rebuilds", "sources_per_rebuild", "raster_fingerprint"]
            regimes.append(dict(pair=parent.name, map=x["map"], regime=x["regime"],
                                exact=all(x[k] == y[k] for k in keys),
                                total_ratio=sum(y["samples_ns"])/sum(x["samples_ns"])))
    else:
        x = [v["rebuild_ns"] for v in a["samples"]]
        y = [v["rebuild_ns"] for v in b["samples"]]
        def inputs(samples):
            return [{k: v for k, v in z.items() if k != "rebuild_ns"} for z in samples]
        exact = a["raster_chain_fnv64"] == b["raster_chain_fnv64"] and inputs(a["samples"]) == inputs(b["samples"])
        traces.append(dict(pair=parent.name, trace=parent.stem.rsplit("-r", 1)[0], exact=exact,
                           total_ratio=sum(y)/sum(x),
                           p95_ratio=sorted(y)[int(len(y)*.95)]/sorted(x)[int(len(x)*.95)]))
assert len(traces) == 27 and len(regimes) == 24
checks = []
for key in sorted({r["trace"] for r in traces}):
    rows = [r for r in traces if r["trace"] == key]
    assert len(rows) == 3
    total = statistics.median(r["total_ratio"] for r in rows)
    p95 = statistics.median(r["p95_ratio"] for r in rows)
    checks.append(dict(trace=key, total_ratio_median=total, p95_ratio_median=p95,
                       pass_screen=all(r["exact"] for r in rows) and total <= 1.01 and p95 <= 1.03))
for key in sorted({(r["map"], r["regime"]) for r in regimes}):
    rows = [r for r in regimes if (r["map"], r["regime"]) == key]
    assert len(rows) == 3
    total = statistics.median(r["total_ratio"] for r in rows)
    limit = 1.01 if key[1] == "changing_sources" else .90
    checks.append(dict(map=key[0], regime=key[1], total_ratio_median=total,
                       limit=limit, pass_screen=all(r["exact"] for r in rows) and total <= limit))
quality = json.loads((folder / "quality.json").read_text())
quality_exact = quality["pass"] and quality["quality"]["case_count"] == 3072 and quality["quality"]["route_hash"] == "5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500"
print(json.dumps(dict(traces=traces, regimes=regimes, checks=checks, quality_exact=quality_exact,
                      pass_screen=quality_exact and all(r["pass_screen"] for r in checks)), indent=2))
