"""Summarize the frozen C9 native micro without altering raw results."""
import json
import statistics
import sys
from pathlib import Path

folder = Path(sys.argv[1])
assert (folder / "DONE").exists(), "Run is incomplete"
groups = {}
for path in sorted(folder.glob("br-*.json")):
    row = json.loads(path.read_text())
    groups.setdefault((row["map"], row["range_px"]), []).append(row)
assert len(groups) == 8
summary = []
for (map_name, range_px), rows in sorted(groups.items()):
    assert len(rows) == 5
    bitmap = statistics.median(row["bitmap_ns_median"] for row in rows)
    conversion = statistics.median(row["conversion_ns_median"] for row in rows)
    replay = statistics.median(row["list_ns_median"] for row in rows)
    exact = all(row["hashes_equal"] and row["set_mismatches"] == 0
                and row["raster_mismatches"] == 0 for row in rows)
    summary.append(dict(map=map_name, range_px=range_px, rounds=len(rows),
                        bitmap_ns=bitmap, conversion_ns=conversion, list_ns=replay,
                        conversion_increment=(conversion-bitmap)/bitmap,
                        list_ratio=replay/bitmap, exact=exact,
                        pass_screen=exact and (conversion-bitmap)/bitmap <= 0.30
                        and replay/bitmap <= 0.50))
print(json.dumps(summary, indent=2))
