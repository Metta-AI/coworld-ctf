## P9B Round 4.1: ALT landmarks and room-corridor margin restriction.

import std/[algorithm, json, math, monotimes, options, os, sets, strformat,
  tables, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_hazard, body_map, body_planner, body_route_index,
  body_route_query]
import ../src/shell/types as shellTypes
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33

const
  FineStep = 4
  TieBits = 21
  TieMask = (1'i64 shl TieBits) - 1
  ClosedBit = 0x8000_0000'u32
  Unreachable = high(uint16)

type
  LandmarkTable* = object
    cellCount*, landmarkCount*: int
    cells*: seq[int32]
    distances*: seq[uint16]
    buildNanoseconds*: seq[int64]

  KeyHeap = object
    keys: seq[int64]
    positions: seq[int32]
    len: int

  AltWorkspace* = object
    generation: uint32
    g, parent, parentBridge, goalCost: seq[int32]
    state, goalStamp: seq[uint32]
    heap: KeyHeap

  Variant = object
    name: string
    landmarks: int
    corridorMargin: bool

  Accum = object
    inflations, pops, nanoseconds: seq[float64]
    strata: Table[string, seq[float64]]
    missing, illegal: int

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc colossalMap(): BodyMap =
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  var gameMap = generateCtfMap(4242, overrides, 4)
  gameMap.name = "size:colossal"
  newBodyMap(gameMap)

proc keyNode(key: int64): int {.inline.} = int(key and TieMask)
proc keyCost(key: int64): int64 {.inline.} = key shr TieBits
proc makeKey(f: int64, node: int): int64 {.inline.} =
  (f shl TieBits) or node.int64

proc swapNodes(heap: var KeyHeap, a, b: int) {.inline.} =
  swap(heap.keys[a], heap.keys[b])
  heap.positions[keyNode(heap.keys[a])] = int32(a)
  heap.positions[keyNode(heap.keys[b])] = int32(b)

proc siftUp(heap: var KeyHeap, start: int) {.inline.} =
  var current = start
  while current > 0:
    let parent = (current - 1) shr 1
    if heap.keys[parent] <= heap.keys[current]: break
    heap.swapNodes(parent, current)
    current = parent

proc siftDown(heap: var KeyHeap, start: int) {.inline.} =
  var current = start
  while true:
    let left = current * 2 + 1
    if left >= heap.len: break
    let right = left + 1
    var child = left
    if right < heap.len and heap.keys[right] < heap.keys[left]: child = right
    if heap.keys[current] <= heap.keys[child]: break
    heap.swapNodes(current, child)
    current = child

proc pushOrDecrease(heap: var KeyHeap, state: openArray[uint32],
    generation: uint32, key: int64) {.inline.} =
  let node = keyNode(key)
  if state[node] == generation:
    let position = heap.positions[node].int
    if key < heap.keys[position]:
      heap.keys[position] = key
      heap.siftUp(position)
    return
  heap.keys[heap.len] = key
  heap.positions[node] = int32(heap.len)
  inc heap.len
  heap.siftUp(heap.len - 1)

proc pop(heap: var KeyHeap): int64 {.inline.} =
  result = heap.keys[0]
  dec heap.len
  if heap.len > 0:
    heap.keys[0] = heap.keys[heap.len]
    heap.positions[keyNode(heap.keys[0])] = 0
    heap.siftDown(0)

proc newAltWorkspace*(count: int): AltWorkspace =
  doAssert count <= (1 shl TieBits)
  result.g = newSeq[int32](count)
  result.parent = newSeq[int32](count)
  result.parentBridge = newSeq[int32](count)
  result.goalCost = newSeq[int32](count)
  result.state = newSeq[uint32](count)
  result.goalStamp = newSeq[uint32](count)
  result.heap.keys = newSeq[int64](count)
  result.heap.positions = newSeq[int32](count)

proc begin(workspace: var AltWorkspace) =
  inc workspace.generation
  if workspace.generation == 0 or
      (workspace.generation and ClosedBit) != 0:
    for stamp in workspace.state.mitems: stamp = 0
    for stamp in workspace.goalStamp.mitems: stamp = 0
    workspace.generation = 1
  workspace.heap.len = 0

proc bfs(index: BodyRouteIndex, source: int,
    queue: var seq[int32]): seq[uint16] =
  let count = index.routeIndexStats.navCells
  result = newSeq[uint16](count)
  for value in result.mitems: value = Unreachable
  result[source] = 0
  queue[0] = int32(source)
  var head = 0
  var tail = 1
  while head < tail:
    let
      cellIndex = queue[head].int
      cell = (x: cellIndex mod index.map.gridWidth,
        y: cellIndex div index.map.gridWidth)
      nextDistance = result[cellIndex] + 1
      legal = index.legalMovesAt(cellIndex)
    inc head
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let next = (x: cell.x + delta.x, y: cell.y + delta.y)
      let nextIndex = next.y * index.map.gridWidth + next.x
      if result[nextIndex] != Unreachable: continue
      result[nextIndex] = nextDistance
      queue[tail] = int32(nextIndex)
      inc tail

proc buildLandmarks*(index: BodyRouteIndex, count: int): LandmarkTable =
  result.cellCount = index.routeIndexStats.navCells
  result.landmarkCount = count
  result.cells = newSeq[int32](count)
  result.distances = newSeq[uint16](count * result.cellCount)
  result.buildNanoseconds = newSeq[int64](count)
  var
    queue = newSeq[int32](result.cellCount)
    minimum = newSeq[uint16](result.cellCount)
    source = -1
  for value in minimum.mitems: value = Unreachable
  for cell in 0 ..< result.cellCount:
    if index.roomForCell(cell) >= 0:
      source = cell
      break
  doAssert source >= 0
  let started = getMonoTime()
  for landmark in 0 ..< count:
    result.cells[landmark] = int32(source)
    let distances = index.bfs(source, queue)
    copyMem(addr result.distances[landmark * result.cellCount],
      unsafeAddr distances[0], result.cellCount * sizeof(uint16))
    for cell in 0 ..< result.cellCount:
      minimum[cell] = min(minimum[cell], distances[cell])
    result.buildNanoseconds[landmark] =
      (getMonoTime() - started).inNanoseconds
    source = -1
    var farthest = 0'u16
    for cell in 0 ..< result.cellCount:
      if index.roomForCell(cell) < 0: continue
      if source < 0 or minimum[cell] > farthest:
        source = cell
        farthest = minimum[cell]

proc landmarkHeuristic(table: LandmarkTable, count, nodeCell,
    goalCell, allowanceCells: int): int32 {.inline.} =
  var cellSteps = 0
  for landmark in 0 ..< count:
    let
      offset = landmark * table.cellCount
      a = table.distances[offset + nodeCell]
      b = table.distances[offset + goalCell]
    if a == Unreachable or b == Unreachable: continue
    cellSteps = max(cellSteps, abs(a.int - b.int))
  # One 4 px graph edge can cross an 8 px cell boundary. Scaling the cell
  # potential by FineStep keeps it consistent on the mixed-resolution graph.
  int32(max(0, cellSteps - allowanceCells) * FineStep * 16)

proc cellAllowed(allowed: openArray[uint8], cell: int): bool {.inline.} =
  allowed.len == 0 or allowed[cell] != 0

proc searchAlt*(graph: MixedGraph, map: BodyMap, item: NavCorpusCase,
    refined: openArray[uint8], weights, hazardCost: openArray[int32],
    landmarks: LandmarkTable, landmarkCount: int,
    allowed: openArray[uint8], workspace: var AltWorkspace): SearchResult =
  workspace.begin()
  let blockedCell = if item.blockedCell.isSome:
      item.blockedCell.get.y * map.gridWidth + item.blockedCell.get.x else: -1
  let
    generation = workspace.generation
    starts = graph.attachments(map, refined, weights, hazardCost,
      blockedCell, item.start)
    goals = graph.attachments(map, refined, weights, hazardCost,
      blockedCell, item.validatedGoal)
    startNode = if starts.len == 1 and starts[0].cost == 0: starts[0].node
      else: -1
    goalNode = if goals.len == 1 and goals[0].cost == 0: goals[0].node
      else: -1
    goalCell = map.cellOf(item.validatedGoal).y * map.gridWidth +
      map.cellOf(item.validatedGoal).x
    octileAllowance = int32(PortalAnchorRingCells * NavCell * 23)
    landmarkAllowance = if goalNode >= 0: 0 else: PortalAnchorRingCells + 1
  if starts.len == 0 or goals.len == 0: return
  for goal in goals:
    if not cellAllowed(allowed, graph.cellForNode[goal.node].int): continue
    if workspace.goalStamp[goal.node] != generation or
        goal.cost < workspace.goalCost[goal.node]:
      workspace.goalStamp[goal.node] = generation
      workspace.goalCost[goal.node] = goal.cost
  for start in starts:
    if not cellAllowed(allowed, graph.cellForNode[start.node].int): continue
    if workspace.state[start.node] != generation or
        start.cost < workspace.g[start.node]:
      workspace.g[start.node] = start.cost
      workspace.parent[start.node] = -1
      workspace.parentBridge[start.node] = -1
      let
        octile = max(0'i32, octileQ4(
          pointAt(start.node, graph.legality.width), item.validatedGoal, 90) -
          octileAllowance)
        alt = if landmarkCount == 0: 0'i32 else:
          landmarks.landmarkHeuristic(landmarkCount,
            graph.cellForNode[start.node].int, goalCell, landmarkAllowance)
      workspace.heap.pushOrDecrease(workspace.state, generation,
        makeKey(start.cost.int64 + max(octile, alt).int64, start.node))
      workspace.state[start.node] = generation
  var
    bestNode = -1
    bestCost = high(int32)
  while workspace.heap.len > 0:
    let
      key = workspace.heap.pop()
      node = keyNode(key)
    if workspace.state[node] != generation: continue
    if key.keyCost >= bestCost.int64: break
    workspace.state[node] = generation or ClosedBit
    inc result.pops
    let currentG = workspace.g[node]
    if workspace.goalStamp[node] == generation:
      let total = currentG.int64 + workspace.goalCost[node].int64
      if total < bestCost.int64:
        bestCost = int32(total)
        bestNode = node
    let
      fineX = node mod graph.legality.width
      fineY = node div graph.legality.width
      legal = graph.legality.legal[node]
      fromPoint = pointAt(node, graph.legality.width)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) != 0:
        let nextNode = (fineY + delta.y) * graph.legality.width +
          fineX + delta.x
        let nextCell = graph.cellForNode[nextNode].int
        if cellAllowed(allowed, nextCell) and
            graph.active(refined, nextNode, startNode, goalNode) and
            workspace.state[nextNode] != (generation or ClosedBit):
          let
            toPoint = pointAt(nextNode, graph.legality.width)
            cell = map.midpointCell(fromPoint, toPoint)
            base = if direction < 4: 64'i64 else: 91'i64
            weighted = (base * weights[cell].int64 + 32_768) shr 16
            blocked = if cell == blockedCell: weighted * 8 else: weighted
            candidate64 = currentG.int64 + blocked + hazardCost[cell].int64
            candidate = int32(candidate64)
          if workspace.state[nextNode] != generation or
              candidate < workspace.g[nextNode]:
            workspace.g[nextNode] = candidate
            workspace.parent[nextNode] = int32(node)
            workspace.parentBridge[nextNode] = -1
            let
              octile = max(0'i32, octileQ4(toPoint,
                item.validatedGoal, 90) - octileAllowance)
              alt = if landmarkCount == 0: 0'i32 else:
                landmarks.landmarkHeuristic(landmarkCount, nextCell,
                  goalCell, landmarkAllowance)
            workspace.heap.pushOrDecrease(workspace.state, generation,
              makeKey(candidate64 + max(octile, alt).int64, nextNode))
            workspace.state[nextNode] = generation
      if graph.anchorNode[node] == 0: continue
      let sourceCell = graph.cellForNode[node].int
      let
        offset = graph.bridgeOffset[sourceCell][direction].int
        pathLen = graph.bridgeLen[sourceCell][direction].int
      if offset < 0 or pathLen == 0: continue
      let target = graph.bridgeNodes[offset + pathLen - 1].int
      let targetCell = graph.cellForNode[target].int
      if not cellAllowed(allowed, targetCell) or
          workspace.state[target] == (generation or ClosedBit): continue
      var
        edgeCost = 0'i32
        previous = fromPoint
      for pathIndex in 0 ..< pathLen:
        let nextPoint = pointAt(graph.bridgeNodes[offset + pathIndex].int,
          graph.legality.width)
        edgeCost += map.integratedEdgeCostQ4(weights, hazardCost,
          blockedCell, previous, nextPoint)
        previous = nextPoint
      let
        candidate64 = currentG.int64 + edgeCost.int64
        candidate = int32(candidate64)
      if workspace.state[target] != generation or
          candidate < workspace.g[target]:
        workspace.g[target] = candidate
        workspace.parent[target] = int32(node)
        workspace.parentBridge[target] = int32(sourceCell * 8 + direction)
        let
          octile = max(0'i32, octileQ4(previous,
            item.validatedGoal, 90) - octileAllowance)
          alt = if landmarkCount == 0: 0'i32 else:
            landmarks.landmarkHeuristic(landmarkCount, targetCell,
              goalCell, landmarkAllowance)
        workspace.heap.pushOrDecrease(workspace.state, generation,
          makeKey(candidate64 + max(octile, alt).int64, target))
        workspace.state[target] = generation
  if bestNode >= 0:
    result.reached = true
    var cursor = bestNode
    while cursor >= 0:
      result.route.add pointAt(cursor, graph.legality.width)
      let bridgeId = workspace.parentBridge[cursor].int
      if bridgeId >= 0:
        let
          cell = bridgeId div 8
          direction = bridgeId mod 8
          offset = graph.bridgeOffset[cell][direction].int
          pathLen = graph.bridgeLen[cell][direction].int
        if pathLen > 1:
          for pathIndex in countdown(pathLen - 2, 0):
            result.route.add pointAt(
              graph.bridgeNodes[offset + pathIndex].int,
              graph.legality.width)
      cursor = workspace.parent[cursor].int
    result.route.reverse()
    if result.route[0] != item.start: result.route.insert(item.start, 0)
    if result.route[^1] != item.validatedGoal:
      result.route.add item.validatedGoal

