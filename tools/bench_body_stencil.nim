## Optional stencil-backed half of the Season 2 body P0 benchmark.
## Compile only with --path:$STENCIL_LAB_DIR; see body_bench/README.md.

when not defined(release):
  {.error: "bench_body_stencil must be compiled with -d:release".}

import std/[algorithm, json, monotimes, options, os, osproc, strutils,
  tables, times, math]
import body_bench/[edt_probe, planner_adapter, stencil_adapter]
import ../src/ctf/arena as ctfArena
import ../src/ctf/sim_types as ctfTypes
import action as stencilAction
import belief_state as stencilBelief
import danger_field as stencilDanger
import fight as stencilFight
import nav as stencilNav
import types as stencilTypes
import worldmap as stencilMap

const DefaultStencilPin = "480120c2f5d2a13bc84917b6470b64e67372a752"

type
  Options = object
    selectedCase: string
    seeds: seq[int]
    warmups, samples: int
    output, stencilPin: string

  Scenario = object
    seed, width, height, teams, spawnPocketArea: int
    explicitSpawnPointsPresent: bool
    walkable: seq[bool]
    markers: Table[stencilTypes.Team, stencilTypes.EndzoneMarker]
    spawnPoints: seq[stencilTypes.Point]
    map: stencilMap.WorldMap

  QueryClass = object
    name: string
    point: stencilTypes.Point
    fromPoint: stencilTypes.Point
    radius: int

proc parseIntList(text: string): seq[int] =
  for item in text.split(','):
    result.add(parseInt(item.strip()))

proc parseOptions(): Options =
  result = Options(selectedCase: "all",
    seeds: @[4242, 14005, 23011, 41017, 65003], warmups: 5, samples: 50,
    stencilPin: DefaultStencilPin)
  let args = commandLineParams()
  var index = 0
  while index < args.len:
    if not args[index].startsWith("--"):
      raise newException(ValueError, "unexpected positional argument: " & args[index])
    let parts = args[index][2 .. ^1].split('=', 1)
    let key = parts[0]
    var value = if parts.len == 2: parts[1] else: ""
    if value.len == 0:
      inc index
      if index >= args.len:
        raise newException(ValueError, "missing value for --" & key)
      value = args[index]
    case key
    of "case": result.selectedCase = value
    of "seeds": result.seeds = parseIntList(value)
    of "warmups": result.warmups = parseInt(value)
    of "samples": result.samples = parseInt(value)
    of "output", "o": result.output = value
    of "stencil-pin": result.stencilPin = value
    else: raise newException(ValueError, "unknown option --" & key)
    inc index
  if result.warmups < 0 or result.samples <= 0 or result.seeds.len == 0:
    raise newException(ValueError, "warmups must be >= 0; samples and seeds must be nonzero")

proc verifyStencilPin(expected: string): tuple[dir, head: string] =
  result.dir = getEnv("STENCIL_LAB_DIR")
  if result.dir.len == 0:
    raise newException(ValueError,
      "STENCIL_LAB_DIR is required for stencil-backed benchmark cases")
  if not dirExists(result.dir):
    raise newException(ValueError, "STENCIL_LAB_DIR does not exist: " & result.dir)
  result.head = execProcess("git", args = ["-C", result.dir, "rev-parse", "HEAD"],
    options = {poUsePath}).strip()
  if result.head != expected:
    raise newException(ValueError,
      "stencil pin mismatch: expected " & expected & ", found " & result.head)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc measure(warmups, samples: int, body: proc() {.closure.}): seq[int64] =
  for _ in 0 ..< warmups: body()
  for _ in 0 ..< samples:
    let started = getMonoTime()
    body()
    result.add(elapsedNs(started))

proc percentile(samples: openArray[int64], fraction: float): int64 =
  var ordered = @samples
  ordered.sort()
  ordered[clamp(int(ceil(fraction * ordered.len.float)) - 1, 0, ordered.high)]

proc row(name: string, samples: seq[int64], details = newJObject()): JsonNode =
  %*{"name": name, "samples": samples.len, "median_ns": percentile(samples, 0.5),
    "p95_ns": percentile(samples, 0.95), "details": details}

proc stampRows(rows: var seq[JsonNode], map: stencilMap.WorldMap, seed: int) =
  for item in rows:
    item["details"]["seed"] = %seed
    item["details"]["map_width"] = %map.width
    item["details"]["map_height"] = %map.height
    item["details"]["grid_w"] = %map.gridW
    item["details"]["grid_h"] = %map.gridH

proc marker(shape: string, x0, y0, x1, y1: int): stencilTypes.EndzoneMarker =
  stencilTypes.EndzoneMarker(shape: shape, x0: x0, y0: y0, x1: x1, y1: y1)

proc buildMap(scenario: Scenario): stencilMap.WorldMap =
  stencilMap.newWorldMap(scenario.walkable, scenario.width, scenario.height,
    scenario.teams, scenario.markers, stencilTypes.Red)

proc syntheticWorld(): Scenario =
  const W = 96
  const H = 64
  var walkable = newSeq[bool](W * H)
  for y in 1 ..< H - 1:
    for x in 1 ..< W - 1:
      walkable[y * W + x] = not (x in 45 .. 50 and y notin 28 .. 35)
  result = Scenario(seed: 0, width: W, height: H, teams: 2, walkable: walkable,
    spawnPoints: @[(12, H div 2), (W - 13, H div 2)])
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 15, H - 1)
  result.markers[stencilTypes.Blue] = marker("box", W - 16, 0, W - 1, H - 1)
  result.map = result.buildMap()

