## Phase-1 laws for the Season 2 body's immutable episode map and exact
## standing-goal validator.

import std/[json, math, options, os, unittest]
import ../src/ctf/arena
import ../src/ctf/sim_types
import ../src/shell/body_cache
import ../src/shell/body_map
import ../src/shell/types as shellTypes

const FixtureDir = "tests" / "fixtures" / "shell" / "body"
const
  TestAtlasSectorCount = 16
  TestPostReachCapPx = 1300

type TestRaySample = object
  offset: BodyPoint
  distance: uint16

proc mix(hash: var uint64, value: int) =
  hash = (hash xor uint64(cast[uint32](value))) * 1099511628211'u64

proc twoComponentMap(): tuple[map: BodyMap, expected: JsonNode] =
  let fixture = parseFile(FixtureDir / "two-components.json")
  let width = fixture["width"].getInt()
  let height = fixture["height"].getInt()
  let barrier = fixture["barrier"]
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = not (
        x in barrier["x0"].getInt() .. barrier["x1"].getInt() and
        y notin barrier["gap_y0"].getInt() .. barrier["gap_y1"].getInt())
  var spawns: seq[BodyPoint]
  for point in fixture["spawn_points"]:
    spawns.add((point[0].getInt(), point[1].getInt()))
  var homes: seq[BodyHome]
  for home in fixture["homes"]:
    homes.add(BodyHome(group: home[0].getInt(),
      point: (home[1].getInt(), home[2].getInt())))
  (newBodyMap(walkable, width, height, 2, spawns, homes), fixture["expected"])

proc openRoomsMap(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100: walkable[y * Width + x] = true
    for x in 600 ..< Width - 1: walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc tieMap(): BodyMap =
  const Width = 104
  const Height = 104
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 28: walkable[y * Width + x] = true
    for x in 74 ..< Width - 1: walkable[y * Width + x] = true
  for y in 72 ..< Height - 1:
    for x in 1 ..< Width - 1: walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(16, 32), (88, 32)])

proc brMap(): CtfMap =
  const Side = 256
  result = CtfMap(
    name: "body-br-16", width: Side, height: Side,
    center: MapPoint(x: Side div 2, y: Side div 2),
    symmetry: symNone, layout: layoutSides, flagless: true,
    spawnGroups: 16)
  for row in 0 ..< 4:
    for column in 0 ..< 4:
      result.spawnPoints.add(MapPoint(
        x: 32 + column * 64, y: 32 + row * 64))

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc atlasRaySamples(): array[TestAtlasSectorCount, seq[TestRaySample]] =
  for sector in 0 ..< TestAtlasSectorCount:
    let angle = sector.float * 2.0 * PI / TestAtlasSectorCount.float
    let dirX = cos(angle)
    let dirY = sin(angle)
    for distance in 1 .. TestPostReachCapPx:
      let sample = (pyRound(dirX * distance.float),
                    pyRound(dirY * distance.float))
      if result[sector].len > 0 and result[sector][^1].offset == sample:
        result[sector][^1].distance = uint16(distance)
      else:
        result[sector].add(TestRaySample(
          offset: sample, distance: uint16(distance)))

proc testRayReach(map: BodyMap, point: BodyPoint,
                  samples: openArray[TestRaySample]): uint16 =
  var reached = 0
  for sample in samples:
    let sx = point.x + sample.offset.x
    let sy = point.y + sample.offset.y
    if sx.uint >= map.width.uint or sy.uint >= map.height.uint or
        map.isWall((sx, sy)):
      break
    reached = sample.distance.int
  uint16(reached)

proc independentThinnedAtlas(map: BodyMap): seq[BodyAtlasPost] =
  let samples = atlasRaySamples()
  for gy in 0 ..< map.gridHeight:
    for gx in 0 ..< map.gridWidth:
      if (gx and 1) != 0 or (gy and 1) != 0:
        continue
      if map.coverDirections((gx, gy)) == 0:
        continue
      var post = BodyAtlasPost(pos: cellCenter((gx, gy)))
      for sector in 0 ..< TestAtlasSectorCount:
        post.reach[sector] = map.testRayReach(post.pos, samples[sector])
      result.add(post)

