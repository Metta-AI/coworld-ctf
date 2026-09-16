## Pop-budgeted mixed-resolution body route search.

import std/[algorithm, math]
import body_danger, body_hazard, body_map, body_route_index
import types as shellTypes

type
  BodyRouteFailure* = enum
    brfNone
    brfStartAttach
    brfGoalAttach
    brfDisconnected
    brfLocalCap
    brfSideCap
    brfDescriptorOverflow
    brfValidation

const
  BodyRoutePopBudgetPerTick* = 1_024
  BodyFineStepPx* = 4
  BodyRouteSpanCap* = 4_096
  BodyEndpointAttachmentCap* = 512
  BodyDialClosedBit = 0x8000_0000'u32
  BodyDialMaxBuckets = 262_144
  BodyDialDefaultBuckets = 131_072

type
  BodyFineLegality* = object
    width*, height*: int
    standable*: seq[uint8]
    legal*: seq[uint8]

  BodyMixedGraph* = ref object
    map*: BodyMap
    legality*: BodyFineLegality
    cellForNode*: seq[int32]
    fineForCell*: seq[array[4, int32]]
    anchorForCell*: seq[int32]
    anchorNode*: seq[uint8]
    wallBand*: seq[uint8]
    bridgeOffset*: seq[array[8, int32]]
    bridgeLen*: seq[array[8, uint8]]
    bridgeNodes*: seq[int32]

  BodyDialQueue = object
    bucketCount, len: int
    currentF: int32
    generation: uint32
    head, tail, touchedGeneration: seq[int32]
    next, previous, bucket, queuedF: seq[int32]

  BodyRouteWorkspace* = ref object
    generation*: uint32
    g*, parent*, parentBridge*, goalCost*: seq[int32]
    state*, goalStamp*: seq[uint32]
    reconstruct*: seq[int32]
    queue: BodyDialQueue

  BodyRouteSearchRequest* = object
    start*, goal*: BodyPoint
    profile*: shellTypes.CostProfile
    blockedCell*: int32
    elapsedZoneTick*: int32
    requestGeneration*, dangerGeneration*: uint64

  BodyRouteSearchJob* = object
    active*, complete*: bool
    workspaceGeneration*: uint32
    request*: BodyRouteSearchRequest
    startNode*, goalNode*, bestNode*: int32
    bestCost*: int32
    settledPops*, queuePops*: int32

  BodyRouteSpan* = object
    start*: BodyPoint
    deltaX*, deltaY*: int16
    steps*: uint16

  BodyRouteBuild* = object
    ok*: bool
    failure*: BodyRouteFailure
    spans*: array[BodyRouteSpanCap, BodyRouteSpan]
    spanCount*: uint16
    pointCount*: int32
    settledPops*, queuePops*: int32

  BodyMixedGraphBytes* = object
    legality*, cellForNode*, fineForCell*, anchors*, wallBand*: int64
    bridges*, workspace*, buckets*, reconstruction*, allocatorOverhead*: int64
    total*: int64

  BodyAttachmentSet = object
    nodes: array[BodyEndpointAttachmentCap, int32]
    costs: array[BodyEndpointAttachmentCap, int32]
    len: int

static:
  doAssert sizeof(BodyRouteSpan) <= 24
  doAssert sizeof(BodyRouteSearchRequest) <= 64
  doAssert sizeof(BodyRouteSearchJob) <= 128

proc fineBitAt(bits: openArray[uint8], index: int): bool {.inline.} =
  (bits[index shr 3] and uint8(1 shl (index and 7))) != 0

proc setFineBit(bits: var seq[uint8], index: int) {.inline.} =
  bits[index shr 3] = bits[index shr 3] or uint8(1 shl (index and 7))

proc finePoint*(graph: BodyMixedGraph, node: int): BodyPoint {.inline.} =
  (x: (node mod graph.legality.width) * BodyFineStepPx,
    y: (node div graph.legality.width) * BodyFineStepPx)