proc generatedWorld(seed: int): Scenario =
  let gameMap = ctfArena.generateCtfMap(seed,
    ctfTypes.MapGenOverrides(size: "giant", windows: -1, pits: -1,
      pitDensity: -1), teams = 2)
  let masks = ctfArena.rasterizeWallMasks(gameMap,
    ctfArena.buildArenaObstacles(gameMap))
  var walkable = newSeq[bool](gameMap.width * gameMap.height)
  for index, wall in masks.maxWall:
    walkable[index] = not wall
  result = Scenario(seed: seed, width: gameMap.width, height: gameMap.height, teams: 2,
    walkable: walkable)
  let red = ctfArena.captureZone(gameMap, ctfTypes.Red)
  let blue = ctfArena.captureZone(gameMap, ctfTypes.Blue)
  result.markers[stencilTypes.Red] = marker(if red.disc: "disc" else: "box",
    red.xLo, red.yLo, red.xHi, red.yHi)
  result.markers[stencilTypes.Blue] = marker(if blue.disc: "disc" else: "box",
    blue.xLo, blue.yLo, blue.xHi, blue.yHi)
  if gameMap.spawnPoints.len > 0:
    for point in gameMap.spawnPoints:
      result.spawnPoints.add((point.x, point.y))
  else:
    let redSpawn = ctfArena.teamAnchor(gameMap, ctfTypes.Red)
    let blueSpawn = ctfArena.teamAnchor(gameMap, ctfTypes.Blue)
    result.spawnPoints = @[(redSpawn.x, redSpawn.y), (blueSpawn.x, blueSpawn.y)]
  result.map = result.buildMap()

proc generatedBrWorld(seed: int): Scenario =
  let gameMap = ctfArena.generateCtfMap(seed,
    ctfTypes.MapGenOverrides(size: "giant", windows: -1, pits: -1,
      pitDensity: -1), teams = 16)
  let masks = ctfArena.rasterizeWallMasks(gameMap,
    ctfArena.buildArenaObstacles(gameMap))
  var walkable = newSeq[bool](gameMap.width * gameMap.height)
  for index, wall in masks.maxWall: walkable[index] = not wall
  result = Scenario(seed: seed, width: gameMap.width, height: gameMap.height,
    teams: 2, walkable: walkable,
    explicitSpawnPointsPresent: gameMap.spawnPoints.len > 0,
    spawnPocketArea: (2 * gameMap.spawnClearW + 1) *
      (2 * gameMap.spawnClearH + 1))
  # Stencil has four team enum values. The component census is independent of
  # teams/endzones, so two synthetic markers let its exact map builder derive
  # clearance and four-connected components for this 16-team engine geometry.
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 20,
    gameMap.height - 1)
  result.markers[stencilTypes.Blue] = marker("box", gameMap.width - 21, 0,
    gameMap.width - 1, gameMap.height - 1)
  result.map = result.buildMap()

proc smokeBrWorld(): Scenario =
  result = syntheticWorld()
  result.spawnPocketArea = 13 * 13

proc makeWorld(options: Options, seed: int): Scenario =
  if options.selectedCase == "smoke": syntheticWorld() else: generatedWorld(seed)

proc standableEndpoints(map: stencilMap.WorldMap): tuple[a, b: stencilTypes.Point] =
  var component: uint16
  for index, label in map.component:
    if label != 0:
      component = label
      result.a = (index mod map.width, index div map.width)
      break
  if component == 0:
    raise newException(ValueError, "map has no standable component")
  for index in countdown(map.component.high, 0):
    if map.component[index] == component:
      result.b = (index mod map.width, index div map.width)
      return
  raise newException(ValueError, "standable component has no endpoint")

proc nsSamples(values: seq[float]): seq[int64] =
  for value in values: result.add(int64(value * 1_000_000.0))

proc episodeRows(options: Options, scenario: Scenario): seq[JsonNode] =
  var clearance, components, topology, cover, atlas, homeFields: seq[float]
  var total: seq[int64]
  var last: stencilMap.WorldMap
  for iteration in 0 ..< options.warmups + options.samples:
    let started = getMonoTime()
    let built = scenario.buildMap()
    let elapsed = elapsedNs(started)
    if iteration >= options.warmups:
      clearance.add(built.clearanceMs)
      components.add(built.componentMs)
      topology.add(built.topologyMs)
      cover.add(built.coverMs)
      atlas.add(built.atlasMs)
      var dijkstraSum = 0.0
      for value in built.dijkstraMs: dijkstraSum += value
      homeFields.add(dijkstraSum)
      total.add(elapsed)
    last = built
  let facts = %*{"width": last.width, "height": last.height,
    "grid_w": last.gridW, "grid_h": last.gridH,
    "components": last.componentCount, "rooms": last.rooms.len,
    "chokes": last.chokes.len, "atlas_posts": last.postAtlas.len,
    "home_field_count": last.dijkstraMs.len}
  result.add(row("episode.clearance_walkability", nsSamples(clearance), facts))
  result.add(row("episode.components", nsSamples(components), facts))
  result.add(row("episode.topology", nsSamples(topology), facts))
  result.add(row("episode.cover_dirs", nsSamples(cover), facts))
  result.add(row("episode.post_atlas", nsSamples(atlas), facts))
  result.add(row("episode.home_dijkstra_sum", nsSamples(homeFields), facts))
  result.add(row("episode.complete_barrier", total, facts))

proc distinctSpawnComponents(scenario: Scenario): seq[tuple[
    component: uint16, fromPoint: stencilTypes.Point]] =
  for point in scenario.spawnPoints:
    let component = uint16(scenario.map.componentOf(point))
    if component == 0:
      raise newException(ValueError, "spawn point is not standable: " & $point)
    var seen = false
    for item in result:
      if item.component == component: seen = true
    if not seen: result.add((component, point))

proc firstPointWith(map: stencilMap.WorldMap,
                    predicate: proc(label: uint16): bool {.closure.}): stencilTypes.Point =
  for index, label in map.component:
    if predicate(label): return (index mod map.width, index div map.width)
  raise newException(ValueError, "requested validator query class is absent")

