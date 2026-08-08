import
  helpers,
  std/[math, os, sets, strutils, unittest],
  crunchy/crc32,
  pixie,
  pixie/fileformats/png,
  ctf/[map_pool, sim],
  "../tools/map_render"

const ValidationBaselinePath =
  currentSourcePath.parentDir / "fixtures" / "map-validation-baseline.tsv"

const PoolRenderHashes = [
  ## T2a MERGE NOTE (corridor68): on its own base that branch moved exactly
  ## one hash — index 18, seed 1021 — because the 68 px length-aware corridor
  ## floor rejected best-of-K's pick ("kill box at (523,392)") and selection
  ## fell through. On THIS merged tree the pin below is re-verified by the
  ## suite; if the floor moves a pool pick again, render and LOOK before
  ## re-pinning (the law above stands).
  ## Re-pinned against the rebuilt generator (`maxwell/mapgen-rebuild`), which
  ## re-deals every seed: all 20 moved. The SEED LIST did not — `gen_map_pool`
  ## re-curates to the same 20 — so this pin is the only place the rewrite is
  ## visible, which is exactly why it is not a mechanical update. Every one of
  ## these 20 renders was looked at before the hash was written down: six
  ## archetypes present (blocks 5, three-lane 5, field 4, warren 3, hub 2,
  ## ring 1), symmetry visibly exact on all 20, no degenerate board. A hash
  ## nobody has looked at makes a bad map the baseline for everyone after.
  ##
  ## FIVE MOVED AGAIN when `clearLanes` started cutting polygons and diagonals
  ## instead of dropping them whole, and closed the gate-mouth hole in the rect
  ## trim (task eea795c7). Indices 3, 6, 10, 12, 13 — seeds 1004, 1007, 1011,
  ## 1013, 1014 — are exactly the pool's three-lane draws; the other fifteen are
  ## byte-identical, which is the control that says the change reached only what
  ## it claims to touch. All five were rendered before and after and looked at:
  ## symmetry exact (largest left/right stone delta 0.046%, and every mismatch
  ## a 1 px line ON the axis, i.e. rasterizer rounding), walkable space one
  ## connected component with both bases on it, blocking cover 14.1-16.6%, and
  ## stone blob counts DOWN on all five (fewer, larger masses — not confetti).
  ##
  ## The review also found what the hash cannot say: pool-wide the WINDOW count
  ## falls 57 -> 50 and two panes now overlap the border ring (0 before). That
  ## is not the clip. Window anchors are drawn from fill shapes that are rect,
  ## disc or diamond — `arena`'s anchor switch gives polygons and diagonals
  ## (0, 0) and the `sx > 0` guard then skips them — so re-dealing the fill
  ## re-deals the anchors, and the anchor step has never had a border test.
  ## Recorded here rather than fixed here: it is the window stage's bug.
  0x254b59b6'u32, 0x3439bd90'u32, 0x087a84d5'u32, 0x3027d369'u32,
  0x01fd2cc7'u32, 0x86673849'u32, 0xf66dd776'u32, 0xac1b2e34'u32,
  0xcab0a916'u32, 0x2c389334'u32, 0xe87734f9'u32, 0xb38ec8dd'u32,
  0x38c717dd'u32, 0x5b54f609'u32, 0xf1cab922'u32, 0x703f4aec'u32,
  0x66a67465'u32, 0x30d4387b'u32, 0x3fdb8e76'u32, 0x1ba77a58'u32
]

proc poolMap(index: int): CtfMap =
  ## The map the pool actually SERVES — a full best-of-K selection, not the
  ## raw first draw. It used to be `generateMapAttempt`, which was the same
  ## thing only while the pool was curated on first-attempt validity; now that
  ## `poolCtfMap` ranks candidates, pinning render hashes against attempt 0
  ## would pin an image nobody plays. Memoized because a selection costs ~1s
  ## and three tests below walk the whole pool.
  ##
  ## The memo lives in `helpers` rather than here so it is shared with the
  ## other pool-sweeping modules: this module is alone in its SHARD, but the
  ## local `tests.nim` run is one binary holding all four.
  cachedPoolMap(index)

proc firstRow(rows: seq[int]): int =
  ## The first collected row, or -1 when the diagnostic collected nothing.
  ## Subscript-free on purpose: an empty perception surface has to fail with
  ## its own value printed, not with an IndexDefect that aborts the test and
  ## hides every check after it. That crash is exactly what kept a 222-case
  ## drift in the validation baseline invisible.
  if rows.len > 0: rows[0] else: -1

const FirstOccupiableRow* = ArenaBorder + MinPassableWidth div 2
  ## The first row a 13 px body can actually stand in. Spelled from the same
  ## two constants the validator uses rather than as a literal, so the scan
  ## and its control cannot drift apart silently again.

