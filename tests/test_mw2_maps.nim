import
  std/[deques, os, strutils, unittest],
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
  test "the validators see the same mask the game plays on":
    # Two definitions of the same rule exist: isProtectedFloor, used once a map
    # is installed as the process map (i.e. in play), and mapProtectedFloorAt,
    # used by the generator, the pool validators and the asymmetry test below
    # on a map that is not installed. Everything those consumers PROMISE about
    # a map -- no sealed pockets, no open firing row, comparable halves -- is
    # promised about whichever mask they compute, so a divergence makes the
    # guarantees describe a layout nobody plays.
    #
    # They did diverge, on all six maps, the moment the recreations started
    # setting fields the abstract arenas leave at their defaults: 9k-14k px
    # from reading captureClear where the game reads carveClear, plus a
    # further 2.4k on Terminal from pinning the spawn pocket to the centre
    # line instead of the declared home point. Both are fixed; this keeps it
    # that way, and it is the pack maps that exercise it -- the arenas leave
    # both fields at defaults and would pass either way.
    for name in Mw2Rotation:
      let
        sim = initCtfForMap(name)
        gameMap = sim.gameMap
        obstacles = (if gameMap.fullObstacles.len > 0: gameMap.fullObstacles
                     else: gameMap.leftObstacles)
      var diffs = 0
      for y in 0 ..< MapHeight:
        for x in 0 ..< MapWidth:
          if mapWallAt(gameMap, obstacles, x, y) !=
              sim.wallMask[mapIndex(x, y)]:
            inc diffs
      if diffs != 0:
        echo name, ": validator and game masks differ on ", diffs, " px"
      check diffs == 0

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

  test "each pack map is fair to both halves":
    ## THE test the asymmetric layouts owe. Every other invariant here is
    ## side-agnostic: it would pass just as happily on a map that gives Red a
    ## fortress and Blue a parking lot.
    ##
    ## `arena` and every generated map get fairness for free by construction —
    ## the right half IS the left half under mirror or 180 rotation, so the two
    ## sides are identical by definition. A CtfMap that fills `fullObstacles`
    ## deliberately gives that up: Terminal's 747 sits at one end of the
    ## concourse and mirroring it would destroy the geometry that makes the map
    ## recognizable. Fidelity is bought with symmetry, so from that moment
    ## nothing else in the suite asserts the halves are even comparable.
    ##
    ## Three ratios, each min/max so the direction of the imbalance never
    ## matters:
    ##
    ## - OCCUPIABLE AREA. Space a 13px player can actually stand in, per half.
    ##   The tightest bound, because a real recreation's halves differ in
    ##   character but not in how much field a team gets to fight over.
    ## - COVER. Wall pixels per half. Loosest bound: cover naturally clusters
    ##   asymmetrically on a real map (Terminal's plane end IS denser than its
    ##   concourse end), and unlike area, more cover is not simply better —
    ##   it is both protection and obstruction.
    ## - WALK TO MIDFIELD. Steps from each pedestal to the contested center.
    ##   This is the one that catches the defect the others cannot see: a
    ##   single traced building edge that walls one spawn off from the middle,
    ##   forcing a lap of the map while the other team strolls in. Note that
    ##   red-spawn-to-blue-pedestal is deliberately NOT measured — BFS is
    ##   undirected and each pedestal sits at its own spawn center, so that
    ##   ratio is 1.0 on every possible layout and proves nothing.
    ##
    ## The bounds are the loosest that still fail an unfair map, not the
    ## tightest the current six happen to pass: they are stated per-quantity
    ## from what the quantity means, and a map landing just inside one is
    ## reported so the slack is visible rather than silently consumed.
    const
      AreaTol = 0.80
      CoverTol = 0.55
      MidTol = 0.70
    for name in Mw2Rotation:
      let sim = initCtfForMap(name)
      var occupiable = newSeq[bool](MapWidth * MapHeight)
      for y in 0 ..< MapHeight:
        for x in 0 ..< MapWidth:
          occupiable[mapIndex(x, y)] = sim.canOccupy(x, y)

      # 1 + 2. Area and cover, per half of the field.
      var areaLeft, areaRight, coverLeft, coverRight: int
      for y in 0 ..< MapHeight:
        for x in 0 ..< MapWidth:
          let left = x < MapWidth div 2
          if occupiable[mapIndex(x, y)]:
            if left: inc areaLeft else: inc areaRight
          if sim.isWall(x, y):
            if left: inc coverLeft else: inc coverRight
      let
        areaRatio = min(areaLeft, areaRight) / max(areaLeft, areaRight)
        coverRatio = min(coverLeft, coverRight) / max(coverLeft, coverRight)

      # 3. Walk to the contested middle, per team. 1px BFS over the same
      #    precomputed occupancy mask the sealed-pocket test uses — a strided
      #    walk would understate a narrow corridor and manufacture a
      #    difference that is not there.
      proc stepsToCenter(sim: SimServer, occupiable: seq[bool],
                         start: MapPoint): int =
        var
          dist = newSeq[int](MapWidth * MapHeight)
          queue = initDeque[(int, int)]()
        for i in 0 ..< dist.len:
          dist[i] = -1
        dist[mapIndex(start.x, start.y)] = 0
        queue.addLast((start.x, start.y))
        while queue.len > 0:
          let (cx, cy) = queue.popFirst()
          if cx == sim.gameMap.center.x and cy == sim.gameMap.center.y:
            return dist[mapIndex(cx, cy)]
          for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            let
              nx = cx + dx
              ny = cy + dy
            if nx < 0 or ny < 0 or nx >= MapWidth or ny >= MapHeight:
              continue
            if dist[mapIndex(nx, ny)] >= 0 or not occupiable[mapIndex(nx, ny)]:
              continue
            dist[mapIndex(nx, ny)] = dist[mapIndex(cx, cy)] + 1
            queue.addLast((nx, ny))
        -1

      let
        redSteps = sim.stepsToCenter(occupiable, sim.gameMap.flagHome(Red))
        blueSteps = sim.stepsToCenter(occupiable, sim.gameMap.flagHome(Blue))
      # A -1 means a pedestal cannot reach the center at all, which is a
      # broken map rather than an unfair one; assert it before the ratio so
      # the failure names the real problem.
      check redSteps > 0
      check blueSteps > 0
      let midRatio = min(redSteps, blueSteps) / max(redSteps, blueSteps)

      if areaRatio < AreaTol or coverRatio < CoverTol or midRatio < MidTol:
        echo "  ", name, " UNFAIR: area ", areaRatio.formatFloat(ffDecimal, 3),
          " cover ", coverRatio.formatFloat(ffDecimal, 3),
          " mid ", midRatio.formatFloat(ffDecimal, 3),
          " (", redSteps, " vs ", blueSteps, " steps)"
      elif areaRatio < AreaTol + 0.04 or coverRatio < CoverTol + 0.05 or
          midRatio < MidTol + 0.05:
        # Near the bound: report so the remaining slack stays visible instead
        # of being silently spent by the next layout change.
        echo "  ", name, " tight: area ",
          areaRatio.formatFloat(ffDecimal, 3), " cover ",
          coverRatio.formatFloat(ffDecimal, 3), " mid ",
          midRatio.formatFloat(ffDecimal, 3)
      check areaRatio >= AreaTol
      check coverRatio >= CoverTol
      check midRatio >= MidTol

  test "the pack layouts are genuinely asymmetric":
    ## Guards the OTHER direction: the fairness test above is satisfied
    ## trivially by an x-mirrored layout, which is exactly what the first pass
    ## shipped and what review rejected. A recreation of a real map must NOT be
    ## its own mirror image, so assert the wall masks actually differ across
    ## the center line by a real margin.
    for name in Mw2Rotation:
      let
        sim = initCtfForMap(name)
        gameMap = sim.gameMap
      # These maps declare their layout verbatim rather than deriving the right
      # half from the left, which is what buys the real geometry.
      check gameMap.fullObstacles.len > 0
      check gameMap.leftObstacles.len == 0
      var differing, considered: int
      for y in 0 ..< MapHeight:
        for x in ArenaBorder ..< MapWidth div 2:
          # Skip the engine-carved regions: they are floor on both sides by
          # fiat, so counting them would dilute the measure toward "mirrored".
          if gameMap.mapProtectedFloorAt(x, y) or
              gameMap.mapProtectedFloorAt(MapWidth - 1 - x, y):
            continue
          inc considered
          if sim.isWall(x, y) != sim.isWall(MapWidth - 1 - x, y):
            inc differing
      let asymmetry = differing / max(considered, 1)
      echo "  ", name, ": ", (asymmetry * 100).formatFloat(ffDecimal, 1),
        "% of comparable cells differ across the center line"
      # A mirrored layout scores 0. Real geometry differs substantially.
      check asymmetry > 0.10

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

  test "declared homes, capture zones, and spawn zones drive the sim":
    ## Terminal declares the full MW2 model: off-edge home points, a capture
    ## RADIUS around the flag stand instead of the legacy edge column, and
    ## real spawn zones. Deterministic checks, no bot behaviour involved.
    let sim = initCtfForMap("terminal")
    # Homes are the declared points, not the derived mid-edge anchors.
    check sim.gameMap.teamHome(Red) == MapPoint(x: 190, y: 396)
    check sim.gameMap.teamHome(Blue) == MapPoint(x: 1046, y: 262)
    check sim.gameMap.flagHome(Red) == sim.gameMap.teamHome(Red)
    # Capture fires AT the flag stand...
    check sim.inCaptureZone(Red, 190 + 40, 396)
    check sim.inCaptureZone(Blue, 1046, 262 + 40)
    # ...and the legacy home-edge column no longer captures anywhere.
    check not sim.inCaptureZone(Red, 30, 60)
    check not sim.inCaptureZone(Red, 30, 596)
    check not sim.inCaptureZone(Blue, MapWidth - 30, 60)
    # Every seat lands inside (or nudged marginally off) its declared zone.
    for team in Team:
      let z = (if team == Red: sim.gameMap.redSpawn
               else: sim.gameMap.blueSpawn)
      for order in 0 ..< 8:
        let seat = sim.spawnPosition(team, order)
        check seat.x >= z.x - 20 and seat.x <= z.x + z.w + 20
        check seat.y >= z.y - 20 and seat.y <= z.y + z.h + 20
        check sim.canOccupy(seat.x, seat.y)

  test "legacy maps keep the derived homes and edge-column capture":
    ## The abstract arena declares nothing and must behave exactly as before.
    let sim = initCtfForMap("arena")
    check sim.gameMap.teamHome(Red) == MapPoint(x: 186, y: 329)
    check sim.inCaptureZone(Red, 30, 60)
    check not sim.inCaptureZone(Red, 400, 329)