proc findEqualTie(map: stencilMap.WorldMap, table: EdtTable,
                  component: uint16): stencilTypes.Point =
  for index, label in map.component:
    if label == component: continue
    let distance = table.distances[index]
    if distance == 0 or distance > 4096: continue
    let point = (x: index mod map.width, y: index div map.width)
    let radius = int(ceil(sqrt(distance.float64)))
    var matches = 0
    for y in max(0, point.y - radius) .. min(map.height - 1, point.y + radius):
      for x in max(0, point.x - radius) .. min(map.width - 1, point.x + radius):
        let dx = x - point.x
        let dy = y - point.y
        if map.component[y * map.width + x] == component and
            uint32(dx * dx + dy * dy) == distance:
          inc matches
          if matches == 2: return point
  raise newException(ValueError, "equal-distance tie query is absent")

proc radiusScenario(): Scenario =
  ## Two disconnected rooms and a long void pin the 256/257px boundaries.
  const W = 720
  const H = 96
  var walkable = newSeq[bool](W * H)
  for y in 1 ..< H - 1:
    for x in 1 .. 100: walkable[y * W + x] = true
    for x in 600 ..< W - 1: walkable[y * W + x] = true
  result = Scenario(width: W, height: H, teams: 2, walkable: walkable,
    spawnPoints: @[(30, 30), (650, 30)])
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 20, H - 1)
  result.markers[stencilTypes.Blue] = marker("box", W - 21, 0, W - 1, H - 1)
  result.map = result.buildMap()

proc tieScenario(): Scenario =
  ## A U-shaped room makes the void midpoint equidistant from both arms while
  ## both candidate pixels remain in one four-connected component.
  const W = 104
  const H = 104
  var walkable = newSeq[bool](W * H)
  for y in 1 ..< H - 1:
    for x in 1 .. 28: walkable[y * W + x] = true
    for x in 74 ..< W - 1: walkable[y * W + x] = true
  for y in 72 ..< H - 1:
    for x in 1 ..< W - 1: walkable[y * W + x] = true
  result = Scenario(width: W, height: H, teams: 2, walkable: walkable,
    spawnPoints: @[(16, 32), (88, 32)])
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 20, H - 1)
  result.markers[stencilTypes.Blue] = marker("box", W - 21, 0, W - 1, H - 1)
  result.map = result.buildMap()

proc compareQuery(map: stencilMap.WorldMap, table: EdtTable,
                  query: QueryClass): tuple[ringFailure, stencilFailure: int,
                    edtNs, stencilNs: int64] =
  let edtStarted = getMonoTime()
  let edtAnswer = table.resolveNearest(query.point, query.radius)
  result.edtNs = elapsedNs(edtStarted)
  let ringAnswer = ringNearest(map.component, map.width, map.height,
    table.component, query.point, query.radius)
  let stencilStarted = getMonoTime()
  let stencilAnswer = map.nearestReachable(query.point, query.fromPoint, query.radius)
  result.stencilNs = elapsedNs(stencilStarted)
  let
    normalizedStencil = if stencilAnswer.isSome:
      some((x: stencilAnswer.get.x, y: stencilAnswer.get.y)) else: none(PixelPoint)
  result.ringFailure = ord(edtAnswer != ringAnswer)
  result.stencilFailure = ord(edtAnswer != normalizedStencil)

proc validatorRows(options: Options, scenario: Scenario): seq[JsonNode] =
  let map = scenario.map
  let spawnComponents = distinctSpawnComponents(scenario)
  var tables: seq[EdtTable]
  let occupiedBefore = getOccupiedMem()
  let totalBefore = getTotalMem()
  var totalLogicalBytes = 0
  for item in spawnComponents:
    let component = item.component
    var table: EdtTable
    let builds = measure(options.warmups, options.samples,
      proc() = table = buildEdt(map.component, map.width, map.height, component))
    totalLogicalBytes += table.distances.len * sizeof(uint32)
    tables.add(table)
    result.add(row("validator.edt_component_" & $component, builds,
      %*{"component": component,
        "logical_bytes": table.distances.len * sizeof(uint32)}))
  let occupiedDelta = max(0, getOccupiedMem() - occupiedBefore)
  let totalDelta = max(0, getTotalMem() - totalBefore)
  result.add(%*{"name": "validator.edt_total", "samples": 1,
    "median_ns": 0, "p95_ns": 0, "details": {
      "distinct_spawn_components": spawnComponents.len,
      "logical_bytes": totalLogicalBytes,
      "allocator_occupied_delta": occupiedDelta,
      "allocator_total_delta": totalDelta,
      "cap_bytes": 268435456,
      "within_cap": totalLogicalBytes <= 268435456}})

  var classCounts = initCountTable[string]()
  var ringFailures = 0
  var stencilFailures = 0
  var edtLookupSamples, stencilOracleSamples: seq[int64]
  let repetitions = if options.selectedCase == "smoke": 1 else: 1667
  for tableIndex, table in tables:
    let fromPoint = spawnComponents[tableIndex].fromPoint
    var queries = @[
      QueryClass(name: "standable_site", point: fromPoint,
        fromPoint: fromPoint, radius: 256),
      QueryClass(name: "blocked_point",
        point: map.firstPointWith(proc(label: uint16): bool = label == 0),
        fromPoint: fromPoint, radius: 256),
      QueryClass(name: "map_edge", point: (0, 0),
        fromPoint: fromPoint, radius: 256)]
    var otherPoint = fromPoint
    for other in spawnComponents:
      if other.component != table.component: otherPoint = other.fromPoint
    if otherPoint != fromPoint:
      queries.add(QueryClass(name: "nearer_other_component", point: otherPoint,
        fromPoint: fromPoint, radius: 256))
    for _ in 0 ..< repetitions:
      for query in queries:
        classCounts.inc(query.name)
        let compared = compareQuery(map, table, query)
        ringFailures += compared.ringFailure
        stencilFailures += compared.stencilFailure
        edtLookupSamples.add(compared.edtNs)
        stencilOracleSamples.add(compared.stencilNs)

  # Dedicated same-oracle geometry guarantees the two exact radius boundaries
  # even when a generated map has no wall 256 pixels thick.
  let radiusCase = radiusScenario()
  let radiusFrom = radiusCase.spawnPoints[0]
  let radiusComponent = uint16(radiusCase.map.componentOf(radiusFrom))
  let radiusTable = buildEdt(radiusCase.map.component, radiusCase.width,
    radiusCase.height, radiusComponent)
  # The rightmost standable pixel of the left room is x=94 after the 6px
  # footprint erosion, so x=350 and x=351 are exactly 256 and 257 pixels away.
  for query in [
      QueryClass(name: "exact_radius_256", point: (350, 30),
        fromPoint: radiusFrom, radius: 256),
      QueryClass(name: "one_past_radius_256", point: (351, 30),
        fromPoint: radiusFrom, radius: 256),
      QueryClass(name: "nearer_other_component", point: radiusCase.spawnPoints[1],
        fromPoint: radiusFrom, radius: 256)]:
    for _ in 0 ..< repetitions:
      classCounts.inc(query.name)
      let compared = compareQuery(radiusCase.map, radiusTable, query)
      ringFailures += compared.ringFailure
      stencilFailures += compared.stencilFailure
      edtLookupSamples.add(compared.edtNs)
      stencilOracleSamples.add(compared.stencilNs)
  let tieCase = tieScenario()
  let tieFrom = tieCase.spawnPoints[0]
  let tieComponent = uint16(tieCase.map.componentOf(tieFrom))
  let tieTable = buildEdt(tieCase.map.component, tieCase.width, tieCase.height,
    tieComponent)
  let tieQuery = QueryClass(name: "equal_distance_tie",
    point: tieCase.map.findEqualTie(tieTable, tieComponent),
    fromPoint: tieFrom, radius: 256)
  for _ in 0 ..< repetitions:
    classCounts.inc(tieQuery.name)
    let tieCompared = compareQuery(tieCase.map, tieTable, tieQuery)
    ringFailures += tieCompared.ringFailure
    stencilFailures += tieCompared.stencilFailure
    edtLookupSamples.add(tieCompared.edtNs)
    stencilOracleSamples.add(tieCompared.stencilNs)
  if ringFailures != 0 or stencilFailures != 0:
    raise newException(ValueError, "EDT parity failures: ring=" & $ringFailures &
      ", stencil=" & $stencilFailures)
  var classesNode = newJObject()
  for name, count in classCounts.pairs: classesNode[name] = %count
  result.add(%*{"name": "validator.parity", "samples": 1,
    "median_ns": 0, "p95_ns": 0, "details": {
      "classes": classesNode, "ring_failures": ringFailures,
      "stencil_failures": stencilFailures}})
  result.add(row("validator.edt_lookup", edtLookupSamples,
    %*{"classes": classesNode}))
  result.add(row("validator.stencil_ring_oracle", stencilOracleSamples,
    %*{"classes": classesNode}))