proc thinnedLattice(size: int): seq[bool] =
  result = newSeq[bool](size * size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      result[y * size + x] = x mod 16 != 12

suite "shell body immutable episode map":
  test "component-by-component static fields match the pinned stencil golden":
    let (map, expected) = twoComponentMap()
    var clearanceHash = 14695981039346656037'u64
    var componentHash = clearanceHash
    var roomHash = clearanceHash
    var coverHash = clearanceHash
    var atlasHash = clearanceHash
    for y in 0 ..< map.height:
      for x in 0 ..< map.width:
        clearanceHash.mix(map.clearanceAt((x, y)))
        componentHash.mix(map.componentOf((x, y)))
        roomHash.mix(map.roomLabelAt((x, y)))
    for y in 0 ..< map.gridHeight:
      for x in 0 ..< map.gridWidth:
        coverHash.mix(map.coverDirections((x, y)).int)
    for index in 0 ..< map.atlasPostCount:
      let post = map.atlasPostAt(index)
      atlasHash.mix(post.pos.x)
      atlasHash.mix(post.pos.y)
      for reach in post.reach: atlasHash.mix(reach.int)

    check map.componentCount == expected["components"].getInt()
    check map.chokeCount == expected["chokes"].getInt()
    check map.atlasPostCount == expected["atlas_posts"].getInt()
    check map.validatorTableCount == expected["validator_tables"].getInt()
    check map.homeFieldCount == expected["home_fields"].getInt()
    check map.homeDistance(0, (12, 32)).get ==
      expected["home_distance_red_from_red"].getFloat()
    check map.homeDistance(0, (87, 31)).isNone
    check $clearanceHash == expected["clearance_hash"].getStr()
    check $componentHash == expected["component_hash"].getStr()
    check $roomHash == expected["room_hash"].getStr()
    check $coverHash == expected["cover_hash"].getStr()
    check $atlasHash == expected["atlas_hash"].getStr()
    check map.roomCount == expected["rooms"].len
    var roomIndex = 0
    for golden in expected["rooms"]:
      let room = map.roomAt(roomIndex)
      check [room.peak.x, room.peak.y, room.peakClearance,
        room.area, room.component] == [golden[0].getInt(), golden[1].getInt(),
        golden[2].getInt(), golden[3].getInt(), golden[4].getInt()]
      check room.chokes.len == 0
      inc roomIndex

  test "exact validator covers sites, walls, edges, radius and components":
    let map = openRoomsMap()
    let origin = (x: 30, y: 30)
    check map.validateGoal(origin, origin).get.goalPoint == origin
    check map.validateGoal((0, 0), origin).get.goalPoint == (7, 7)
    check map.validateGoal((350, 30), origin).get.goalPoint == (94, 30)
    check map.validateGoal((351, 30), origin).isNone
    check map.validateGoal((650, 30), origin).isNone
    check map.validateGoal((100, 30), origin).get.goalPoint == (94, 30)
    check map.validateGoal((30, 30), (0, 0)).isNone

  test "equal-distance ties choose the row-major pixel":
    let map = tieMap()
    let goal = map.validateGoal((51, 32), (16, 32)).get
    check goal.goalPoint == (22, 32)
    check goal.goalComponent == map.componentOf((16, 32))
    check goal.belongsTo(map)

  test "ValidatedGoal has no external construction or mutable map escape":
    let (map, _) = twoComponentMap()
    static:
      doAssert not compiles(ValidatedGoal())
      doAssert not compiles(ValidatedGoal(point: (1, 1)))
      doAssert not compiles(map.mapWidth = 1)
      doAssert not compiles(map.wall[0] = true)
    var room = map.roomAt(0)
    room.chokes.add(999)
    check map.roomAt(0).chokes.len == 0

  test "flagless 16-group maps build without homes or four-team facts":
    let map = newBodyMap(brMap())
    check map.groupCount == 16
    check map.homeFieldCount == 0
    check map.validatorTableCount == 1
    check map.componentCount == 1
    check map.validateGoal((128, 128), (32, 32)).isSome

  test "the committed 16-team BR map builds endzone-free":
    let gameMap = mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json"))
    let map = newBodyMap(gameMap)
    check map.groupCount == 16
    check map.homeFieldCount == 0
    check map.validatorTableCount >= 1
    check map.validatorLogicalBytes <= shellTypes.MaxValidatorTableBytes.int64
    check map.maxAtlasPostsInRadius <= shellTypes.MaxCoverPostsExamined
    for point in gameMap.spawnPoints:
      check map.componentOf((point.x, point.y)) != 0

  test "atlas thinning keeps only the 16px candidate grid":
    let (map, _) = twoComponentMap()
    let expected = map.independentThinnedAtlas()
    check map.atlasPostCount == expected.len
    for index, expectedPost in expected:
      let actual = map.atlasPostAt(index)
      check actual.pos == expectedPost.pos
      check actual.reach == expectedPost.reach
      let cell = map.cellOf(actual.pos)
      check (cell.x and 1) == 0
      check (cell.y and 1) == 0

  test "duck cache works on thinned atlas posts":
    const Side = 512
    let map = newBodyMap(thinnedLattice(Side), Side, Side, 2, @[(20, 20)])
    check map.atlasPostCount > shellTypes.MaxDuckEntriesPerSeat
    let cache = newBodySeatCache(map)
    for index in 0 ..< shellTypes.MaxDuckEntriesPerSeat:
      let duck = cache.duckFor(index)
      check map.canStand(duck.pos)
    check cache.duckEntryCount == shellTypes.MaxDuckEntriesPerSeat
    let firstKey = map.routeKey(map.atlasPostAt(0).pos)
    discard cache.duckFor(shellTypes.MaxDuckEntriesPerSeat)
    check firstKey notin cache.duckKeys

  test "atlas density cap riders use thinned construction":
    const BoundarySide = 512
    let boundary = newBodyMap(thinnedLattice(BoundarySide), BoundarySide,
      BoundarySide, 2, @[(20, 20)])
    # The synthetic 16px lattice measures 957 posts in its densest 331px disc,
    # just below the frozen 1,024-post cap.
    check boundary.maxAtlasPostsInRadius == 957

    const DenseSide = 640
    # The larger synthetic 16px lattice measures 1,309 posts in its densest
    # 331px disc under the thinned construction, so it remains a one-past-
    # density negative control for MaxCoverPostsExamined=1,024.
    expect BodyMapError:
      discard newBodyMap(thinnedLattice(DenseSide), DenseSide, DenseSide, 2,
        @[(20, 20)])

  test "validator byte cap arithmetic is exact":
    check validatorBytesFor(3211, 1713, 1) == 22_001_772
    check validatorBytesFor(3211, 1713, 12) <=
      shellTypes.MaxValidatorTableBytes.int64
    check validatorBytesFor(3211, 1713, 13) >
      shellTypes.MaxValidatorTableBytes.int64

  test "invalid spawn fails the activation build":
    var tiny = newSeq[bool](32 * 32)
    for value in tiny.mitems: value = true
    expect BodyMapError:
      discard newBodyMap(tiny, 32, 32, 2, @[(0, 0)])
