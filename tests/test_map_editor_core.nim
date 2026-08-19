import
  std/[math, os, sets, strutils, unittest],
  crunchy/crc32,
  pixie,
  pixie/fileformats/png,
  ctf/[map_pool, sim],
  "../tools/map_render"

const ValidationBaselinePath =
  currentSourcePath.parentDir / "fixtures" / "map-validation-baseline.tsv"

const PoolRenderHashes = [
  0xff7ea386'u32, 0xe7a608d6'u32, 0xcfbc5c15'u32, 0xbc4bbdba'u32,
  0xb0e53440'u32, 0x64365320'u32, 0x9eef99a4'u32, 0x8e7237dc'u32,
  0x56d6b747'u32, 0x23906590'u32, 0xb04e9473'u32, 0x81eaef9f'u32,
  0xa1d457d4'u32, 0x8a5b61a2'u32, 0x4522b04c'u32, 0x8fa035f7'u32,
  0xee524a7e'u32, 0x65501d0f'u32, 0xe736475e'u32, 0xae0849b1'u32,
]

type BaselineRow = object
  ## One data row of fixtures/map-validation-baseline.tsv.
  teams, seed: int
  endzone, layout, expected: string

proc validationBaseline(): seq[BaselineRow] =
  ## Parsed once per test rather than shared in a global: reading and splitting
  ## 402 lines is microseconds next to generating a single map, and a global
  ## would make the shards order-dependent.
  for line in readFile(ValidationBaselinePath).splitLines():
    if line.len == 0 or line[0] == '#' or line.startsWith("teams\t"):
      continue
    let fields = line.split('\t', maxsplit = 4)
    doAssert fields.len == 5, "malformed baseline row: " & line
    result.add BaselineRow(
      teams: parseInt(fields[0]),
      seed: parseInt(fields[1]),
      endzone: fields[2],
      layout: fields[3],
      expected: fields[4],
    )

proc baselineMap(row: BaselineRow): CtfMap =
  generateMapAttempt(
    row.seed,
    MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
    row.teams,
  )

proc poolMap(index: int): CtfMap =
  generateMapAttempt(
    MapPoolSeeds[index],
    MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
  )

proc poolRenderOptions(maxDimension = 0): MapRenderOptions =
  MapRenderOptions(
    maxDimension: maxDimension,
    overlays: {overlayProtected, overlayPickups},
    pickupKinds: {pickupMedKitActive, pickupMedKitCandidate},
  )

proc surroundingsMap(symmetry: MapSymmetry): CtfMap =
  let (width, height) =
    if symmetry == symRot90: (101, 101)
    else: (101, 81)
  result = CtfMap(
    width: width,
    height: height,
    center: MapPoint(x: width div 2, y: height div 2),
    flagRing: 5,
    captureClear: 15,
    spawnClearW: 3,
    spawnClearH: 3,
    homeDepth: 700,
    symmetry: symmetry,
    layout: (if symmetry == symRot90: layoutCorners else: layoutSides),
    leftObstacles: @[
      ArenaShape(
        kind: shapeRect,
        rect: MapRect(x: 20, y: 25, w: 7, h: 11),
      ),
    ],
  )

proc checkSymmetricSurroundings(gameMap: CtfMap, source: MapPoint) =
  ## A coordinate orbit is only useful when it carries the same terrain
  ## with it. Sample both stone and floor so an empty patch cannot make this
  ## fairness assertion pass vacuously.
  let
    obstacles = buildArenaObstacles(gameMap)
    wall = rasterizeRestWallMask(
      gameMap,
      obstacles,
      proc (x, y: int): bool = mapProtectedFloorAt(gameMap, x, y),
    )
    sourceOrbit = gameMap.symmetryImages(source)
  var sawWall, sawFloor: bool
  for dy in -8 .. 8:
    for dx in -8 .. 8:
      let
        sample = MapPoint(x: source.x + dx, y: source.y + dy)
        sampleOrbit = gameMap.symmetryImages(sample)
        sourceIsWall = wall[sample.y * gameMap.width + sample.x]
      check sampleOrbit.len == sourceOrbit.len
      if sourceIsWall: sawWall = true
      else: sawFloor = true
      for image in sampleOrbit:
        check wall[image.y * gameMap.width + image.x] == sourceIsWall
  check sawWall
  check sawFloor