proc brValidatorRows(options: Options, seed: int): seq[JsonNode] =
  let scenario = if options.selectedCase == "smoke": smokeBrWorld()
    else: generatedBrWorld(seed)
  let map = scenario.map
  var pixelsByComponent = initCountTable[uint16]()
  for component in map.component:
    if component != 0: pixelsByComponent.inc(component)
  var eligible: seq[tuple[component: uint16, pixels: int]]
  var restPixels = 0
  var restComponents = 0
  for component, pixels in pixelsByComponent.pairs:
    if pixels >= scenario.spawnPocketArea:
      eligible.add((component, pixels))
    else:
      inc restComponents
      restPixels += pixels
  eligible.sort(proc(a, b: tuple[component: uint16, pixels: int]): int =
    result = cmp(b.pixels, a.pixels)
    if result == 0: result = cmp(a.component, b.component))
  var eligibleNode = newJArray()
  for item in eligible:
    eligibleNode.add(%*{"component": item.component, "pixels": item.pixels})
  let
    bytesPerTable = map.width * map.height * sizeof(uint32)
    upperBoundBytes = eligible.len * bytesPerTable
    capBytes = 268435456
    buildCount = min(16, eligible.len)
  result.add(%*{"name": "validator.br_census", "samples": 1,
    "median_ns": 0, "p95_ns": 0, "details": {
      "engine_team_count": 16,
      "spawn_points_present_on_main": scenario.explicitSpawnPointsPresent,
      "spawn_pocket_area_pixels": scenario.spawnPocketArea,
      "total_standable_components": pixelsByComponent.len,
      "census_components": eligibleNode,
      "census_count": eligible.len,
      "rest_component_count": restComponents,
      "rest_pixels": restPixels,
      "edt_components_built": buildCount,
      "edt_largest_n_requested": 16,
      "edt_bytes_per_component": bytesPerTable,
      "upper_bound_bytes": upperBoundBytes,
      "cap_bytes": capBytes,
      "upper_bound_within_cap": upperBoundBytes <= capBytes,
      "bound_kind": "upper bound — real BR spawn placement lands with the branch merge; spawn-hosting components cannot exceed the census"}})
  for index in 0 ..< buildCount:
    let component = eligible[index].component
    var table: EdtTable
    let builds = measure(options.warmups, options.samples,
      proc() = table = buildEdt(map.component, map.width, map.height, component))
    result.add(row("validator.br_edt_" & $(index + 1), builds,
      %*{"component": component, "component_pixels": eligible[index].pixels,
        "logical_bytes": table.distances.len * sizeof(uint32),
        "rank_by_component_pixels": index + 1}))
  result.stampRows(map, seed)

proc componentPoints(map: stencilMap.WorldMap,
                     component: uint16): seq[stencilTypes.Point] =
  for index, label in map.component:
    if label == component: result.add((index mod map.width, index div map.width))

proc fallbackScenario(centerY: int): Scenario =
  const W = 96
  const H = 32
  var walkable = newSeq[bool](W * H)
  for y in centerY - 6 .. centerY + 6:
    for x in 1 ..< W - 1: walkable[y * W + x] = true
  result = Scenario(width: W, height: H, teams: 2, walkable: walkable,
    spawnPoints: @[(12, centerY), (W - 13, centerY)])
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 20, H - 1)
  result.markers[stencilTypes.Blue] = marker("box", W - 21, 0, W - 1, H - 1)
  result.map = result.buildMap()

