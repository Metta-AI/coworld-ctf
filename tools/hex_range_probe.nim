## Measures the shipped hex arena against the two questions the LANDSCAPE flip
## opened: does a base still fit behind its endzone now that the 2-team axis
## runs to a VERTEX, and does the fixed 1050px `GunRange` still outreach the
## board now that the board's long axis is 1119px rather than 969px?
##
## Both are measurements, not assertions — the numbers go in the commit message
## and the plan doc. `tests/test_hex_arena.nim` is where the invariants live.
##
##   nim c -d:release -r tools/hex_range_probe.nim

import std/[math, strformat, strutils]
import ../src/ctf/[sim_types, arena, hex]

proc classReport() =
  echo "=== SIZE CLASSES (flat-top, landscape) ==="
  echo "  class      W x H        aspect    playfield   R      A     ",
       "endzoneR  window     depth  behind  need"
  for cls in HexSizeClass:
    let
      board = hexBoardOf(cls)
      name = HexClassNames[cls]
    let
      probe = arenaHexCtfMap(name, cls)
      window = probe.homeDepthWindow()
      anchor = probe.teamAnchor(Red)
      behind = board.hexEdgeDist(anchor.x, anchor.y)
      need = probe.endzoneRadius + EndzoneApron
    echo &"  {name:<9} {board.width:>5} x {board.height:<5} {board.aspect():.5f} " &
         &"{board.hexArea():>11.0f} {board.circumradius():>6.1f} {board.apothem():>6.1f} " &
         &"{probe.endzoneRadius:>7}  {window.lo:>3}-{window.hi:<3}  " &
         &"{probe.homeDepth:>5}  {behind:>6.1f}  {need:>4}" &
         (if behind >= float(need): "" else: "   <-- FAILS")

proc baseReport(gameMap: CtfMap) =
  echo ""
  echo "=== BASES (standard arena) ==="
  let board = gameMap.mapBoard()
  for team in gameMap.teams():
    let
      a = gameMap.teamAnchor(team)
      dx = a.x - gameMap.center.x
      dy = a.y - gameMap.center.y
    echo &"  {teamText(team):<7} anchor ({a.x}, {a.y})  radial {hypot(float(dx), float(dy)):.1f}" &
         &"  hull behind {board.hexEdgeDist(a.x, a.y):.1f}"
  let
    ra = gameMap.teamAnchor(Red)
    ba = gameMap.teamAnchor(Blue)
  echo &"  base-to-base separation: {abs(ba.x - ra.x)} px  (gun range {GunRange})"
  ## Vertical field available at the anchor's column: the flank room a base has.
  var flank = 0
  while ra.y - flank - 1 > 0 and
      board.hexEdgeDist(ra.x, ra.y - flank - 1) >= float(ArenaBorder):
    inc flank
  echo &"  open field above/below the anchor column: {flank} px " &
       &"(endzone radius {gameMap.endzoneRadius})"

proc longestOpenRun(gameMap: CtfMap): tuple[len: int, deg: float,
                                            x0, y0, x1, y1: int] =
  ## The longest straight run of non-wall pixels anywhere on the board, swept
  ## over 180 directions at 1-degree steps. This is the real answer to "does the
  ## gun outrange the map": the hexagon's longest CHORD is 1118px, but terrain
  ## cuts it, and what a gun can actually cover is the longest run no obstacle
  ## interrupts.
  let
    obstacles = buildArenaObstacles(gameMap)
    cx = gameMap.center.x
    cy = gameMap.center.y
  ## Bake the wall mask ONCE. `mapWallAt` walks every obstacle, and the sweep
  ## below samples a few hundred million points.
  var wall = newSeq[bool](gameMap.width * gameMap.height)
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      wall[y * gameMap.width + x] = gameMap.mapWallAt(obstacles, x, y)
  result.len = 0
  for degI in 0 ..< 180:
    let
      ang = degToRad(float(degI))
      dxs = cos(ang)
      dys = sin(ang)
      ## March perpendicular to the ray to cover the whole board with parallel
      ## lines 1px apart.
      px = -dys
      py = dxs
      reach = int(hypot(float(gameMap.width), float(gameMap.height))) div 2 + 2
    for off in -reach .. reach:
      var
        run = 0
        sx = 0
        sy = 0
      for t in -reach .. reach:
        let
          fx = float(cx) + dxs * float(t) + px * float(off)
          fy = float(cy) + dys * float(t) + py * float(off)
          x = int(round(fx))
          y = int(round(fy))
        var open = x >= 0 and y >= 0 and x < gameMap.width and y < gameMap.height
        if open:
          open = not wall[y * gameMap.width + x]
        if open:
          if run == 0:
            sx = x
            sy = y
          inc run
          if run > result.len:
            result = (len: run, deg: float(degI), x0: sx, y0: sy, x1: x, y1: y)
        else:
          run = 0

when isMainModule:
  classReport()
  installDefaultArena()
  let gameMap = loadCtfMapMetadata("arena")
  baseReport(gameMap)
  echo ""
  echo "=== LONGEST FULLY-OPEN RUN (standard arena, all directions) ==="
  let best = longestOpenRun(gameMap)
  echo &"  {best.len} px at {best.deg:.0f} deg, ({best.x0},{best.y0}) -> ({best.x1},{best.y1})"
  echo &"  board long axis (vertex to vertex): {gameMap.width - 1} px"
  echo &"  board short axis (edge to edge):    {gameMap.height - 1} px"
  echo &"  GunRange: {GunRange} px"
  if best.len <= GunRange:
    echo &"  => the gun still covers the longest open run, with " &
         &"{GunRange - best.len} px to spare."
  else:
    echo &"  => the longest open run EXCEEDS gun range by {best.len - GunRange} px: " &
         "the board now outreaches the gun."
