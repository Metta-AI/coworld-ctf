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

  test "no map leaves a fully-open cross-field firing row":
    ## The guns are effectively map-wide, so the default arena guarantees every
    ## horizontal row hits cover (tests/test_map_los.nim). A pack map that
    ## leaves a row clear from one capture column to the other lets a defender
    ## shoot an attacker at spawn with no counterplay, so every map owes the
    ## same invariant. All six failed this when the layouts first landed; the
    ## per-map "sightline picket" shapes in sim.nim exist to hold it.
    for name in Mw2Rotation:
      let
        sim = initCtfForMap(name)
        lo = sim.gameMap.captureClear + 5
        hi = MapWidth - sim.gameMap.captureClear - 5
      var openRows: seq[int]
      var y = 10
      while y < MapHeight - 10:
        if sim.isWalkable(lo, y) or sim.isWalkable(hi, y):
          var blocked = false
          for s in 1 .. hi - lo:
            if sim.isWall(lo + s, y):
              blocked = true
              break
          if not blocked:
            openRows.add y
        inc y
      if openRows.len > 0:
        echo "  ", name, ": open rows ", openRows[0], "..", openRows[^1]
      check openRows.len == 0

  test "no map strands occupiable floor in a sealed pocket":
    ## Every cell a player can stand on must be reachable from the red
    ## pedestal with the REAL 13px footprint. A sealed pocket can swallow a
    ## nudged pickup (nearestWalkable is purely local and does not check
    ## connectivity) or trap a spawning player.
    ##
    ## Walked at 1px over a PRECOMPUTED occupancy mask: a strided flood is not
    ## sound here, because a hop wider than a corridor reports live floor on
    ## the far side as sealed (stride 3 flagged 3 phantom cells on Rust).
    ## Building the mask once keeps the exact version cheap — one canOccupy per
    ## cell instead of one per flood step.
    for name in Mw2Rotation:
      let
        sim = initCtfForMap(name)
        home = sim.gameMap.flagHome(Red)
      var occupiable = newSeq[bool](MapWidth * MapHeight)
      for y in 0 ..< MapHeight:
        for x in 0 ..< MapWidth:
          occupiable[mapIndex(x, y)] = sim.canOccupy(x, y)
      check occupiable[mapIndex(home.x, home.y)]
      var
        seen = newSeq[bool](MapWidth * MapHeight)
        queue = initDeque[(int, int)]()
      seen[mapIndex(home.x, home.y)] = true
      queue.addLast((home.x, home.y))
      while queue.len > 0:
        let (cx, cy) = queue.popFirst()
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
          let
            nx = cx + dx
            ny = cy + dy
          if nx < 0 or ny < 0 or nx >= MapWidth or ny >= MapHeight:
            continue
          if seen[mapIndex(nx, ny)] or not occupiable[mapIndex(nx, ny)]:
            continue
          seen[mapIndex(nx, ny)] = true
          queue.addLast((nx, ny))
      var stranded = 0
      for i in 0 ..< occupiable.len:
        if occupiable[i] and not seen[i]:
          inc stranded
      if stranded > 0:
        echo "  ", name, ": ", stranded, " stranded cells"
      check stranded == 0

  test "every pickup and spawn seat lands on occupiable floor":
    ## Pickups and spawns are placed by nudging a target to nearestWalkable,
    ## which is purely local — on a new layout the nudge can land somewhere a
    ## player cannot actually stand. Assert every one fits the real footprint.
    for name in Mw2Rotation:
      let sim = initCtfForMap(name)
      for sp in sim.grenadeSpawns:
        check sim.canOccupy(sp.x, sp.y)
      for sp in sim.medKitSpawns:
        check sim.canOccupy(sp.x, sp.y)
      for sp in sim.shieldSpawns:
        check sim.canOccupy(sp.x, sp.y)
      for sp in sim.plasmaArcSpawns:
        check sim.canOccupy(sp.x, sp.y)
      for team in Team:
        for order in 0 ..< 8:
          let seat = sim.spawnPosition(team, order)
          check sim.canOccupy(seat.x, seat.y)

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
