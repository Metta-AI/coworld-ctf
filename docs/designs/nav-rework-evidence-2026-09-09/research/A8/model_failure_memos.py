"""Replay recorded raw searches; no cached result changes the recorded run."""
from collections import OrderedDict
import json
from pathlib import Path
import sys

source = json.loads(Path(sys.argv[1]).read_text())
rows = []
for entry in source["maps"]:
    calls = entry["calls"]
    for stage in sorted({c["stage"] for c in calls}):
        scoped = [c for c in calls if c["stage"] == stage]
        failed = {c["key"]: c for c in scoped if c["category"] == 0}
        baseline = dict(map=entry["map"], stage=stage, calls=len(scoped),
                        dequeues=sum(c["dequeues"] for c in scoped),
                        unique_failed_keys=len(failed),
                        unique_failed_target_bytes=sum(c["target_count"]*4 for c in failed.values()),
                        max_targets=max((c["target_count"] for c in scoped), default=0))
        models = []
        for policy in ["first_keys", "lru_keys", "latest_failed_per_start"]:
            for capacity in [16, 64, 128, 256, 512]:
                memo = OrderedDict()
                hits = saved = peak_payload = 0
                for call in scoped:
                    key = call["weak_key"] if policy == "latest_failed_per_start" else call["key"]
                    hit = key in memo and memo[key]["key"] == call["key"]
                    if hit:
                        assert call["category"] == 0
                        hits += 1
                        saved += call["dequeues"]
                        if policy == "lru_keys":
                            memo.move_to_end(key)
                    elif call["category"] == 0:
                        if key in memo or len(memo) < capacity:
                            memo[key] = call
                        elif policy == "lru_keys":
                            memo.popitem(last=False)
                            memo[key] = call
                    peak_payload = max(peak_payload, sum(c["target_count"]*4 for c in memo.values()))
                models.append(dict(policy=policy, capacity=capacity, hits=hits,
                                   saved_dequeues=saved, max_target_payload_bytes=peak_payload))
        rows.append(dict(**baseline, models=models))
print(json.dumps(rows, indent=2))