proc costProfile(profile: NavCorpusProfile): shellTypes.CostProfile =
  case profile
  of ncpDefault: shellTypes.cpDefault
  of ncpCarrier: shellTypes.cpCarrier
  of ncpHunter: shellTypes.cpHunter

proc corridorWithMargin(map: BodyMap, index: BodyRouteIndex,
    scratch: BodyRouteQueryScratch, item: NavCorpusCase,
    danger: BodyDangerField): seq[uint8] =
  let goal = map.validateGoal(item.validatedGoal, item.start)
  if goal.isNone: return
  var dangerCopy = danger
  let request = BodyRouteRequest(start: item.start, goal: goal.get,
    profile: item.profile.costProfile, danger: addr dangerCopy,
    blockedCell: item.blockedCell)
  let route = index.queryBodyRoute(scratch, request)
  if not route.ok: return
  var rooms = initHashSet[int]()
  rooms.incl index.roomForCell(map.cellOf(item.start).y * map.gridWidth +
    map.cellOf(item.start).x)
  rooms.incl index.roomForCell(map.cellOf(item.validatedGoal).y *
    map.gridWidth + map.cellOf(item.validatedGoal).x)
  for edgeOffset in 0 ..< route.descriptor.edgeCount.int:
    let
      edge = route.resultEdgeAt(edgeOffset)
      segment = edge.routeEdgeSegment
      metadata = index.routeSegmentAt(segment)
    for offset in 0 ..< metadata.cellLen.int:
      let cell = index.segmentCellAt(segment, offset,
        edge.routeEdgeReversed).int
      rooms.incl index.roomForCell(cell)
  var expanded = rooms
  for cell in 0 ..< index.routeIndexStats.navCells:
    let room = index.roomForCell(cell)
    if room < 0: continue
    let
      point = (x: cell mod map.gridWidth, y: cell div map.gridWidth)
      legal = index.legalMovesAt(cell)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let next = (x: point.x + delta.x, y: point.y + delta.y)
      let nextRoom = index.roomForCell(next.y * map.gridWidth + next.x)
      if room in rooms: expanded.incl nextRoom
      if nextRoom in rooms: expanded.incl room
  result = newSeq[uint8](index.routeIndexStats.navCells)
  for cell in 0 ..< result.len:
    if index.roomForCell(cell) in expanded: result[cell] = 1

