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
import ../src/ctf/map_score  ## installs the best-of-K ranker at module init

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

proc standMetrics(gameMap: CtfMap, obstacles: seq[ArenaShape], team: Team) =
  ## The two numbers that decide whether a base is PLAYABLE where it sits, as
  ## opposed to merely geometrically legal:
  ##
  ##   stand-ring openness — the fraction of a ring at `r` around the pedestal
  ##     that is walkable floor. This is the funnel test: a base parked in the
  ##     120-degree vertex wedge with its approaches pinched would read as a low
  ##     number on the outer rings even while the inner ones stay clear.
  ##   stand-side cover — the wall fraction of the disc within 200px. Too low is
  ##     an exposed base, too high is a sealed one.
  ##
  ## Reported per TEAM, because "the bases are images of each other" is a claim
  ## worth checking rather than assuming: on a mirror board it should come out
  ## exactly equal, and any difference is a pipeline bug.
  let
    anchor = gameMap.teamAnchor(team)
    board = gameMap.mapBoard()
  var line = &"  {teamText(team):<7}"
  for radius in [120, 160, 200, 240]:
    var open = 0
    var total = 0
    for step in 0 ..< 720:
      let
        ang = degToRad(float(step) * 0.5)
        x = anchor.x + int(round(float(radius) * cos(ang)))
        y = anchor.y + int(round(float(radius) * sin(ang)))
      inc total
      if x >= 0 and y >= 0 and x < gameMap.width and y < gameMap.height and
          not gameMap.mapWallAt(obstacles, x, y):
        inc open
    line.add &" r{radius}={float(open) / float(total) * 100.0:5.1f}%"
  var wall = 0
  var cells = 0
  for dy in -200 .. 200:
    for dx in -200 .. 200:
      if dx * dx + dy * dy > 200 * 200: continue
      let
        x = anchor.x + dx
        y = anchor.y + dy
      inc cells
      if x < 0 or y < 0 or x >= gameMap.width or y >= gameMap.height or
          gameMap.mapWallAt(obstacles, x, y):
        inc wall
  line.add &"  cover200={float(wall) / float(cells) * 100.0:5.1f}%"
  line.add &"  hullBehind={board.hexEdgeDist(anchor.x, anchor.y):6.1f}"
  echo line

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
  echo "  stand-ring openness (walkable fraction of a ring at r):"
  let obstacles = buildArenaObstacles(gameMap)
  for team in gameMap.teams():
    standMetrics(gameMap, obstacles, team)

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
