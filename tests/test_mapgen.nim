import
  helpers,
  std/[sequtils, unittest],
  ctf/sim, ctf/map_pool

proc cachedMap(seed: int,
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
    teams = 2): CtfMap =
  ## This module's local name for `helpers.cachedCtfMap`. The memo moved to
  ## helpers so it is shared with the OTHER modules in this shard that sweep
  ## the same pool — `test_endzone_shapes` was rebuilding all 20 maps.
  cachedCtfMap(seed, overrides, teams)

proc obstacleAt(obstacles: seq[ArenaShape], x, y: int): bool =
  ## Raw obstacle-union test (no border, no protected-floor carve). On
  ## 2-TEAM maps this is the only exactly symmetric layer: their carve is
  ## anchored to the div-derived center, which sits half a pixel off the
  ## mirror/rot180 axis on the even-width size classes. rot90 boards carve
  ## against the true axis instead, so there the whole rasterized MASK is
  ## exact — see the 4-team test below, which asserts on that and not on
  ## this.
  for shape in obstacles:
    if inShape(x, y, shape):
      return true
  false

suite "procedural terrain":
  test "same seed generates the same map":
    check generateCtfMap(4242) == generateCtfMap(4242)

  test "every pool seed ships a valid map under its own seed":
    ## Renamed from "validates on its first attempt". `cachedMap` goes through
    ## `generateCtfMap`, so what this has always actually checked is the
    ## SHIPPED map — and first-attempt validity is no longer the curation rule
    ## (`tools/gen_map_pool.nim` curates on the shipped best-of-K map now).
    ##
    ## `genSeed == seed` is the load-bearing half. The old re-roll walked
    ## `seed + attempt`, so a pool entry needing one re-roll silently became a
    ## DIFFERENT seed on a different board size — the first draw off the flat
    ## stream was the size class. That is why the pool used to have to demand
    ## first-attempt validity. It is structural now: every candidate for a
    ## seed is the same board, under the same seed.
    var widths: seq[int]
    for seed in MapPoolSeeds:
      let gameMap = cachedMap(seed)
      check gameMap.genSeed == seed
      check validateGeneratedMap(gameMap) == ""
      widths.add gameMap.width
    ## The curated pool spans every size class the POOL'S OWN MODE can draw.
    ##
    ## That used to be all five, because the size draw was uniform and `teams`
    ## chose only the shell family. It is now the classes whose area suits the
    ## roster the pool is generated at — 2 teams at the shipping 8 per side,
    ## for which `map_rules.legalSizeNames` is {small, standard}. A 16-player
    ## match on a giant board is 6.8x the area that roster wants, and 22.7 s to
    ## first contact at 6 teams x 1 was the reductio that motivated the change.
    ##
    ## Asserted against `legalSizeNames` rather than against a width list, so
    ## this test cannot go stale the way the old literal list did.
    let legal = legalSizeNames(2, fitMapSize(2).unitsPerTeam)
    check legal.len >= 2
    for name in legal:
      check sizeClassOf(name).boardDims(boardRect2).width in widths
    for w in widths:
      check sizeClassOf(MapSizeClass(sizeClassOfWidth(w)).sizeName()).sizeName() in legal

  test "obstacle union is exact under the map's symmetry":
    for seed in [MapPoolSeeds[0], MapPoolSeeds[1], 777]:
      let
        gameMap = cachedMap(seed)
        obstacles = buildArenaObstacles(gameMap)
        w = gameMap.width
        h = gameMap.height
      var x = ArenaBorder
      while x < w - ArenaBorder:
        var y = ArenaBorder
        while y < h - ArenaBorder:
          let (sx, sy) =
            case gameMap.symmetry
            of symMirror: (w - 1 - x, y)
            of symRot180: (w - 1 - x, h - 1 - y)
            of symRot90: (w - 1 - y, x)
            of symQuadMirror: (w - 1 - x, y)
          check obstacleAt(obstacles, x, y) ==
            obstacleAt(obstacles, sx, sy)
          y += 13
        x += 11

  test "4-team maps are exactly rot90-fair and deterministic":
    ## The invariant is on the RASTERIZED WALL MASK, not on the obstacle
    ## union: border, protected-floor carve and obstacles together must map
    ## wall to wall under a quarter turn, (x, y) -> (w-1-y, x). Checking
    ## only the union hid a real fairness bug — the spawn pockets stamped
    ## one upright W x H box at every anchor, so two of the four quadrants
    ## were carved to a different shape than their rotational twins, ~8% of
    ## the board, worth up to 400-pixel blobs of cover that one team had and
    ## its twin did not.
    ##
    ## Seeds are chosen to span the size classes — smallest (816), middle
    ## (1248), and the oversize ceiling (2496) — since the half-pixel rot90
    ## axis of an EVEN side is what the carve has to respect.
    for layout in ["corners", "plus"]:
      for seed in [13, 6, 17]:
        let
          overrides = MapGenOverrides(windows: -1, layout: layout)
          gameMap = cachedMap(seed, overrides, teams = 4)
          again = generateCtfMap(seed, overrides, teams = 4)
          obstacles = buildArenaObstacles(gameMap)
          w = gameMap.width
        check gameMap == again
        check gameMap.symmetry == symRot90
        check w == gameMap.height
        ## The carve alone, at EVERY pixel: it is cheap (no obstacle loop)
        ## and it is the layer that broke, so it gets exhaustive coverage.
        ## Counted rather than `check`ed per pixel — a million-iteration
        ## unittest assertion loop is far slower than the geometry.
        var carveMismatch = 0
        for y in 0 ..< w:
          for x in 0 ..< w:
            if mapProtectedFloorAt(gameMap, x, y) !=
                mapProtectedFloorAt(gameMap, w - 1 - y, x):
              inc carveMismatch
        check carveMismatch == 0
        ## Then the full mask, sampled finer than the thinnest wall feature.
        var wallMismatch = 0
        var x = ArenaBorder
        while x < w - ArenaBorder:
          var y = ArenaBorder
          while y < w - ArenaBorder:
            if mapWallAt(gameMap, obstacles, x, y) !=
                mapWallAt(gameMap, obstacles, w - 1 - y, x):
              inc wallMismatch
            y += 5
          x += 5
        check wallMismatch == 0

  test "4-team capture zones are exact under a quarter turn":
    ## The scoring side of the same promise: a quarter turn carries each
    ## team's endzone onto the next team's, pixel for pixel. The plus arms
    ## used to span the integer center, which is half a pixel off the rot90
    ## axis, so the west mouth landed one pixel off the north mouth.
    for layout in ["corners", "plus"]:
      let
        overrides = MapGenOverrides(windows: -1, layout: layout)
        gameMap = cachedMap(11, overrides, teams = 4)
        w = gameMap.width
      for team in gameMap.teams():
        ## The team one quarter turn further round the orbit.
        var next = team
        for other in gameMap.teams():
          if gameMap.rot90Quarter(other) ==
              (gameMap.rot90Quarter(team) + 1) mod 4:
            next = other
        check next != team
        let
          zone = gameMap.captureZone(team)
          nextZone = gameMap.captureZone(next)
        var mismatch = 0
        var x = 0
        while x < w:
          var y = 0
          while y < w:
            if zone.inCaptureZone(x, y) !=
                nextZone.inCaptureZone(w - 1 - y, x):
              inc mismatch
            y += 3
          x += 3
        check mismatch == 0

  test "4-team homes and pockets are a rot90 orbit":
    ## Every team's anchor is exactly a quarter turn of the previous team's,
    ## and its pocket is that anchor's box rotated with it — the odd
    ## quarters carry the swapped H x W extents. Anchors derived from the
    ## map center instead would sit one pixel off the orbit on an even side.
    for layout in ["corners", "plus"]:
      let
        overrides = MapGenOverrides(windows: -1, layout: layout)
        gameMap = cachedMap(11, overrides, teams = 4)
        w = gameMap.width
      for team in gameMap.teams():
        var
          point = gameMap.teamAnchor(Red)
          half = gameMap.spawnPocketHalf(Red)
        for _ in 0 ..< gameMap.rot90Quarter(team):
          point = point.rot90Point(w)
          half = (w: half.h, h: half.w)
        check gameMap.teamAnchor(team) == point
        check gameMap.spawnPocketHalf(team) == half
      ## The orbit is a genuine 4-cycle: no two teams share a home.
      var homes: seq[MapPoint]
      for team in gameMap.teams():
        homes.add gameMap.teamAnchor(team)
      check homes.deduplicate().len == 4

  test "4-team pickups are exact under a quarter turn":
    ## The pickups have to ride the same orbit as the homes and the zones.
    ## Placed by MIRRORING, Red's shield sat on the left edge at anchor
    ## height and Blue's on the right edge — but the quarter turn sends
    ## Red's to the TOP edge, so Blue's copy sat in the transpose of Red's
    ## surroundings: different cover, different sightlines to the same item.
    for layout in ["corners", "plus"]:
      let
        overrides = MapGenOverrides(windows: -1, layout: layout)
        gameMap = cachedMap(11, overrides, teams = 4)
        w = gameMap.width
        shields = gameMap.shieldSpawnPoints()
        cans = gameMap.plasmaArcSpawnPoints()
      var sets = @[shields, cans]
      sets.add(@(gameMap.grenadeSpawnPoints()))
      for points in sets:
        check points.len == 4
        ## Closed under (x, y) -> (w - 1 - y, x): every point's quarter turn
        ## is another point of the same set.
        for point in points:
          check (w - 1 - point.y, point.x) in points
      ## And each team holds the copy that belongs to ITS quadrant — the
      ## orbit runs Red -> Blue -> Yellow -> Green on corners, so handing the
      ## images out in team order would put two teams' pickups in the wrong
      ## corner entirely.
      for points in [shields, cans]:
        for team in gameMap.teams():
          var red = MapPoint(x: points[ord(Red)].x, y: points[ord(Red)].y)
          for _ in 0 ..< gameMap.rot90Quarter(team):
            red = red.rot90Point(w)
          check points[ord(team)] == (red.x, red.y)
          ## The point is in that team's own endzone, not just anywhere on
          ## its orbit.
          check gameMap.captureZone(team).inCaptureZone(
            points[ord(team)].x, points[ord(team)].y)
      ## Shields and cans are distinct spots, not a doubled-up pile.
      for shield in shields:
        check shield notin cans

  test "2-team pickups follow the map's own symmetry":
    ## The same promise on a 2-team board, where the symmetry is a coin flip
    ## between mirror and rot180. A MIRRORED copy on a rot180 map lands in
    ## the rotation of Red's OTHER pickup, so Blue's shield sat in the
    ## terrain of the cans and vice versa. Compact endzones are 2-team only,
    ## so both endzone shapes are covered here.
    for seed in [MapPoolSeeds[0], MapPoolSeeds[1], 777, 4242]:
      let
        gameMap = cachedMap(seed)
        w = gameMap.width
        h = gameMap.height
      for points in [gameMap.shieldSpawnPoints(),
          gameMap.plasmaArcSpawnPoints()]:
        check points.len == 2
        let image =
          case gameMap.symmetry
          of symMirror: (w - 1 - points[0].x, points[0].y)
          of symRot180: (w - 1 - points[0].x, h - 1 - points[0].y)
          of symRot90: (w - 1 - points[0].y, points[0].x)
          of symQuadMirror: (w - 1 - points[0].x, points[0].y)
        check points[1] == image
        ## Each team still keeps its own pickups on its own side.
        check points[0].x < gameMap.center.x
        check points[1].x > gameMap.center.x

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
    check gameMap.width == 1606
    check gameMap.symmetry == symRot180

  test "oversize size locks produce the doubled ceiling":
    ## "giant" doubles the old "large" scale (1.3 -> 2.6): the widest
    ## 2-team board grows from 1606x857 to 3211x1713; "huge" sits between.
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "huge"}""")
    var gameMap = resolveCtfMapMetadata(config)
    check gameMap.width == 2223
    check gameMap.height == 1186
    config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "giant"}""")
    gameMap = resolveCtfMapMetadata(config)
    check gameMap.width == 3211
    check gameMap.height == 1713
    ## The gun range is fixed (GV34): the config still follows the map def,
    ## but the def no longer scales it with the field.
    check config.gunRange == gameMap.gunRange
    check config.gunRange == GunRange

  test "a size class never rejects its own column draw":
    ## The mapColumns ceiling used to be a flat 24 that predated the oversize
    ## classes, so colossal (5.2x) drew past its own bound and RAISED instead of
    ## generating: 32 of 40 two-team seeds failed. The 4-team draw tops out at
    ## cols(4) = 21, which is why record_colossal_demo.sh never hit it.
    ##
    ## Drawing is what regresses here, so this uses generateMapAttempt rather
    ## than a validated generate — the bound is checked before any validator
    ## runs, and validating eight 22-megapixel boards would cost ~100s for no
    ## extra signal. Eight seeds is ample: the old bug rejected ~80% of draws,
    ## so the chance of all eight slipping past a regression is ~1e-6.
    const ColossalOverrides = MapGenOverrides(
      size: "colossal", windows: -1, pits: -1, pitDensity: -1)
    for seed in 1001 .. 1008:
      let gameMap = generateMapAttempt(seed, ColossalOverrides)
      check gameMap.width == 6422
      check gameMap.height == 3427
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
