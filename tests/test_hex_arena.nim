## THE SAFETY NET for the hexagonal arena.
##
## `arena.nim` warns at `isProtectedFloor` that the wall rule is written FOUR
## times — `mapWallAt` (uninstalled, integer), `isArenaWall` (installed,
## integer), `mapObstacleWallAtF` (uninstalled, float) and `mapShapeWallAtF`
## (one shape, float) — and that they must stay pixel-identical, with the same
## warning on the three copies of the protected-floor carve. On the rectangular
## board each of them spelled out its own four-way border comparison; the
## hexagon replaced all of that with ONE boundary predicate in `hex.nim`, and
## this module is the regression guard that keeps them from drifting apart
## again. It sweeps WHOLE BOARDS pixel by pixel, on a real generated hex map and
## on the hand-authored arena.
##
## What each predicate promises is not the same thing, and this asserts exactly
## that and no more:
##   * the two INTEGER predicates are total — the border ring and the six void
##     corners of the bounding box are wall, everywhere, always;
##   * the two FLOAT predicates deliberately EXCLUDE the border ring (renderers
##     draw it as separate slabs) but DO include the out-of-hex void, because
##     the void is not a ring, it is the shape of the board.
## So the four are compared where all four claim to answer — off the ring — and
## the ring itself is asserted only against what the integer pair promises.
import
  helpers,
  std/[strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc sweepStep(gameMap: CtfMap): int =
  ## 1 on a standard-sized board, so the sweep really is every pixel; coarser
  ## on the oversize classes, which no test here uses today.
  if gameMap.width * gameMap.height <= 1_500_000: 1 else: 3

proc installedGame(configJson: string): SimServer =
  var config = defaultGameConfig()
  if configJson.len > 0:
    config.update(configJson)
  initCtfForTest(config)

suite "hex arena: the four wall predicates agree pixel for pixel":
  proc sweep(sim: SimServer, name: string) =
    let
      gameMap = sim.gameMap
      obstacles = buildArenaObstacles(gameMap)
      board = gameMap.mapBoard()
      cx = gameMap.center.x
      cy = gameMap.center.y
      step = gameMap.sweepStep()
    var
      pixels = 0
      ringPixels = 0
      voidPixels = 0
      floorPixels = 0
      ## Disagreements, counted rather than `check`ed per pixel: a million
      ## unittest assertions cost far more than the geometry they check.
      wallVsInstalled = 0
      wallVsFloat = 0
      floatVsPerShape = 0
      ringNotWall = 0
      voidNotWall = 0
      voidNotFloatWall = 0
      carveVsInstalled = 0
      carveVsFloat = 0
      firstMismatch = ""
    proc note(what: string, x, y: int) =
      if firstMismatch.len == 0:
        firstMismatch = name & ": " & what & " at " & $(x, y)
    var y = 0
    while y < gameMap.height:
      var x = 0
      while x < gameMap.width:
        inc pixels
        let
          fx = float(x)
          fy = float(y)
          dist = board.hexEdgeDist(x, y)
          isVoid = dist <= 0.0
          isRing = not isVoid and dist < float(ArenaBorder)
          intWall = mapWallAt(gameMap, obstacles, x, y)
          installedWall = isArenaWall(x, y, cx, cy)
        if intWall != installedWall:
          inc wallVsInstalled
          note("mapWallAt != isArenaWall", x, y)
        ## The protected-floor carve, in all three of its copies.
        let
          carveMap = mapProtectedFloorAt(gameMap, x, y)
          carveInstalled = isProtectedFloor(x, y, cx, cy)
          carveFloat = mapProtectedFloorAtF(gameMap, fx, fy, cx, cy)
        if carveMap != carveInstalled:
          inc carveVsInstalled
          note("mapProtectedFloorAt != isProtectedFloor", x, y)
        if carveMap != carveFloat:
          inc carveVsFloat
          note("mapProtectedFloorAt != mapProtectedFloorAtF", x, y)
        if isVoid:
          inc voidPixels
          ## The void is the SHAPE of the board, not a ring: every predicate,
          ## float ones included, calls it wall.
          if not intWall:
            inc voidNotWall
            note("void is not wall", x, y)
          if not mapObstacleWallAtF(gameMap, obstacles, fx, fy, cx, cy):
            inc voidNotFloatWall
            note("void is not float wall", x, y)
        elif isRing:
          inc ringPixels
          ## The ring is wall to the integer pair and EXCLUDED from the float
          ## pair, so only the integer promise is assertable here.
          if not intWall:
            inc ringNotWall
            note("border ring is not wall", x, y)
        else:
          inc floorPixels
          let floatWall = mapObstacleWallAtF(gameMap, obstacles, fx, fy, cx, cy)
          if floatWall != intWall:
            inc wallVsFloat
            note("mapWallAt != mapObstacleWallAtF", x, y)
          ## ...and the whole-map float test is exactly the OR of the
          ## per-shape float test, carve and hull included.
          var anyShape = false
          for shape in obstacles:
            if mapShapeWallAtF(gameMap, fx, fy, shape, cx, cy):
              anyShape = true
              break
          if anyShape != floatWall:
            inc floatVsPerShape
            note("mapObstacleWallAtF != OR mapShapeWallAtF", x, y)
        x += step
      y += step
    ## The sweep saw a real board with all three regions on it.
    check pixels > 100_000
    check voidPixels > 0
    check ringPixels > 0
    check floorPixels > 0
    ## A hexagon throws away 25% of its bounding box; allowing for the ring,
    ## somewhere near a quarter of what we swept must be void.
    check voidPixels * 100 > pixels * 20
    check voidPixels * 100 < pixels * 30
    checkpoint(name & " first mismatch: " & firstMismatch)
    check wallVsInstalled == 0
    check wallVsFloat == 0
    check floatVsPerShape == 0
    check ringNotWall == 0
    check voidNotWall == 0
    check voidNotFloatWall == 0
    check carveVsInstalled == 0
    check carveVsFloat == 0

  test "on a generated hex map":
    let sim = installedGame("""{"mapPath": "gen", "mapSeed": 1}""")
    check sim.gameMap.genSeed == 1
    sim.sweep("gen:1")

  test "on the hand-authored arena":
    let sim = installedGame("")
    check sim.gameMap.name == "arena"
    check (sim.gameMap.width, sim.gameMap.height) ==
      (HexStandardWidth, HexStandardHeight)
    sim.sweep("arena")

suite "hex arena: terrain lives on the hexagon":
  const MaxOvershoot = ArenaBorder + 60
    ## The generator's column stubs deliberately overshoot the end of their
    ## band — `band.lo - ArenaBorder - 30` and `band.hi + ArenaBorder + 30` —
    ## so the boundary carves the stub flush against a SLANTED wall and leaves
    ## no sliver of floor between them. On the rectangular board the same trick
    ## anchored a stub to a straight border. `ArenaBorder + 60` is that worst
    ## case with room to spare; a shape sprawling further than this into the
    ## void is a real bug, not the anchoring trick.

  test "terrain never escapes the hull by more than the wall anchor":
    ## The rectangular board had no unreachable interior, so terrain could be
    ## stamped anywhere in the box. A hexagon throws 25% of its box away, and
    ## an obstacle sprawling out there is cover nobody can use — the generator
    ## counts a column it did not really place. Two things have to hold, and
    ## "no pixel outside the hull at all" is stricter than either:
    ##   * every outside pixel is within the anchoring overshoot of the hull;
    ##   * every outside pixel reads as WALL to both integer predicates, so
    ##     nothing out there is standable, walkable or shootable. That is the
    ##     property a policy could actually observe.
    for spec in ["arena", "arena-large", "gen:1", "gen:777"]:
      let
        gameMap = loadCtfMapMetadata(spec)
        obstacles = buildArenaObstacles(gameMap)
        board = gameMap.mapBoard()
      var
        inside = 0
        outside = 0
        sprawl = 0
        worst = 0.0
        notWall = 0
        sample = ""
      for shape in obstacles:
        let b = shape.shapeBounds()
        for y in b.y0 .. b.y1:
          for x in b.x0 .. b.x1:
            if not inShape(x, y, shape):
              continue
            if board.insideHex(x, y):
              inc inside
              continue
            inc outside
            let depth = -board.hexEdgeDist(x, y)
            if depth > worst:
              worst = depth
            if depth > float(MaxOvershoot):
              inc sprawl
              if sample.len == 0:
                sample = $(x, y) & " is " & $depth & "px into the void"
            ## Uninstalled and installed alike: the void is wall.
            if not mapWallAt(gameMap, obstacles, x, y):
              inc notWall
      checkpoint(spec & " obstacle pixels inside/outside: " & $inside & "/" &
        $outside & ", deepest overshoot " & $worst & "px" &
        (if sample.len > 0: " (" & sample & ")" else: ""))
      check inside > 0
      check sprawl == 0
      check notWall == 0

  test "the installed board agrees that the overshoot is wall":
    ## The same promise through `isArenaWall`, which needs the map INSTALLED
    ## and so cannot ride the loop above.
    let sim = installedGame("""{"mapPath": "gen", "mapSeed": 1}""")
    let
      gameMap = sim.gameMap
      board = gameMap.mapBoard()
      cx = gameMap.center.x
      cy = gameMap.center.y
    var outside, notWall = 0
    for shape in buildArenaObstacles(gameMap):
      let b = shape.shapeBounds()
      for y in b.y0 .. b.y1:
        for x in b.x0 .. b.x1:
          if not inShape(x, y, shape) or board.insideHex(x, y):
            continue
          inc outside
          if not isArenaWall(x, y, cx, cy):
            inc notWall
          if not sim.isWall(x, y):
            inc notWall
    checkpoint("gen:1 overshoot pixels: " & $outside)
    ## No `outside > 0` pin here. Whether a given map USES the border
    ## anchoring at all depends on where its columns fall — seed 1 happens
    ## not to, and pinning the trick as always-exercised makes this test fail
    ## on a generator retune that changed nothing it cares about. What is
    ## asserted is the IMPLICATION: if terrain does escape the hull, the
    ## escape is bounded and every pixel of it reads as wall.
    check notWall == 0

  test "the wall mask is exact under the map's own symmetry":
    ## Team fairness, at the pixel. The image is taken from the map's OWN group
    ## via `teamOp` — a mirror on one board, a half turn on another — because
    ## asserting the wrong one is the very bug `teamImagePoint` exists to stop.
    ##
    ## The ODD-width classes are asserted on the FULL rasterized mask. On an
    ## EVEN-width board the always-open flag ring is centered on `width div 2`,
    ## half a pixel off the true mirror axis at `(width - 1) / 2`, so the carve
    ## — and only the carve — is a pixel out of true; there the assertion is on
    ## the obstacle UNION, which is exact on every class.
    for spec in ["arena", "arena-large", "gen:1", "gen:777"]:
      let
        gameMap = loadCtfMapMetadata(spec)
        obstacles = buildArenaObstacles(gameMap)
        op = gameMap.teamOp(Blue)
        oddWidth = gameMap.width mod 2 == 1
      check op in [hexMir90, hexRot180]
      var unionMismatch, maskMismatch = 0
      var y = 0
      while y < gameMap.height:
        var x = 0
        while x < gameMap.width:
          let image = gameMap.pixelImage(MapPoint(x: x, y: y), op)
          var here, there = false
          for shape in obstacles:
            if not here and inShape(x, y, shape):
              here = true
            if not there and inShape(image.x, image.y, shape):
              there = true
            if here and there:
              break
          if here != there:
            inc unionMismatch
          if mapWallAt(gameMap, obstacles, x, y) !=
              mapWallAt(gameMap, obstacles, image.x, image.y):
            inc maskMismatch
          x += 3
        y += 3
      checkpoint(spec & " union/mask mismatches: " &
        $unionMismatch & "/" & $maskMismatch)
      check unionMismatch == 0
      if oddWidth:
        check maskMismatch == 0

suite "hex arena: the shape vocabulary is exact":
  test "rectShape round-trips through shapeAsRect, even extents included":
    ## `shapeRect` is deleted; `rectShape` builds the bar that covers exactly a
    ## rectangle's pixels. The DOUBLED center is what makes an EVEN extent
    ## representable at all (its true center falls on a half pixel), and the
    ## trench pipeline round-trips rects through this pair on every map.
    for w in [1, 2, 3, 12, 13, 60, 61]:
      for h in [1, 2, 3, 12, 13, 60, 61]:
        for (x, y) in [(0, 0), (1, 0), (7, 11), (100, 250), (963, 1100)]:
          let r = MapRect(x: x, y: y, w: w, h: h)
          check shapeAsRect(rectShape(r)) == r
          ## ...and membership is the rectangle's own pixels, no more, no less.
          let shape = rectShape(r)
          for py in y - 2 .. y + h + 1:
            for px in x - 2 .. x + w + 1:
              check inShape(px, py, shape) ==
                (px >= x and px < x + w and py >= y and py < y + h)

  test "diamondShape is exactly the L1 ball":
    ## The old `shapeDiamond` is gone; a diamond is now a bar on the (1, 1)
    ## axis, and the spinning-diamond art bakes its hole from |dx| + |dy| <= r.
    ## If the bar and the L1 test ever disagreed, the art and the collision
    ## mask would disagree with it.
    for radius in [1, 2, 5, 28, 30, 31]:
      for (cx, cy) in [(60, 60), (61, 60), (450, 413)]:
        let shape = diamondShape(cx, cy, radius)
        for dy in -radius - 2 .. radius + 2:
          for dx in -radius - 2 .. radius + 2:
            check inShape(cx + dx, cy + dy, shape) ==
              (abs(dx) + abs(dy) <= radius)
        ## And it is still recognizable as one, which is what selects it for
        ## the spin.
        let spot = shape.asDiamond()
        check spot == (true, cx, cy, radius)

  test "hexShape membership is mirror-exact":
    ## A hexagonal obstacle has to be its own image under the axis mirrors, or
    ## a mirrored map hands one team a shape a pixel wider than its twin's.
    ## The predicate is integer with sqrt(3) as the exact rational 265/153
    ## precisely so this holds.
    for flatTop in [false, true]:
      for radius in [4, 10, 28, 29]:
        for (cx, cy) in [(200, 300), (201, 300), (200, 301), (201, 301)]:
          let shape = hexShape(cx, cy, radius, flatTop)
          var pixels = 0
          for dy in -radius - 2 .. radius + 2:
            for dx in -radius - 2 .. radius + 2:
              let here = inShape(cx + dx, cy + dy, shape)
              if here:
                inc pixels
              check here == inShape(cx - dx, cy + dy, shape)  # mirror in x
              check here == inShape(cx + dx, cy - dy, shape)  # mirror in y
          check pixels > 0
          ## The bounding box the renderer and the validators work from really
          ## does contain every pixel.
          let b = shape.shapeBounds()
          for dy in -radius - 2 .. radius + 2:
            for dx in -radius - 2 .. radius + 2:
              if inShape(cx + dx, cy + dy, shape):
                check cx + dx >= b.x0 and cx + dx <= b.x1
                check cy + dy >= b.y0 and cy + dy <= b.y1

## Generated maps are installed as the process map above; put the arena back.
installDefaultArena()
invalidateBoardMapCaches()