proc buildBodyFineLegality(map: BodyMap): BodyFineLegality =
  result.width = (map.width - 1) div BodyFineStepPx + 1
  result.height = (map.height - 1) div BodyFineStepPx + 1
  let count = result.width * result.height
  result.standable = newSeq[uint8]((count + 7) div 8)
  result.legal = newSeq[uint8](count)
  for node in 0 ..< count:
    let point: BodyPoint = (x: (node mod result.width) * BodyFineStepPx,
      y: (node div result.width) * BodyFineStepPx)
    if map.canStand(point):
      result.standable.setFineBit(node)
  for node in 0 ..< count:
    if not result.standable.fineBitAt(node):
      continue
    let
      point: BodyPoint = (x: (node mod result.width) * BodyFineStepPx,
        y: (node div result.width) * BodyFineStepPx)
      x = node mod result.width
      y = node div result.width
    # Unit axis and diagonal segments have the same samples in reverse.
    for (direction, reverse) in [(1, 0), (3, 2), (6, 5), (7, 4)]:
      let delta = NavNeighbors[direction]
      let next = (x: x + delta.x, y: y + delta.y)
      if next.x < 0 or next.x >= result.width or
          next.y < 0 or next.y >= result.height:
        continue
      let nextNode = next.y * result.width + next.x
      if result.standable.fineBitAt(nextNode):
        let nextPoint: BodyPoint = (x: next.x * BodyFineStepPx,
          y: next.y * BodyFineStepPx)
        if map.segmentClear(point, nextPoint):
          result.legal[node] = result.legal[node] or uint8(1 shl direction)
          result.legal[nextNode] = result.legal[nextNode] or uint8(1 shl reverse)

proc chooseBodyAnchor(table: BodyFineLegality; map: BodyMap;
    cell: BodyPoint): int32 =
  let center = cellCenter(cell)
  let centerNode = center.y div BodyFineStepPx * table.width +
    center.x div BodyFineStepPx
  if centerNode >= 0 and centerNode < table.legal.len and
      table.standable.fineBitAt(centerNode):
    return int32(centerNode)
  var best = -1
  var bestClearance = low(int)
  var bestDistance = high(int)
  for dy in [0, BodyFineStepPx]:
    for dx in [0, BodyFineStepPx]:
      let point: BodyPoint = (x: cell.x * NavCell + dx,
        y: cell.y * NavCell + dy)
      if map.cellOf(point) != cell:
        continue
      let node = point.y div BodyFineStepPx * table.width +
        point.x div BodyFineStepPx
      if node < 0 or node >= table.legal.len or
          not table.standable.fineBitAt(node):
        continue
      let
        clearance = map.clearanceAt(point)
        candidateDistance = (point.x - center.x) * (point.x - center.x) +
          (point.y - center.y) * (point.y - center.y)
      if best < 0 or clearance > bestClearance or
          (clearance == bestClearance and candidateDistance < bestDistance):
        best = node
        bestClearance = clearance
        bestDistance = candidateDistance
  int32(best)

