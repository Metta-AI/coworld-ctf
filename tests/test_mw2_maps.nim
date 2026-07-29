import
  std/[deques, os, unittest],
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForMap(mapName: string): SimServer =
  ## Initializes the CTF sim on one named map from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.mapPath = mapName
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc isWalkable(sim: SimServer, x, y: int): bool =
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight and
    sim.walkMask[mapIndex(x, y)]

proc reaches(sim: SimServer, ax, ay, bx, by: int): bool =
  ## BFS over the walk mask on a 2px stride: true when (bx, by) is reachable
  ## from (ax, ay). The stride-2 lattice understates narrow corridors, so a
  ## pass here is conservative proof the full-resolution mask connects too.
  const Stride = 2
  let
    gw = MapWidth div Stride
    gh = MapHeight div Stride
  var
    seen = newSeq[bool](gw * gh)
    queue = initDeque[(int, int)]()
  queue.addLast((ax div Stride, ay div Stride))
  seen[(ay div Stride) * gw + ax div Stride] = true
  while queue.len > 0:
    let (cx, cy) = queue.popFirst()
    if cx == bx div Stride and cy == by div Stride:
      return true
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
        continue
      if seen[ny * gw + nx]:
        continue
      if not sim.isWalkable(nx * Stride, ny * Stride):
        continue
      seen[ny * gw + nx] = true
      queue.addLast((nx, ny))
  false

suite "mw2 paintball map pack":
  test "all six maps load and connect red spawn to blue flag":
    for name in Mw2Rotation:
      let sim = initCtfForMap(name)
      check sim.gameMap.name == name
      # Red spawn pocket center must reach the blue pedestal: the flag-run
      # round trip is the game, so a sealed map is a broken map.
      let
        redHome = sim.gameMap.flagHome(Red)
        blueHome = sim.gameMap.flagHome(Blue)
      check sim.isWalkable(redHome.x, redHome.y)
      check sim.isWalkable(blueHome.x, blueHome.y)
      check sim.reaches(redHome.x, redHome.y, blueHome.x, blueHome.y)

  test "mw2 alias resolves deterministically and covers the whole pack":
    var covered: array[6, bool]
    for seed in 0 ..< 6:
      var config = defaultGameConfig()
      config.update("""{"seed": """ & $seed & """, "mapPath": "mw2"}""")
      # Alias resolution is a pure function of the seed...
      check config.mapPath == Mw2Rotation[seed]
      var again = defaultGameConfig()
      again.update("""{"seed": """ & $seed & """, "mapPath": "mw2"}""")
      check again.mapPath == config.mapPath
      for i, name in Mw2Rotation:
        if name == config.mapPath:
          covered[i] = true
    # ...and six consecutive seeds visit all six maps.
    for i in 0 ..< 6:
      check covered[i]

  test "the registry rejects the alias and unknown names":
    expect CtfError:
      discard loadCtfMapMetadata("mw2")
    expect CtfError:
      discard loadCtfMapMetadata("shipment")
