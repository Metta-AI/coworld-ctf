#!/usr/bin/env python3
"""FOUR DIGITS lane (W1; controller field added W11 v63, 2026-09-23/24) --
aggregates the tick-share + track-presence instrument (src/shell/ladder.nim,
`-d:tickShareProbe`) across a run_series.sh multi-seed series.

Reads, per seed directory OUT_ROOT/seed<i>/:
  - persona_map.json   {"<team 0..15>": "<persona>"}   (written by run_series.sh)
  - server.log          the probe's own `[tickshare] seat=.. tick=.. phase=..
                         native=0|1 controller=<name>|none trackHit=-1|0|1
                         distCenter=F distEdge=F` lines, one per sampled
                         (seat, tick) -- see ladder.nim's module comment
                         above tickShareProbeTick for exactly what each
                         field means, the ally-exclusion caveat on
                         trackHit, and (e) for `controller`.

Seat -> team mapping matches run_series.sh's own launch loop exactly:
`team = seat % 16`; only seats whose team's persona_map entry is "monet" are
counted (the other three personas are opponents in this local harness, not
Monet -- their tick behaviour is not this instrument's subject).

Reports, per phase bucket (opening tick<1500, mid 1500<=tick<6000,
endgame tick>=6000 -- ladder.nim's own convention, see its module comment):
  (a) native share = native ticks / all sampled alive ticks
  (b) controller-loop track-hit share = trackHit==1 / (trackHit==1 or ==0),
      i.e. restricted to sampled ticks where native did NOT fire and the
      view JSON parsed cleanly
  (c, W11 v63) PASSING CONTROLLER share = count(controller==X) / n_samples,
      for every distinct controller name observed (native, none, and every
      play name that ever won `livePassingController` this tick) -- this
      is the direct, per-tick measurement of "who actually held the seat,"
      independent of whether that controller's own client-side gate looked
      open at SEND time (the ~21% figure the FOUR DIGITS v63 lever targets
      is exactly this share for fire_superiority).
  (d) median distance to zone centre / zone edge, over ALL sampled alive
      ticks (native + controller), across the -1.0 sentinel (no zone data
      that sample -- excluded, not treated as a real 0px reading)

Usage: policies/monet/aggregate_tickshare.py [OUT_ROOT]
"""
from __future__ import annotations

import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

PHASES = ("opening", "mid", "endgame")

LINE_RE = re.compile(
    r"\[tickshare\] seat=(\d+) tick=(\d+) phase=(\w+) native=(\d) "
    r"controller=(\S+) trackHit=(-?\d) distCenter=(-?[\d.]+) "
    r"distEdge=(-?[\d.]+)")
# Pre-W11-v63 server.log lines (no `controller=` field) still parse: the
# probe/aggregator pair upgrades together on any one rebuild, but a log
# captured on the OLD binary should read as "controller unknown" rather
# than being silently dropped from the series.
LINE_RE_LEGACY = re.compile(
    r"\[tickshare\] seat=(\d+) tick=(\d+) phase=(\w+) native=(\d) "
    r"trackHit=(-?\d) distCenter=(-?[\d.]+) distEdge=(-?[\d.]+)")


def monet_seats(persona_map: dict) -> set[int]:
    return {seat for seat in range(32)
            if persona_map.get(str(seat % 16)) == "monet"}


def load_seed(seed_dir: Path):
    map_path = seed_dir / "persona_map.json"
    log_path = seed_dir / "server.log"
    if not map_path.exists() or not log_path.exists():
        return None
    persona_map = json.loads(map_path.read_text())
    wanted = monet_seats(persona_map)
    if not wanted:
        return None
    rows = []
    with log_path.open(errors="replace") as f:
        for line in f:
            if "[tickshare]" not in line:
                continue
            m = LINE_RE.search(line)
            if m:
                seat = int(m.group(1))
                if seat not in wanted:
                    continue
                rows.append(dict(
                    seat=seat, tick=int(m.group(2)), phase=m.group(3),
                    native=int(m.group(4)), controller=m.group(5),
                    trackHit=int(m.group(6)),
                    distCenter=float(m.group(7)), distEdge=float(m.group(8))))
                continue
            m = LINE_RE_LEGACY.search(line)
            if not m:
                continue
            seat = int(m.group(1))
            if seat not in wanted:
                continue
            rows.append(dict(
                seat=seat, tick=int(m.group(2)), phase=m.group(3),
                native=int(m.group(4)), controller="unknown",
                trackHit=int(m.group(5)),
                distCenter=float(m.group(6)), distEdge=float(m.group(7))))
    return rows


def summarize(rows: list[dict]) -> dict:
    out = {"overall": {}, "by_phase": {}}

    def bucket_stats(sub):
        total = len(sub)
        native = sum(1 for r in sub if r["native"] == 1)
        ctrl = [r for r in sub if r["native"] == 0]
        ctrl_valid = [r for r in ctrl if r["trackHit"] in (0, 1)]
        track_hit = sum(1 for r in ctrl_valid if r["trackHit"] == 1)
        centers = [r["distCenter"] for r in sub if r["distCenter"] != -1.0]
        # distEdge's -1.0 sentinel collides with a legitimate "1px outside"
        # reading; treated as missing here (see module docstring) -- the
        # collision rate is reported separately so this approximation is
        # checkable, not silently trusted.
        edges = [r["distEdge"] for r in sub if r["distEdge"] != -1.0]
        # (c, W11 v63) passing-controller share: count(controller==X) /
        # n_samples, for every distinct name seen ("native", "none", or a
        # play name) -- the direct per-tick measurement of who actually
        # held the seat, independent of any play's own client-side gate.
        controller_counts = Counter(r.get("controller", "unknown")
                                    for r in sub)
        passing_share = {name: round(n / total, 4)
                         for name, n in sorted(controller_counts.items())} \
            if total else {}
        return {
            "n_samples": total,
            "native_share": round(native / total, 4) if total else None,
            "controller_samples": len(ctrl),
            "controller_track_hit_share":
                round(track_hit / len(ctrl_valid), 4) if ctrl_valid else None,
            "controller_track_hit_valid_n": len(ctrl_valid),
            "passing_controller_share": passing_share,
            "median_dist_center": round(statistics.median(centers), 1)
                if centers else None,
            "median_dist_edge": round(statistics.median(edges), 1)
                if edges else None,
            "dist_center_missing_n": total - len(centers),
            "dist_edge_missing_n": total - len(edges),
        }

    out["overall"] = bucket_stats(rows)
    for phase in PHASES:
        sub = [r for r in rows if r["phase"] == phase]
        out["by_phase"][phase] = bucket_stats(sub)
    return out


def main():
    out_root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/monet-series")
    all_rows: list[dict] = []
    seed_dirs = sorted(out_root.glob("seed*"),
                        key=lambda p: int(p.name.replace("seed", "")))
    used = []
    for seed_dir in seed_dirs:
        rows = load_seed(seed_dir)
        if rows is None:
            continue
        all_rows.extend(rows)
        used.append(seed_dir.name)

    if not all_rows:
        print(f"no tickshare rows found under {out_root}", file=sys.stderr)
        sys.exit(1)

    summary = summarize(all_rows)
    summary["seeds_used"] = used
    summary["out_root"] = str(out_root)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
