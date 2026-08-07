## Scratch probe: the control arena's landmark metrics on the landscape hull.
import std/[os, strformat], ctf/[arena, sim], "./map_metrics", "./map_eval"

setCurrentDir(getAppDir() / "..")
let control = computeMapMetrics(loadCtfMapMetadata("arena"))
echo &"hardGates = '{hardGates(control)}'"
echo &"validationReason = '{control.validationReason}'"
echo &"interiorFrac = {control.interiorFrac}"
echo &"p95ClearancePx = {control.p95ClearancePx}"
echo &"minRoutes = {control.minRoutes}"
echo &"crossings = {control.crossings.len} {control.crossings}"
echo &"chokepoints = {control.chokepoints} candidates = {control.chokeCandidates}"
echo &"chokeCoveredByOnePoint = {control.chokeCoveredByOnePoint}"
echo &"stands = {control.stands.len}"
for s in control.stands: echo &"  coverFrac={s.coverFrac}"
echo &"standRingDelta = {control.standRingDelta}"
let card = scoreMap(control, control)
for c in card.checks:
  if c.scored and not c.passes():
    echo &"FAILING BAND: {c.name} value={c.value} lo={c.lo} hi={c.hi}"
