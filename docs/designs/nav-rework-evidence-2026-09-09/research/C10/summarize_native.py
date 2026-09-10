#!/usr/bin/env python3
"""Evaluate the preregistered C10 three-arm replay screen from raw results."""
import json
from pathlib import Path
import statistics
import sys

MAPS = ("br-gen-5120", "br-gen-5204", "br-gen-5263")
IDENTITY = (
    "sampling", "candidate_cells", "map", "grid", "range_px", "origins",
    "origin_list", "stride", "batches", "repeats", "set_bits_per_origin",
    "full_words_per_origin", "batch_raster_hashes",
)


def evaluate_host(root):
    correctness = json.loads((root / "correctness.json").read_text())
    assert len(correctness["cases"]) == 5
    assert correctness["border_mask_cases"] == 256
    assert all(row["cell_mismatches"] == 0 for row in correctness["cases"])
    rows = []
    for name in MAPS:
        for reach in (331, 1300):
            pairs = []
            for repeat in range(1, 6):
                arms = {}
                for arm in ("parent", "scalar", "simd"):
                    path = root / f"{arm}-{name}-{reach}-r{repeat}.json"
                    value = json.loads(path.read_text())
                    assert value["arm"] == arm
                    assert value["reference_cell_mismatches"] == 0
                    assert value["origins"] == 64
                    assert value["stride"] == 97
                    assert value["batches"] == 5 and value["repeats"] == 4
                    assert len(value["per_replay_ns_by_batch"]) == 5
                    assert min(value["per_replay_ns_by_batch"]) > 0
                    assert statistics.median(value["per_replay_ns_by_batch"]) == value["per_replay_ns_median"]
                    arms[arm] = value
                for arm in ("scalar", "simd"):
                    for field in IDENTITY:
                        assert arms[arm][field] == arms["parent"][field], (name, reach, repeat, arm, field)
                medians = {arm: value["per_replay_ns_median"] for arm, value in arms.items()}
                pairs.append({
                    "repeat": repeat,
                    "median_ns": medians,
                    "scalar_parent": medians["scalar"] / medians["parent"],
                    "simd_parent": medians["simd"] / medians["parent"],
                    "simd_scalar": medians["simd"] / medians["scalar"],
                })
            row = {"map": name, "range_px": reach, "pairs": pairs}
            for ratio in ("scalar_parent", "simd_parent", "simd_scalar"):
                row[ratio] = statistics.median(pair[ratio] for pair in pairs)
            rows.append(row)
    return {"exact": True, "rows": rows}


def evaluate(paths):
    hosts = {path.name: evaluate_host(path) for path in paths}
    assert len(hosts) == 2, "Both m8i and m5a are required"
    rows = [row for host in hosts.values() for row in host["rows"]]
    qualifies = {}
    for arm in ("scalar", "simd"):
        qualifies[arm] = all(row[arm + "_parent"] <= (0.8 if row["range_px"] == 1300 else 1.01) for row in rows)
    simd_increment = all(row["simd_scalar"] <= 0.95 for row in rows if row["range_px"] == 1300)
    selected = "simd" if qualifies["simd"] and simd_increment else "scalar" if qualifies["scalar"] else None
    return {"hosts": hosts, "qualifies": qualifies, "simd_increment_qualifies": simd_increment,
            "selected_for_next_screen": selected, "production_qualified": False}


if __name__ == "__main__":
    print(json.dumps(evaluate([Path(path) for path in sys.argv[1:]]), indent=2))