proc plannerRows(options: Options, scenario: Scenario): seq[JsonNode] =
  let map = scenario.map
  let endpoints = standableEndpoints(map)
  let component = uint16(map.componentOf(endpoints.a))
  let points = componentPoints(map, component)
  if points.len < 4:
    raise newException(ValueError, "planner component has too few points")
  let centerGoal = map.nearestReachable(map.center, endpoints.a, 256).get(
    points[points.len div 2])
  var rankedGoals: seq[tuple[distance: float, point: stencilTypes.Point]]
  for gy in 0 ..< map.gridH:
    for gx in 0 ..< map.gridW:
      let point = stencilMap.cellCenter((gx, gy))
      if uint16(map.componentOf(point)) == component:
        rankedGoals.add((map.routeDistance(point, endpoints.a), point))
  rankedGoals.sort(proc(a, b: tuple[distance: float,
      point: stencilTypes.Point]): int =
    result = cmp(a.distance, b.distance)
    if result == 0: result = cmp(a.point.y * map.width + a.point.x,
      b.point.y * map.width + b.point.x))
  let typicalPairs = @[
    (name: "spawn_to_center", start: endpoints.a, goal: centerGoal),
    (name: "goal_quartile_25", start: endpoints.a,
      goal: rankedGoals[rankedGoals.len div 4].point),
    (name: "goal_quartile_50", start: endpoints.a,
      goal: rankedGoals[rankedGoals.len div 2].point),
    (name: "goal_quartile_75", start: endpoints.a,
      goal: rankedGoals[(rankedGoals.len * 3) div 4].point)]
  for pair in typicalPairs:
    let pairName = pair.name
    let pairStart = pair.start
    let pairGoal = pair.goal
    var planned: planner_adapter.PlanResult
    let samples = measure(options.warmups, options.samples,
      proc() =
        var state: planner_adapter.PlannerState
        planned = state.benchmarkPlanPath(map, stencilDanger.DangerField(),
          pairStart, pairGoal))
    result.add(row("planner.typical_" & pairName, samples,
      %*{"expansions": planned.expansions, "path_points": planned.path.len,
        "fallback_step": planned.fallbackStep}))

  let candidates = @[points[0], points[points.len div 4],
    points[points.len div 2], points[(points.len * 3) div 4], points[^1]]
  var worstStart = candidates[0]
  var worstGoal = candidates[^1]
  var worstExpansions = -1
  for start in candidates:
    for goal in candidates:
      if start == goal: continue
      var state: planner_adapter.PlannerState
      let planned = state.benchmarkPlanPath(map, stencilDanger.DangerField(),
        start, goal)
      if planned.expansions > worstExpansions:
        worstExpansions = planned.expansions
        worstStart = start
        worstGoal = goal
  var worstPlan: planner_adapter.PlanResult
  var worstWorkspace: planner_adapter.PlannerWorkspaceStats
  let worstSamples = measure(options.warmups, options.samples,
    proc() =
      var state: planner_adapter.PlannerState
      worstPlan = state.benchmarkPlanPath(map, stencilDanger.DangerField(),
        worstStart, worstGoal)
      worstWorkspace = state.benchmarkWorkspaceStats())
  result.add(row("planner.worst_cold", worstSamples,
    %*{"start": [worstStart.x, worstStart.y], "goal": [worstGoal.x, worstGoal.y],
      "expansions": worstPlan.expansions, "path_points": worstPlan.path.len,
      "workspace_bytes": worstWorkspace.totalBytes,
      "lattice_w": worstWorkspace.latticeW, "lattice_h": worstWorkspace.latticeH,
      "seen_bytes": worstWorkspace.seenBytes,
      "closed_bytes": worstWorkspace.closedBytes,
      "score_bytes": worstWorkspace.scoreBytes,
      "came_from_bytes": worstWorkspace.cameFromBytes,
      "heap_bytes": worstWorkspace.heapBytes}))

  let missScenario = syntheticWorld()
  var missState: planner_adapter.PlannerState
  let missPlan = missState.benchmarkPlanPath(missScenario.map,
    stencilDanger.DangerField(), missScenario.spawnPoints[0],
    missScenario.spawnPoints[1])
  result.add(%*{"name": "planner.oracle_miss", "samples": 1,
    "median_ns": int64(missPlan.elapsedMs * 1_000_000),
    "p95_ns": int64(missPlan.elapsedMs * 1_000_000),
    "details": {"path_points": missPlan.path.len,
      "expansions": missPlan.expansions}})
  for expectedCenter in [10, 11]:
    let fallback = fallbackScenario(expectedCenter)
    let fallbackEndpoints = standableEndpoints(fallback.map)
    var fallbackState: planner_adapter.PlannerState
    let fallbackPlan = fallbackState.benchmarkPlanPath(fallback.map,
      stencilDanger.DangerField(), fallbackEndpoints.a, fallbackEndpoints.b)
    let expectedStep = if expectedCenter == 10: 2 else: 1
    if fallbackPlan.fallbackStep != expectedStep:
      raise newException(ValueError, "planner fallback fixture expected step " &
        $expectedStep & ", got " & $fallbackPlan.fallbackStep)
    result.add(%*{"name": "planner.fallback_step_" &
      $expectedStep, "samples": 1,
      "median_ns": int64(fallbackPlan.elapsedMs * 1_000_000),
      "p95_ns": int64(fallbackPlan.elapsedMs * 1_000_000),
      "details": {"fallback_step": fallbackPlan.fallbackStep,
        "expansions": fallbackPlan.expansions,
        "path_points": fallbackPlan.path.len}})

proc followerRows(options: Options, map: stencilMap.WorldMap): seq[JsonNode] =
  let endpoints = standableEndpoints(map)
  var states = newSeq[stencilNav.NavState](32)
  for state in states.mitems:
    discard state.astarWaypoint(map, endpoints.a, endpoints.b)
  let samples = measure(options.warmups, options.samples,
    proc() =
      for state in states.mitems:
        discard state.astarWaypoint(map, endpoints.a, endpoints.b))
  result.add(row("follower.batch32", samples))

