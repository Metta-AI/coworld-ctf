import
  helpers,
  std/[sequtils, tables, unittest],
  ctf/[global, sim], ctf/map_pool

var mapCache = initTable[string, CtfMap]()

proc cachedMap(seed: int,
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
    teams = 2): CtfMap =
  ## generateCtfMap memoized per (seed, overrides, teams): generation is
  ## deterministic (the "same seed" test pins that on every run), so the
  ## tests that assert different properties of the SAME map share one build.
  ## Determinism checks keep calling generateCtfMap directly — a cache hit
  ## would make them vacuous.
  let key = $seed & "|" & $teams & "|" & $overrides
  if key notin mapCache:
    mapCache[key] = generateCtfMap(seed, overrides, teams)
  mapCache[key]

proc obstacleAt(obstacles: seq[ArenaShape], x, y: int): bool =
  ## Raw obstacle-union test (no hull, no protected-floor carve). This is the
  ## layer that is exactly symmetric on a 2-TEAM board: the carve is anchored
  ## to the div-derived center, which sits half a pixel off the mirror/rot180
  ## axis on the even-width size classes, so the rasterized MASK is not. The
  ## HULL is symmetric under all of D6 by construction and is swept separately
  ## in test_hex_arena.nim.
  for shape in obstacles:
    if inShape(x, y, shape):
      return true
  false

