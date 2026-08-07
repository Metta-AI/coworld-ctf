## What layout / anchors / endzone-box centers does a 4-team board have, and
## which pedestal does the baseline bot's "largest |dx|" raid rule pick?
##
## This is the evidence behind docs/plans/2026-08-06-attackpairs-measures-the-bot.md:
## on BOTH 4-team layouts the rule ties between two enemies, so only two of the
## four pedestals are ever an intentional target and attackPairs is capped at
## 4/12 by the BOT, not by the map.
##
##   tools/t4probe maps/arena4.json 1003 1007
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
  ## `--dump-spec <dir>` also writes each generated 4-team board out as a
  ## mapSpec .json, which is what lets `map_eval score` compare a generated
  ## 4-team board against arena4 — `score` resolves a spec path but has no
  ## --teams flag, so a bare `gen:1007` there is the TWO-team board.
  var dumpDir = ""
  let argv = commandLineParams()
  for i, arg in argv:
    if arg == "--dump-spec" and i + 1 < argv.len:
      dumpDir = argv[i + 1]
  for i, arg in argv:
    if arg == "--dump-spec" or (i > 0 and argv[i - 1] == "--dump-spec"):
      continue
    if arg.endsWith(".json"):
      describe(mapFromSpecJson(readFile(arg)), arg)
    else:
      let
        seed = arg.parseInt
        gameMap = generateCtfMap(seed,
          MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 4)
      describe(gameMap, "gen:" & arg)
      if dumpDir.len > 0:
        createDir(dumpDir)
        writeFile(dumpDir / ("gen4-" & arg & ".json"), mapSpecJson(gameMap))
