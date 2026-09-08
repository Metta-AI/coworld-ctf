## Reproducible measurements for the play spatial-knowledge design.

when not defined(release):
  {.error: "spatial_surface_census must be compiled with -d:release".}

import std/[algorithm, json, math, monotimes, options, os, osproc, random,
  strutils, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[binary_view, body_cache, body_map, body_planner, types, view]

when defined(spatialFuel):
  import ../src/shell/[emit_validator, instance, module_validation, runtime]

const
  RoomRecordBytes = 20
  ChokeRecordBytes = 16
  AdjacencyRecordBytes = 2
  CoverRecordBytes = 40
  BitmapSectionKind = 104'u16
  RoomSectionKind = 204'u16
  ChokeSectionKind = 205'u16
  AdjacencySectionKind = 206'u16
  QuerySamples = 10_000

var timingSink: int64

proc percentile(samples: openArray[int64], fraction: float): int64 =
  var ordered = @samples
  ordered.sort()
  ordered[clamp(int(ceil(fraction * ordered.len.float)) - 1, 0, ordered.high)]

template timedSamples(count: int, body: untyped): seq[int64] =
  block:
    var measured = newSeq[int64](count)
    for measurementIndex {.inject.} in 0 ..< count:
      let started = getMonoTime()
      body
      measured[measurementIndex] = (getMonoTime() - started).inNanoseconds
    measured

proc timingRow(name, shape: string; samples: seq[int64]): JsonNode =
  %*{"query": name, "shape": shape, "calls": samples.len,
    "p50_ns": percentile(samples, 0.50),
    "p95_ns": percentile(samples, 0.95)}

proc ceilDiv(value, divisor: int): int =
  (value + divisor - 1) div divisor

proc bitmapBytes(width, height, scale: int): int =
  let cells = ceilDiv(width, scale) * ceilDiv(height, scale)
  BinarySectionEntryBytes + ceilDiv(cells, 8)

proc jsonGraphBytes(map: BodyMap): int =
  var rooms = newJArray()
  for index in 0 ..< map.roomCount:
    let room = map.roomAt(index)
    var chokeIndices = newJArray()
    for choke in room.chokes:
      chokeIndices.add(%(choke + 1))
    rooms.add(%*[room.peak.x, room.peak.y, room.peakClearance, room.area,
      room.component, chokeIndices])
  var chokes = newJArray()
  for index in 0 ..< map.chokeCount:
    let choke = map.chokeAt(index)
    chokes.add(%*[choke.pos.x, choke.pos.y, choke.clearance,
      choke.roomA + 1, choke.roomB + 1])
  ($(%*{"terrain": {"rooms": rooms, "chokes": chokes}})).len

proc jsonContextBudget(name: string; map: BodyMap;
                       graphObjectBytes: int): tuple[baseline, withGraph: int] =
  var roster: seq[PlayContextRosterRow]
  for seat in 0 ..< MaxPlayers:
    roster.add(PlayContextRosterRow(seat: seat, team: Red, control: pccPlay,
      name: "x".repeat(MaxRosterNameBytes)))
  let source = PlayContextSource(mode: gmBr, mapName: name,
    mapWidth: map.width, mapHeight: map.height, roster: roster,
    selfSeat: 0, selfTeam: Red, duoPartner: some(1), gunRange: 331,
    viewInterval: 6)
  result.baseline = buildPlayContext(source).len
  # The standalone graph object has two braces. Appending its sole field to
  # the non-empty context replaces the opening brace with one comma.
  result.withGraph = result.baseline + graphObjectBytes - 1

proc measureMap(name: string; map: BodyMap): JsonNode =
  var adjacencyCount = 0
  for index in 0 ..< map.roomCount:
    adjacencyCount += map.roomAt(index).chokes.len
  let graphBytes = 3 * BinarySectionEntryBytes +
    map.roomCount * RoomRecordBytes + map.chokeCount * ChokeRecordBytes +
    adjacencyCount * AdjacencyRecordBytes
  let graphJsonBytes = jsonGraphBytes(map)
  let jsonBudget = jsonContextBudget(name, map, graphJsonBytes)
  result = %*{
    "name": name,
    "width": map.width,
    "height": map.height,
    "rooms": map.roomCount,
    "chokes": map.chokeCount,
    "room_choke_indices": adjacencyCount,
    "graph_added_bytes": graphBytes,
    "json_graph_object_bytes": graphJsonBytes,
    "json_context_baseline_worst_roster_bytes": jsonBudget.baseline,
    "json_context_with_graph_bytes": jsonBudget.withGraph,
    "json_context_with_graph_headroom": MaxContextBytes - jsonBudget.withGraph,
    "bitmap_64_added_bytes": bitmapBytes(map.width, map.height, 64),
    "bitmap_32_added_bytes": bitmapBytes(map.width, map.height, 32),
    "bitmap_16_added_bytes": bitmapBytes(map.width, map.height, 16),
    "bitmap_8_added_bytes": bitmapBytes(map.width, map.height, 8),
    "cover_posts": map.atlasPostCount,
    "cover_added_bytes": BinarySectionEntryBytes +
      map.atlasPostCount * CoverRecordBytes,
    "max_cover_posts_in_331px": map.maxAtlasPostsInRadius,
    "binary_context_cap": MaxBinaryContextBytes,
    "json_context_cap": MaxContextBytes
  }

proc summary(values: seq[int]): JsonNode =
  var ordered = values
  ordered.sort()
  %*{"min": ordered[0], "median": ordered[ordered.len div 2],
    "max": ordered[^1]}

proc census(): JsonNode =
  let pool = loadBrS2PoolRaw()
  var rows = newJArray()
  var graph, jsonGraph, jsonContext, bitmap64, bitmap32, bitmap16, bitmap8,
    cover: seq[int]
  for entry in pool:
    var gameMap = mapFromSpecJson($entry["spec"])
    var bodyMap = newBodyMap(gameMap)
    let row = measureMap(entry["name"].getStr(), bodyMap)
    rows.add(row)
    graph.add(row["graph_added_bytes"].getInt())
    jsonGraph.add(row["json_graph_object_bytes"].getInt())
    jsonContext.add(row["json_context_with_graph_bytes"].getInt())
    bitmap64.add(row["bitmap_64_added_bytes"].getInt())
    bitmap32.add(row["bitmap_32_added_bytes"].getInt())
    bitmap16.add(row["bitmap_16_added_bytes"].getInt())
    bitmap8.add(row["bitmap_8_added_bytes"].getInt())
    cover.add(row["cover_added_bytes"].getInt())
    bodyMap = nil
    gameMap = default(CtfMap)
    GC_fullCollect()

  let colossalOverrides = MapGenOverrides(size: "colossal", windows: -1,
    pits: -1, pitDensity: -1)
  let colossalGameMap = generateCtfMap(4242, colossalOverrides, teams = 2)
  let colossalMap = newBodyMap(colossalGameMap)
  let colossal = measureMap("gen-colossal-seed-4242", colossalMap)
  %*{
    "layout": {
      "rooms": "measurement-only kind 204, 20-byte little-endian records",
      "chokes": "measurement-only kind 205, 16-byte little-endian records",
      "room_choke_indices": "measurement-only kind 206, 2-byte little-endian indices",
      "bitmap_rule": "one bit per coarse cell; set iff any 8px body-nav cell in the cell is walkable",
      "cover": "40 bytes per thinned post: i32 x/y plus 16 u16 reach values"
    },
    "pool_source": BrS2MapPoolPath,
    "pool_count": pool.len,
    "pool_rows": rows,
    "pool_summary": {
      "graph_added_bytes": summary(graph),
      "json_graph_object_bytes": summary(jsonGraph),
      "json_context_with_graph_bytes": summary(jsonContext),
      "bitmap_64_added_bytes": summary(bitmap64),
      "bitmap_32_added_bytes": summary(bitmap32),
      "bitmap_16_added_bytes": summary(bitmap16),
      "bitmap_8_added_bytes": summary(bitmap8),
      "cover_added_bytes": summary(cover)
    },
    "colossal_source": "generateCtfMap(4242, MapGenOverrides(size=colossal), teams=2)",
    "colossal": colossal
  }

proc nearestChokeIndex(map: BodyMap; point: BodyPoint): int =
  var best = high(int64)
  result = -1
  for index in 0 ..< map.chokeCount:
    let choke = map.chokeAt(index)
    let dx = int64(choke.pos.x - point.x)
    let dy = int64(choke.pos.y - point.y)
    let distance = dx * dx + dy * dy
    if distance < best:
      best = distance
      result = index

proc straightDistance(a, b: BodyPoint): float =
  hypot((a.x - b.x).float, (a.y - b.y).float)

proc mint(cache: BodySeatCache; minter: BodyFieldMinter; goal: BodyPoint;
          revision: uint64) =
  var job: BodyMintJob
  minter.beginMint(cache, job, goal, revision)
  while job.mintPending:
    var budget = 1_000_000
    discard minter.stepMint(cache, job, budget)
  if not job.mintFinished:
    raise newException(ValueError, "route field did not finish")

proc routeMeasurement(map: BodyMap; start, requested: BodyPoint): JsonNode =
  let validated = map.validateGoal(requested, start)
  if validated.isNone:
    return %*{"requested": [requested.x, requested.y],
      "straight_px": straightDistance(start, requested),
      "reachable": false}
  let snapped = validated.get.goalPoint
  let cache = newBodySeatCache(map)
  let minter = newBodyFieldMinter(map)
  cache.mint(minter, snapped, 1)
  let distance = cache.peekRouteDistance(start, snapped)
  %*{"requested": [requested.x, requested.y],
    "snapped": [snapped.x, snapped.y],
    "straight_px": straightDistance(start, requested),
    "route_px": if distance.isSome: distance.get else: -1.0,
    "reachable": distance.isSome,
    "line_of_sight": map.rayClear(start, requested),
    "start_room": map.roomLabelAt(start),
    "snapped_room": map.roomLabelAt(snapped)}

proc projectTowardManhattan(origin, toward: BodyPoint; distance: int): BodyPoint =
  let dx = toward.x - origin.x
  let dy = toward.y - origin.y
  let denominator = abs(dx) + abs(dy)
  if denominator == 0:
    return origin
  (origin.x + dx * distance div denominator,
    origin.y + dy * distance div denominator)

proc projectAway(origin, toward: BodyPoint; distance: int): BodyPoint =
  let dx = int64(origin.x - toward.x)
  let dy = int64(origin.y - toward.y)
  let lengthSquared = dx * dx + dy * dy
  if lengthSquared <= 0:
    return (origin.x + distance, origin.y)
  var length = 1'i64
  while length * length < lengthSquared:
    inc length
  (origin.x + int(dx * int64(distance) div length),
    origin.y + int(dy * int64(distance) div length))

proc reproducedCases(): JsonNode =
  var rows = newJArray()

  block edgeRide:
    let gameMap = getBrMap("br-gen-505")
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (196, 20)
    let raw: BodyPoint = (196, 240)
    doAssert not map.rayClear(start, raw)
    rows.add(%*{"play": "edge_ride", "map": gameMap.name,
      "self": [start.x, start.y], "play_arithmetic": "220px margin clamp",
      "measurement": routeMeasurement(map, start, raw),
      "wrong_because": "the margin point is behind a wall",
      "better_choice": "score reachable candidates on the same margin band by route cost"})

  block supplyRun:
    let gameMap = getBrMap("br-gen-5040")
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (468, 1108)
    let chosen: BodyPoint = (553, 1435)
    let better: BodyPoint = (164, 1256)
    let chosenResult = routeMeasurement(map, start, chosen)
    let betterResult = routeMeasurement(map, start, better)
    doAssert straightDistance(start, chosen) < straightDistance(start, better)
    doAssert not map.rayClear(start, chosen) and map.rayClear(start, better)
    doAssert chosenResult["route_px"].getFloat() > betterResult["route_px"].getFloat()
    rows.add(%*{"play": "supply_run", "also_demonstrates": ["loot", "starter item_dist gate"],
      "map": gameMap.name, "self": [start.x, start.y],
      "play_arithmetic": "Euclidean-nearest visible medkit",
      "chosen": chosenResult, "better": betterResult,
      "wrong_because": "the 337.87px Euclidean medkit is behind a wall and routes 108.69px farther",
      "better_choice": "choose the minimum route-distance eligible item"})

  block jackal:
    let gameMap = getBrMap("br-gen-505")
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (140, 440)
    let enemy: BodyPoint = (86, 1195)
    let raw = projectTowardManhattan(enemy, start, 500)
    doAssert raw == (119, 729)
    let measured = routeMeasurement(map, start, raw)
    doAssert measured["snapped"][0].getInt() == 63
    rows.add(%*{"play": "jackal", "also_demonstrates": ["bodyguard"],
      "map": gameMap.name,
      "self": [start.x, start.y], "enemy": [enemy.x, enemy.y],
      "play_arithmetic": "500px Manhattan-normalized loiter projection",
      "measurement": measured,
      "wrong_because": "the projected point lands in wall; validation moves it 56px without preserving tactical exposure",
      "better_choice": "resolve a room/choke loiter goal with route and cover scoring"})

  block scatter:
    let gameMap = getBrMap("br-gen-505")
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (1149, 504)
    let enemy: BodyPoint = (870, 1017)
    let raw = projectAway(start, enemy, 320)
    doAssert raw == (1301, 223)
    let measured = routeMeasurement(map, start, raw)
    let roomIndex = measured["snapped_room"].getInt() - 1
    doAssert roomIndex >= 0 and map.roomAt(roomIndex).chokes.len == 1
    rows.add(%*{"play": "scatter", "also_demonstrates": ["crossfire"],
      "map": gameMap.name, "self": [start.x, start.y],
      "enemy": [enemy.x, enemy.y],
      "play_arithmetic": "320px Euclidean-normalized flee projection",
      "measurement": measured, "destination_room_chokes": 1,
      "wrong_because": "the flee vector enters a leaf room and turns 319.48px displacement into a 596.45px route",
      "better_choice": "score current and adjacent room peaks away from the threat; reject leaf-room regressions"})

  %*{"cases": rows,
    "not_applicable": {
      "pact": "targeting overlay; emits no destination",
      "target_law": "targeting overlay; emits no destination"
    }}

proc randomPoint(rng: var Rand; map: BodyMap): BodyPoint =
  (rng.rand(map.width - 1), rng.rand(map.height - 1))

proc randomRay(rng: var Rand; map: BodyMap; length: int):
    tuple[a, b: BodyPoint] =
  const directions = [(1, 0), (-1, 0), (0, 1), (0, -1),
    (1, 1), (1, -1), (-1, 1), (-1, -1)]
  result.a = rng.randomPoint(map)
  let direction = directions[rng.rand(directions.high)]
  let diagonal = direction[0] != 0 and direction[1] != 0
  let step = if diagonal: int(round(length.float / sqrt(2.0))) else: length
  result.b = (clamp(result.a.x + direction[0] * step, 0, map.width - 1),
    clamp(result.a.y + direction[1] * step, 0, map.height - 1))

proc clearRayOfLength(map: BodyMap; length: int): tuple[a, b: BodyPoint] =
  const directions = [(1, 0), (-1, 0), (0, 1), (0, -1),
    (1, 1), (1, -1), (-1, 1), (-1, -1)]
  for roomIndex in 0 ..< map.roomCount:
    let start = map.roomAt(roomIndex).peak
    for direction in directions:
      let diagonal = direction[0] != 0 and direction[1] != 0
      let step = if diagonal: int(round(length.float / sqrt(2.0))) else: length
      let finish = (start.x + direction[0] * step,
        start.y + direction[1] * step)
      if map.inBounds(finish) and map.rayClear(start, finish):
        return (start, finish)
  raise newException(ValueError,
    "giant query map has no clear ray of requested length " & $length)

proc benchmarkQueries(): JsonNode =
  let gameMap = loadBrMapPool()[0]
  let map = newBodyMap(gameMap)
  var rng = initRand(0x5A17)
  var points = newSeq[BodyPoint](QuerySamples)
  var rays331 = newSeq[tuple[a, b: BodyPoint]](QuerySamples)
  var rays1024 = newSeq[tuple[a, b: BodyPoint]](QuerySamples)
  for index in 0 ..< QuerySamples:
    points[index] = rng.randomPoint(map)
    rays331[index] = rng.randomRay(map, 331)
    rays1024[index] = rng.randomRay(map, 1024)
  let fullRay331 = map.clearRayOfLength(331)
  let fullRay1024 = map.clearRayOfLength(1024)

  var danger = BodyDangerField(values:
    newSeq[float32](map.gridWidth * map.gridHeight),
    gridW: map.gridWidth, gridH: map.gridHeight)
  for index in 0 ..< danger.values.len:
    danger.values[index] = float32((index mod 17).float / 17.0)

  let cache = newBodySeatCache(map)
  let minter = newBodyFieldMinter(map)
  var warmGoals: seq[BodyPoint]
  for index in 0 ..< min(4, map.roomCount):
    let goal = map.roomAt(index).peak
    warmGoals.add(goal)
    cache.mint(minter, goal, uint64(index + 1))

  var rows = newJArray()
  rows.add(timingRow("room_of", "random", timedSamples(QuerySamples,
    timingSink += map.roomLabelAt(points[measurementIndex]))))
  rows.add(timingRow("room_of", "adversarial_same_pixel", timedSamples(QuerySamples,
    timingSink += map.roomLabelAt((map.width div 2, map.height div 2)))))
  rows.add(timingRow("line_of_sight_331", "random", timedSamples(QuerySamples,
    block:
      if map.rayClear(rays331[measurementIndex].a, rays331[measurementIndex].b):
        inc timingSink)))
  rows.add(timingRow("line_of_sight_331", "max_length", timedSamples(QuerySamples,
    block:
      if map.rayClear(fullRay331.a, fullRay331.b):
        inc timingSink)))
  rows.add(timingRow("line_of_sight_1024", "random", timedSamples(QuerySamples,
    block:
      if map.rayClear(rays1024[measurementIndex].a,
          rays1024[measurementIndex].b):
        inc timingSink)))
  rows.add(timingRow("line_of_sight_1024", "max_length", timedSamples(QuerySamples,
    block:
      if map.rayClear(fullRay1024.a, fullRay1024.b):
        inc timingSink)))
  rows.add(timingRow("danger_at", "random", timedSamples(QuerySamples,
    timingSink += int64(danger.sample(map, points[measurementIndex]) * 1000))))
  rows.add(timingRow("danger_at", "adversarial_same_cell", timedSamples(QuerySamples,
    timingSink += int64(danger.sample(map,
      (map.width div 2, map.height div 2)) * 1000))))

  var misses = 0
  rows.add(timingRow("route_distance_current", "arbitrary_goal", timedSamples(QuerySamples,
    block:
      let found = cache.peekRouteDistance(points[measurementIndex],
        points[(measurementIndex * 7919 + 17) mod QuerySamples])
      if found.isSome:
        timingSink += int64(found.get)
      else:
        inc misses)))
  rows.add(timingRow("route_distance_current", "four_warm_goals", timedSamples(QuerySamples,
    block:
      let found = cache.peekRouteDistance(points[measurementIndex],
        warmGoals[measurementIndex mod warmGoals.len])
      if found.isSome:
        timingSink += int64(found.get))))
  rows.add(timingRow("nearest_choke", "random", timedSamples(QuerySamples,
    timingSink += map.nearestChokeIndex(points[measurementIndex]))))
  rows.add(timingRow("nearest_choke", "adversarial_same_pixel", timedSamples(QuerySamples,
    timingSink += map.nearestChokeIndex((map.width div 2, map.height div 2)))))

  %*{"map": gameMap.name, "width": map.width, "height": map.height,
    "rooms": map.roomCount, "chokes": map.chokeCount,
    "calls_per_shape": QuerySamples,
    "warm_route_slots": warmGoals.len,
    "arbitrary_route_misses": misses,
    "arbitrary_route_miss_rate": misses.float / QuerySamples.float,
    "max_length_ray_331": [[fullRay331.a.x, fullRay331.a.y],
      [fullRay331.b.x, fullRay331.b.y]],
    "max_length_ray_1024": [[fullRay1024.a.x, fullRay1024.a.y],
      [fullRay1024.b.x, fullRay1024.b.y]],
    "rows": rows,
    "existing_nearest_cover_p95_us": 13.3,
    "runtime_share_us": 4000,
    "timing_sink": timingSink}

proc putU16(bytes: var string; value: uint16) =
  bytes.add(char(value and 0xFF))
  bytes.add(char(value shr 8))

proc putU32(bytes: var string; value: uint32) =
  for shift in [0, 8, 16, 24]:
    bytes.add(char((value shr shift) and 0xFF))

proc putI32(bytes: var string; value: int32) =
  bytes.putU32(cast[uint32](value))

proc graphContext(rooms, chokes, adjacency: int): string =
  let sectionCount = 3
  let headerBytes = BinaryFrameHeaderBytes +
    sectionCount * BinarySectionEntryBytes
  let roomOffset = headerBytes
  let chokeOffset = roomOffset + rooms * RoomRecordBytes
  let adjacencyOffset = chokeOffset + chokes * ChokeRecordBytes
  let payloadEnd = adjacencyOffset + adjacency * AdjacencyRecordBytes
  let frameBytes = ceilDiv(payloadEnd, 4) * 4
  result = newStringOfCap(frameBytes)
  result.add("PV1\0")
  result.putU16(1)
  result.add(char(2))
  result.add(char(sectionCount))
  result.putU32(0)
  result.putU32(0)
  result.putU32(0)
  result.putU32(0)
  result.putU32(uint32(frameBytes))
  result.putU32(0)
  for entry in [(RoomSectionKind, rooms, RoomRecordBytes, roomOffset),
      (ChokeSectionKind, chokes, ChokeRecordBytes, chokeOffset),
      (AdjacencySectionKind, adjacency, AdjacencyRecordBytes, adjacencyOffset)]:
    result.putU16(entry[0])
    result.putU16(uint16(entry[1]))
    result.putU16(uint16(entry[2]))
    result.putU16(0)
    result.putU32(uint32(entry[3]))
  for index in 0 ..< rooms:
    result.putI32(int32(index * 7 + 1))
    result.putI32(int32(index * 11 + 2))
    result.putU16(uint16(8 + index mod 128))
    result.putU16(1)
    result.putI32(int32(100 + index * 13))
    result.putU16(uint16(min(adjacency, index * 2)))
    result.putU16(uint16(min(2, max(0, adjacency - index * 2))))
  for index in 0 ..< chokes:
    result.putI32(int32(index * 5 + 3))
    result.putI32(int32(index * 9 + 4))
    result.putU16(uint16(8 + index mod 128))
    result.putU16(uint16(index mod max(rooms, 1)))
    result.putU16(uint16((index + 1) mod max(rooms, 1)))
    result.putU16(0)
  for index in 0 ..< adjacency:
    result.putU16(uint16(index mod max(chokes, 1)))
  while result.len < frameBytes:
    result.add('\0')

proc bitmapContext(width, height, scale: int): string =
  let byteCount = ceilDiv(ceilDiv(width, scale) * ceilDiv(height, scale), 8)
  let sectionOffset = BinaryFrameHeaderBytes + BinarySectionEntryBytes
  let frameBytes = ceilDiv(sectionOffset + byteCount, 4) * 4
  result = newStringOfCap(frameBytes)
  result.add("PV1\0")
  result.putU16(1)
  result.add(char(2))
  result.add(char(1))
  result.putU32(0)
  result.putU32(0)
  result.putU32(0)
  result.putU32(0)
  result.putU32(uint32(frameBytes))
  result.putU32(0)
  result.putU16(BitmapSectionKind)
  result.putU16(uint16(byteCount))
  result.putU16(1)
  result.putU16(0)
  result.putU32(uint32(sectionOffset))
  for index in 0 ..< byteCount:
    result.add(char((index * 37 + 0x5A) and 0xFF))
  while result.len < frameBytes:
    result.add('\0')

when defined(spatialFuel):
  proc readModule(path: string): seq[byte] =
    let data = readFile(path)
    result = newSeq[byte](data.len)
    if data.len > 0:
      copyMem(addr result[0], unsafeAddr data[0], data.len)

  proc openMeterMap(): BodyMap =
    const Width = 720
    const Height = 96
    var walkable = newSeq[bool](Width * Height)
    for y in 1 ..< Height - 1:
      for x in 1 ..< Width - 1:
        walkable[y * Width + x] = true
    newBodyMap(walkable, Width, Height, 2, @[(30, 30), (680, 30)])

  proc fuelOne(modulePath, strategy, frameName: string; context: string): JsonNode =
    let engine = newRuntimeEngine()
    defer: engine.close()
    var validation = engine.validateUploadedModule(readModule(modulePath))
    defer: validation.close()
    if not validation.accepted:
      raise newException(ValueError, "fuel module rejected: " & validation.detail)
    var shell = newShellInstance(validation.module, openMeterMap(), (30, 30),
      ecOverlay, gmBr)
    defer: shell.close()
    let init = shell.invokeInit("{}", context)
    var stepFuel: int64 = -1
    var stepFault = ""
    if not init.faulted:
      let step = shell.invokeStep("{}", 1, (30, 30))
      stepFuel = int64(StepFuel.uint64 - step.fuelRemaining)
      stepFault = step.reason
    %*{"strategy": strategy, "frame": frameName,
      "context_bytes": context.len,
      "init_fuel": int64(InitFuel.uint64 - init.fuelRemaining),
      "init_fault": init.reason,
      "step_lookup_fuel": stepFuel,
      "step_fault": stepFault}

  proc fuelMeasurements(fullPath, rawPath: string): JsonNode =
    let pool = loadBrS2PoolRaw()
    var maxRow = (rooms: 0, chokes: 0, adjacency: 0, bytes: 0, name: "")
    var maxBitmap = (width: 0, height: 0, bytes: 0, name: "")
    for entry in pool:
      let map = newBodyMap(mapFromSpecJson($entry["spec"]))
      var adjacency = 0
      for index in 0 ..< map.roomCount:
        adjacency += map.roomAt(index).chokes.len
      let frame = graphContext(map.roomCount, map.chokeCount, adjacency)
      if frame.len > maxRow.bytes:
        maxRow = (map.roomCount, map.chokeCount, adjacency, frame.len,
          entry["name"].getStr())
      let bitmap = bitmapContext(map.width, map.height, 32)
      if bitmap.len > maxBitmap.bytes:
        maxBitmap = (map.width, map.height, bitmap.len,
          entry["name"].getStr())
    let colossalGameMap = generateCtfMap(4242, MapGenOverrides(
      size: "colossal", windows: -1, pits: -1, pitDensity: -1), teams = 2)
    let colossal = newBodyMap(colossalGameMap)
    var colossalAdjacency = 0
    for index in 0 ..< colossal.roomCount:
      colossalAdjacency += colossal.roomAt(index).chokes.len
    let poolFrame = graphContext(maxRow.rooms, maxRow.chokes, maxRow.adjacency)
    let colossalFrame = graphContext(colossal.roomCount, colossal.chokeCount,
      colossalAdjacency)
    let poolBitmap = bitmapContext(maxBitmap.width, maxBitmap.height, 32)
    let colossalBitmap = bitmapContext(colossal.width, colossal.height, 32)
    var rows = newJArray()
    for item in [("graph_pool_max:" & maxRow.name, poolFrame),
        ("graph_colossal:gen-colossal-seed-4242", colossalFrame),
        ("bitmap32_pool_max:" & maxBitmap.name, poolBitmap),
        ("bitmap32_colossal", colossalBitmap)]:
      rows.add(fuelOne(fullPath, "full_typed_decode", item[0], item[1]))
      rows.add(fuelOne(rawPath, "retain_raw_and_index", item[0], item[1]))
    %*{"full_module": fullPath, "raw_module": rawPath, "rows": rows}

proc gitHead(): string =
  execProcess("git", args = ["rev-parse", "HEAD"],
    options = {poUsePath}).strip()

proc main() =
  let args = commandLineParams()
  var output = %*{"tool": "spatial_surface_census", "repo_commit": gitHead(),
    "nim_version": NimVersion, "release": true}
  if args.len == 0 or "--all-pool-maps" in args:
    output["census"] = census()
    output["queries"] = benchmarkQueries()
    output["reproduced_cases"] = reproducedCases()
  elif args[0] == "--queries":
    output["queries"] = benchmarkQueries()
  elif args[0] == "--cases":
    output["reproduced_cases"] = reproducedCases()
  elif args[0] == "--fuel":
    when defined(spatialFuel):
      if args.len != 3:
        quit("usage: spatial_surface_census --fuel <full.wasm> <raw.wasm>", 1)
      output["fuel"] = fuelMeasurements(args[1], args[2])
    else:
      quit("--fuel requires -d:spatialFuel and WASMTIME_C_API", 1)
  else:
    quit("usage: spatial_surface_census [--all-pool-maps|--queries|--cases|--fuel full.wasm raw.wasm]", 1)
  echo pretty(output)

when isMainModule:
  main()
