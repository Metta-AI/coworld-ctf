## Positive control for the routeReport export (driver 71450 §2): the exported
## disjoint-route count MUST match evaluateMap's validated routeCountMin/Max.
## arena=8, gen:4120=5. A mismatch = broken instrument; fail closed.
import ../src/ctf/[arena, map_metrics, sim_types]
import std/[os, strformat]
doAssert mapFitnessInstalled()
var ok = true
for name in ["arena", "arena-large", "gen:4120", "pool:2", "pool:4", "gen:4035"]:
  let m = loadCtfMapMetadata(name)
  let e = evaluateMap(m, name)
  let r = routeReport(m)
  let match = r.countMin == e.routeCountMin and r.countMax == e.routeCountMax
  echo &"{name}: routeReport.countMin={r.countMin} (evaluateMap.routeCountMin={e.routeCountMin}), " &
    &"countMax={r.countMax} ({e.routeCountMax}), pairs={r.pairs.len}, " &
    &"bottleneck=({r.bottleneckX},{r.bottleneckY}) -> " & (if match: "MATCH" else: "MISMATCH")
  if not match: ok = false
if ok:
  echo "POSITIVE CONTROL PASS: routeReport count == routeCountMin/Max on all maps."
  quit(0)
echo "POSITIVE CONTROL FAIL: export disagrees with the validated counter — broken instrument."
quit(1)
