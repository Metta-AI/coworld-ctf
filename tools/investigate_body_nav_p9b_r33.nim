## P9B Round 3.3: dense danger-adaptive plus wall-band navigation.

import std/[algorithm, json, math, monotimes, options, os, strformat, tables,
  times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_map, body_planner, body_route_index]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31

const
  Samples = 7
  TieBits = 21
  TieMask = (1'i64 shl TieBits) - 1
  ClosedBit = 0x8000_0000'u32
  FineStep = 4

type
  KeyHeap = object
    keys: seq[int64]
    positions: seq[int32]
    len: int

  DenseWorkspace* = object
    generation: uint32
    g, parent, parentBridge, goalCost: seq[int32]
    state, goalStamp: seq[uint32]
    heap: KeyHeap

  MixedGraph* = object
    legality*: FineLegality
    cellForNode*: seq[int32]
    fineForCell*: seq[array[4, int32]]
    anchorForCell*: seq[int32]
    anchorNode*: seq[uint8]
    wallBand*: seq[uint8]
    bridgeOffset*: seq[array[8, int32]]
    bridgeLen*: seq[array[8, uint8]]
    bridgeNodes*: seq[int32]
    wallBandCells*, wallBandFineNodes*: int

  SearchResult* = object
    reached*: bool
    pops*: int
    route*: seq[BodyPoint]

  Accum = object
    inflations, pops, nanoseconds, hotCells, unionCells, activeNodes: seq[float64]
    strata: Table[string, seq[float64]]
    missing, illegal, longest: int

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc findCase*(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id: return item
  raise newException(ValueError, "corpus case not found: " & id)

proc percentile*(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

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
  doAssert heap.len < heap.keys.len
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

proc newWorkspace*(count: int): DenseWorkspace =
  doAssert count <= (1 shl TieBits)
  result.g = newSeq[int32](count)
  result.parent = newSeq[int32](count)
  result.parentBridge = newSeq[int32](count)
  result.goalCost = newSeq[int32](count)
  result.state = newSeq[uint32](count)
  result.goalStamp = newSeq[uint32](count)
  result.heap.keys = newSeq[int64](count)
  result.heap.positions = newSeq[int32](count)

proc begin(workspace: var DenseWorkspace) =
  inc workspace.generation
  if workspace.generation == 0 or
      (workspace.generation and ClosedBit) != 0:
    for stamp in workspace.state.mitems: stamp = 0
    for stamp in workspace.goalStamp.mitems: stamp = 0
    workspace.generation = 1
  workspace.heap.len = 0

proc chooseAnchor(table: FineLegality, map: BodyMap,
    cell: BodyPoint): int32 =
  let center = cellCenter(cell)
  let centerNode = center.y div FineStep * table.width +
    center.x div FineStep
  if centerNode >= 0 and centerNode < table.legal.len and
      table.standable.bitAt(centerNode):
    return int32(centerNode)
  var
    best = -1
    bestClearance = low(int)
    bestDistance = high(int)
  for dy in [0, FineStep]:
    for dx in [0, FineStep]:
      let point = (x: cell.x * NavCell + dx, y: cell.y * NavCell + dy)
      if map.cellOf(point) != cell: continue
      let node = point.y div FineStep * table.width + point.x div FineStep
      if node < 0 or node >= table.legal.len or
          not table.standable.bitAt(node): continue
      let
        clearance = map.clearanceAt(point)
        distance = (point.x - center.x) * (point.x - center.x) +
          (point.y - center.y) * (point.y - center.y)
      if best < 0 or clearance > bestClearance or
          (clearance == bestClearance and distance < bestDistance):
        best = node
        bestClearance = clearance
        bestDistance = distance
  int32(best)

proc findBridge(table: FineLegality, startNode,
    targetNode: int): seq[int32] =
  if startNode == targetNode: return
  let
    startX = startNode mod table.width
    startY = startNode div table.width
    targetX = targetNode mod table.width
    targetY = targetNode div table.width
    minX = max(0, min(startX, targetX) - 2)
    maxX = min(table.width - 1, max(startX, targetX) + 2)
    minY = max(0, min(startY, targetY) - 2)
    maxY = min(table.height - 1, max(startY, targetY) + 2)
  var
    nodes: array[128, int32]
    parents: array[128, int16]
    head, tail, found: int
  nodes[0] = int32(startNode)
  parents[0] = -1
  tail = 1
  found = -1
  while head < tail and found < 0:
    let
      node = nodes[head].int
      x = node mod table.width
      y = node div table.width
      legal = table.legal[node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let
        nextX = x + delta.x
        nextY = y + delta.y
      if nextX < minX or nextX > maxX or nextY < minY or nextY > maxY:
        continue
      let nextNode = nextY * table.width + nextX
      var seen = false
      for offset in 0 ..< tail:
        if nodes[offset].int == nextNode:
          seen = true
          break
      if seen: continue
      doAssert tail < nodes.len
      nodes[tail] = int32(nextNode)
      parents[tail] = int16(head)
      if nextNode == targetNode:
        found = tail
        break
      inc tail
    inc head
  if found < 0: return
  var cursor = found
  while cursor > 0:
    result.add nodes[cursor]
    cursor = parents[cursor].int
  result.reverse()

proc buildMixedGraph*(map: BodyMap): MixedGraph =
  result.legality = map.buildFineLegality()
  let
    nodeCount = result.legality.legal.len
    cellCount = map.gridWidth * map.gridHeight
  result.cellForNode = newSeq[int32](nodeCount)
  result.fineForCell = newSeq[array[4, int32]](cellCount)
  for nodes in result.fineForCell.mitems:
    for node in nodes.mitems: node = -1
  result.anchorForCell = newSeq[int32](cellCount)
  result.anchorNode = newSeq[uint8](nodeCount)
  result.wallBand = newSeq[uint8](cellCount)
  result.bridgeOffset = newSeq[array[8, int32]](cellCount)
  result.bridgeLen = newSeq[array[8, uint8]](cellCount)
  for offsets in result.bridgeOffset.mitems:
    for offset in offsets.mitems: offset = -1
  for node in 0 ..< nodeCount:
    let cell = map.cellOf(pointAt(node, result.legality.width))
    let cellIndex = cell.y * map.gridWidth + cell.x
    result.cellForNode[node] = int32(cellIndex)
    let point = pointAt(node, result.legality.width)
    let slot = ((point.y mod NavCell) div FineStep) * 2 +
      ((point.x mod NavCell) div FineStep)
    result.fineForCell[cellIndex][slot] = int32(node)
  var wallSeeds = newSeq[uint8](cellCount)
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      let
        cell = (x: x, y: y)
        cellIndex = y * map.gridWidth + x
        anchor = result.legality.chooseAnchor(map, cell)
      result.anchorForCell[cellIndex] = anchor
      if anchor >= 0:
        result.anchorNode[anchor.int] = 1
        if not map.cellWalkable(cell): wallSeeds[cellIndex] = 1
  for source, seeded in wallSeeds:
    if seeded == 0: continue
    let cell = (x: source mod map.gridWidth, y: source div map.gridWidth)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let next = (x: cell.x + dx, y: cell.y + dy)
        if next.x >= 0 and next.x < map.gridWidth and
            next.y >= 0 and next.y < map.gridHeight:
          result.wallBand[next.y * map.gridWidth + next.x] = 1
  for value in result.wallBand:
    if value != 0: inc result.wallBandCells
  for node in 0 ..< nodeCount:
    if result.wallBand[result.cellForNode[node].int] != 0 and
        result.legality.standable.bitAt(node):
      inc result.wallBandFineNodes
  for cellIndex in 0 ..< cellCount:
    let
      node = result.anchorForCell[cellIndex].int
      cell = (x: cellIndex mod map.gridWidth,
        y: cellIndex div map.gridWidth)
    if node < 0: continue
    for direction, delta in NavNeighbors:
      let next = (x: cell.x + delta.x, y: cell.y + delta.y)
      if next.x < 0 or next.x >= map.gridWidth or
          next.y < 0 or next.y >= map.gridHeight: continue
      let nextIndex = next.y * map.gridWidth + next.x
      let target = result.anchorForCell[nextIndex].int
      if target < 0: continue
      let path = result.legality.findBridge(node, target)
      if path.len == 0 or path.len > high(uint8).int: continue
      result.bridgeOffset[cellIndex][direction] =
        int32(result.bridgeNodes.len)
      result.bridgeLen[cellIndex][direction] = uint8(path.len)
      result.bridgeNodes.add path

proc buildHot*(map: BodyMap, danger: BodyDangerField): seq[uint8] =
  result = newSeq[uint8](map.gridWidth * map.gridHeight)
  for source, value in danger.values:
    if value <= 0: continue
    let cell = (x: source mod map.gridWidth, y: source div map.gridWidth)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let next = (x: cell.x + dx, y: cell.y + dy)
        if next.x >= 0 and next.x < map.gridWidth and
            next.y >= 0 and next.y < map.gridHeight:
          result[next.y * map.gridWidth + next.x] = 1

proc buildRefined*(graph: MixedGraph, hot: openArray[uint8]): seq[uint8] =
  result = newSeq[uint8](hot.len)
  for cell in 0 ..< hot.len:
    result[cell] = hot[cell] or graph.wallBand[cell]

proc nodeCount*(graph: MixedGraph): int = graph.legality.legal.len

proc active*(graph: MixedGraph, refined: openArray[uint8],
    node: int, startNode = -1, goalNode = -1): bool {.inline.} =
  graph.legality.standable.bitAt(node) and
    (node == startNode or node == goalNode or
      refined[graph.cellForNode[node].int] != 0 or
      graph.anchorNode[node] != 0)

proc profileWeightQ8(profile: NavCorpusProfile): int64 {.inline.} =
  case profile
  of ncpDefault: 256
  of ncpCarrier: 640
  of ncpHunter: 64

proc quantizeDangerQ8(value: float32): int64 {.inline.} =
  if value <= 0: return 0
  let scaled = value.float * 256.0
  let lower = floor(scaled).int64
  let fraction = scaled - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0): lower + 1
  else: lower

proc buildWeights*(danger: BodyDangerField,
    profile: NavCorpusProfile): seq[int32] =
  result = newSeq[int32](danger.values.len)
  let weight = profile.profileWeightQ8
  for cell, value in danger.values:
    result[cell] = int32(65_536'i64 + weight * quantizeDangerQ8(value))

proc octileQ4*(a, b: BodyPoint, diagonalCost: int): int32 {.inline.} =
  let
    dx = abs(a.x - b.x) div FineStep
    dy = abs(a.y - b.y) div FineStep
    diagonal = min(dx, dy)
  int32(diagonalCost * diagonal + 64 * (max(dx, dy) - diagonal))

proc midpointCell*(map: BodyMap, a, b: BodyPoint): int {.inline.} =
  let cell = map.cellOf(((a.x + b.x) div 2, (a.y + b.y) div 2))
  cell.y * map.gridWidth + cell.x

proc distanceQ4(dx, dy: int): int32 {.inline.} =
  case dx * dx + dy * dy
  of 0: 0
  of 1: 16
  of 2: 23
  of 4: 32
  of 5: 36
  of 8: 45
  of 9: 48
  of 10: 51
  of 13: 58
  of 16: 64
  of 17: 66
  of 18: 68
  of 20: 72
  of 25: 80
  of 32: 91
  else: raise newException(ValueError, "edge subdivision exceeded 4 px")

proc roundedFraction(delta, part, parts: int): int {.inline.} =
  let numerator = delta * part
  if numerator >= 0: (numerator + parts div 2) div parts
  else: -((-numerator + parts div 2) div parts)

proc integratedEdgeCostQ4*(map: BodyMap, weights,
    hazardCost: openArray[int32], blockedCell: int,
    a, b: BodyPoint): int32 {.inline.} =
  let
    dx = b.x - a.x
    dy = b.y - a.y
    parts = max(1, (max(abs(dx), abs(dy)) + FineStep - 1) div FineStep)
  var previous = a
  for part in 1 .. parts:
    let next = (x: a.x + roundedFraction(dx, part, parts),
      y: a.y + roundedFraction(dy, part, parts))
    let
      cell = map.midpointCell(previous, next)
      base = distanceQ4(abs(next.x - previous.x),
        abs(next.y - previous.y)).int64
      weighted = (base * weights[cell].int64 + 32_768) shr 16
      blocked = if cell == blockedCell: weighted * 8 else: weighted
    result += int32(blocked + hazardCost[cell].int64)
    previous = next

proc attachments*(graph: MixedGraph, map: BodyMap,
    refined: openArray[uint8], weights, hazardCost: openArray[int32],
    blockedCell: int, endpoint: BodyPoint):
    seq[tuple[node: int, cost: int32]] =
  if endpoint.x mod FineStep == 0 and endpoint.y mod FineStep == 0:
    let node = endpoint.y div FineStep * graph.legality.width +
      endpoint.x div FineStep
    if node >= 0 and node < graph.legality.legal.len and
        graph.legality.standable.bitAt(node):
      return @[(node: node, cost: 0'i32)]
  let center = map.cellOf(endpoint)
  var seen = initTable[int, bool]()
  for ring in 0 .. PortalAnchorRingCells:
    for y in max(0, center.y - ring) .. min(map.gridHeight - 1,
        center.y + ring):
      for x in max(0, center.x - ring) .. min(map.gridWidth - 1,
          center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring: continue
        let cellIndex = y * map.gridWidth + x
        if refined[cellIndex] != 0:
          for rawNode in graph.fineForCell[cellIndex]:
            let node = rawNode.int
            if node < 0 or not graph.active(refined, node) or node in seen:
              continue
            let point = pointAt(node, graph.legality.width)
            if map.segmentClear(endpoint, point):
              seen[node] = true
              result.add (node: node,
                cost: map.integratedEdgeCostQ4(weights, hazardCost,
                  blockedCell, endpoint, point))
        else:
          let node = graph.anchorForCell[cellIndex].int
          if node >= 0 and node notin seen:
            let point = pointAt(node, graph.legality.width)
            if map.segmentClear(endpoint, point):
              seen[node] = true
              result.add (node: node,
                cost: map.integratedEdgeCostQ4(weights, hazardCost,
                  blockedCell, endpoint, point))

proc search*(graph: MixedGraph, map: BodyMap,
    item: NavCorpusCase, refined: openArray[uint8], weights,
    hazardCost: openArray[int32], workspace: var DenseWorkspace): SearchResult =
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
  if starts.len == 0 or goals.len == 0: return
  for goal in goals:
    if workspace.goalStamp[goal.node] != generation or
        goal.cost < workspace.goalCost[goal.node]:
      workspace.goalStamp[goal.node] = generation
      workspace.goalCost[goal.node] = goal.cost
  let allowance = int32(PortalAnchorRingCells * NavCell * 23)
  for start in starts:
    if workspace.state[start.node] != generation or
        start.cost < workspace.g[start.node]:
      workspace.g[start.node] = start.cost
      workspace.parent[start.node] = -1
      workspace.parentBridge[start.node] = -1
      let heuristic = max(0'i32,
        octileQ4(pointAt(start.node, graph.legality.width),
          item.validatedGoal, 90) - allowance)
      workspace.heap.pushOrDecrease(workspace.state, generation,
        makeKey(start.cost.int64 + heuristic.int64, start.node))
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
        if graph.active(refined, nextNode, startNode, goalNode) and
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
            let f = candidate64 + max(0'i32,
              octileQ4(pointAt(nextNode, graph.legality.width),
                item.validatedGoal, 90) - allowance).int64
            workspace.heap.pushOrDecrease(workspace.state, generation,
              makeKey(f, nextNode))
            workspace.state[nextNode] = generation
      if graph.anchorNode[node] == 0: continue
      let sourceCell = graph.cellForNode[node].int
      let
        offset = graph.bridgeOffset[sourceCell][direction].int
        pathLen = graph.bridgeLen[sourceCell][direction].int
      if offset < 0 or pathLen == 0: continue
      let target = graph.bridgeNodes[offset + pathLen - 1].int
      if workspace.state[target] == (generation or ClosedBit): continue
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
        let f = candidate64 + max(0'i32,
          octileQ4(previous, item.validatedGoal, 90) - allowance).int64
        workspace.heap.pushOrDecrease(workspace.state, generation,
          makeKey(f, target))
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

proc routeLegal*(map: BodyMap, item: NavCorpusCase,
    route: openArray[BodyPoint]): bool =
  if route.len == 0 or route[0] != item.start or
      route[^1] != item.validatedGoal: return false
  for point in route:
    if not map.canStand(point) or map.componentOf(point) != item.component:
      return false
  for offset in 1 ..< route.len:
    if not map.segmentClear(route[offset - 1], route[offset]): return false
  true

proc resultRow(name: string, values: openArray[float64]): JsonNode =
  %*{"stratum": name, "count": values.len,
    "p95_inflation_pct": percentile(values, 0.95),
    "max_inflation_pct": if values.len == 0: Inf else: max(values)}

proc accumJson(accum: Accum, maxSharedBytes, maxWallCells,
    maxWallFineNodes: int): JsonNode =
  var rows = newJArray()
  rows.add resultRow("overall", accum.inflations)
  for roster in [16, 32]:
    for profile in NavCorpusProfile:
      for dynamic in NavCorpusDynamic:
        for distance in NavCorpusDistance:
          let key = &"r{roster}/{profile}/{dynamic}/{distance}"
          rows.add resultRow(key, accum.strata.getOrDefault(key))
  %*{"name": "R3.3_danger_plus_wall_band", "missing": accum.missing,
    "illegal": accum.illegal, "longest_path_cells": accum.longest,
    "pops_p50": percentile(accum.pops, 0.50),
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": if accum.pops.len == 0: 0.0 else: max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95),
    "hot_cells_mean": sum(accum.hotCells) / accum.hotCells.len.float,
    "hot_cells_max": max(accum.hotCells),
    "union_cells_mean": sum(accum.unionCells) / accum.unionCells.len.float,
    "union_cells_max": max(accum.unionCells),
    "active_nodes_mean": sum(accum.activeNodes) / accum.activeNodes.len.float,
    "active_nodes_max": max(accum.activeNodes),
    "wall_band_cells_max": maxWallCells,
    "wall_band_fine_nodes_max": maxWallFineNodes,
    "shared_bytes_max": maxSharedBytes, "quality": rows}

proc countNonzero(values: openArray[uint8]): int =
  for value in values:
    if value != 0: inc result

proc activeNodeCount(graph: MixedGraph,
    refined: openArray[uint8]): int =
  for node in 0 ..< graph.legality.legal.len:
    if graph.active(refined, node): inc result

proc measure(pool: JsonNode, corpus: NavCorpus): JsonNode =
  var accum: Accum
  var maxSharedBytes, maxWallCells, maxWallFineNodes: int
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"R3.3 map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      graph = map.buildMixedGraph()
      nodeCount = graph.legality.legal.len
      sharedBytes = graph.legality.legal.len + graph.legality.standable.len +
        nodeCount * (sizeof(int32) + sizeof(uint8) +
          sizeof(int32) * 6 + sizeof(uint32) * 2 +
          sizeof(int64) + sizeof(int32)) +
        graph.anchorForCell.len * (sizeof(int32) + sizeof(array[4, int32])) +
        graph.wallBand.len +
        graph.bridgeOffset.len * (sizeof(array[8, int32]) +
          sizeof(array[8, uint8])) + graph.bridgeNodes.len * sizeof(int32)
    maxSharedBytes = max(maxSharedBytes, sharedBytes)
    maxWallCells = max(maxWallCells, graph.wallBandCells)
    maxWallFineNodes = max(maxWallFineNodes, graph.wallBandFineNodes)
    var
      workspace = newWorkspace(nodeCount)
      dangerByHash = initTable[string, BodyDangerField]()
      weightsByKey = initTable[string, seq[int32]]()
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
        hazardCost = newSeq[int32](map.gridWidth * map.gridHeight)
        started = getMonoTime()
        found = graph.search(map, item, refined,
          weightsByKey[weightKey], hazardCost, workspace)
        elapsed = (getMonoTime() - started).inNanoseconds
      accum.hotCells.add countNonzero(hot).float
      accum.unionCells.add countNonzero(refined).float
      accum.activeNodes.add graph.activeNodeCount(refined).float
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
      accum.inflations.add inflation
      accum.strata.mgetOrPut(key, @[]).add inflation
      accum.pops.add found.pops.float
      accum.nanoseconds.add elapsed.float
      accum.longest = max(accum.longest, found.route.len)
  accum.accumJson(maxSharedBytes, maxWallCells, maxWallFineNodes)

proc profileCase(pool: JsonNode, corpus: NavCorpus, id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    graph = map.buildMixedGraph()
    danger = map.buildOracleDanger(item)
    hot = map.buildHot(danger)
    refined = graph.buildRefined(hot)
    weights = danger.buildWeights(item.profile)
    hazardCost = newSeq[int32](map.gridWidth * map.gridHeight)
  var workspace = newWorkspace(graph.legality.legal.len)
  var samples = newJArray()
  for _ in 0 ..< Samples:
    let started = getMonoTime()
    let found = graph.search(map, item, refined, weights,
      hazardCost, workspace)
    let elapsed = (getMonoTime() - started).inNanoseconds
    samples.add %*{"ns": elapsed, "pops": found.pops,
      "reached": found.reached, "path_cells": found.route.len}
  %*{"id": id, "hot_cells": countNonzero(hot),
    "union_cells": countNonzero(refined),
    "active_nodes": graph.activeNodeCount(refined), "samples": samples}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r33 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    result = pool.measure(corpus)
    median = pool.profileCase(corpus,
      "m09-br-gen-21450-r32-s9-default-blocked-far")
    far = pool.profileCase(corpus,
      "m15-br-gen-22010-r16-s15-default-danger-far")
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r33", "v": 1,
    "result": result, "profiles": [median, far]})
