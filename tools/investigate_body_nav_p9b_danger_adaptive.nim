## P9B Idea D: danger-adaptive mixed-resolution weighted A*.

import std/[algorithm, heapqueue, json, math, monotimes, options, os, sets,
  strformat, tables, times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_hazard, body_map, body_nav, body_planner,
  body_route_index, body_route_query]
import ../tests/nav_route_corpus_support

const
  SearchPopCap = 262_144
  Samples = 7
  FineStep = 4

type
  SearchNode = object
    priority, cost: float64
    node: int

  SearchWorkspace = object
    generation: uint32
    cost: seq[float64]
    parent: seq[int32]
    seen, closed: seq[uint32]

  AdaptiveGraph = object
    width, height: int
    points: seq[BodyPoint]
    standable: seq[bool]
    centerNode: seq[int32]

  SearchResult = object
    reached: bool
    pops: int
    route: seq[BodyPoint]

  Variant = object
    name: string
    dilation: int
    corridorOnly: bool

  Accum = object
    all, pops, nanoseconds, hotCounts, hotBuildNs, activeNodes: seq[float64]
    strata: Table[string, seq[float64]]
    missing, illegal, longest: int

proc `<`(a, b: SearchNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.node < b.node

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc findCase(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id: return item
  raise newException(ValueError, "corpus case not found: " & id)

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc buildGraph(map: BodyMap): AdaptiveGraph =
  result.width = (map.width - 1) div FineStep + 1
  result.height = (map.height - 1) div FineStep + 1
  result.points = newSeq[BodyPoint](result.width * result.height)
  result.standable = newSeq[bool](result.points.len)
  result.centerNode = newSeq[int32](map.gridWidth * map.gridHeight)
  for center in result.centerNode.mitems: center = -1
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        node = y * result.width + x
        point = (x: x * FineStep, y: y * FineStep)
      result.points[node] = point
      result.standable[node] = map.canStand(point)
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      let
        point = cellCenter((x, y))
        fine = (x: point.x div FineStep, y: point.y div FineStep)
      if fine.x < result.width and fine.y < result.height:
        let node = fine.y * result.width + fine.x
        if result.standable[node]:
          result.centerNode[y * map.gridWidth + x] = int32(node)

proc begin(workspace: var SearchWorkspace) =
  inc workspace.generation
  if workspace.generation == 0:
    for stamp in workspace.seen.mitems: stamp = 0
    for stamp in workspace.closed.mitems: stamp = 0
    workspace.generation = 1

proc newWorkspace(count: int): SearchWorkspace =
  result.cost = newSeq[float64](count)
  result.parent = newSeq[int32](count)
  result.seen = newSeq[uint32](count)
  result.closed = newSeq[uint32](count)

proc active(graph: AdaptiveGraph, map: BodyMap,
    hot: openArray[bool], node: int): bool {.inline.} =
  if node < 0 or node >= graph.points.len or not graph.standable[node]:
    return false
  let
    cell = map.cellOf(graph.points[node])
    cellIndex = cell.y * map.gridWidth + cell.x
  hot[cellIndex] or graph.centerNode[cellIndex] == int32(node)

proc buildHot(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, dilation: int,
    allowedRooms: HashSet[int]): seq[bool] =
  let count = map.gridWidth * map.gridHeight
  result = newSeq[bool](count)
  for source, value in danger.values:
    if value <= 0: continue
    let cell = (x: source mod map.gridWidth, y: source div map.gridWidth)
    for dy in -dilation .. dilation:
      for dx in -dilation .. dilation:
        let next = (x: cell.x + dx, y: cell.y + dy)
        if next.x < 0 or next.x >= map.gridWidth or
            next.y < 0 or next.y >= map.gridHeight:
          continue
        let nextIndex = next.y * map.gridWidth + next.x
        if allowedRooms.len == 0 or index.roomForCell(nextIndex) in allowedRooms:
          result[nextIndex] = true

proc routeLegal(map: BodyMap, item: NavCorpusCase,
    route: openArray[BodyPoint]): bool =
  if route.len == 0 or route[0] != item.start or
      route[^1] != item.validatedGoal: return false
  for point in route:
    if not map.canStand(point) or map.componentOf(point) != item.component:
      return false
  for offset in 1 ..< route.len:
    if not map.segmentClear(route[offset - 1], route[offset]): return false
  true

proc edgeCost(map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, a, b: BodyPoint): float64 =
  let
    midpoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
    weight = planCostProfile(item.profile.corpusProfile).dangerWeight
  result = hypot((b.x - a.x).float, (b.y - a.y).float) *
    (1.0 + weight * danger.sample(map, midpoint))
  if item.blockedCell.isSome and map.cellOf(midpoint) == item.blockedCell.get:
    result *= 8.0

proc addUnique(values: var seq[int], value: int) {.inline.} =
  for existing in values:
    if existing == value: return
  values.add value

proc cellFineNodes(graph: AdaptiveGraph, map: BodyMap,
    hot: openArray[bool], cell: BodyPoint): seq[int] =
  if cell.x < 0 or cell.x >= map.gridWidth or
      cell.y < 0 or cell.y >= map.gridHeight: return
  let cellIndex = cell.y * map.gridWidth + cell.x
  if hot[cellIndex]:
    for dy in [0, 4]:
      for dx in [0, 4]:
        let
          point = (x: cell.x * NavCell + dx,
            y: cell.y * NavCell + dy)
          fine = (x: point.x div FineStep, y: point.y div FineStep)
        if fine.x < graph.width and fine.y < graph.height:
          let node = fine.y * graph.width + fine.x
          if graph.standable[node]: result.addUnique(node)
  elif graph.centerNode[cellIndex] >= 0:
    result.add graph.centerNode[cellIndex].int

proc neighbors(graph: AdaptiveGraph, map: BodyMap,
    hot: openArray[bool], node: int): seq[int] =
  let
    point = graph.points[node]
    fine = (x: point.x div FineStep, y: point.y div FineStep)
    cell = map.cellOf(point)
    cellIndex = cell.y * map.gridWidth + cell.x
    isCenter = graph.centerNode[cellIndex] == int32(node)
  for delta in NavNeighbors:
    let next = (x: fine.x + delta.x, y: fine.y + delta.y)
    if next.x < 0 or next.x >= graph.width or
        next.y < 0 or next.y >= graph.height: continue
    let nextNode = next.y * graph.width + next.x
    if graph.active(map, hot, nextNode) and
        map.segmentClear(point, graph.points[nextNode]):
      result.addUnique(nextNode)
  if isCenter or hot[cellIndex]:
    for delta in NavNeighbors:
      let nextCell = (x: cell.x + delta.x, y: cell.y + delta.y)
      if nextCell.x < 0 or nextCell.x >= map.gridWidth or
          nextCell.y < 0 or nextCell.y >= map.gridHeight: continue
      let nextIndex = nextCell.y * map.gridWidth + nextCell.x
      if not isCenter and hot[nextIndex]: continue
      for nextNode in graph.cellFineNodes(map, hot, nextCell):
        if map.segmentClear(point, graph.points[nextNode]):
          result.addUnique(nextNode)

proc attachments(graph: AdaptiveGraph, map: BodyMap,
    danger: BodyDangerField, item: NavCorpusCase, hot: openArray[bool],
    endpoint: BodyPoint): seq[tuple[node: int, cost: float64]] =
  let center = map.cellOf(endpoint)
  var seen = initHashSet[int]()
  for ring in 0 .. PortalAnchorRingCells:
    for y in max(0, center.y - ring) .. min(map.gridHeight - 1,
        center.y + ring):
      for x in max(0, center.x - ring) .. min(map.gridWidth - 1,
          center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring: continue
        for node in graph.cellFineNodes(map, hot, (x, y)):
          if node notin seen and map.segmentClear(endpoint, graph.points[node]):
            seen.incl node
            result.add (node: node,
              cost: map.edgeCost(danger, item, endpoint, graph.points[node]))

proc heuristic(point, goal: BodyPoint): float64 {.inline.} =
  max(0.0, hypot((point.x - goal.x).float, (point.y - goal.y).float) -
    PortalAnchorRingCells.float * NavCell.float * sqrt(2.0))

proc search(graph: AdaptiveGraph, map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, hot: openArray[bool],
    workspace: var SearchWorkspace): SearchResult =
  workspace.begin()
  let
    starts = graph.attachments(map, danger, item, hot, item.start)
    goals = graph.attachments(map, danger, item, hot, item.validatedGoal)
  if starts.len == 0 or goals.len == 0: return
  var
    heap: HeapQueue[SearchNode]
    goalCosts = initTable[int, float64]()
    bestGoal = -1
    bestCost = Inf
  for goal in goals:
    if goal.node notin goalCosts or goal.cost < goalCosts[goal.node]:
      goalCosts[goal.node] = goal.cost
  for start in starts:
    if workspace.seen[start.node] != workspace.generation or
        start.cost < workspace.cost[start.node]:
      workspace.seen[start.node] = workspace.generation
      workspace.cost[start.node] = start.cost
      workspace.parent[start.node] = -1
      heap.push SearchNode(priority: start.cost + heuristic(
        graph.points[start.node], item.validatedGoal),
        cost: start.cost, node: start.node)
  while heap.len > 0 and result.pops < SearchPopCap:
    let current = heap.pop()
    if workspace.closed[current.node] == workspace.generation or
        workspace.seen[current.node] != workspace.generation or
        current.cost != workspace.cost[current.node]: continue
    if current.priority >= bestCost: break
    workspace.closed[current.node] = workspace.generation
    inc result.pops
    if current.node in goalCosts:
      let total = current.cost + goalCosts[current.node]
      if total < bestCost:
        bestCost = total
        bestGoal = current.node
      continue
    for nextNode in graph.neighbors(map, hot, current.node):
      if workspace.closed[nextNode] == workspace.generation: continue
      let candidate = current.cost + map.edgeCost(danger, item,
        graph.points[current.node], graph.points[nextNode])
      if workspace.seen[nextNode] != workspace.generation or
          candidate < workspace.cost[nextNode]:
        workspace.seen[nextNode] = workspace.generation
        workspace.cost[nextNode] = candidate
        workspace.parent[nextNode] = int32(current.node)
        heap.push SearchNode(priority: candidate + heuristic(
          graph.points[nextNode], item.validatedGoal),
          cost: candidate, node: nextNode)
  if bestGoal >= 0:
    result.reached = true
    var cursor = bestGoal
    while cursor >= 0:
      result.route.add graph.points[cursor]
      cursor = workspace.parent[cursor].int
    result.route.reverse()
    if result.route[0] != item.start: result.route.insert(item.start, 0)
    if result.route[^1] != item.validatedGoal:
      result.route.add item.validatedGoal

proc queryRequest(map: BodyMap, item: NavCorpusCase,
    danger: var BodyDangerField): BodyRouteRequest =
  let goal = map.validateGoal(item.requestedGoal, item.start)
  if goal.isNone or goal.get.goalPoint != item.validatedGoal:
    raise newException(ValueError, "goal validation drift: " & item.id)
  BodyRouteRequest(start: item.start, goal: goal.get,
    profile: item.profile.corpusProfile,
    danger: if item.dynamic in {ncdDanger, ncdBoth}: addr danger else: nil,
    blockedCell: if item.blockedCell.isSome:
      some(cellCenter(item.blockedCell.get)) else: none(BodyPoint),
    hazard: newDarkBodyHazardOverlay())

proc corridorRooms(map: BodyMap, index: BodyRouteIndex,
    scratch: BodyRouteQueryScratch, item: NavCorpusCase,
    danger: var BodyDangerField): HashSet[int] =
  let route = index.queryBodyRoute(scratch, map.queryRequest(item, danger))
  if not route.ok:
    raise newException(ValueError, "corridor route missing: " & item.id)
  let seat = BodyNavSeat()
  if not seat.installRoute(scratch, route, 1):
    raise newException(ValueError, "corridor install failed: " & item.id)
  var position = item.start
  result.incl map.roomLabelAt(position)
  let limit = route.descriptor.startLegLen.int +
    route.descriptor.goalLegLen.int +
    route.descriptor.edgeCount.int * RouteLocalLegCap + 2
  for _ in 0 .. limit:
    let waypoint = seat.routeWaypoint(index, position)
    if waypoint.isNone or waypoint.get == position: break
    position = waypoint.get
    result.incl map.roomLabelAt(position)
    if position == item.validatedGoal: break

proc resultRow(name: string, values: openArray[float64]): JsonNode =
  %*{"stratum": name, "count": values.len,
    "p95_inflation_pct": percentile(values, 0.95),
    "max_inflation_pct": if values.len == 0: Inf else: max(values)}

proc accumJson(accum: Accum, variant: Variant,
    maxMapNodes: int): JsonNode =
  var rows = newJArray()
  rows.add resultRow("overall", accum.all)
  for roster in [16, 32]:
    for profile in NavCorpusProfile:
      for dynamic in NavCorpusDynamic:
        for distance in NavCorpusDistance:
          let key = &"r{roster}/{profile}/{dynamic}/{distance}"
          rows.add resultRow(key, accum.strata.getOrDefault(key))
  %*{"name": variant.name, "dilation": variant.dilation,
    "corridor_only": variant.corridorOnly, "missing": accum.missing,
    "illegal": accum.illegal, "longest_path_cells": accum.longest,
    "pops_p50": percentile(accum.pops, 0.50),
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": if accum.pops.len == 0: 0.0 else: max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95),
    "hot_cells_mean": if accum.hotCounts.len == 0: 0.0 else:
      sum(accum.hotCounts) / accum.hotCounts.len.float,
    "hot_cells_max": if accum.hotCounts.len == 0: 0.0 else:
      max(accum.hotCounts),
    "hot_build_ns_p50": percentile(accum.hotBuildNs, 0.50),
    "hot_build_ns_p95": percentile(accum.hotBuildNs, 0.95),
    "active_nodes_mean": if accum.activeNodes.len == 0: 0.0 else:
      sum(accum.activeNodes) / accum.activeNodes.len.float,
    "active_nodes_max": if accum.activeNodes.len == 0: 0.0 else:
      max(accum.activeNodes),
    "dense_workspace_bytes": maxMapNodes * 20,
    "compact_workspace_bytes_max":
      (if accum.activeNodes.len == 0: 0 else: int(max(accum.activeNodes))) * 20,
    "hot_bitset_bytes_max": (maxMapNodes div 4 + 7) div 8,
    "quality": rows}

proc activeNodeCount(graph: AdaptiveGraph, map: BodyMap,
    hot: openArray[bool]): int =
  for node in 0 ..< graph.points.len:
    if graph.active(map, hot, node): inc result

proc measure(pool: JsonNode, corpus: NavCorpus, variant: Variant): JsonNode =
  var accum: Accum
  var maxMapNodes = 0
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"{variant.name} map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      index = newBodyRouteIndex(map)
      graph = map.buildGraph()
    var
      workspace = newWorkspace(graph.points.len)
      routeScratch = newBodyRouteQueryScratch(index)
      dangerCache = initTable[string, BodyDangerField]()
    maxMapNodes = max(maxMapNodes, graph.points.len)
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerCache:
        dangerCache[item.dangerHash] = map.buildOracleDanger(item)
      var danger = dangerCache[item.dangerHash]
      let allowedRooms = if variant.corridorOnly:
        map.corridorRooms(index, routeScratch, item, danger)
      else:
        initHashSet[int]()
      let hotStarted = getMonoTime()
      let hot = map.buildHot(index, danger, variant.dilation, allowedRooms)
      let hotNs = (getMonoTime() - hotStarted).inNanoseconds
      var hotCount = 0
      for value in hot:
        if value: inc hotCount
      let activeCount = graph.activeNodeCount(map, hot)
      let started = getMonoTime()
      let found = graph.search(map, danger, item, hot, workspace)
      let elapsed = (getMonoTime() - started).inNanoseconds
      accum.hotCounts.add hotCount.float
      accum.hotBuildNs.add hotNs.float
      accum.activeNodes.add activeCount.float
      if not found.reached:
        inc accum.missing
        continue
      if not map.routeLegal(item, found.route):
        inc accum.illegal
        continue
      let inflation = routeInflationPct(
        oracleFloatCost(resampleRoute4px(found.route), map, danger,
          item.profile.corpusProfile, item.blockedCell), item.oracleCost)
      let key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      accum.all.add inflation
      accum.strata.mgetOrPut(key, @[]).add inflation
      accum.pops.add found.pops.float
      accum.nanoseconds.add elapsed.float
      accum.longest = max(accum.longest, found.route.len)
  accum.accumJson(variant, maxMapNodes)

proc profileCase(pool: JsonNode, corpus: NavCorpus, variant: Variant,
    id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    index = newBodyRouteIndex(map)
    graph = map.buildGraph()
  var
    danger = map.buildOracleDanger(item)
    routeScratch = newBodyRouteQueryScratch(index)
    workspace = newWorkspace(graph.points.len)
  let allowedRooms = if variant.corridorOnly:
    map.corridorRooms(index, routeScratch, item, danger)
  else:
    initHashSet[int]()
  let hot = map.buildHot(index, danger, variant.dilation, allowedRooms)
  var samples = newJArray()
  for _ in 0 ..< Samples:
    let started = getMonoTime()
    let found = graph.search(map, danger, item, hot, workspace)
    let elapsed = (getMonoTime() - started).inNanoseconds
    samples.add %*{"ns": elapsed, "pops": found.pops,
      "reached": found.reached, "path_cells": found.route.len}
  %*{"name": variant.name, "id": id, "samples": samples}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_danger_adaptive CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    variants = [
      Variant(name: "D1_hot_dilate_1", dilation: 1),
      Variant(name: "D2_hot_dilate_2", dilation: 2),
      Variant(name: "D3_hot_dilate_2_corridor", dilation: 2,
        corridorOnly: true)]
    medianId = "m09-br-gen-21450-r32-s9-default-blocked-far"
    farId = "m15-br-gen-22010-r16-s15-default-danger-far"
  var
    results = newJArray()
    profiles = newJArray()
  for variant in variants:
    results.add pool.measure(corpus, variant)
    profiles.add pool.profileCase(corpus, variant, medianId)
    profiles.add pool.profileCase(corpus, variant, farId)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_danger_adaptive",
    "v": 1, "variants": results, "profiles": profiles})