proc sightlineScanRows(height: int): int =
  ## How many rows the validator's sightline scan visits on a board of this
  ## height — the count an obstacle-free board has to report as open.
  ##
  ## Both of this helper's numbers moved with the scan and NEITHER is a taste:
  ## the stride went 4 -> 1 because a strided scan missed fully open rows on
  ## seeds 1001 and 1014, and the start moved from `ArenaBorder + 2` to the
  ## first OCCUPIABLE row because the ~10 px strip above it is open on every
  ## map by construction and can hold neither a shooter nor a target. This
  ## helper described the old scan, so the control it feeds was asserting the
  ## validator still had the defect that was fixed.
  var y = FirstOccupiableRow
  while y < height - FirstOccupiableRow:
    inc result
    inc y

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

  test "generated-map validation matches the baseline on both code paths":
    ## The fixture pins `validateGeneratedMap` for the generator's RAW first
    ## draw across 402 (teams, seed) pairs. It is a regression pin, not a
    ## quality claim: regenerate it with `tools/gen_validation_baseline.nim`
    ## whenever the draws or the validators move, and report the pass rate it
    ## prints.
    ##
    ## Every case is ALSO re-checked through the FULL diagnostic pass, so the
    ## two implementations behind `collectMapDiagnostics` — the generator's
    ## first-failure early exit and the editor's complete pass — cannot drift
    ## apart. That used to be three hand-picked seeds ("one 2-team sightline
    ## rejection, one 2-team cover rejection, one 4-team rejection"), and the
    ## hand-picking is precisely what rotted: the generator moved, not one of
    ## the three still failed for the reason it had been chosen for, and the
    ## expectations they carried went stale with nothing to say so. All 402
    ## costs ~12s more and has no seeds to re-pick.
    var
      cases = 0
      endzones2 = initHashSet[string]()
      layouts4 = initHashSet[string]()
      mismatches: seq[string]
      openSightlineMaps: seq[string]
    for line in readFile(ValidationBaselinePath).splitLines():
      if line.len == 0 or line[0] == '#' or line.startsWith("teams\t"):
        continue
      let fields = line.split('\t', maxsplit = 4)
      check fields.len == 5
      if fields.len != 5:
        continue
      let
        teams = parseInt(fields[0])
        seed = parseInt(fields[1])
        expected = fields[4]
        gameMap = generateMapAttempt(
          seed,
          MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
          teams,
        )
        actual = validateGeneratedMap(gameMap)
        diagnostics = mapDiagnostics(gameMap)
      inc cases
      if teams == 2:
        endzones2.incl fields[2]
      else:
        layouts4.incl fields[3]
      if actual != expected:
        mismatches.add(
          "teams=" & $teams & " seed=" & $seed &
            " expected=" & expected.repr & " actual=" & actual.repr
        )
      if diagnostics.reason != actual:
        mismatches.add(
          "code paths disagree teams=" & $teams & " seed=" & $seed &
            " early-exit=" & actual.repr &
            " full-pass=" & diagnostics.reason.repr
        )
      if diagnostics.openSightlineRows.len > 0:
        openSightlineMaps.add(
          "teams=" & $teams & " seed=" & $seed &
            " rows=" & $diagnostics.openSightlineRows
        )
    check cases == 402
    check endzones2 == ["column", "disc", "square"].toHashSet()
    check layouts4 == ["corners", "plus"].toHashSet()
    ## Compared as SEQUENCES, not lengths: `unittest` prints both operands, so
    ## a red run names the seeds that drifted instead of only how many did.
    check mismatches == newSeq[string]()

    ## SIGHTLINE ROWS: RE-DERIVED, not re-pinned. This block used to assert
    ## that seed 1020 collected MORE THAN ONE open sightline row, the first at
    ## y=12 — a pin on the pre-rewrite generator, which shipped candidates
    ## carrying open horizontal firing lanes for the validator to reject. The
    ## rewrite's row-cover pass closes every row of the `sightlineLoX ..
    ## sightlineHiX` band constructively, BEFORE validation runs, so all 402
    ## draws now reach the validator with the lane already blocked: zero open
    ## rows anywhere, zero sightline rejections in the fixture, and seed 1020
    ## validating clean. The count is 0 BY DESIGN. The old y=12 was never a
    ## property of seed 1020 either — it was `ArenaBorder + 2`, the first row
    ## the old 4px scan visited on any board, and it is now
    ## `FirstOccupiableRow`, the first row the scan visits at stride 1.
    ##
    ## An empty perception surface is how this codebase has been blinded
    ## before, so the re-derivation is a PAIR. The census above asserts the
    ## emptiness is real; the positive control below asserts the diagnostic
    ## still fires when a lane genuinely is open, so "collects nothing" can
    ## never quietly become "no longer collects".
    check openSightlineMaps == newSeq[string]()

    var strippedMap = generateMapAttempt(
      1020, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 2
    )
    strippedMap.leftObstacles.setLen(0)
    let strippedRows = mapDiagnostics(strippedMap).openSightlineRows
    check strippedRows.len == sightlineScanRows(strippedMap.height)
    check strippedRows.firstRow == FirstOccupiableRow

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
