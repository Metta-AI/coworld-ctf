import
  std/[os, random, unittest],
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(defaultGameConfig())
  finally:
    setCurrentDir(previousDir)

proc segmentBlocked(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when a wall pixel blocks the straight segment between two
  ## map points (same stepping as the sim's line-of-sight routine).
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.isWall(ax + dx * s div steps, ay + dy * s div steps):
      return true
  false

proc isWalkable(sim: SimServer, x, y: int): bool =
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight and
    sim.walkMask[mapIndex(x, y)]

suite "map long sightlines":
  let sim = initCtfForTest()

  test "no full horizontal crossing on any walkable row":
    var y = 10
    while y < MapHeight - 10:
      if sim.isWalkable(215, y) or sim.isWalkable(1020, y):
        check sim.segmentBlocked(215, y, 1020, y)
      y += 4

  test "at least 95% of long diagonals are wall-blocked":
    var rng = initRand(0xC7F5EED)
    proc randomWalkable(): (int, int) =
      while true:
        let
          x = rng.rand(MapWidth - 1)
          y = rng.rand(MapHeight - 1)
        if sim.isWalkable(x, y):
          return (x, y)
    var blocked = 0
    const Pairs = 500
    for _ in 0 ..< Pairs:
      var (ax, ay, bx, by) = (0, 0, 0, 0)
      while true:
        (ax, ay) = randomWalkable()
        (bx, by) = randomWalkable()
        if distSq(ax, ay, bx, by) >= 700 * 700:
          break
      if sim.segmentBlocked(ax, ay, bx, by):
        inc blocked
    echo "long sightlines blocked: ", blocked, "/", Pairs
    check blocked * 100 >= Pairs * 95

  test "capture columns and flag center stay mutually reachable":
    var visited = newSeq[bool](MapWidth * MapHeight)
    var queue = @[(100, MapHeight div 2)]
    visited[mapIndex(100, MapHeight div 2)] = true
    var head = 0
    while head < queue.len:
      let (x, y) = queue[head]
      inc head
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nx = x + dx
          ny = y + dy
        if sim.isWalkable(nx, ny) and not visited[mapIndex(nx, ny)]:
          visited[mapIndex(nx, ny)] = true
          queue.add((nx, ny))
    check visited[mapIndex(sim.gameMap.center.x, sim.gameMap.center.y)]
    check visited[mapIndex(MapWidth - 100, MapHeight div 2)]