proc dangerRows(options: Options, map: stencilMap.WorldMap): seq[JsonNode] =
  let endpoints = standableEndpoints(map)
  let component = uint16(map.componentOf(endpoints.a))
  let points = componentPoints(map, component)
  for sourceCount in [4, 8, 16, 31]:
    var sources: seq[stencilTypes.Point]
    for index in 0 ..< sourceCount:
      sources.add(points[(index * max(1, points.len div sourceCount)) mod points.len])
    var field: stencilDanger.DangerField
    let perField = measure(options.warmups, options.samples,
      proc() = field.rebuildLosDanger(map, sources))
    result.add(row("danger.sources_" & $sourceCount, perField,
      %*{"sources": sourceCount, "headline": sourceCount == 8,
        "cap_stress": sourceCount == 31, "cadence_ticks": 12,
        "cadence_amortized_p95_ns": percentile(perField, 0.95) div 12}))
    var fields = newSeq[stencilDanger.DangerField](32)
    let batch = measure(options.warmups, options.samples,
      proc() =
        for item in fields.mitems: item.rebuildLosDanger(map, sources))
    result.add(row("danger.batch32_sources_" & $sourceCount, batch,
      %*{"sources": sourceCount, "cadence_ticks": 12,
        "cadence_amortized_p95_ns": percentile(batch, 0.95) div 12}))

proc makeBelief(map: stencilMap.WorldMap, enemyCount = 8): stencilBelief.Belief =
  result = stencilBelief.newBelief(0)
  result.worldmap = map
  let origin = standableEndpoints(map).a
  result.selfXy = some(origin)
  result.alive = true
  result.fireReady = true
  result.firefightActive = true
  result.aimBrads = 0
  for index in 0 ..< enemyCount:
    result.enemies.add(stencilTypes.Enemy(
      pos: (min(map.width - 8, origin.x + 16 + index * 2),
        min(map.height - 8, origin.y + index)),
      facing: stencilTypes.FacingLeft, aimBrads: some(128),
      color: stencilTypes.Blue, identity: some(index + 1),
      hpSegments: some(10 - index mod 4), weapon: stencilTypes.WeaponGun))

proc targetingRows(options: Options, map: stencilMap.WorldMap): seq[JsonNode] =
  for enemyCount in [4, 8, 16, 31]:
    let belief = makeBelief(map, enemyCount)
    var candidates: seq[stencilTypes.TargetCandidate]
    let buildSamples = measure(options.warmups, options.samples,
      proc() = candidates = benchmarkTargetCandidates(belief))
    let selectSamples = measure(options.warmups, options.samples,
      proc() = discard belief.selectTarget(candidates))
    let combinedSamples = measure(options.warmups, options.samples,
      proc() =
        candidates = benchmarkTargetCandidates(belief)
        discard belief.selectTarget(candidates))
    var beliefs: seq[stencilBelief.Belief]
    for _ in 0 ..< 32: beliefs.add(makeBelief(map, enemyCount))
    let batchSamples = measure(options.warmups, options.samples,
      proc() =
        for item in beliefs:
          let batchCandidates = benchmarkTargetCandidates(item)
          discard item.selectTarget(batchCandidates))
    let details = %*{"enemies": enemyCount, "candidates": candidates.len,
      "headline": enemyCount == 8, "cap_stress": enemyCount == 31}
    result.add(row("targeting.candidates_" & $enemyCount, buildSamples, details))
    result.add(row("targeting.select_" & $enemyCount, selectSamples, details))
    result.add(row("targeting.combined_" & $enemyCount, combinedSamples, details))
    result.add(row("targeting.batch32_" & $enemyCount, batchSamples, details))

proc actionWorld(): stencilMap.WorldMap =
  const W = 640
  const H = 320
  var walkable = newSeq[bool](W * H)
  for y in 1 ..< H - 1:
    for x in 1 ..< W - 1: walkable[y * W + x] = true
  var markers: Table[stencilTypes.Team, stencilTypes.EndzoneMarker]
  markers[stencilTypes.Red] = marker("box", 0, 0, 20, H - 1)
  markers[stencilTypes.Blue] = marker("box", W - 21, 0, W - 1, H - 1)
  stencilMap.newWorldMap(walkable, W, H, 2, markers, stencilTypes.Red)

proc configureAction(name: string, map: stencilMap.WorldMap): tuple[
    belief: stencilBelief.Belief, intent: stencilTypes.Intent,
    state: stencilTypes.ActionState] =
  let endpoints = standableEndpoints(map)
  result.belief = makeBelief(map, if name in ["hold", "navigate", "corridor_reject"]: 0 else: 2)
  result.belief.selfXy = some((100, map.height div 2))
  result.intent = stencilTypes.Intent(kind: stencilTypes.NavigateTo,
    point: some((300, map.height div 2)), idleAimCenterBrads: some(0),
    arriveRadius: 4.0, profile: stencilTypes.ProfileDefault)
  case name
  of "hold":
    result.intent.kind = stencilTypes.Hold
    result.intent.point = none(stencilTypes.Point)
  of "navigate": discard
  of "gun_fire":
    result.belief.enemies[0].pos = (130, map.height div 2)
    result.belief.enemies.setLen(1)
  of "spray_fire":
    result.belief.iHaveArc = true
    result.belief.enemies[0].pos = (130, map.height div 2)
    result.belief.enemies.setLen(1)
  of "grenade_charge":
    result.belief.iHaveGrenade = true
    result.belief.enemies[0].pos = (190, map.height div 2)
    result.belief.enemies[1].pos = (195, map.height div 2)
  of "grenade_release":
    result.belief.iHaveGrenade = true
    result.belief.enemies[0].pos = (190, map.height div 2)
    result.belief.enemies.setLen(1)
    result.belief.throwChargeTicks = 24
    result.belief.throwTarget = some((190, map.height div 2))
    result.belief.throwReason = "group"
    result.belief.throwEnemyCount = 1
    result.belief.throwLiveTarget = true
  of "corridor_reject":
    result.intent.micro = {stencilTypes.MicroFormationBias}
    result.belief.teammates = @[stencilTypes.Enemy(
      pos: (100, map.height div 2 - 2), facing: stencilTypes.FacingRight,
      color: stencilTypes.Red)]
    result.belief.nav.path = @[(100, map.height div 2), (200, map.height div 2),
      (300, map.height div 2)]
    result.belief.nav.hasPath = true
    result.belief.nav.goal = result.intent.point
    result.belief.nav.profileSet = true
  else: raise newException(ValueError, "unknown action scenario " & name)
  discard endpoints