suite "procedural terrain":
  test "same seed generates the same map":
    check generateCtfMap(4242) == generateCtfMap(4242)

  test "every pool seed validates on its first attempt":
    var widths: seq[int]
    for seed in MapPoolSeeds:
      let gameMap = cachedMap(seed)
      check gameMap.genSeed == seed
      check validateGeneratedMap(gameMap) == ""
      ## The bounding box is a hexagon's, not a rectangle's: portrait, and
      ## within a pixel of the sqrt(3)/2 aspect on every class.
      check gameMap.height > gameMap.width
      check gameMap.mapBoard().aspectOk()
      widths.add gameMap.width
    ## The curated pool spans the size classes, including the two oversize
    ## ones (huge 1744, giant 2519).
    for cls in [hxSmall, hxStandard, hxLarge, hxHuge, hxGiant]:
      check HexSizes[cls].width in widths

  test "obstacle union is exact under the map's symmetry":
    ## The map's OWN symmetry, resolved through `teamOp` — not a hard-coded
    ## mirror. A 2-team board's group is order 2 and its non-identity element
    ## is either the vertical mirror or the half turn; asserting the wrong one
    ## is the bug `teamImagePoint` exists to prevent.
    for seed in [MapPoolSeeds[0], MapPoolSeeds[1], 777]:
      let
        gameMap = cachedMap(seed)
        obstacles = buildArenaObstacles(gameMap)
        op = gameMap.teamOp(Blue)
        w = gameMap.width
        h = gameMap.height
      check op in [hexMir90, hexRot180]
      var x = ArenaBorder
      while x < w - ArenaBorder:
        var y = ArenaBorder
        while y < h - ArenaBorder:
          let image = gameMap.pixelImage(MapPoint(x: x, y: y), op)
          check obstacleAt(obstacles, x, y) ==
            obstacleAt(obstacles, image.x, image.y)
          y += 13
        x += 11

  test "terrain never escapes the hull by more than the wall anchor":
    ## The rectangular board had no unreachable interior, so terrain could be
    ## stamped anywhere in the box. A hexagon throws 25% of its box away, and an
    ## obstacle sprawling out there is invisible cover that costs the generator
    ## a column it thinks it placed.
    ##
    ## But "no pixel outside the hull at all" is stricter than the invariant
    ## that matters, and would fail on purpose-built geometry: the `colStubs`
    ## family deliberately overshoots its column band — `band.lo - ArenaBorder -
    ## 30`, `band.hi + ArenaBorder + 30` — so the boundary carves the stub flush
    ## against a SLANTED wall with no sliver of floor between them. On the
    ## rectangular board the same trick anchored a stub to a straight border.
    ## What has to hold is that the overshoot is BOUNDED, and that nothing out
    ## there is ever floor. (`tests/test_hex_arena.nim` asserts the same pair on
    ## the hand-authored arena.)
    const MaxOvershoot = ArenaBorder + 60
    for seed in [MapPoolSeeds[0], MapPoolSeeds[7], 777]:
      let
        gameMap = cachedMap(seed)
        obstacles = buildArenaObstacles(gameMap)
        board = gameMap.mapBoard()
      var
        sprawl = 0
        outsideNotWall = 0
        outside = 0
      for shape in obstacles:
        let b = shape.shapeBounds()
        var x = b.x0
        while x <= b.x1:
          var y = b.y0
          while y <= b.y1:
            if inShape(x, y, shape) and not board.insideHex(x, y):
              inc outside
              if board.hexEdgeDist(x, y) < -float(MaxOvershoot):
                inc sprawl
              if not mapWallAt(gameMap, obstacles, x, y):
                inc outsideNotWall
            y += 3
          x += 3
      check sprawl == 0
      check outsideNotWall == 0

  test "generating any team count but 2 is refused until Stage 2b":
    ## 3/4/6-team hex boards need their orbits walked in CUBE space and
    ## rasterized once (sin 60 is irrational, so a pixel rotation would round
    ## and hand one team different cover). The generator says so rather than
    ## shipping a rounded orbit — the same discipline the old validator
    ## applied to rot90 on non-square boards.
    const Plain = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
    for teams in [1, 3, 4, 6]:
      expect CtfError:
        discard generateMapAttempt(11, Plain, teams)
    ## And the symmetries that only make sense with more teams are refused by
    ## name, not silently downgraded to a 2-team group.
    for symmetry in ["rot120", "rot60", "klein4"]:
      expect CtfError:
        discard generateMapAttempt(
          11, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1,
                              symmetry: symmetry))
    expect CtfError:
      discard generateMapAttempt(
        11, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1,
                            layout: "corners"))

  test "2-team pickups follow the map's own symmetry":
    ## A MIRRORED copy on a rot180 map lands in the rotation of Red's OTHER
    ## pickup, so Blue's shield sat in the terrain of the cans and vice versa.
    for seed in [MapPoolSeeds[0], MapPoolSeeds[1], 777, 4242]:
      let gameMap = cachedMap(seed)
      for points in [gameMap.shieldSpawnPoints(),
          gameMap.plasmaArcSpawnPoints()]:
        check points.len == 2
        let image = gameMap.teamImagePoint(
          MapPoint(x: points[0].x, y: points[0].y), Blue)
        check points[1] == (image.x, image.y)
        ## Each team still keeps its own pickups on its own side.
        check points[0].x < gameMap.center.x
        check points[1].x > gameMap.center.x

  test "grenades spawn on four vertices of the hexagon":
    ## The old four points sat at the four CORNERS OF THE BOUNDING BOX, which
    ## on a hexagon are permanent void: unreachable, and never corrected,
    ## because grenades are the one pickup family `placeWalkablePickups` does
    ## not nudge. Four VERTEX pockets replace them — the four off-axis ones, so
    ## the set is closed under the mirror AND the half turn, which is the same
    ## exact fairness every other pickup family gets from `teamImagePoint`.
    for seed in [MapPoolSeeds[0], MapPoolSeeds[4], 777]:
      let
        gameMap = cachedMap(seed)
        board = gameMap.mapBoard()
        w = gameMap.width
        h = gameMap.height
        points = gameMap.grenadeSpawnPoints()
      check points.len == 4
      for point in points:
        check board.insideHex(point.x, point.y)
        check (w - 1 - point.x, point.y) in points
        check (point.x, h - 1 - point.y) in points
      ## Off the two symmetry axes, so the four are genuinely distinct spots
      ## rather than a doubled-up pair on a vertex the mirror fixes.
      for point in points:
        check 2 * point.x != w - 1
        check 2 * point.y != h - 1

  test "map spec JSON round-trips the exact map":
    let gameMap = cachedMap(MapPoolSeeds[2])
    check mapFromSpecJson(mapSpecJson(gameMap)) == gameMap

  test "pool config pins the expanded spec and follows its gun range":
    var config = defaultGameConfig()
    config.update("""{"mapPath": "pool", "mapPoolIndex": 3}""")
    check config.mapSpec.len > 0
    let gameMap = resolveCtfMapMetadata(config)
    check gameMap.genSeed == MapPoolSeeds[3]
    check config.gunRange == gameMap.gunRange
    ## The replay config round-trip rebuilds the identical map.
    var replayConfig = defaultGameConfig()
    replayConfig.update(config.configJson())
    check resolveCtfMapMetadata(replayConfig) == gameMap

  test "generator honors parameter locks":
    var config = defaultGameConfig()
    config.update("""{
      "mapPath": "gen", "mapSeed": 99, "mapSize": "large",
      "mapSymmetry": "rot180", "mapCenterFeature": "ring"
    }""")
    let gameMap = resolveCtfMapMetadata(config)
    check (gameMap.width, gameMap.height) == HexSizes[hxLarge]
    check gameMap.symmetry == symRot180

  test "oversize size locks produce the doubled ceiling":
    ## "giant" doubles the "large" scale (1.3 -> 2.6): the biggest 2-team board
    ## grows from 1260x1455 to 2519x2909; "huge" sits between. Every class
    ## holds the same PLAYFIELD AREA as the rectangular class it replaced, so a
    ## size name still means the same amount of field.
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "huge"}""")
    var gameMap = resolveCtfMapMetadata(config)
    check (gameMap.width, gameMap.height) == HexSizes[hxHuge]
    config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "giant"}""")
    gameMap = resolveCtfMapMetadata(config)
    check (gameMap.width, gameMap.height) == HexSizes[hxGiant]
    ## The gun range is fixed (GV34): the config still follows the map def,
    ## but the def no longer scales it with the field.
    check config.gunRange == gameMap.gunRange
    check config.gunRange == GunRange

  test "a size class never rejects its own column draw":
    ## The mapColumns ceiling used to be a flat 24 that predated the oversize
    ## classes, so colossal (5.2x) drew past its own bound and RAISED instead of
    ## generating: 32 of 40 two-team seeds failed.
    ##
    ## Drawing is what regresses here, so this uses generateMapAttempt rather
    ## than a validated generate — the bound is checked before any validator
    ## runs, and validating 29-megapixel boards would cost far more for no
    ## extra signal. Eight seeds is ample: the old bug rejected ~80% of draws,
    ## so the chance of all eight slipping past a regression is ~1e-6.
    const ColossalOverrides = MapGenOverrides(
      size: "colossal", windows: -1, pits: -1, pitDensity: -1)
    for seed in 1001 .. 1008:
      let gameMap = generateMapAttempt(seed, ColossalOverrides)
      check (gameMap.width, gameMap.height) == HexSizes[hxColossal]
    ## ...while the classes that scale by 1 keep exactly the historical bound.
    var narrow = defaultGameConfig()
    expect CtfError:
      narrow.update(
        """{"mapPath": "gen", "mapSeed": 7, "mapSize": "standard",
            "mapColumns": 25}""")
      discard resolveCtfMapMetadata(narrow)

  test "med kits spawn on the generated map's active pair":
    var config = defaultGameConfig()
    config.update("""{"mapPath": "pool", "mapPoolIndex": 0, "minPlayers": 1}""")
    let sim = initCtfForTest(config)
    check sim.gameMap.medKitCandidates.len == 4
    check sim.gameMap.medKitSpawns.len == 2
    for i in 0 ..< 2:
      let expected = sim.gameMap.medKitSpawns[i]
      check abs(sim.medKitSpawns[i].x - expected.x) <= 20
      check abs(sim.medKitSpawns[i].y - expected.y) <= 20
      check sim.medKitSpawns[i].present

## A pool map is installed as the process map above, and pool index 0 is the
## SAME 969 x 1119 standard board as the default arena — so the board render
## caches cannot self-heal on a size mismatch. Put the arena back explicitly.
installDefaultArena()
invalidateBoardMapCaches()
