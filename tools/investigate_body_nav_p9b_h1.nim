## P9B Round 2 H1: distinguish lattice resolution from search quality.

import std/[algorithm, heapqueue, json, math, monotimes, options, os,
  strformat, tables, times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_map, body_planner, body_route_index]
import ../tests/nav_route_corpus_support

const
  SearchPopCap = 262_144
  Samples = 7

type
  SearchNode = object
    priority, cost: float64
    cell: int

  SearchWorkspace = object
    generation: uint32
    cost: seq[float64]
    parent: seq[int32]
    seen, closed: seq[uint32]

  SearchGraph = object
    width, height, step, attachRadius: int
    points: seq[BodyPoint]
    legal: seq[uint8]

  SearchResult = object
    reached: bool
    pops: int
    route: seq[BodyPoint]

  Accum = object
    all: seq[float64]
    strata: Table[string, seq[float64]]
    missing, illegal, longest: int
    pops, nanoseconds: seq[float64]

proc `<`(a, b: SearchNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.cell < b.cell

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc findCase(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id:
      return item
  raise newException(ValueError, "corpus case not found: " & id)

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0:
    return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc initWorkspace(cellCount: int): SearchWorkspace =
  result.cost = newSeq[float64](cellCount)
  result.parent = newSeq[int32](cellCount)
  result.seen = newSeq[uint32](cellCount)
  result.closed = newSeq[uint32](cellCount)

proc beginSearch(workspace: var SearchWorkspace) =
  inc workspace.generation
  if workspace.generation == 0:
    for stamp in workspace.seen.mitems: stamp = 0
    for stamp in workspace.closed.mitems: stamp = 0
    workspace.generation = 1

proc graphPoint(graph: SearchGraph, x, y: int): BodyPoint {.inline.} =
  graph.points[y * graph.width + x]

proc buildFourPixelGraph(map: BodyMap): SearchGraph =
  result.step = 4
  result.width = (map.width - 1) div result.step + 1
  result.height = (map.height - 1) div result.step + 1
  result.points = newSeq[BodyPoint](result.width * result.height)
  result.legal = newSeq[uint8](result.points.len)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let offset = y * result.width + x
      result.points[offset] = (x * result.step, y * result.step)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        offset = y * result.width + x
        point = result.points[offset]
      if not map.canStand(point):
        continue
      for direction, delta in NavNeighbors:
        let next = (x: x + delta.x, y: y + delta.y)
        if next.x < 0 or next.x >= result.width or
            next.y < 0 or next.y >= result.height:
          continue
        let nextPoint = result.graphPoint(next.x, next.y)
        if map.canStand(nextPoint) and map.segmentClear(point, nextPoint):
          result.legal[offset] = result.legal[offset] or uint8(1 shl direction)

proc buildSubcellAnchorGraph(map: BodyMap): SearchGraph =
  result.step = NavCell
  result.attachRadius = PortalAnchorRingCells
  result.width = map.gridWidth
  result.height = map.gridHeight
  result.points = newSeq[BodyPoint](result.width * result.height)
  result.legal = newSeq[uint8](result.points.len)
  for point in result.points.mitems:
    point = (-1, -1)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        offset = y * result.width + x
        center = cellCenter((x, y))
      var
        found = false
        best = center
        bestClearance = low(int)
        bestDistance = high(int)
      for dy in [0, 4]:
        for dx in [0, 4]:
          let point = (x: x * NavCell + dx, y: y * NavCell + dy)
          if map.cellOf(point) != (x, y) or not map.canStand(point):
            continue
          let
            clearance = map.clearanceAt(point)
            distance = (point.x - center.x) * (point.x - center.x) +
              (point.y - center.y) * (point.y - center.y)
          if not found or clearance > bestClearance or
              (clearance == bestClearance and
               (distance < bestDistance or
                (distance == bestDistance and
                 (point.y < best.y or
                  (point.y == best.y and point.x < best.x))))):
            found = true
            best = point
            bestClearance = clearance
            bestDistance = distance
      if found:
        result.points[offset] = best
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let
        offset = y * result.width + x
        point = result.points[offset]
      if point.x < 0:
        continue
      for direction, delta in NavNeighbors:
        let next = (x: x + delta.x, y: y + delta.y)
        if next.x < 0 or next.x >= result.width or
            next.y < 0 or next.y >= result.height:
          continue
        let nextPoint = result.graphPoint(next.x, next.y)
        if nextPoint.x >= 0 and map.segmentClear(point, nextPoint):
          result.legal[offset] = result.legal[offset] or uint8(1 shl direction)

proc routeLegal(map: BodyMap, item: NavCorpusCase,
    route: openArray[BodyPoint]): bool =
  if route.len == 0 or route[0] != item.start or
      route[^1] != item.validatedGoal:
    return false
  for point in route:
    if not map.canStand(point) or map.componentOf(point) != item.component:
      return false
  for offset in 1 ..< route.len:
    if not map.segmentClear(route[offset - 1], route[offset]):
      return false
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

proc attachments(map: BodyMap, graph: SearchGraph, danger: BodyDangerField,
    item: NavCorpusCase, endpoint: BodyPoint):
    seq[tuple[cell: int, cost: float64]] =
  let center = (x: clamp(endpoint.x div graph.step, 0, graph.width - 1),
    y: clamp(endpoint.y div graph.step, 0, graph.height - 1))
  for ring in 0 .. graph.attachRadius:
    for y in max(0, center.y - ring) .. min(graph.height - 1, center.y + ring):
      for x in max(0, center.x - ring) .. min(graph.width - 1, center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring:
          continue
        let
          cell = y * graph.width + x
          point = graph.points[cell]
        if point.x >= 0 and map.segmentClear(endpoint, point):
          result.add (cell: cell,
            cost: map.edgeCost(danger, item, endpoint, point))

proc search(map: BodyMap, graph: SearchGraph, danger: BodyDangerField,
    item: NavCorpusCase, workspace: var SearchWorkspace): SearchResult =
  workspace.beginSearch()
  let
    starts = map.attachments(graph, danger, item, item.start)
    goals = map.attachments(graph, danger, item, item.validatedGoal)
  if starts.len == 0 or goals.len == 0:
    return
  var
    heap: HeapQueue[SearchNode]
    goalCosts = initTable[int, float64]()
    bestGoal = -1
    bestGoalCost = Inf
  for goal in goals:
    if goal.cell notin goalCosts or goal.cost < goalCosts[goal.cell]:
      goalCosts[goal.cell] = goal.cost
  let heuristicAllowance = graph.attachRadius.float * graph.step.float *
    sqrt(2.0) + graph.step.float
  for start in starts:
    if workspace.seen[start.cell] != workspace.generation or
        start.cost < workspace.cost[start.cell]:
      workspace.seen[start.cell] = workspace.generation
      workspace.cost[start.cell] = start.cost
      workspace.parent[start.cell] = -1
      let point = graph.points[start.cell]
      heap.push SearchNode(priority: start.cost +
        max(0.0, hypot((point.x - item.validatedGoal.x).float,
                       (point.y - item.validatedGoal.y).float) -
          heuristicAllowance),
        cost: start.cost, cell: start.cell)
  while heap.len > 0 and result.pops < SearchPopCap:
    let current = heap.pop()
    if workspace.closed[current.cell] == workspace.generation or
        workspace.seen[current.cell] != workspace.generation or
        current.cost != workspace.cost[current.cell]:
      continue
    if current.priority >= bestGoalCost:
      break
    workspace.closed[current.cell] = workspace.generation
    inc result.pops
    if current.cell in goalCosts:
      let total = current.cost + goalCosts[current.cell]
      if total < bestGoalCost:
        bestGoal = current.cell
        bestGoalCost = total
    let
      cell = (x: current.cell mod graph.width,
        y: current.cell div graph.width)
      legal = graph.legal[current.cell]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0:
        continue
      let
        next = (x: cell.x + delta.x, y: cell.y + delta.y)
        nextCell = next.y * graph.width + next.x
      if workspace.closed[nextCell] == workspace.generation:
        continue
      let candidate = current.cost + map.edgeCost(danger, item,
        graph.points[current.cell], graph.points[nextCell])
      if workspace.seen[nextCell] != workspace.generation or
          candidate < workspace.cost[nextCell]:
        workspace.seen[nextCell] = workspace.generation
        workspace.cost[nextCell] = candidate
        workspace.parent[nextCell] = int32(current.cell)
        let point = graph.points[nextCell]
        heap.push SearchNode(priority: candidate +
          max(0.0, hypot((point.x - item.validatedGoal.x).float,
                         (point.y - item.validatedGoal.y).float) -
            heuristicAllowance),
          cost: candidate, cell: nextCell)
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

proc resultRow(name: string, values: openArray[float64]): JsonNode =
  %*{"stratum": name, "count": values.len,
    "p95_inflation_pct": percentile(values, 0.95),
    "max_inflation_pct": if values.len == 0: Inf else: max(values)}

proc accumJson(accum: Accum, name: string, workspaceBytes: int64): JsonNode =
  var rows = newJArray()
  rows.add resultRow("overall", accum.all)
  for roster in [16, 32]:
    for profile in NavCorpusProfile:
      for dynamic in NavCorpusDynamic:
        for distance in NavCorpusDistance:
          let key = &"r{roster}/{profile}/{dynamic}/{distance}"
          rows.add resultRow(key, accum.strata.getOrDefault(key))
  %*{"name": name, "missing": accum.missing, "illegal": accum.illegal,
    "longest_path_cells": accum.longest,
    "pops_p50": percentile(accum.pops, 0.50),
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": if accum.pops.len == 0: 0.0 else: max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95),
    "workspace_bytes": workspaceBytes, "quality": rows}

proc measureGraph(pool: JsonNode, corpus: NavCorpus,
    graphName: string, buildGraph: proc(map: BodyMap): SearchGraph): JsonNode =
  var accum: Accum
  var maxWorkspaceBytes = 0'i64
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"{graphName} map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      graph = buildGraph(map)
    var
      workspace = initWorkspace(graph.points.len)
      dangerByHash = initTable[string, BodyDangerField]()
    maxWorkspaceBytes = max(maxWorkspaceBytes,
      int64(graph.points.len * (sizeof(float64) + sizeof(int32) +
        2 * sizeof(uint32))))
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      let danger = dangerByHash[item.dangerHash]
      let started = getMonoTime()
      let found = map.search(graph, danger, item, workspace)
      let elapsed = (getMonoTime() - started).inNanoseconds
      let key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      if not found.reached:
        inc accum.missing
        continue
      if not map.routeLegal(item, found.route):
        inc accum.illegal
        continue
      let inflation = routeInflationPct(
        oracleFloatCost(resampleRoute4px(found.route), map, danger,
          item.profile.corpusProfile, item.blockedCell), item.oracleCost)
      accum.all.add inflation
      accum.strata.mgetOrPut(key, @[]).add inflation
      accum.longest = max(accum.longest, found.route.len)
      accum.pops.add found.pops.float
      accum.nanoseconds.add elapsed.float
  accum.accumJson(graphName, maxWorkspaceBytes)

proc worstWallStats(pool: JsonNode, corpus: NavCorpus,
    artifact: JsonNode): JsonNode =
  var ranked: seq[tuple[inflation: float64, id: string]]
  for row in artifact["quality"]["cases"]:
    if row["status"].getStr() == "ok":
      ranked.add (row["inflation_pct"].getFloat(), row["id"].getStr())
  ranked.sort(proc(a, b: auto): int =
    result = cmp(b.inflation, a.inflation)
    if result == 0: result = cmp(a.id, b.id))
  result = newJArray()
  for offset in 0 ..< 30:
    let
      item = corpus.findCase(ranked[offset].id)
      map = pool.loadMap(item.poolIndex)
      oracle = map.oracleRoute4px(item)
    var unwalkable = 0
    var clearanceSum = 0.0
    for point in oracle:
      let cell = map.cellOf(point)
      if not map.cellWalkable(cell):
        inc unwalkable
        clearanceSum += map.clearanceAt(point).float
    result.add %*{"id": item.id, "points": oracle.len,
      "unwalkable_8px_cells": unwalkable,
      "fraction": unwalkable.float / oracle.len.float,
      "average_clearance": if unwalkable == 0: 0.0 else:
        clearanceSum / unwalkable.float}

proc profileCase(pool: JsonNode, corpus: NavCorpus, id, graphName: string,
    buildGraph: proc(map: BodyMap): SearchGraph): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    graph = buildGraph(map)
  var
    workspace = initWorkspace(graph.points.len)
    danger = map.buildOracleDanger(item)
    samples = newJArray()
  for _ in 0 ..< Samples:
    let started = getMonoTime()
    let found = map.search(graph, danger, item, workspace)
    let elapsed = (getMonoTime() - started).inNanoseconds
    samples.add %*{"nanoseconds": elapsed, "pops": found.pops,
      "reached": found.reached, "path_cells": found.route.len}
  %*{"name": graphName, "id": id, "samples": samples}

when isMainModule:
  if paramCount() != 2:
    quit("usage: investigate_body_nav_p9b_h1 CORPUS CANONICAL_JSON", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    artifact = parseFile(paramStr(2))
    pool = loadBrS2PoolRaw()
    medianId = "m09-br-gen-21450-r32-s9-default-blocked-far"
    farId = "m15-br-gen-22010-r16-s15-default-danger-far"
  stderr.writeLine "measure worst-30 wall occupancy"
  let walls = pool.worstWallStats(corpus, artifact)
  stderr.writeLine "measure full 4px graph"
  let four = pool.measureGraph(corpus, "full_4px", buildFourPixelGraph)
  stderr.writeLine "measure subcell anchors"
  let anchors = pool.measureGraph(corpus, "subcell_anchor_8px",
    buildSubcellAnchorGraph)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_h1", "v": 1,
    "worst_30_wall_stats": walls,
    "graphs": [four, anchors],
    "profiles": [
      pool.profileCase(corpus, medianId, "full_4px", buildFourPixelGraph),
      pool.profileCase(corpus, farId, "full_4px", buildFourPixelGraph),
      pool.profileCase(corpus, medianId, "subcell_anchor_8px",
        buildSubcellAnchorGraph),
      pool.profileCase(corpus, farId, "subcell_anchor_8px",
        buildSubcellAnchorGraph)]})