proc findBodyBridge(table: BodyFineLegality; startNode,
    targetNode: int): seq[int32] =
  if startNode == targetNode:
    return
  let
    startX = startNode mod table.width
    startY = startNode div table.width
    targetX = targetNode mod table.width
    targetY = targetNode div table.width
    minX = max(0, min(startX, targetX) - 2)
    maxX = min(table.width - 1, max(startX, targetX) + 2)
    minY = max(0, min(startY, targetY) - 2)
    maxY = min(table.height - 1, max(startY, targetY) + 2)
  # For regular anchors this is the same first two-hop path as the BFS:
  # cardinal hops precede diagonals, and a two-step diagonal is unique.
  for direction, delta in NavNeighbors:
    if targetX - startX == 2 * delta.x and targetY - startY == 2 * delta.y:
      let middle = startNode + delta.y * table.width + delta.x
      let bit = uint8(1 shl direction)
      if (table.legal[startNode] and bit) != 0 and
          (table.legal[middle] and bit) != 0:
        return @[int32(middle), int32(targetNode)]
      break
  var nodes: array[128, int32]
  var parents: array[128, int16]
  var head = 0
  var tail = 1
  var found = -1
  nodes[0] = int32(startNode)
  parents[0] = -1
  while head < tail and found < 0:
    let
      node = nodes[head].int
      x = node mod table.width
      y = node div table.width
      legal = table.legal[node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0:
        continue
      let next = (x: x + delta.x, y: y + delta.y)
      if next.x < minX or next.x > maxX or
          next.y < minY or next.y > maxY:
        continue
      let nextNode = next.y * table.width + next.x
      var seen = false
      for offset in 0 ..< tail:
        if nodes[offset].int == nextNode:
          seen = true
          break
      if seen:
        continue
      if tail >= nodes.len:
        return
      nodes[tail] = int32(nextNode)
      parents[tail] = int16(head)
      if nextNode == targetNode:
        found = tail
        break
      inc tail
    inc head
  if found < 0:
    return
  var cursor = found
  while cursor > 0:
    result.add nodes[cursor]
    cursor = parents[cursor].int
  result.reverse()

proc newBodyMixedGraph*(map: BodyMap): BodyMixedGraph =
  if map == nil:
    raise newException(ValueError, "body mixed graph requires a map")
  new(result)
  result.map = map
  result.legality = buildBodyFineLegality(map)
  let
    nodeCount = result.legality.legal.len
    cellCount = map.gridWidth * map.gridHeight
  result.cellForNode = newSeq[int32](nodeCount)
  result.fineForCell = newSeq[array[4, int32]](cellCount)
  result.anchorForCell = newSeq[int32](cellCount)
  result.anchorNode = newSeq[uint8](nodeCount)
  result.wallBand = newSeq[uint8](cellCount)
  result.bridgeOffset = newSeq[array[8, int32]](cellCount)
  result.bridgeLen = newSeq[array[8, uint8]](cellCount)
  for nodes in result.fineForCell.mitems:
    for node in nodes.mitems:
      node = -1
  for offset in result.bridgeOffset.mitems:
    for value in offset.mitems:
      value = -1
  for node in 0 ..< nodeCount:
    let point = result.finePoint(node)
    let cell = map.cellOf(point)
    let cellIndex = cell.y * map.gridWidth + cell.x
    result.cellForNode[node] = int32(cellIndex)
    let slot = ((point.y mod NavCell) div BodyFineStepPx) * 2 +
      ((point.x mod NavCell) div BodyFineStepPx)
    result.fineForCell[cellIndex][slot] = int32(node)
  var wallSeeds = newSeq[uint8](cellCount)
  for cellIndex in 0 ..< cellCount:
    let cell: BodyPoint = (x: cellIndex mod map.gridWidth,
      y: cellIndex div map.gridWidth)
    let anchor = chooseBodyAnchor(result.legality, map, cell)
    result.anchorForCell[cellIndex] = anchor
    if anchor >= 0:
      result.anchorNode[anchor.int] = 1
      if not map.cellWalkable(cell):
        wallSeeds[cellIndex] = 1
  for source, seeded in wallSeeds:
    if seeded == 0:
      continue
    let cell: BodyPoint = (x: source mod map.gridWidth,
      y: source div map.gridWidth)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let next = (x: cell.x + dx, y: cell.y + dy)
        if next.x >= 0 and next.x < map.gridWidth and
            next.y >= 0 and next.y < map.gridHeight:
          result.wallBand[next.y * map.gridWidth + next.x] = 1
  for cellIndex in 0 ..< cellCount:
    let
      node = result.anchorForCell[cellIndex].int
      cell: BodyPoint = (x: cellIndex mod map.gridWidth,
        y: cellIndex div map.gridWidth)
    if node < 0:
      continue
    for direction, delta in NavNeighbors:
      let next = (x: cell.x + delta.x, y: cell.y + delta.y)
      if next.x < 0 or next.x >= map.gridWidth or
          next.y < 0 or next.y >= map.gridHeight:
        continue
      let target = result.anchorForCell[
        next.y * map.gridWidth + next.x].int
      if target < 0:
        continue
      let path = findBodyBridge(result.legality, node, target)
      if path.len == 0 or path.len > high(uint8).int:
        continue
      result.bridgeOffset[cellIndex][direction] =
        int32(result.bridgeNodes.len)
      result.bridgeLen[cellIndex][direction] = uint8(path.len)
      result.bridgeNodes.add path

proc packedDangerQ8(value: float32): uint16 {.inline.} =
  if value <= 0:
    return 0
  let scaled = value.float * 256.0
  let lower = scaled.int
  let fraction = scaled - lower.float
  let rounded = if fraction > 0.5 or
      (fraction == 0.5 and (lower and 1) != 0): lower + 1 else: lower
  if rounded > 0x7fff:
    raise newException(BodyMapError,
      "body danger exceeds the exact packed 15-bit Q8 range")
  uint16(rounded)

proc rebuildPackedWeights*(graph: BodyMixedGraph; danger: BodyDangerField;
    weights: var seq[int16]) =
  let cellCount = graph.map.gridWidth * graph.map.gridHeight
  if danger.values.len != cellCount:
    raise newException(ValueError, "body danger raster does not match graph")
  if weights.len != cellCount:
    weights = newSeq[int16](cellCount)
  let width = graph.map.gridWidth
  let height = graph.map.gridHeight
  for y in 0 ..< height:
    let above = max(0, y - 1) * width
    let row = y * width
    let below = min(height - 1, y + 1) * width
    template columnHot(x: int): bool =
      not (danger.values[above + x] <= 0) or
        not (danger.values[row + x] <= 0) or
        not (danger.values[below + x] <= 0)
    var leftHot = false
    var centerHot = columnHot(0)
    for x in 0 ..< width:
      let rightHot = x + 1 < width and columnHot(x + 1)
      var packed = packedDangerQ8(danger.values[row + x])
      if leftHot or centerHot or rightHot:
        packed = packed or 0x8000'u16
      weights[row + x] = cast[int16](packed)
      leftHot = centerHot
      centerHot = rightHot

proc packedHot(value: int16): bool {.inline.} =
  (cast[uint16](value) and 0x8000'u16) != 0

proc packedFactor(value: int16;
    profile: shellTypes.CostProfile): int32 {.inline.} =
  let profileWeight = case profile
    of shellTypes.cpDefault: 256'i32
    of shellTypes.cpCarrier: 640'i32
    of shellTypes.cpHunter: 64'i32
  65_536'i32 + profileWeight *
    int32(cast[uint16](value) and 0x7fff'u16)

proc mixedActive(graph: BodyMixedGraph; weights: openArray[int16];
    node, startNode, goalNode: int): bool {.inline.} =
  if not graph.legality.standable.fineBitAt(node):
    return false
  node == startNode or node == goalNode or graph.anchorNode[node] != 0 or
    graph.wallBand[graph.cellForNode[node].int] != 0 or
    weights[graph.cellForNode[node].int].packedHot

proc midpointCell(graph: BodyMixedGraph; a, b: BodyPoint): int {.inline.} =
  let midpoint: BodyPoint = (x: (a.x + b.x) div 2,
    y: (a.y + b.y) div 2)
  let cell = graph.map.cellOf(midpoint)
  cell.y * graph.map.gridWidth + cell.x

proc mixedStepCost(factor: int32; diagonal: bool): int32 {.inline.} =
  let base = if diagonal: 91'i64 else: 64'i64
  int32((base * factor.int64 + 32_768) shr 16)

proc integratedMixedCost(graph: BodyMixedGraph; weights: openArray[int16];
    profile: shellTypes.CostProfile; blockedCell: int32;
    hazard: BodyHazardOverlay; elapsedZoneTick: int; a, b: BodyPoint): int32 =
  let
    dx = b.x - a.x
    dy = b.y - a.y
    parts = max(1, (max(abs(dx), abs(dy)) + BodyFineStepPx - 1) div
      BodyFineStepPx)
  var previous = a
  for part in 1 .. parts:
    let
      xNumerator = dx * part
      yNumerator = dy * part
      next: BodyPoint = (x: a.x + (if xNumerator >= 0:
          (xNumerator + parts div 2) div parts
        else: -((-xNumerator + parts div 2) div parts)),
        y: a.y + (if yNumerator >= 0:
          (yNumerator + parts div 2) div parts
        else: -((-yNumerator + parts div 2) div parts)))
      cell = graph.midpointCell(previous, next)
      diagonal = previous.x != next.x and previous.y != next.y
      base = mixedStepCost(weights[cell].packedFactor(profile), diagonal)
      priced = if cell == blockedCell.int: base * 8 else: base
    result += priced
    if hazard != nil and hazard.state == bhsReady:
      result += int32(min(high(int32).int64,
        hazard.hazardStepCostQ4(cell, elapsedZoneTick,
          uint32(if diagonal: 91 else: 64))))
    previous = next

proc addAttachment(result: var BodyAttachmentSet; node: int32; cost: int32) =
  for offset in 0 ..< result.len:
    if result.nodes[offset] == node:
      if cost < result.costs[offset]:
        result.costs[offset] = cost
      return
  if result.len >= BodyEndpointAttachmentCap:
    raise newException(BodyMapError,
      "body route endpoint attachment capacity exceeded")
  result.nodes[result.len] = node
  result.costs[result.len] = cost
  inc result.len

proc attachments(graph: BodyMixedGraph; weights: openArray[int16];
    request: BodyRouteSearchRequest; endpoint: BodyPoint): BodyAttachmentSet =
  if endpoint.x mod BodyFineStepPx == 0 and
      endpoint.y mod BodyFineStepPx == 0:
    let node = endpoint.y div BodyFineStepPx * graph.legality.width +
      endpoint.x div BodyFineStepPx
    if node >= 0 and node < graph.legality.legal.len and
        graph.legality.standable.fineBitAt(node):
      result.addAttachment(int32(node), 0)
      return
  let center = graph.map.cellOf(endpoint)
  for ring in 0 .. PortalAnchorRingCells:
    for y in max(0, center.y - ring) ..
        min(graph.map.gridHeight - 1, center.y + ring):
      for x in max(0, center.x - ring) ..
          min(graph.map.gridWidth - 1, center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring:
          continue
        let cellIndex = y * graph.map.gridWidth + x
        if graph.wallBand[cellIndex] != 0 or weights[cellIndex].packedHot:
          for rawNode in graph.fineForCell[cellIndex]:
            let node = rawNode.int
            if node < 0 or not graph.mixedActive(weights, node, -1, -1):
              continue
            let point = graph.finePoint(node)
            if graph.map.segmentClear(endpoint, point):
              result.addAttachment(int32(node), graph.integratedMixedCost(
                weights, request.profile, request.blockedCell, nil,
                request.elapsedZoneTick.int, endpoint, point))
        else:
          let node = graph.anchorForCell[cellIndex]
          if node >= 0:
            let point = graph.finePoint(node.int)
            if graph.map.segmentClear(endpoint, point):
              result.addAttachment(node, graph.integratedMixedCost(weights,
                request.profile, request.blockedCell, nil,
                request.elapsedZoneTick.int, endpoint, point))

proc queueRemove(queue: var BodyDialQueue; node: int) {.inline.} =
  let bucket = queue.bucket[node].int
  if bucket < 0:
    return
  let previous = queue.previous[node]
  let next = queue.next[node]
  if previous >= 0:
    queue.next[previous] = next
  else:
    queue.head[bucket] = next
  if next >= 0:
    queue.previous[next] = previous
  else:
    queue.tail[bucket] = previous
  queue.bucket[node] = -1
  dec queue.len

proc queuePush(queue: var BodyDialQueue; node: int; f: int32) {.inline.} =
  if queue.bucket[node] >= 0:
    queue.queueRemove(node)
  let bucket = int(uint32(f) mod uint32(queue.bucketCount))
  if queue.touchedGeneration[bucket] != int32(queue.generation):
    queue.touchedGeneration[bucket] = int32(queue.generation)
    queue.head[bucket] = -1
    queue.tail[bucket] = -1
  let tail = queue.tail[bucket]
  queue.previous[node] = tail
  queue.next[node] = -1
  if tail >= 0:
    queue.next[tail] = int32(node)
  else:
    queue.head[bucket] = int32(node)
  queue.tail[bucket] = int32(node)
  queue.bucket[node] = int32(bucket)
  queue.queuedF[node] = f
  queue.currentF = min(queue.currentF, f)
  inc queue.len

proc queuePop(queue: var BodyDialQueue): tuple[node: int32, f: int32] =
  while queue.len > 0:
    let bucket = int(uint32(queue.currentF) mod uint32(queue.bucketCount))
    if queue.touchedGeneration[bucket] == int32(queue.generation):
      var node = queue.head[bucket]
      while node >= 0:
        if queue.queuedF[node] == queue.currentF:
          result = (node, queue.currentF)
          queue.queueRemove(node.int)
          return
        node = queue.next[node]
    inc queue.currentF
  raise newException(IndexDefect, "pop from empty body Dial queue")

proc beginQueue(queue: var BodyDialQueue) =
  inc queue.generation
  if queue.generation == 0 or queue.generation > uint32(high(int32)):
    for value in queue.touchedGeneration.mitems:
      value = 0
    queue.generation = 1
  queue.len = 0
  queue.currentF = high(int32)

proc newBodyRouteWorkspace*(graph: BodyMixedGraph;
    bucketCount = BodyDialDefaultBuckets): BodyRouteWorkspace =
  if graph == nil:
    raise newException(ValueError, "body route workspace requires a graph")
  if bucketCount <= 1 or bucketCount > BodyDialMaxBuckets:
    raise newException(ValueError, "body Dial bucket count is out of range")
  new(result)
  let count = graph.legality.legal.len
  result.g = newSeq[int32](count)
  result.parent = newSeq[int32](count)
  result.parentBridge = newSeq[int32](count)
  result.goalCost = newSeq[int32](count)
  result.state = newSeq[uint32](count)
  result.goalStamp = newSeq[uint32](count)
  result.reconstruct = newSeq[int32](count)
  result.queue.bucketCount = bucketCount
  result.queue.head = newSeq[int32](bucketCount)
  result.queue.tail = newSeq[int32](bucketCount)
  result.queue.touchedGeneration = newSeq[int32](bucketCount)
  result.queue.next = newSeq[int32](count)
  result.queue.previous = newSeq[int32](count)
  result.queue.bucket = newSeq[int32](count)
  result.queue.queuedF = newSeq[int32](count)

proc beginWorkspace(workspace: BodyRouteWorkspace) =
  inc workspace.generation
  if workspace.generation == 0 or
      (workspace.generation and BodyDialClosedBit) != 0:
    for stamp in workspace.state.mitems:
      stamp = 0
    for stamp in workspace.goalStamp.mitems:
      stamp = 0
    workspace.generation = 1
  workspace.queue.beginQueue()

proc octileFine(a, b: BodyPoint): int32 {.inline.} =
  let
    dx = abs(a.x - b.x) div BodyFineStepPx
    dy = abs(a.y - b.y) div BodyFineStepPx
    diagonal = min(dx, dy)
  int32(90 * diagonal + 64 * (max(dx, dy) - diagonal))

proc beginBodyRouteSearch*(job: var BodyRouteSearchJob;
    graph: BodyMixedGraph; workspace: BodyRouteWorkspace;
    weights: openArray[int16]; request: BodyRouteSearchRequest) =
  if weights.len != graph.map.gridWidth * graph.map.gridHeight:
    raise newException(ValueError, "body route weights do not match graph")
  workspace.beginWorkspace()
  job = BodyRouteSearchJob(active: true,
    workspaceGeneration: workspace.generation, request: request,
    startNode: -1, goalNode: -1, bestNode: -1,
    bestCost: high(int32))
  let
    starts = graph.attachments(weights, request, request.start)
    goals = graph.attachments(weights, request, request.goal)
  if starts.len == 0 or goals.len == 0:
    job.complete = true
    return
  if starts.len == 1 and starts.costs[0] == 0:
    job.startNode = starts.nodes[0]
  if goals.len == 1 and goals.costs[0] == 0:
    job.goalNode = goals.nodes[0]
  let generation = workspace.generation
  for offset in 0 ..< goals.len:
    let node = goals.nodes[offset].int
    if workspace.goalStamp[node] != generation or
        goals.costs[offset] < workspace.goalCost[node]:
      workspace.goalStamp[node] = generation
      workspace.goalCost[node] = goals.costs[offset]
  let allowance = int32(PortalAnchorRingCells * NavCell * 23)
  for offset in 0 ..< starts.len:
    let
      node = starts.nodes[offset].int
      cost = starts.costs[offset]
    if workspace.state[node] != generation or cost < workspace.g[node]:
      workspace.g[node] = cost
      workspace.parent[node] = -1
      workspace.parentBridge[node] = -1
      workspace.queue.bucket[node] = -1
      workspace.queue.queuePush(node, cost + max(0'i32,
        octileFine(graph.finePoint(node), request.goal) - allowance))
      workspace.state[node] = generation

proc spendBodyRoutePops*(job: var BodyRouteSearchJob;
    graph: BodyMixedGraph; workspace: BodyRouteWorkspace;
    weights: openArray[int16]; hazard: BodyHazardOverlay;
    popBudget: int): int =
  if popBudget < 0:
    raise newException(ValueError, "body route pop budget must not be negative")
  if not job.active or job.complete:
    return
  doAssert job.workspaceGeneration == workspace.generation,
    "body route job and shared workspace disagree"
  let generation = job.workspaceGeneration
  let allowance = int32(PortalAnchorRingCells * NavCell * 23)
  while result < popBudget and workspace.queue.len > 0:
    let entry = workspace.queue.queuePop()
    inc result
    inc job.queuePops
    let node = entry.node.int
    if workspace.state[node] != generation or
        workspace.g[node] + max(0'i32,
          octileFine(graph.finePoint(node), job.request.goal) - allowance) !=
          entry.f:
      continue
    if entry.f >= job.bestCost:
      job.complete = true
      break
    workspace.state[node] = generation or BodyDialClosedBit
    inc job.settledPops
    let currentG = workspace.g[node]
    if workspace.goalStamp[node] == generation:
      let total = currentG.int64 + workspace.goalCost[node].int64
      if total < job.bestCost.int64:
        job.bestCost = int32(total)
        job.bestNode = int32(node)
    let
      x = node mod graph.legality.width
      y = node div graph.legality.width
      legal = graph.legality.legal[node]
      fromPoint = graph.finePoint(node)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) != 0:
        let nextNode = (y + delta.y) * graph.legality.width + x + delta.x
        if graph.mixedActive(weights, nextNode, job.startNode.int,
            job.goalNode.int) and
            workspace.state[nextNode] != (generation or BodyDialClosedBit):
          let
            toPoint = graph.finePoint(nextNode)
            edge = graph.integratedMixedCost(weights, job.request.profile,
              job.request.blockedCell, hazard,
              job.request.elapsedZoneTick.int, fromPoint, toPoint)
            candidate64 = currentG.int64 + edge.int64
          if candidate64 < high(int32).int64:
            let candidate = int32(candidate64)
            if workspace.state[nextNode] != generation or
                candidate < workspace.g[nextNode]:
              workspace.g[nextNode] = candidate
              workspace.parent[nextNode] = int32(node)
              workspace.parentBridge[nextNode] = -1
              if workspace.state[nextNode] != generation:
                workspace.queue.bucket[nextNode] = -1
              workspace.queue.queuePush(nextNode, candidate + max(0'i32,
                octileFine(toPoint, job.request.goal) - allowance))
              workspace.state[nextNode] = generation
      if graph.anchorNode[node] == 0:
        continue
      let
        sourceCell = graph.cellForNode[node].int
        bridgeOffset = graph.bridgeOffset[sourceCell][direction].int
        bridgeLen = graph.bridgeLen[sourceCell][direction].int
      if bridgeOffset < 0 or bridgeLen == 0:
        continue
      let target = graph.bridgeNodes[bridgeOffset + bridgeLen - 1].int
      if workspace.state[target] == (generation or BodyDialClosedBit):
        continue
      var edge = 0'i32
      var previous = fromPoint
      for pathOffset in 0 ..< bridgeLen:
        let nextPoint = graph.finePoint(
          graph.bridgeNodes[bridgeOffset + pathOffset].int)
        edge += graph.integratedMixedCost(weights, job.request.profile,
          job.request.blockedCell, hazard,
          job.request.elapsedZoneTick.int, previous, nextPoint)
        previous = nextPoint
      let candidate64 = currentG.int64 + edge.int64
      if candidate64 < high(int32).int64:
        let candidate = int32(candidate64)
        if workspace.state[target] != generation or
            candidate < workspace.g[target]:
          workspace.g[target] = candidate
          workspace.parent[target] = int32(node)
          workspace.parentBridge[target] = int32(sourceCell * 8 + direction)
          if workspace.state[target] != generation:
            workspace.queue.bucket[target] = -1
          workspace.queue.queuePush(target, candidate + max(0'i32,
            octileFine(previous, job.request.goal) - allowance))
          workspace.state[target] = generation
  if workspace.queue.len == 0:
    job.complete = true

proc appendRoutePoint(build: var BodyRouteBuild; point: BodyPoint) =
  if build.pointCount == 0:
    build.spans[0] = BodyRouteSpan(start: point)
    build.spanCount = 1
    build.pointCount = 1
    return
  let spanIndex = build.spanCount.int - 1
  let span = build.spans[spanIndex]
  let previous: BodyPoint = (
    x: span.start.x + span.deltaX.int * span.steps.int,
    y: span.start.y + span.deltaY.int * span.steps.int)
  let delta = (x: point.x - previous.x, y: point.y - previous.y)
  if span.steps == 0:
    if delta.x < low(int16).int or delta.x > high(int16).int or
        delta.y < low(int16).int or delta.y > high(int16).int:
      build.failure = brfDescriptorOverflow
      return
    build.spans[spanIndex].deltaX = int16(delta.x)
    build.spans[spanIndex].deltaY = int16(delta.y)
    build.spans[spanIndex].steps = 1
  elif delta.x == span.deltaX.int and delta.y == span.deltaY.int and
      span.steps < high(uint16):
    inc build.spans[spanIndex].steps
  else:
    if build.spanCount.int >= BodyRouteSpanCap:
      build.failure = brfDescriptorOverflow
      return
    build.spans[build.spanCount] = BodyRouteSpan(start: previous)
    inc build.spanCount
    build.appendRoutePoint(point)
    return
  inc build.pointCount

proc finishBodyRouteSearch*(job: BodyRouteSearchJob;
    graph: BodyMixedGraph; workspace: BodyRouteWorkspace): BodyRouteBuild =
  result.settledPops = job.settledPops
  result.queuePops = job.queuePops
  if not job.complete:
    return
  if job.bestNode < 0:
    result.failure = brfDisconnected
    return
  var cursor = job.bestNode.int
  var count = 0
  while cursor >= 0:
    if count >= workspace.reconstruct.len:
      result.failure = brfDescriptorOverflow
      return
    workspace.reconstruct[count] = int32(cursor)
    inc count
    let bridge = workspace.parentBridge[cursor]
    if bridge >= 0:
      let
        sourceCell = bridge.int div 8
        direction = bridge.int mod 8
        offset = graph.bridgeOffset[sourceCell][direction].int
        length = graph.bridgeLen[sourceCell][direction].int
      if length > 1:
        for pathOffset in countdown(length - 2, 0):
          if count >= workspace.reconstruct.len:
            result.failure = brfDescriptorOverflow
            return
          workspace.reconstruct[count] = graph.bridgeNodes[offset + pathOffset]
          inc count
    cursor = workspace.parent[cursor].int
  result.failure = brfNone
  result.appendRoutePoint(job.request.start)
  for offset in countdown(count - 1, 0):
    let point = graph.finePoint(workspace.reconstruct[offset].int)
    if result.pointCount == 0 or point != (
        x: result.spans[result.spanCount.int - 1].start.x +
          result.spans[result.spanCount.int - 1].deltaX.int *
            result.spans[result.spanCount.int - 1].steps.int,
        y: result.spans[result.spanCount.int - 1].start.y +
          result.spans[result.spanCount.int - 1].deltaY.int *
            result.spans[result.spanCount.int - 1].steps.int):
      result.appendRoutePoint(point)
    if result.failure != brfNone:
      return
  let lastSpan = result.spans[result.spanCount.int - 1]
  let lastPoint: BodyPoint = (
    x: lastSpan.start.x + lastSpan.deltaX.int * lastSpan.steps.int,
    y: lastSpan.start.y + lastSpan.deltaY.int * lastSpan.steps.int)
  if lastPoint != job.request.goal:
    result.appendRoutePoint(job.request.goal)
  result.ok = result.failure == brfNone

proc bodyMixedGraphBytes*(graph: BodyMixedGraph;
    workspace: BodyRouteWorkspace): BodyMixedGraphBytes =
  const SequenceAllocationOverhead = 16'i64
  result.legality = int64(graph.legality.legal.capacity +
    graph.legality.standable.capacity)
  result.cellForNode = int64(graph.cellForNode.capacity * sizeof(int32))
  result.fineForCell = int64(graph.fineForCell.capacity *
    sizeof(array[4, int32]))
  result.anchors = int64(graph.anchorForCell.capacity * sizeof(int32) +
    graph.anchorNode.capacity * sizeof(uint8))
  result.wallBand = int64(graph.wallBand.capacity)
  result.bridges = int64(graph.bridgeOffset.capacity *
      sizeof(array[8, int32]) + graph.bridgeLen.capacity *
      sizeof(array[8, uint8]) + graph.bridgeNodes.capacity * sizeof(int32))
  result.workspace = int64(workspace.g.capacity + workspace.parent.capacity +
      workspace.parentBridge.capacity + workspace.goalCost.capacity) * sizeof(int32) +
    int64(workspace.state.capacity + workspace.goalStamp.capacity) * sizeof(uint32)
  result.buckets = int64(workspace.queue.head.capacity + workspace.queue.tail.capacity +
      workspace.queue.touchedGeneration.capacity) * sizeof(int32) +
    int64(workspace.queue.next.capacity + workspace.queue.previous.capacity +
      workspace.queue.bucket.capacity + workspace.queue.queuedF.capacity) * sizeof(int32)
  result.reconstruction = int64(workspace.reconstruct.capacity * sizeof(int32))
  for length in [
      graph.legality.legal.capacity, graph.legality.standable.capacity,
      graph.cellForNode.capacity, graph.fineForCell.capacity,
      graph.anchorForCell.capacity, graph.anchorNode.capacity, graph.wallBand.capacity,
      graph.bridgeOffset.capacity, graph.bridgeLen.capacity, graph.bridgeNodes.capacity,
      workspace.g.capacity, workspace.parent.capacity, workspace.parentBridge.capacity,
      workspace.goalCost.capacity, workspace.state.capacity, workspace.goalStamp.capacity,
      workspace.reconstruct.capacity, workspace.queue.head.capacity,
      workspace.queue.tail.capacity, workspace.queue.touchedGeneration.capacity,
      workspace.queue.next.capacity, workspace.queue.previous.capacity,
      workspace.queue.bucket.capacity, workspace.queue.queuedF.capacity]:
    if length > 0:
      result.allocatorOverhead += SequenceAllocationOverhead
  result.total = result.legality + result.cellForNode + result.fineForCell +
    result.anchors + result.wallBand + result.bridges + result.workspace +
    result.buckets + result.reconstruction + result.allocatorOverhead