proc actionRows(options: Options, ignoredMap: stencilMap.WorldMap): seq[JsonNode] =
  discard ignoredMap
  let map = actionWorld()
  let names = ["hold", "navigate", "gun_fire", "spray_fire",
    "grenade_charge", "grenade_release", "corridor_reject"]
  for nameIndex in 0 ..< names.len:
    let name = names[nameIndex]
    var probe = configureAction(name, map)
    let probeMask = stencilAction.resolveAction(probe.intent,
      probe.belief, probe.state).heldMask
    if name in ["gun_fire", "spray_fire"] and
        (probeMask and 32'u8) == 0:
      raise newException(ValueError, name & " did not engage its weapon")
    if name == "grenade_charge" and (probeMask and 128'u8) == 0:
      raise newException(ValueError, "grenade charge did not hold ButtonC")
    if name == "grenade_release" and (probeMask and 128'u8) != 0:
      raise newException(ValueError, "grenade release remained charged")
    if name == "corridor_reject" and probe.belief.nav.microCorridorRejects == 0:
      raise newException(ValueError, "corridor rejection scenario did not reject")
    var runs: seq[tuple[belief: stencilBelief.Belief,
      intent: stencilTypes.Intent, state: stencilTypes.ActionState]]
    for _ in 0 ..< options.warmups + options.samples:
      runs.add(configureAction(name, map))
    var cursor = 0
    var mask = 0'u8
    let samples = measure(options.warmups, options.samples,
      proc() =
        mask = stencilAction.resolveAction(runs[cursor].intent,
          runs[cursor].belief, runs[cursor].state).heldMask
        inc cursor)
    result.add(row("action." & name, samples,
      %*{"held_mask": mask,
        "corridor_rejections": runs[^1].belief.nav.microCorridorRejects}))
  var batchRuns: seq[tuple[belief: stencilBelief.Belief,
    intent: stencilTypes.Intent, state: stencilTypes.ActionState]]
  for iteration in 0 ..< (options.warmups + options.samples) * 32:
    batchRuns.add(configureAction(names[iteration mod names.len], map))
  var batchCursor = 0
  let batchSamples = measure(options.warmups, options.samples,
    proc() =
      for _ in 0 ..< 32:
        discard stencilAction.resolveAction(batchRuns[batchCursor].intent,
          batchRuns[batchCursor].belief, batchRuns[batchCursor].state)
        inc batchCursor)
  result.add(row("action.mixed_batch32", batchSamples,
    %*{"scenarios": names.len}))
  result.stampRows(map, 0)

proc routeRows(options: Options, map: stencilMap.WorldMap): seq[JsonNode] =
  let endpoints = standableEndpoints(map)
  let component = uint16(map.componentOf(endpoints.a))
  var goals: seq[stencilTypes.Point]
  for gy in 0 ..< map.gridH:
    for gx in 0 ..< map.gridW:
      let point = stencilMap.cellCenter((gx, gy))
      if uint16(map.componentOf(point)) == component: goals.add(point)
  var coldSamples, dijkstraSamples: seq[int64]
  var lastGoal = endpoints.b
  var goalIndex = 0
  while coldSamples.len < options.samples and goalIndex < goals.len:
    let before = map.dijkstraMs.len
    let started = getMonoTime()
    discard map.routeDistance(endpoints.a, goals[goalIndex])
    let elapsed = elapsedNs(started)
    if map.dijkstraMs.len > before:
      coldSamples.add(elapsed)
      dijkstraSamples.add(int64(map.dijkstraMs[^1] * 1_000_000.0))
      lastGoal = goals[goalIndex]
    inc goalIndex
  if coldSamples.len != options.samples:
    raise newException(ValueError, "not enough distinct route-field goal keys")
  var distance = 0.0
  let warmSamples = measure(options.warmups, options.samples,
    proc() = distance = map.routeDistance(endpoints.a, lastGoal))
  let fields = map.cachedRouteFields
  var reachable = 0
  for value in fields[^1].distances:
    if value.classify notin {fcInf, fcNegInf, fcNan}: inc reachable
  let details = %*{"distance": distance, "fresh_goals": coldSamples.len,
    "reachable_cells": reachable, "cached_fields": fields.len,
    "dijkstra_median_ns": percentile(dijkstraSamples, 0.5),
    "dijkstra_p95_ns": percentile(dijkstraSamples, 0.95)}
  result.add(row("route_field.cold_mint", coldSamples, details))
  result.add(row("route_field.warm_lookup", warmSamples, details))

proc duckRows(options: Options, map: stencilMap.WorldMap): seq[JsonNode] =
  if map.postAtlas.len == 0:
    raise newException(ValueError, "map has no atlas post for duck benchmark")
  var duck: stencilMap.DuckResult
  let cold = measure(0, 1, proc() = duck = map.duckFor(0))
  let warm = measure(options.warmups, options.samples,
    proc() = duck = map.duckFor(0))
  result.add(row("duck.cold", cold, %*{"atlas_posts": map.postAtlas.len}))
  result.add(row("duck.warm", warm, %*{"x": duck.pos.x, "y": duck.pos.y}))

type SeatMemory = object
  routeDistances: seq[seq[float]]
  routeHops: seq[seq[uint8]]
  ducks: seq[stencilMap.DuckResult]
  planner: planner_adapter.PlannerState
  danger: stencilDanger.DangerField

proc cloneSeq[T](source: seq[T]): seq[T] =
  result = newSeq[T](source.len)
  for index, value in source: result[index] = value

proc memoryRows(inputMap: stencilMap.WorldMap): seq[JsonNode] =
  let map = if inputMap.postAtlas.len >= 256: inputMap else: actionWorld()
  let endpoints = standableEndpoints(map)
  let component = uint16(map.componentOf(endpoints.a))
  let points = componentPoints(map, component)
  for fraction in [1, 2, 3, 4]:
    discard map.routeDistance(endpoints.a, points[(points.len * fraction) div 5])
  let allFields = map.cachedRouteFields
  if allFields.len < 4:
    raise newException(ValueError, "memory benchmark could not mint four route fields")
  let firstField = max(0, allFields.len - 4)
  var duckTemplates: seq[stencilMap.DuckResult]
  for index in 0 ..< 256:
    duckTemplates.add(map.duckFor(index))
  if map.cachedDuckCount < 256:
    raise newException(ValueError, "memory benchmark did not mint 256 duck entries")

  proc allocateSeat(): SeatMemory =
    for index in firstField ..< allFields.len:
      result.routeDistances.add(cloneSeq(allFields[index].distances))
      result.routeHops.add(cloneSeq(allFields[index].hops))
    result.ducks = cloneSeq(duckTemplates)
    discard result.planner.benchmarkPlanPath(map, stencilDanger.DangerField(),
      endpoints.a, endpoints.b)
    result.danger.rebuildLosDanger(map, @[endpoints.a, endpoints.b])

  let occupiedBefore = getOccupiedMem()
  let totalBefore = getTotalMem()
  var seats: seq[SeatMemory]
  seats.add(allocateSeat())
  let occupiedOne = getOccupiedMem()
  let totalOne = getTotalMem()
  for _ in 1 ..< 32: seats.add(allocateSeat())
  let occupied32 = getOccupiedMem()
  let total32 = getTotalMem()
  let workspace = seats[0].planner.benchmarkWorkspaceStats()
  var routeBytes = 0
  for index in firstField ..< allFields.len:
    routeBytes += allFields[index].distances.len * sizeof(float) +
      allFields[index].hops.len * sizeof(uint8)
  let duckBytes = 256 * sizeof(stencilMap.DuckResult)
  let dangerBytes = seats[0].danger.values.len * sizeof(float32)
  let perSeatLogical = routeBytes + duckBytes + workspace.totalBytes + dangerBytes
  let details = %*{"route_fields": 4, "duck_entries": 256,
    "route_bytes_per_seat": routeBytes, "duck_bytes_per_seat": duckBytes,
    "planner_bytes_per_seat": workspace.totalBytes,
    "danger_bytes_per_seat": dangerBytes,
    "logical_bytes_one": perSeatLogical,
    "logical_bytes_32": perSeatLogical * 32,
    "allocator_occupied_one_delta": max(0, occupiedOne - occupiedBefore),
    "allocator_total_one_delta": max(0, totalOne - totalBefore),
    "allocator_occupied_32_delta": max(0, occupied32 - occupiedBefore),
    "allocator_total_32_delta": max(0, total32 - totalBefore)}
  result.add(%*{"name": "memory.steady_one", "samples": 1,
    "median_ns": 0, "p95_ns": 0, "details": details})
  result.add(%*{"name": "memory.steady_32", "samples": 32,
    "median_ns": 0, "p95_ns": 0, "details": details})
  result.stampRows(map, -1)

proc addRows(target: JsonNode, rows: seq[JsonNode]) =
  for item in rows: target.add(item)

proc runCase(options: Options, scenario: Scenario): JsonNode =
  result = newJArray()
  let map = scenario.map
  template add(call: untyped) = result.addRows(call)
  case options.selectedCase
  of "smoke", "all":
    add episodeRows(options, scenario)
    add validatorRows(options, scenario)
    add brValidatorRows(options, scenario.seed)
    add plannerRows(options, scenario)
    add followerRows(options, map)
    add dangerRows(options, map)
    add targetingRows(options, map)
    add actionRows(options, map)
    add routeRows(options, map)
    add duckRows(options, map)
    add memoryRows(map)
  of "episode": add episodeRows(options, scenario)
  of "validator":
    add validatorRows(options, scenario)
    add brValidatorRows(options, scenario.seed)
  of "planner": add plannerRows(options, scenario)
  of "follower": add followerRows(options, map)
  of "danger": add dangerRows(options, map)
  of "targeting": add targetingRows(options, map)
  of "action": add actionRows(options, map)
  of "route-field": add routeRows(options, map)
  of "duck": add duckRows(options, map)
  of "memory": add memoryRows(map)
  else: raise newException(ValueError, "unknown stencil-backed case: " & options.selectedCase)
  for item in result.elems:
    if not item["details"].hasKey("map_width"):
      item["details"]["seed"] = %scenario.seed
      item["details"]["map_width"] = %map.width
      item["details"]["map_height"] = %map.height
      item["details"]["grid_w"] = %map.gridW
      item["details"]["grid_h"] = %map.gridH

proc main() =
  var options = parseOptions()
  let stencil = verifyStencilPin(options.stencilPin)
  if options.selectedCase == "smoke":
    options.warmups = 0
    options.samples = 1
  var rows = newJArray()
  if options.selectedCase == "smoke":
    rows.addRows(runCase(options, makeWorld(options, options.seeds[0])).elems)
  else:
    for seed in options.seeds:
      rows.addRows(runCase(options, makeWorld(options, seed)).elems)
  let output = %*{"harness": "body-p0-stencil-local", "release": true,
    "stencil_dir": stencil.dir, "stencil_commit": stencil.head,
    "stencil_pin": options.stencilPin, "case": options.selectedCase,
    "seeds": options.seeds, "warmups": options.warmups,
    "samples": options.samples, "rows": rows}
  let encoded = pretty(output)
  if options.output.len > 0:
    let destination = absolutePath(options.output)
    if destination.startsWith(getCurrentDir() & DirSep):
      raise newException(ValueError, "benchmark output must stay outside the repository")
    writeFile(destination, encoded & "\n")
  echo encoded

when isMainModule:
  main()
