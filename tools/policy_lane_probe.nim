## Does the reference policy's LANE geometry land on floor?
##
## `players/baseline/baseline.nim` navigates to three horizontal lanes —
## `LaneTop` (y = 40), `LaneMid` (the centre row) and `LaneBottom`
## (`MapH - 40`) — and it adopts the map's REAL dimensions at runtime from the
## walkability sprite, so the y values scale with the board. On a RECTANGLE
## every one of those rows was floor for its whole width. The hexagon has no
## floor at all near the top and bottom of its bounding box, so the same
## expression can name permanent void, and a bot ordered there simply never
## arrives: no crash, no log line, just a seat that stops contributing.
##
## Prints, per board, the fraction of each lane that is walkable and the widest
## clear run on it. Run before changing the policy's lanes — the point is to
## measure, not to assume.
##
##   nim c -d:release -r tools/policy_lane_probe.nim

import std/[strformat, strutils], ../src/ctf/sim

const
  LaneTopY = 40      ## baseline.nim's `LaneTop`, on the real board height.
  ## The two hand-authored arenas, three free-drawn seeds, and one seed pinned
  ## to each size class: the flank offsets are absolute pixels, so the class
  ## WIDTH is what decides whether they clear the hull's slanted shoulder.
  Boards = [("arena", 0, ""), ("arena-large", 0, ""),
            ("gen", 4242, ""), ("gen", 1337, ""), ("gen", 2026, ""),
            ("gen", 7001, "small"), ("gen", 7002, "small"),
            ("gen", 7003, "standard"), ("gen", 7004, "large"),
            ("gen", 7005, "huge"), ("gen", 7006, "giant")]

proc laneStats(gameMap: CtfMap, obstacles: seq[ArenaShape],
               y: int): tuple[open: int, longest: int] =
  ## Floor-pixel count and longest clear run along one row. Pure in `gameMap`
  ## (`mapWallAt`, not the installed-arena globals), so it measures the board
  ## named on the command line rather than whatever was installed last.
  var run = 0
  for x in 0 ..< gameMap.width:
    if not gameMap.mapWallAt(obstacles, x, y):
      inc result.open
      inc run
      if run > result.longest: result.longest = run
    else:
      run = 0

proc flankTargets(w, h: int): seq[tuple[name: string, x, y: int]] =
  ## The concrete points `baseline.nim`'s FLANK roles steer to. Unlike the
  ## carrier's lane pick — which since GV38 charges a lane for every
  ## unwalkable sample and so retires a wall lane on its own — these are
  ## unconditional: `FlankTop`/`FlankBottom` head for
  ## `(CenterX -/+ FlankDepth, LaneTop|LaneBottom)` and the standoff post for
  ## `(CenterX +/- 200, LaneTop|LaneBottom)`, with no walkability term.
  const FlankDepth = 260
  const StandoffX = 200
  let cx = w div 2
  for (label, dx) in [("flank", FlankDepth), ("standoff", StandoffX)]:
    for sign in [-1, 1]:
      for (laneName, y) in [("Top", LaneTopY), ("Bottom", h - LaneTopY)]:
        result.add((label & laneName & (if sign < 0: "-W" else: "-E"),
                    cx + sign * dx, y))

proc main() =
  echo "board            dims        lane      y     open%   longest-run"
  for (source, seed, size) in Boards:
    var config = defaultGameConfig()
    config.teams = 2
    config.mapPath = source
    config.mapSeed = seed
    if size.len > 0:
      config.mapGen.size = size
    let
      gameMap = resolveCtfMapMetadata(config)
      obstacles = buildArenaObstacles(gameMap)
      w = gameMap.width
      h = gameMap.height
      lanes = [("LaneTop", LaneTopY), ("LaneMid", h div 2),
               ("LaneBottom", h - LaneTopY)]
    for (name, y) in lanes:
      let (open, longest) = laneStats(gameMap, obstacles, y)
      let label = (if source == "gen": source & ":" & $seed else: source)
      echo &"{label:<16} {w:>4}x{h:<4}  {name:<10} {y:>4}  " &
        &"{(100.0 * float(open) / float(w)):>6.1f}  {longest:>6}"
    var wallTargets: seq[string]
    for (name, x, y) in flankTargets(w, h):
      if gameMap.mapWallAt(obstacles, x, y):
        wallTargets.add &"{name}({x},{y})"
    let label = (if source == "gen": source & ":" & $seed else: source)
    echo &"  -> flank/standoff targets in WALL: " &
      (if wallTargets.len == 0: "none" else: wallTargets.join(" ")) &
      &"   [{wallTargets.len}/8]"

when isMainModule:
  main()
