## Does the hand-authored arena hold the invariants the generator enforces?
##
## The generator's validators never run on an authored map, so the default
## league arena can silently drift below the standard every generated map has
## to clear — including the "no straight shot crosses the field" rule
## docs/RULES.md publishes as a gameplay promise.
##
##   nim c -d:release -r tools/hex_arena_check.nim

import std/strutils
import ../src/ctf/[sim_types, arena]

proc report(name: string, gameMap: CtfMap) =
  let d = mapDiagnostics(gameMap)
  echo name, "  ", gameMap.width, "x", gameMap.height,
    "  shapes(left) ", gameMap.leftObstacles.len,
    "  ez r=", gameMap.endzoneRadius,
    "  anchor ", gameMap.teamAnchor(Red).x, ",", gameMap.teamAnchor(Red).y
  echo "  cover ", d.coverPermille, " permille (min ", d.minCoverPermille,
    "), bounds ", d.coverPermilleFloor, "..", d.coverPermilleCeiling
  echo "  open sightline rows (axis 0): ", d.openSightlineRows.len
  echo "  center reachable: ", d.centerReachable,
    "   unreachable teams: ", d.unreachableTeams.len
  for g in d.endzoneGates:
    echo "  gate ", g.name, ": ", g.state
  echo "  rear route around endzone: ", d.rearGateReachesCenterWithoutEndzone
  echo "  VERDICT: ", (if d.reason.len == 0: "PASS" else: "FAIL — " & d.reason)
  echo ""

report("arena", loadCtfMapMetadata("arena"))
report("arena-large", loadCtfMapMetadata("arena-large"))
