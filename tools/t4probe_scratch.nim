## Throwaway: what layout / anchors / endzone-box centers does a 4-team board
## have, and which pedestal does the baseline bot's "largest |dx|" rule pick?
import std/[strformat, os, strutils]
import ../src/ctf/sim

proc describe(gameMap: CtfMap, label: string) =
  echo &"=== {label}  {gameMap.width}x{gameMap.height} {gameMap.layout} " &
    &"{gameMap.symmetry} {gameMap.endzone} ring={gameMap.flagRing} " &
    &"captureClear={gameMap.captureClear} homeDepth={gameMap.homeDepth}"
  var centers: seq[tuple[t: Team, cx, cy: float]]
  for team in gameMap.teams():
    let
      a = gameMap.teamAnchor(team)
      z = gameMap.captureZone(team)
      cx = float(z.xLo + z.xHi) * 0.5
      cy = float(z.yLo + z.yHi) * 0.5
    centers.add (team, cx, cy)
    echo &"  {team:<8} anchor=({a.x},{a.y})  zone=({z.xLo},{z.yLo})..({z.xHi},{z.yHi})" &
      &"  boxCenter=({cx:.1f},{cy:.1f})"
  ## The bot's rule, replicated: skip self, keep the FIRST strict max |dx|.
  for me in centers:
    var best = -1.0
    var pick = ""
    for other in centers:
      if other.t == me.t: continue
      let dx = abs(other.cx - me.cx)
      if dx > best:
        best = dx
        pick = $other.t
    echo &"  RAID {me.t:<8} -> {pick:<8} (|dx|={best:.1f})"

when isMainModule:
  for arg in commandLineParams():
    if arg.endsWith(".json"):
      describe(mapFromSpecJson(readFile(arg)), arg)
    else:
      let seed = arg.parseInt
      describe(generateCtfMap(seed,
        MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 4), "gen:" & arg)
