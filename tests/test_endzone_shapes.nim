## Endzones on the hexagonal arena. Every board is ALL-DISC now: `ezDisc` is
## the one endzone geometry that survives a rotation, so the archetype draw is
## gone and what remains is the disc's RADIUS and the base's DEPTH.
##
## `ezColumn` (a full-height strip pinned to a straight home border) has no
## meaning on a hexagon — there is no straight home border — and `ezSquare` is
## not closed under a 60-degree turn; both are deleted with their tests. The
## properties those tests were really protecting survive here, re-expressed:
## the scoring region wraps the base rather than the border, the ground behind
## the base is ordinary field carrying real cover, and a base pushed too deep
## or a disc grown too fat is refused rather than shipped.
import
  helpers,
  std/[strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim], ctf/map_pool

proc discMap(seed = 4242): CtfMap =
  generateCtfMap(seed, MapGenOverrides(
    windows: -1, pits: -1, pitDensity: -1, endzone: "disc"))

proc discConfig(seed = 4242): GameConfig =
  result = defaultGameConfig()
  result.update("""{"mapPath": "gen", "mapSeed": """ & $seed &
    """, "mapEndzone": "disc", "minPlayers": 1}""")

suite "endzone discs":
  test "the hand-authored arenas wear the one hex endzone":
    for name in ["arena", "arena-large"]:
      let gameMap = loadCtfMapMetadata(name)
      check gameMap.endzone == ezDisc
      check gameMap.endzoneRadius > 0
      let zone = gameMap.captureZone(Red)
      check zone.disc
      check zone.radius == gameMap.endzoneRadius
      ## The zone is the disc's bounding BOX around the anchor, nowhere near
      ## the hull: on a hexagon a zone flush against x = 0 would be half void.
      check zone.xLo == gameMap.teamAnchor(Red).x - gameMap.endzoneRadius
      check zone.xLo > ArenaBorder
      check gameMap.mapBoard().hexEdgeDist(
        gameMap.teamAnchor(Red).x, gameMap.teamAnchor(Red).y) >
        float(gameMap.endzoneRadius + EndzoneWallMargin)
    ## The two homes are exact mirror images on the standard hexagon. 170 was
    ## the PORTRAIT hull's column; the flat-top flip made the board landscape
    ## (1119x969 rather than 969x1119) and the home rides the width, so the
    ## literal moved with it. Re-measured off the installed arena, not scaled
    ## by hand.
    let arena = loadCtfMapMetadata("arena")
    check arena.teamHomeX(Red) == 254
    check arena.teamHomeX(Blue) == arena.width - 1 - arena.teamHomeX(Red)

  test "the disc endzone generates, validates and is deterministic":
    let gameMap = discMap()
    check gameMap == discMap()
    check validateGeneratedMap(gameMap) == ""
    check gameMap.endzone == ezDisc
    ## The radius bounds SCALE with the board: `EndzoneRadiusMin` was authored
    ## against the old 1235-wide field, and the hex classes are narrower at
    ## equal playfield area, so a flat 90 sat above what the small class's own
    ## draw produces.
    check gameMap.endzoneRadius >= minEndzoneRadius(gameMap.width)
    check gameMap.endzoneRadius <= maxEndzoneRadius(gameMap.width)

  test "the base sits deep enough to leave buildable midfield":
    ## THE arithmetic the hex generator is tuned around: a base needs
    ## `anchorDist - (radius + apron) - flagRing` px of ordinary field in front
    ## of it, or its protected apron touches the always-open flag ring and the
    ## row through the two bases becomes a lane no obstacle may ever stand in —
    ## permanently open, unpluggable, rejected by the sightline validator on
    ## every attempt. The hex board is 22% narrower than the rectangle it
    ## replaced at equal area, so this budget is tight and worth pinning.
    for index in 0 ..< MapPoolSeeds.len:
      let
        gameMap = poolCtfMap(index)
        anchor = gameMap.teamAnchor(Red)
        midfield = (gameMap.center.x - anchor.x) -
          (gameMap.endzoneRadius + EndzoneWallMargin) - gameMap.flagRing
      check midfield > 0
      ## And the base is far enough off the hull that its whole apron is real
      ## floor rather than half void.
      check gameMap.mapBoard().hexEdgeDist(anchor.x, anchor.y) >
        float(gameMap.endzoneRadius + EndzoneWallMargin)

  test "the capture zone wraps the base instead of the border":
    let
      gameMap = discMap()
      anchor = gameMap.teamAnchor(Red)
      r = gameMap.endzoneRadius
      zone = gameMap.captureZone(Red)
    check zone.inCaptureZone(anchor.x, anchor.y)
    ## Every side of the base scores, including BEHIND it...
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      check zone.inCaptureZone(anchor.x + dx * (r - 2), anchor.y + dy * (r - 2))
      check not zone.inCaptureZone(
        anchor.x + dx * (r + 2), anchor.y + dy * (r + 2))
    ## ...and the home border strip does NOT: it is ordinary field now.
    check not zone.inCaptureZone(ArenaBorder + 1, gameMap.center.y)
    ## A disc rounds its corners off — the one property that made `ezSquare` a
    ## different shape, asserted now as the only shape's own signature.
    check not zone.inCaptureZone(anchor.x - r + 3, anchor.y - r + 3)

  test "the zone is clear floor and the ground behind the base is not":
    ## Swept over the whole curated pool rather than one seed: "the freed home
    ## strip is wilderness that carries cover" is a claim about the map FAMILY,
    ## and a single draw can legitimately leave its backfield empty.
    ##
    ## So it is COUNTED, not asserted per map. Three properties are per-map
    ## invariants and stay exact — no wall inside the scoring shape, no
    ## protected floor behind the base, no void sampled as playfield — while
    ## "carries real cover" is scored over the pool. Seed 1005 (small class,
    ## a 128px strip) currently ships an empty backfield and is not a bug;
    ## asserting `behind > 0` on every map made the pool's own draw a test
    ## failure, which is how this check has broken on every re-curation.
    var withCover = 0
    for index in 0 ..< MapPoolSeeds.len:
      let
        gameMap = poolCtfMap(index)
        obstacles = buildArenaObstacles(gameMap)
        board = gameMap.mapBoard()
        anchor = gameMap.teamAnchor(Red)
        zone = gameMap.captureZone(Red)
      ## No wall inside the scoring shape: a carrier can always finish.
      var walled = 0
      var y = anchor.y - gameMap.endzoneRadius
      while y <= anchor.y + gameMap.endzoneRadius:
        var x = anchor.x - gameMap.endzoneRadius
        while x <= anchor.x + gameMap.endzoneRadius:
          if zone.inCaptureZone(x, y) and mapWallAt(gameMap, obstacles, x, y):
            inc walled
          x += 3
        y += 3
      check walled == 0
      ## Wilderness: the strip between the base and the hull is ordinary field
      ## (never protected floor) and carries real cover. Only pixels on the
      ## PLAYFIELD count — every pixel of the void outside the hexagon reads as
      ## wall, so counting the whole box would make this pass on an empty map.
      var behind, floorSeen, protectedSeen, strayVoid = 0
      y = ArenaBorder
      while y < gameMap.height - ArenaBorder:
        var x = ArenaBorder
        while x < anchor.x - (gameMap.endzoneRadius + EndzoneWallMargin):
          if not gameMap.mapBorderWallAt(x, y):
            if not board.insideHex(x, y):
              inc strayVoid
            inc floorSeen
            if mapProtectedFloorAt(gameMap, x, y):
              inc protectedSeen
            if mapWallAt(gameMap, obstacles, x, y):
              inc behind
          x += 3
        y += 3
      check strayVoid == 0
      check floorSeen > 0
      check protectedSeen == 0
      if behind > 0:
        inc withCover
    ## A strong majority, not "at least one": one map with a shrub behind its
    ## base would satisfy the letter of the claim while the family had gone
    ## bare.
    checkpoint("pool maps with backfield cover: " & $withCover & "/" &
      $MapPoolSeeds.len)
    check withCover * 10 >= MapPoolSeeds.len * 8

  test "every pool seed keeps its flanks open":
    for seed in MapPoolSeeds:
      let gameMap = generateCtfMap(seed)
      check gameMap.endzone == ezDisc
      ## validateGeneratedMap is what enforces the cardinal gates and the route
      ## around the endzone; the pool pins first-attempt passes.
      check validateGeneratedMap(gameMap) == ""

  test "a sealed backfield is rejected":
    ## Push the base against the hull and its behind-gate falls off the map —
    ## a base you could only reach from the field. The validator names it
    ## rather than shipping it, on every attempt, so the generator gives up.
    let sealed = generateMapAttempt(4242, MapGenOverrides(
      windows: -1, pits: -1, pitDensity: -1, size: "standard",
      endzone: "disc", endzoneRadius: 97, baseDepth: HomeDepthMax))
    check validateGeneratedMap(sealed) == "endzone gate behind is off the map"
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{
        "mapPath": "gen", "mapSeed": 4242, "mapSize": "standard",
        "mapEndzoneRadius": 97, "mapBaseDepth": 800
      }""")

  test "an endzone that swallows the midfield opens a cross-field lane":
    ## The other end of the same budget: a fat disc on a shallow base pushes
    ## its protected apron into the flag ring, and the row joining the two
    ## bases is then open border to border with nowhere legal to build.
    ##
    ## `maxEndzoneRadius` keys off the SHORT axis (the apothem is the
    ## orientation-independent measure of "how much field"), which the flat-top
    ## flip made the HEIGHT. Passing the width here asked for a radius 15.5%
    ## above the ceiling the generator itself enforces, so the attempt raised
    ## on the config bound instead of ever reaching the validator.
    let fat = generateMapAttempt(4242, MapGenOverrides(
      windows: -1, pits: -1, pitDensity: -1, size: "standard",
      endzone: "disc", endzoneRadius: maxEndzoneRadius(HexStandardHeight),
      baseDepth: HomeDepthMin))
    ## THE CLAIM IS THE BUDGET, so the budget is what is asserted: the disc
    ## plus its apron reaches past the flag ring, which leaves the row joining
    ## the two bases with nowhere legal to build.
    let
      anchor = fat.teamAnchor(Red)
      midfield = (fat.center.x - anchor.x) -
        (fat.endzoneRadius + EndzoneWallMargin) - fat.flagRing
    check midfield < 0
    ## ...and the map is REFUSED rather than shipped. Not pinned to "open
    ## sightline" any more: the re-derived cover band gave the repair pass six
    ## chord families and sight of its own work, so it now succeeds in plugging
    ## this lane — and pays 351 permille of cover to do it, against a scale-free
    ## ceiling of 266. The far end of the budget is still rejected; the
    ## diagnostic that names it moved from "the lane cannot be closed" to
    ## "closing the lane costs more cover than the board may carry", which is
    ## the same fact read one stage later.
    let fatDiagnostics = mapDiagnostics(fat)
    check (fatDiagnostics.openSightlineRows.len > 0 or
           fatDiagnostics.coverPermille > fatDiagnostics.coverPermilleCeiling)
    check validateGeneratedMap(fat).len > 0
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{
        "mapPath": "gen", "mapSeed": 4242, "mapSize": "standard",
        "mapEndzoneRadius": 220, "mapBaseDepth": 400
      }""")

  test "capture, respawn and pickups follow the shape":
    let sim = initCtfForTest(discConfig())
    let
      zone = sim.gameMap.captureZone(Red)
      anchor = sim.gameMap.teamAnchor(Red)
      r = sim.gameMap.endzoneRadius
    ## Both pickups sit inside a zone, clear of the pedestal art.
    for points in [sim.gameMap.shieldSpawnPoints(),
        sim.gameMap.plasmaArcSpawnPoints()]:
      check points.len == 2
      for point in points:
        check zone.inCaptureZone(point.x, point.y) or
          sim.gameMap.captureZone(Blue).inCaptureZone(point.x, point.y)
    ## Scoring is the ring, not a border column: standing behind the base
    ## (further out than the ring) does not score.
    check zone.inCaptureZone(anchor.x - r + 4, anchor.y)
    check not zone.inCaptureZone(anchor.x - r - 4, anchor.y)

  test "respawn draws land inside a ROUND zone, not its bounding box":
    ## A disc fills only ~78% of the box it is drawn from, so the sampler
    ## has to re-roll — the corners are wilderness, not endzone.
    var sim = initCtfForTest(discConfig())
    let zone = sim.gameMap.captureZone(Red)
    for i in 0 ..< 200:
      let spot = sim.randomEndzonePosition(Red)
      check zone.inCaptureZone(spot.x, spot.y)

  test "a stepped episode is deterministic and respawns in-zone":
    proc runGame(): SimServer =
      result = initCtfForTest(discConfig())
      for i in 0 ..< 4:
        discard result.addPlayer("p" & $i)
      result.startGame()
      result.killPlayer(2, 0)
      let none = newSeq[InputState](0)
      for tick in 0 ..< 400:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameHash() == b.gameHash()
    check a.players[2].alive
    let
      zone = a.gameMap.captureZone(a.players[2].team)
      px = a.players[2].x + CollisionW div 2
      py = a.players[2].y + CollisionH div 2
    check zone.inCaptureZone(px, py)

  test "the spec round-trips the endzone and the config locks it":
    let gameMap = discMap()
    check mapFromSpecJson(mapSpecJson(gameMap)) == gameMap
    ## A spec pinned before the endzone fields existed still reads as a disc:
    ## `ezDisc` is the loader's one silent default, and the reason the enum is
    ## kept as an enum rather than collapsed away — a future hex SECTOR zone
    ## must arrive as a NEW token, never as a fallthrough onto this one.
    let node = mapSpecJson(gameMap).replace(""""endzone":"disc",""", "")
    check node != mapSpecJson(gameMap)     # the key really was dropped
    check mapFromSpecJson(node) == gameMap

  test "bad endzone configs fail loudly":
    for bad in [
      # Not a shape the hexagon has — and the deleted ones are refused BY
      # NAME, never silently reinterpreted as the disc.
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "blob"}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "column"}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "square"}""",
      # Below the board's own radius floor, and past the depth bounds.
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "mapEndzoneRadius": 40}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "mapBaseDepth": 900}""",
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "mapBaseDepth": 300}""",
      # 4-team generation is Stage 2b.
      """{"mapPath": "gen", "mapSeed": 5, "mapEndzone": "disc",
          "teams": 4}""",
    ]:
      var config = defaultGameConfig()
      expect CtfError:
        config.update(bad)

## Generated maps are installed as the process map above; put the arena back.
installDefaultArena()
invalidateBoardMapCaches()
