#!/usr/bin/env python3
"""LRU model over NAVSRC traces (CACHE_TRACE_PLAN.md section 6). Count only.
Usage: cache_sim.py navsrc.txt [more...]   Keys: (sys, cell). Only changed
scheduled rebuilds produce lookups; steps are measured castRay iterations."""
import sys
from collections import OrderedDict, defaultdict

def parse(path):
    lines = []
    for raw in open(path):
        if not raw.startswith("NAVSRC "):
            continue
        kind, *rest = raw[7:].split()
        kv = dict(t.split("=", 1) for t in rest)
        lines.append((kind, kv))
    return lines

def rebuilds(lines):
    pending = {}
    for kind, kv in lines:
        if kind == "sched" and kv["changed"] == "1":
            cells = kv["cells"].split(",") if kv["n"] != "0" else []
            pending[(kv["sys"], kv["tick"], kv["seat"])] = cells
        elif kind == "rays":
            cells = pending.pop((kv["sys"], kv["tick"], kv["seat"]))
            src = kv["src"]
            steps = [int(s.split(":")[2]) for s in src.split(",")] if src else []
            srccells = [":".join(s.split(":")[:2]) for s in src.split(",")] if src else []
            assert srccells == cells, (kv, cells)
            yield kv["sys"], int(kv["tick"]), int(kv["seat"]), list(zip(cells, steps))
    assert not pending, f"sched changed=1 without rays: {list(pending)[:3]}"

def simulate(all_rebuilds, cap):
    """Shared LRU over (sys, cell). Attribution split (corrected after root
    review): a hit is 'carry-servable' only when the SAME seat's immediately
    previous changed rebuild selected that key (an exact per-seat carry of
    the last rebuild's per-source lists would serve it); every other hit is
    'beyond-carry' (served only because a shared cache remembered it, from
    another seat or from this seat's older rebuilds). Reuse distance is
    ticks since the key's last use by any seat."""
    lru = OrderedDict(); hits = misses = dup = saved = total = 0
    seen = {}; last_tick = {}; prev_sets = {}
    carry_hits = beyond_hits = 0; carry_saved = beyond_saved = 0
    distances = []
    for sys_id, tick, seat, srcs in all_rebuilds:
        in_this = set(); prev = prev_sets.get(seat, set())
        for cell, steps in srcs:
            key = (sys_id, cell); total += steps
            if key in seen:
                assert seen[key] == steps, ("nondeterministic steps", key, seen[key], steps)
            else:
                seen[key] = steps
            if key in lru:
                hits += 1; saved += steps; lru.move_to_end(key)
                if key in in_this: dup += 1
                if key in prev: carry_hits += 1; carry_saved += steps
                else: beyond_hits += 1; beyond_saved += steps
                distances.append(tick - last_tick[key])
            else:
                misses += 1; lru[key] = steps
                if cap and len(lru) > cap: lru.popitem(last=False)
            in_this.add(key); last_tick[key] = tick
        prev_sets[seat] = in_this
    distances.sort()
    def pct(q): return distances[min(len(distances) - 1, int(q * len(distances)))] if distances else 0
    return dict(cap=cap or "inf", lookups=hits + misses, hits=hits, dup_hits=dup,
                hit_rate=hits / max(1, hits + misses), total_steps=total,
                saved_steps=saved, steps_removed=saved / max(1, total),
                carry_servable_hits=carry_hits, beyond_carry_hits=beyond_hits,
                carry_servable_removed=carry_saved / max(1, total),
                beyond_carry_removed=beyond_saved / max(1, total),
                reuse_ticks_p50=pct(0.5), reuse_ticks_p90=pct(0.9),
                distinct_keys=len(seen))

def simulate_carry_only(all_rebuilds):
    """Per-seat carry only: the seat keeps its previous changed rebuild's
    per-source lists; a lookup is served iff the key was in that previous
    rebuild. No sharing across seats, no memory beyond one rebuild per seat."""
    prev_sets = {}; hits = total = saved = 0; lookups = 0
    for sys_id, tick, seat, srcs in all_rebuilds:
        prev = prev_sets.get(seat, set()); cur = set()
        for cell, steps in srcs:
            key = (sys_id, cell); total += steps; lookups += 1
            if key in prev: hits += 1; saved += steps
            cur.add(key)
        prev_sets[seat] = cur
    return dict(model="carry_only", lookups=lookups, hits=hits,
                hit_rate=hits / max(1, lookups), steps_removed=saved / max(1, total))