suite "map editor core":
  test "symmetry images form exact deduplicated integer orbits":
    var gameMap = CtfMap(width: 11, height: 9, symmetry: symMirror)
    check gameMap.symmetryImages(MapPoint(x: 2, y: 3)) == @[
      MapPoint(x: 2, y: 3),
      MapPoint(x: 8, y: 3),
    ]
    check gameMap.symmetryImages(MapRect(x: 1, y: 2, w: 3, h: 2)) == @[
      MapRect(x: 1, y: 2, w: 3, h: 2),
      MapRect(x: 7, y: 2, w: 3, h: 2),
    ]
    check gameMap.symmetryImages(MapPoint(x: 5, y: 4)) == @[
      MapPoint(x: 5, y: 4),
    ]
    gameMap.width = 10
    check gameMap.symmetryImages(MapRect(x: 4, y: 2, w: 2, h: 3)) == @[
      MapRect(x: 4, y: 2, w: 2, h: 3),
    ]

    gameMap = CtfMap(width: 11, height: 9, symmetry: symRot180)
    check gameMap.symmetryImages(MapPoint(x: 2, y: 3)) == @[
      MapPoint(x: 2, y: 3),
      MapPoint(x: 8, y: 5),
    ]
    check gameMap.symmetryImages(MapRect(x: 1, y: 2, w: 3, h: 2)) == @[
      MapRect(x: 1, y: 2, w: 3, h: 2),
      MapRect(x: 7, y: 5, w: 3, h: 2),
    ]
    check gameMap.symmetryImages(MapPoint(x: 5, y: 4)) == @[
      MapPoint(x: 5, y: 4),
    ]
    check gameMap.symmetryImages(MapRect(x: 4, y: 3, w: 3, h: 3)) == @[
      MapRect(x: 4, y: 3, w: 3, h: 3),
    ]

    gameMap = CtfMap(width: 9, height: 9, symmetry: symRot90)
    check gameMap.symmetryImages(MapPoint(x: 1, y: 2)) == @[
      MapPoint(x: 1, y: 2),
      MapPoint(x: 6, y: 1),
      MapPoint(x: 7, y: 6),
      MapPoint(x: 2, y: 7),
    ]
    check gameMap.symmetryImages(MapRect(x: 1, y: 2, w: 3, h: 2)) == @[
      MapRect(x: 1, y: 2, w: 3, h: 2),
      MapRect(x: 5, y: 1, w: 2, h: 3),
      MapRect(x: 5, y: 5, w: 3, h: 2),
      MapRect(x: 2, y: 5, w: 2, h: 3),
    ]
    check gameMap.symmetryImages(MapPoint(x: 4, y: 4)) == @[
      MapPoint(x: 4, y: 4),
    ]
    check gameMap.symmetryImages(MapRect(x: 3, y: 3, w: 3, h: 3)) == @[
      MapRect(x: 3, y: 3, w: 3, h: 3),
    ]
    check gameMap.symmetryImages(MapRect(x: 3, y: 2, w: 3, h: 5)) == @[
      MapRect(x: 3, y: 2, w: 3, h: 5),
      MapRect(x: 2, y: 3, w: 5, h: 3),
    ]

  test "symmetry images carry the original wall surroundings":
    for symmetry in [symMirror, symRot180, symRot90]:
      surroundingsMap(symmetry).checkSymmetricSurroundings(
        MapPoint(x: 23, y: 30)
      )

  test "rectangle expansion matches generated finalized trenches":
    for symmetry in ["mirror", "rot180"]:
      let gameMap = generateMapAttempt(
        1001,
        MapGenOverrides(
          size: "small",
          symmetry: symmetry,
          windows: -1,
          pits: 2,
          pitDensity: -1,
        ),
      )
      check gameMap.trenches.len == 2
      var trenchRects: seq[MapRect]
      for t in gameMap.trenches:
        trenchRects.add shapeAsRect(t)
      check gameMap.symmetryImages(shapeAsRect(gameMap.trenches[0])) ==
        trenchRects

  # The 402-row baseline is the single most expensive thing in the suite: at
  # ~180ms per row it was one 73-second `test`, which set the wall clock of the
  # whole run and could not be broken up by any amount of fan-out (caos runs
  # tests by NAME, and a name is indivisible). So it is 8 named shards, each
  # runnable on its own.
  #
  # Interleaved (row i goes to shard i mod ValidationShards), not chunked: the
  # fixture is ordered by teams then seed, and 4-team maps cost noticeably more
  # to generate, so contiguous blocks would be lopsided.
  const ValidationShards = 8

  proc shardSize(rows, shard: int): int =
    ## How many rows shard `shard` owns. Derived, not written down, so it
    ## cannot drift from the fixture — but still checked against what each
    ## shard actually ran, which is what catches a row silently skipped.
    (rows - shard + ValidationShards - 1) div ValidationShards

  proc checkValidationShard(shard: int) =
    let rows = validationBaseline()
    var
      cases = 0
      mismatches: seq[string]
    var i = shard
    while i < rows.len:
      let
        row = rows[i]
        actual = validateGeneratedMap(baselineMap(row))
      inc cases
      if actual != row.expected:
        mismatches.add(
          "teams=" & $row.teams & " seed=" & $row.seed &
            " expected=" & row.expected.repr & " actual=" & actual.repr
        )
      i += ValidationShards
    check cases == shardSize(rows.len, shard)
    check mismatches.len == 0

  test "generated-map validation baseline is complete and fully sharded":
    ## Guards the split itself. Every assertion the sharded tests cannot make
    ## — because each of them sees only its own slice — lives here, and none of
    ## it generates a map, so it costs nothing.
    let rows = validationBaseline()
    check rows.len == 402
    # The shards partition the rows EXACTLY: nothing run twice, nothing
    # dropped. Without this, deleting a shard below would quietly reduce
    # coverage and every remaining test would still pass.
    var covered = 0
    for shard in 0 ..< ValidationShards:
      covered += shardSize(rows.len, shard)
    check covered == rows.len

    var
      endzones2 = initHashSet[string]()
      layouts4 = initHashSet[string]()
    for row in rows:
      if row.teams == 2:
        endzones2.incl row.endzone
      else:
        layouts4.incl row.layout
    check endzones2 == ["column", "disc", "square"].toHashSet()
    check layouts4 == ["corners", "plus"].toHashSet()

  test "generated-map validation reports full diagnostics on the pinned rows":
    ## Three rows got the expensive full-diagnostics treatment inside the old
    ## loop. Pulled out here so the shards stay a uniform map-and-validate.
    const Pinned = [(2, 1002), (2, 1156), (4, 1024)]
    var seen = 0
    for row in validationBaseline():
      if (row.teams, row.seed) notin Pinned:
        continue
      inc seen
      let diagnostics = mapDiagnostics(baselineMap(row))
      check diagnostics.reason == row.expected
      if row.teams == 2 and row.seed == 1002:
        check diagnostics.openSightlineRows.len > 1
        check diagnostics.openSightlineRows[0] == 512
    check seen == Pinned.len

  # Eight literal names, not a loop building them. caos's test runner selects
  # tests by grepping `test "..."` out of this file, so a computed name is one
  # the fan-out cannot see — it would simply stop running, silently.
  test "generated-map validation baseline shard 0 of 8":
    checkValidationShard(0)

  test "generated-map validation baseline shard 1 of 8":
    checkValidationShard(1)

  test "generated-map validation baseline shard 2 of 8":
    checkValidationShard(2)

  test "generated-map validation baseline shard 3 of 8":
    checkValidationShard(3)

  test "generated-map validation baseline shard 4 of 8":
    checkValidationShard(4)

  test "generated-map validation baseline shard 5 of 8":
    checkValidationShard(5)

  test "generated-map validation baseline shard 6 of 8":
    checkValidationShard(6)

  test "generated-map validation baseline shard 7 of 8":
    checkValidationShard(7)
  test "every curated map spec round-trips byte-identically":
    for index in 0 ..< MapPoolSeeds.len:
      let
        gameMap = poolMap(index)
        spec = mapSpecJson(gameMap)
        rebuilt = mapFromSpecJson(spec)
      check mapSpecJson(rebuilt) == spec
      check rebuilt == gameMap

  test "shared pool rendering matches the pre-extraction images":
    for index in 0 ..< MapPoolSeeds.len:
      let
        rendered = renderMap(poolMap(index), poolRenderOptions())
        actualHash = crc32(rendered.image.encodePng())
      check actualHash == PoolRenderHashes[index]

  test "maxDimension uses one exact non-upscaling render scale":
    let
      gameMap = poolMap(0)
      rendered = renderMap(gameMap, poolRenderOptions(maxDimension = 160))
      expectedScale = 160.0 / float(max(gameMap.width, gameMap.height))
      summary = mapDiagnostics(gameMap)
      withMasks = mapDiagnostics(
        gameMap,
        {diagnosticWallMasks, diagnosticCorridorOpen, diagnosticReachable},
      )
    var reachabilityOptions = poolRenderOptions(maxDimension = 160)
    reachabilityOptions.overlays.incl overlayReachability
    let reachabilityRender = renderMap(gameMap, reachabilityOptions)
    check abs(rendered.renderScale - expectedScale) < 1e-12
    check rendered.image.width == int(ceil(float(gameMap.width) * expectedScale))
    check rendered.image.height ==
      int(ceil(float(gameMap.height) * expectedScale))
    check reachabilityRender.image.width == rendered.image.width
    check reachabilityRender.image.height == rendered.image.height
    check summary.maxWall.len == 0
    check summary.minWall.len == 0
    check summary.corridorOpen.len == 0
    check summary.reachable.len == 0
    check withMasks.maxWall.len == gameMap.width * gameMap.height
    check withMasks.minWall.len == gameMap.width * gameMap.height
    check withMasks.corridorOpen.len == gameMap.width * gameMap.height
    check withMasks.reachable.len == gameMap.width * gameMap.height

  test "rendering arbitrary maps is independent of installed globals":
    let
      widthBefore = MapWidth
      heightBefore = MapHeight
      obstaclesBefore = ArenaObstacles
      twoTeamMap = poolMap(0)
      fourTeamMap = generateMapAttempt(
        1001,
        MapGenOverrides(
          size: "small", windows: -1, pits: -1, pitDensity: -1,
        ),
        teams = 4,
      )
    discard renderMap(twoTeamMap, poolRenderOptions(maxDimension = 160))
    discard renderMap(fourTeamMap, poolRenderOptions(maxDimension = 160))
    check MapWidth == widthBefore
    check MapHeight == heightBefore
    check ArenaObstacles == obstaclesBefore