proc rowJson(variant: Variant, accum: Accum): JsonNode =
  var worstP95, worstMax = 0.0
  for values in accum.strata.values:
    worstP95 = max(worstP95, percentile(values, 0.95))
    if values.len > 0: worstMax = max(worstMax, max(values))
  %*{"name": variant.name, "landmarks": variant.landmarks,
    "corridor_margin": variant.corridorMargin,
    "missing": accum.missing, "illegal": accum.illegal,
    "overall_p95_inflation_pct": percentile(accum.inflations, 0.95),
    "overall_max_inflation_pct": max(accum.inflations),
    "worst_stratum_p95_inflation_pct": worstP95,
    "worst_stratum_max_inflation_pct": worstMax,
    "pops_p50": percentile(accum.pops, 0.50),
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95)}

proc measure(pool: JsonNode, corpus: NavCorpus): JsonNode =
  let variants = [
    Variant(name: "R3.3 binary baseline", landmarks: 0),
    Variant(name: "R4.1 ALT L4", landmarks: 4),
    Variant(name: "R4.1 ALT L8", landmarks: 8),
    Variant(name: "R4.1 ALT L16", landmarks: 16),
    Variant(name: "R4.1 corridor plus adjacent rooms", landmarks: 0,
      corridorMargin: true)]
  var
    accum = newSeq[Accum](variants.len)
    buildRows = newJArray()
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"R4.1 map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      graph = map.buildMixedGraph()
      index = newBodyRouteIndex(map)
      landmarks = index.buildLandmarks(16)
      queryScratch = newBodyRouteQueryScratch(index)
    buildRows.add %*{"map": pool[poolIndex]["name"].getStr(),
      "nav_cells": landmarks.cellCount,
      "retained_bytes_l4": landmarks.cellCount * 4 * sizeof(uint16),
      "retained_bytes_l8": landmarks.cellCount * 8 * sizeof(uint16),
      "retained_bytes_l16": landmarks.cellCount * 16 * sizeof(uint16),
      "build_ns_l4": landmarks.buildNanoseconds[3],
      "build_ns_l8": landmarks.buildNanoseconds[7],
      "build_ns_l16": landmarks.buildNanoseconds[15]}
    var
      workspaces = newSeq[AltWorkspace](variants.len)
      dangerByHash = initTable[string, BodyDangerField]()
      weightsByKey = initTable[string, seq[int32]]()
    for workspace in workspaces.mitems:
      workspace = newAltWorkspace(graph.nodeCount)
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      let
        danger = dangerByHash[item.dangerHash]
        weightKey = item.dangerHash & "/" & $item.profile
      if weightKey notin weightsByKey:
        weightsByKey[weightKey] = danger.buildWeights(item.profile)
      let
        hot = map.buildHot(danger)
        refined = graph.buildRefined(hot)
        hazard = newSeq[int32](map.gridWidth * map.gridHeight)
      for variantIndex, variant in variants:
        let allowed = if variant.corridorMargin:
            corridorWithMargin(map, index, queryScratch, item, danger)
          else: newSeq[uint8]()
        let started = getMonoTime()
        let found = graph.searchAlt(map, item, refined,
          weightsByKey[weightKey], hazard, landmarks, variant.landmarks,
          allowed, workspaces[variantIndex])
        let elapsed = (getMonoTime() - started).inNanoseconds.float
        if not found.reached:
          inc accum[variantIndex].missing
          continue
        if not map.routeLegal(item, found.route):
          inc accum[variantIndex].illegal
          continue
        let inflation = routeInflationPct(
          oracleFloatCost(resampleRoute4px(found.route), map, danger,
            item.profile.corpusProfile, item.blockedCell), item.oracleCost)
        let key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
        accum[variantIndex].inflations.add inflation
        accum[variantIndex].strata.mgetOrPut(key, @[]).add inflation
        accum[variantIndex].pops.add found.pops.float
        accum[variantIndex].nanoseconds.add elapsed
  var rows = newJArray()
  for index, variant in variants:
    rows.add rowJson(variant, accum[index])
  %*{"rows": rows, "landmark_builds": buildRows}

proc measureColossal(): JsonNode =
  stderr.writeLine "R4.1 colossal landmark build"
  let
    map = colossalMap()
    index = newBodyRouteIndex(map)
    landmarks = index.buildLandmarks(16)
  %*{"map": "size:colossal", "nav_cells": landmarks.cellCount,
    "retained_bytes_l4": landmarks.cellCount * 4 * sizeof(uint16),
    "retained_bytes_l8": landmarks.cellCount * 8 * sizeof(uint16),
    "retained_bytes_l16": landmarks.cellCount * 16 * sizeof(uint16),
    "build_ns_l4": landmarks.buildNanoseconds[3],
    "build_ns_l8": landmarks.buildNanoseconds[7],
    "build_ns_l16": landmarks.buildNanoseconds[15]}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r41 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    measured = pool.measure(corpus)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r41", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "rows": measured["rows"],
    "landmark_builds": measured["landmark_builds"],
    "colossal": measureColossal()})
