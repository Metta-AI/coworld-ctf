#!/usr/bin/env python3
"""A1 config delta: ring schedule + honest round cap for config.practice.br.json.

Parse-modify-dump ONLY (json.load -> mutate -> json.dump) against a COPY of
the live template. Never sed/regex JSON.

WHAT THIS CHANGES, and why (see .proof/run-experience-20260902/design_ledger.md
RING-PACING EXPERIMENT + .proof/run-experience-20260902/pacing_experiment.json):

  zonePhases: waitTicks on the 5 live phases move to the rig-pacing lane's
  MEASURED WINNER -- "armB" (halve early waits AND compress the tail waits),
  PLUS the two-phase closing FLOOR that makes a maxTicks timeout structurally
  impossible ("armBz" in pacing_experiment.json; same pattern as
  tools/record_br_match.sh's showmatch zonePhases at tag
  deployed/swap11-20260901). z/dps/shrinkTicks on the 5 live phases are
  UNCHANGED -- only waitTicks moves, plus two brand-new trailing phases.

  CAUTION for whoever re-derives this: pacing_experiment.json also has an
  "armA" arm (halve ONLY phase1/2 waits, phases 3-5 waitTicks left at the
  live 360/240/180) that LOOKS similar at a glance but was MEASURED WORSE
  than control (more survivors fed into the unclosable final ring, 5/6
  rounds hit the 300s cap, dead tail 185s median vs control's 112.5s --
  verdict.armA in pacing_experiment.json: "DO NOT SHIP"). This script uses
  armB's waits (300/240/180/120/60), not armA's (300/240/360/240/180).

  maxTicks: 7200 (5:00 @ 24fps) was set for the OLD schedule and was never
  approached even then (live rounds land ~2:13). This package's measured
  rounds land 89-117s (armBz in pacing_experiment.json, n=4, dead_tail_s
  median 19.6s vs control's 112.5s). 4320 ticks (180s/24fps, "~3:00") keeps
  ~1.5x headroom over the worst measured round without advertising a TIME
  LEFT the game never approaches.

Usage:
  cp ~/.pbnf/app/vendor/config.practice.br.json /tmp/config.practice.br.a1.json
  python3 a1_config_delta.py /tmp/config.practice.br.a1.json /tmp/config.practice.br.a1.out.json
  # review the diff, then hand /tmp/config.practice.br.a1.out.json to the
  # orchestrator for deploy -- this script NEVER writes to ~/.pbnf itself.
"""
import json, sys

if len(sys.argv) != 3:
    sys.exit("usage: a1_config_delta.py <in_config.json> <out_config.json>")

in_path, out_path = sys.argv[1], sys.argv[2]

with open(in_path) as f:
    cfg = json.load(f)

BEFORE_WAITS = [p["waitTicks"] for p in cfg["zonePhases"]]
BEFORE_MAXTICKS = cfg["maxTicks"]

# armB waits (measured in pacing_experiment.json): halve early + compress tail.
NEW_WAITS = [300, 240, 180, 120, 60]
assert len(cfg["zonePhases"]) == len(NEW_WAITS) == 5, (
    "zonePhases phase count drifted from the 5-phase live schedule this "
    "delta was derived against -- re-measure before reusing these numbers"
)
for phase, wt in zip(cfg["zonePhases"], NEW_WAITS):
    phase["waitTicks"] = wt

# Closing floor: two new trailing phases, z/dps unchanged from the
# showmatch-lane pattern (tools/record_br_match.sh at deployed/swap11-20260901)
# and from the rig-pacing lane's armBz measurement.
cfg["zonePhases"].append({"z": 0.06, "waitTicks": 60, "shrinkTicks": 180, "dps": 16})
cfg["zonePhases"].append({"z": 0.001, "waitTicks": 0, "shrinkTicks": 180, "dps": 20})

cfg["maxTicks"] = 4320  # 180s @ 24fps, was 7200 (300s)

with open(out_path, "w") as f:
    json.dump(cfg, f, indent=1)

print(f"waitTicks: {BEFORE_WAITS} -> {NEW_WAITS} + [60, 0] (2 new floor phases)")
print(f"maxTicks:  {BEFORE_MAXTICKS} -> {cfg['maxTicks']}")
print(f"zonePhases: 5 phases -> {len(cfg['zonePhases'])} phases")
print(f"wrote {out_path}")
