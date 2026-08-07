## WHERE does a hex map's connectivity break?
##
## The hex conversion inverted the generator's failure profile: on the square
## board open horizontal sightlines dominated rejections, and on the hexagon
## "no 26px route to the center" does. That is a different design problem, and
## which fix it wants depends on WHERE the corridor pinches:
##
##   - near the HULL — terrain crowding the six boundary faces, so the ring
##     road round the outside is severed. Fix: a boundary apron.
##   - in the INTERIOR — the middle of the board is sealed off while the outer
##     ring stays connected. Fix: carve and pin a group-invariant central hub
##     FIRST, so connectivity reduces to a local check.
##
## This measures it: for every seed rejected for connectivity, it flood-fills
## from Red's home over the player-width-eroded floor and reports how much of
## the open field was reached, and how the reached and UNREACHED open pixels
## are distributed by distance from the hull.
##
##   nim c -d:release -r tools/hex_connectivity_probe.nim [count] [firstSeed]

import std/[os, strutils]
import ../src/ctf/[sim_types, arena]
import ../src/ctf/map_score  ## installs the best-of-K ranker at module init

type Bucket = enum
  bRim      ## within 80px of the hull — the ring road
  bMid
  bCore     ## the innermost third — the hub

proc bucketOf(edge, apothem: float): Bucket =
  if edge < 80.0: bRim
  elif edge < apothem * 0.55: bMid
  else: bCore

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 200
    firstSeed = if paramCount() >= 2: parseInt(paramStr(2)) else: 1
  var
    examined = 0
    reachedTotal, openTotal: array[Bucket, int]
    unreachedNearHome = 0
    unreachedFarFromHome = 0
  for i in 0 ..< count:
    let seed = firstSeed + i
    var gameMap: CtfMap
    try:
      gameMap = generateMapAttempt(
        seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 2)
    except CatchableError:
      continue
    let quick = validateGeneratedMap(gameMap)
    if not quick.startsWith("no ") or "route" notin quick:
      continue
    inc examined
    let
      d = mapDiagnostics(gameMap, {diagnosticCorridorOpen, diagnosticReachable})
      board = gameMap.mapBoard()
      apothem = board.apothem()
      w = gameMap.width
    var reachedOpen, unreachedOpen = 0
    for y in 0 ..< gameMap.height:
      for x in 0 ..< w:
        let idx = y * w + x
        if not d.corridorOpen[idx]:
          continue
        let b = bucketOf(board.hexEdgeDist(x, y), apothem)
        inc openTotal[b]
        if d.reachable[idx]:
          inc reachedOpen
          inc reachedTotal[b]
        else:
          inc unreachedOpen
    ## Is Red boxed into a pocket, or does it own most of the field?
    if reachedOpen * 2 < reachedOpen + unreachedOpen:
      inc unreachedNearHome
    else:
      inc unreachedFarFromHome
    if examined <= 6:
      echo "seed ", seed, " (", gameMap.width, "x", gameMap.height, "): ",
        reachedOpen * 100 div max(1, reachedOpen + unreachedOpen),
        "% of the eroded floor reachable from Red — ", quick
  echo ""
  echo "connectivity-rejected maps examined: ", examined
  if examined == 0:
    return
  echo "  Red reaches LESS than half the open floor (boxed in): ",
    unreachedNearHome
  echo "  Red reaches MORE than half (the far side is sealed):  ",
    unreachedFarFromHome
  echo ""
  echo "  open floor reached, by distance from the hull:"
  for b in Bucket:
    let total = openTotal[b]
    echo "    ", align($b, 6), "  ", align($(reachedTotal[b] * 100 div
      max(1, total)), 3), "%  of ", total, " px"

main()
