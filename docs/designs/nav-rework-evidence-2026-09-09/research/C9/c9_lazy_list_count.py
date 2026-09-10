#!/usr/bin/env python3
"""C9 count screen: sequential per-source LRU-64 over each NAVSRC trace (the
cache is updated after every source, in recorded source order, exactly as
production does), tracking each residency (insertion until eviction) and how
many hits it earns. Reports per trace: sources, misses, first hits, later
hits, residency hit histogram (0/1/2/3+), and two materialization policies:
  first_hit : list built on a residency's first hit; later hits replay the list
  second_hit: list built on the second hit; hits after the second replay it
Break-even: with r = list/bitmap replay cost ratio, each list replay saves
(1 - r) bitmap units; the maximum one-time conversion cost X (in bitmap
replay units) the trace can afford is X = (1 - r) * list_replays / conversions.
Usage: c9_lazy_list_count.py <ratio> <trace.navsrc.txt>...
"""
import json, sys, hashlib, os
from collections import OrderedDict, Counter

def trace_label(path):
    """Per-episode layout (<run>/navsrc.txt) or named files (<run>.navsrc.txt)."""
    base = os.path.basename(path)
    if base == "navsrc.txt":
        return os.path.basename(os.path.dirname(path))
    return base[:-len(".navsrc.txt")] if base.endswith(".navsrc.txt") else base

CAP = 64

def parse(path):
    rebuilds = []
    for raw in open(path):
        if not raw.startswith("NAVSRC sched "):
            continue
        kv = dict(t.split("=", 1) for t in raw[13:].split())
        if kv["changed"] != "1":
            continue
        cells = kv["cells"].split(",") if kv["n"] != "0" else []
        rebuilds.append((int(kv["tick"]), int(kv["seat"]), cells))
    return rebuilds

def run(path, ratio):
    lru = OrderedDict()            # key -> hits in current residency
    finished = []                  # hit counts of evicted residencies
    sources = misses = hits = first_hits = later_hits = 0
    for tick, seat, cells in parse(path):
        for cell in cells:         # sequential: cache updated per source
            sources += 1
            if cell in lru:
                hits += 1
                lru[cell] += 1
                if lru[cell] == 1: first_hits += 1
                else: later_hits += 1
                lru.move_to_end(cell)
            else:
                misses += 1
                lru[cell] = 0
                if len(lru) > CAP:
                    _, h = lru.popitem(last=False); finished.append(h)
    residencies = finished + list(lru.values())
    hist = Counter(min(h, 3) for h in residencies)
    conv_first = sum(1 for h in residencies if h >= 1)
    replays_first = sum(h - 1 for h in residencies if h >= 1)
    conv_second = sum(1 for h in residencies if h >= 2)
    replays_second = sum(h - 2 for h in residencies if h >= 2)
    def breakeven(conv, replays):
        return None if conv == 0 else (1.0 - ratio) * replays / conv
    return {"trace": trace_label(path), "source_path": path,
            "source_sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(), "capacity": CAP, "sources": sources, "misses": misses,
            "hits": hits, "first_hits": first_hits, "later_hits": later_hits,
            "residencies": len(residencies),
            "residency_hit_histogram": {"0": hist[0], "1": hist[1], "2": hist[2], "3+": hist[3]},
            "policy_first_hit": {"conversions": conv_first, "list_replays": replays_first,
                                 "max_affordable_conversion_cost_bitmap_units": breakeven(conv_first, replays_first)},
            "policy_second_hit": {"conversions": conv_second, "list_replays": replays_second,
                                  "max_affordable_conversion_cost_bitmap_units": breakeven(conv_second, replays_second)},
            "eager_c7_reference": {"list_replays_all_hits": hits, "conversions_every_miss": misses}}

if __name__ == "__main__":
    ratio = float(sys.argv[1])
    out = {"list_over_bitmap_ratio_used": ratio, "traces": [run(p, ratio) for p in sys.argv[2:]]}
    print(json.dumps(out, indent=1))