def check_invariants(lines):
    """Header/system/map/phase invariants; raises on violation."""
    syss = [kv for k, kv in lines if k == "sys"]
    assert len(syss) == 1, f"expected one nav system header, got {len(syss)}"
    sys_id = syss[0]["id"]
    for k, kv in lines:
        if k != "sys":
            assert kv["sys"] == sys_id, ("line from another system", k, kv)
    last_tick = -1; pending = set(); active = set(); max_n = 0
    for k, kv in lines:
        if k == "active":
            (active.add if kv["active"] == "1" else active.discard)(kv["seat"])
        elif k == "sched":
            t = int(kv["tick"]); seat = int(kv["seat"])
            assert t >= last_tick, ("sched ticks not monotone", kv); last_tick = t
            assert t % 32 == seat % 32, ("seat visited off cadence", kv)
            n = int(kv["n"]); max_n = max(max_n, n)
            assert 0 <= n <= 8, ("source count out of range", kv)
            if n > 0: assert kv["seat"] in active, ("sources for inactive seat", kv)
            assert len(kv["cells"].split(",")) == n if n else kv["cells"] == "", kv
            if kv["changed"] == "1":
                assert (kv["tick"], kv["seat"]) not in pending
                pending.add((kv["tick"], kv["seat"]))
        elif k == "rays":
            assert (kv["tick"], kv["seat"]) in pending, ("rays without sched", kv)
            pending.discard((kv["tick"], kv["seat"]))
        elif k == "init":
            raise AssertionError(f"forced initializeDanger seen: {kv}")
    assert not pending, f"changed rebuilds without rays: {sorted(pending)[:3]}"
    return dict(sys_id=sys_id, grid=syss[0]["grid"], range_px=syss[0]["range_px"],
                map=syss[0].get("map"), sight_fnv=syss[0]["sight_fnv"],
                seats=syss[0]["seats"], max_selected_sources=max_n)

def summary(lines, rb):
    sched = [kv for k, kv in lines if k == "sched"]
    changed = [kv for kv in sched if kv["changed"] == "1"]
    zero = sum(1 for kv in changed if kv["n"] == "0")
    acts = sum(1 for k, kv in lines if k == "active" and kv["active"] == "1")
    deacts = sum(1 for k, kv in lines if k == "active" and kv["active"] == "0")
    inits = sum(1 for k, _ in lines if k == "init")
    syss = [kv for k, kv in lines if k == "sys"]
    ticks = [int(kv["tick"]) for kv in sched]
    per_seat = defaultdict(int)
    for _, _, seat, srcs in rb: per_seat[seat] += len(srcs)
    return (f"sys={len(syss)} map={syss[0].get('map','?') if syss else '?'} range={syss[0].get('range_px','?') if syss else '?'} "
            f"sched={len(sched)} changed={len(changed)} changed_zero_sources={zero} unchanged={len(sched)-len(changed)} "
            f"activations={acts} deactivations={deacts} init_lines={inits} "
            f"tick_range={min(ticks) if ticks else '-'}..{max(ticks) if ticks else '-'} "
            f"lookups_by_seat={dict(sorted(per_seat.items()))}")

def main(paths):
    for path in paths:
        lines = parse(path); rb = list(rebuilds(lines))
        inv = check_invariants(lines)
        print(f"== {path}\n  {summary(lines, rb)}")
        print("  invariants_ok " + " ".join(f"{k}={v}" for k, v in inv.items()))
        c = simulate_carry_only(rb)
        print("  " + " ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in c.items()))
        for cap in (8, 16, 32, 64, 128, 256, None):
            r = simulate(rb, cap)
            print("  " + " ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in r.items()))

if __name__ == "__main__":
    main(sys.argv[1:])
