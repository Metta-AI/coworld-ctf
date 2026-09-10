## Immutable episode-shared hierarchical navigation index.
##
## Construction is activation-only. Retained arrays are counted before they
## are allocated and never grow while being filled. Live route queries consume
## this data in body_route_query.nim; they never build a source field.

import std/[algorithm, math, strformat]
import bitworld/profile
import body_map

# A5 attribution markers: compiled only with -d:ProfileTracePath; otherwise the
# template is the bare body and the counters do not exist. Whole stages only.
template indexStage(name: string, body: untyped) =
  when ProfileTracePath.len > 0:
    profileBlock(name, body)
  else:
    body

# A6 screen (isolated tree only): how pixelPathInBox learns box standability.
#   eager  = parent: fill the whole box once per search (default)
#   direct = no fill; every read calls map.canStand
#   lazy   = no fill; generation-stamped first-read memo in the scratch
const PixelStandabilityArm* = "lazy"  # materialized A6 snapshot
static:
  doAssert PixelStandabilityArm in ["eager", "direct", "lazy"],
    "PixelStandabilityArm must be eager, direct or lazy"

when defined(pixelStandabilityCounters):
  type PixelStandabilityCounters* = object
    searches*, exactEdgeSearches*, invalidStartReturns*: int
    boxPixels*, eagerFills*, readRequests*, canStandEvaluations*: int
  var pixelStandability*: PixelStandabilityCounters

when ProfileTracePath.len > 0:
  type PocketProfileCounters* = object
    coverageCells*, pixelScanCells*, secondaryCells*: int
    scannedPixels*, deferredSecondary*, coverageUnresolved*: int
    coveragePending*, resolvePasses*, resolveSeeds*: int
    joinCandidates*, joinPaths*, finalPending*, paths*, pocketPoints*: int
  var pocketProfile*: PocketProfileCounters

const
  PortalAnchorRingCells* = 4
  PortalCrossingBoxCells* = 4
  PortalCrossingMaxPops* = 64
  PortalClusterSeparationPx* = 64
  FineNavCell* = 4
  FineCrossingMaxPops* = 256
  ConnectorMaxDistancePx* = 32
  PixelConnectorMaxCells* =
    (ConnectorMaxDistancePx * 2 + 1) * (ConnectorMaxDistancePx * 2 + 1)
  RouteEdgeIdCapacity* = 32_767
  NoRoom = high(uint16)
  NoHop = high(uint8)
  OrthStepQ4 = uint32(NavCell * 16)
  DiagonalStepQ4 = 181'u32

static:
  doAssert FineNavCell == NavCell div 2
  doAssert FineCrossingMaxPops == 256
  doAssert PortalClusterSeparationPx mod NavCell == 0
  doAssert PixelConnectorMaxCells == 4_225

type
  BodyPortalSide* = object
    portal*, room*: uint16
    anchorCell*: int32
    fieldStart*: int32

  BodyRouteSegment* = object
    cellStart*: int32
    cellLen*: uint16
    staticLengthQ4*: uint32
    minX*, minY*, maxX*, maxY*: uint16

  BodyRouteArc* = object
    fromSide*, toSide*: uint16
    segment*: uint16
    reversed*: bool

  BodyPocketConnector* = object
    sourcePoint*, targetCell*: int32
    pointStart*: int32
    pointLen*: uint16
    staticLengthQ4*: uint32

  BodyRouteIndexStats* = object
    navCells*, walkableCells*, rooms*, portals*, sides*: int
    portalFieldCells*, segments*, crossings*, segmentCells*, arcs*: int
    fineCrossings*, pocketConnectors*, finePoints*, finePointBytes*: int
    droppedChokes*, maxRoomDegree*, graphComponents*: int
    retainedBytes*, transientPeakBytes*: int64

  BodyRouteCoverageStats* = object
    standablePixels*, coveredPixels*, uncoveredPixels*: int
    unreachableComponents*, unreachablePixels*: int
    firstUncovered*: BodyPoint
    componentHash*: uint64

  BodyRouteIndex* = ref object
    map*: BodyMap
    legalMoves: seq[uint8]
    roomOf: seq[uint16]
    localIndex: seq[int32]
    roomCellStart: seq[int32]
    roomCells: seq[int32]
    roomSideStart: seq[int32]
    roomSides: seq[uint16]
    sides: seq[BodyPortalSide]
    portalNext: seq[uint8]
    segments: seq[BodyRouteSegment]
    cells: seq[int32]
    arcStart: seq[int32]
    arcs: seq[BodyRouteArc]
    sideComponent: seq[uint16]
    cellComponent: seq[uint16]
    pockets: seq[BodyPocketConnector]
    pocketCells: seq[int32]
    fineAnchorStart: seq[int32]
    fineAnchors: seq[int32]
    stats: BodyRouteIndexStats

  BuildHeapNode = object
    distance: uint32
    cellIndex, localIndex: int

  BuildHeap = object
    nodes: seq[BuildHeapNode]
    positions: seq[int]
    len: int

  CrossingPath = object
    cells: seq[int32]
    fine: bool

  PortalBuild = object
    roomA, roomB: uint16
    anchorA, anchorB: int32
    crossing: CrossingPath

  BoundaryCluster = object
    roomA, roomB: uint16
    anchorA, anchorB, representativeCell: int32
    neighborOrder: uint8
    clearance: int

  FineTargetKind = enum
    ftkCrossing
    ftkPocket

  PocketSeedResult = enum
    psCovered
    psAdded
    psUnresolved

  PendingPocketPoint = object
    point: BodyPoint
    nextPath: int32

  FineTarget = object
    pointRef: int32
    pathIndex: int32
    pointOffset: uint16
    kind: FineTargetKind

  FineAnchorPair = object
    cellIndex, pointRef: int32

  PixelPath = object
    points: seq[BodyPoint]
    targetRef: int32
    reachedTarget: bool

  PixelSearchScratch = object
    parent: seq[int32]
    visitedGeneration: seq[uint32]
    standable: seq[bool]
    standableGeneration: seq[uint32]
    targetGeneration: seq[uint32]
    targetRef: seq[int32]
    queue: seq[int32]
    generation: uint32

proc cellIndex(index: BodyRouteIndex, cell: BodyPoint): int {.inline.} =
  cell.y * index.map.gridWidth + cell.x

proc cellPoint(index: BodyRouteIndex, cellIndex: int): BodyPoint {.inline.} =
  (cellIndex mod index.map.gridWidth, cellIndex div index.map.gridWidth)

proc mapLabel(map: BodyMap): string =
  if map.name.len > 0: map.name else: "unnamed"

proc validateRouteEdgeCapacity*(mapName: string,
    segmentCount, crossingCount: int) =
  let total = segmentCount + crossingCount
  if segmentCount < 0 or crossingCount < 0 or total > RouteEdgeIdCapacity:
    raise newException(BodyMapError,
      &"body route index map '{mapName}' has {segmentCount} intra-room " &
      &"segments + {crossingCount} crossings = {total} edges; " &
      &"RouteEdgeRef's 15-bit ID limit is {RouteEdgeIdCapacity}")

proc nodeLess(a, b: BuildHeapNode): bool {.inline.} =
  a.distance < b.distance or
    (a.distance == b.distance and a.cellIndex < b.cellIndex)

proc swapNodes(heap: var BuildHeap, a, b: int) {.inline.} =
  swap(heap.nodes[a], heap.nodes[b])
  heap.positions[heap.nodes[a].localIndex] = a
  heap.positions[heap.nodes[b].localIndex] = b

proc siftUp(heap: var BuildHeap, start: int) =
  var current = start
  while current > 0:
    let parent = (current - 1) div 2
    if not nodeLess(heap.nodes[current], heap.nodes[parent]):
      break
    heap.swapNodes(current, parent)
    current = parent

proc siftDown(heap: var BuildHeap, start: int) =
  var current = start
  while true:
    let left = current * 2 + 1
    if left >= heap.len:
      break
    let right = left + 1
    let child =
      if right < heap.len and nodeLess(heap.nodes[right], heap.nodes[left]):
        right
      else:
        left
    if not nodeLess(heap.nodes[child], heap.nodes[current]):
      break
    heap.swapNodes(current, child)
    current = child

proc reset(heap: var BuildHeap, count: int) =
  heap.len = 0
  for index in 0 ..< count:
    heap.positions[index] = -1

proc pushOrDecrease(heap: var BuildHeap, node: BuildHeapNode) =
  let position = heap.positions[node.localIndex]
  if position >= 0:
    if not nodeLess(node, heap.nodes[position]):
      return
    heap.nodes[position] = node
    heap.siftUp(position)
    return
  if heap.len >= heap.nodes.len:
    raise newException(BodyMapError, "body route build heap exhausted")
  let insert = heap.len
  inc heap.len
  heap.nodes[insert] = node
  heap.positions[node.localIndex] = insert
  heap.siftUp(insert)

proc pop(heap: var BuildHeap): BuildHeapNode =
  result = heap.nodes[0]
  heap.positions[result.localIndex] = -1
  dec heap.len
  if heap.len > 0:
    heap.nodes[0] = heap.nodes[heap.len]
    heap.positions[heap.nodes[0].localIndex] = 0
    heap.siftDown(0)

proc reverseNeighbor(index: int): int =
  let delta = NavNeighbors[index]
  for candidate, other in NavNeighbors:
    if other.x == -delta.x and other.y == -delta.y:
      return candidate
  raise newException(Defect, "navigation neighbor has no reverse")

proc stepCost(index: int): uint32 {.inline.} =
  if NavNeighbors[index].x != 0 and NavNeighbors[index].y != 0:
    DiagonalStepQ4
  else:
    OrthStepQ4

iterator ringCells(center: BodyPoint, ring: int): BodyPoint =
  ## Clockwise perimeter, beginning at the north-west corner.
  if ring == 0:
    yield center
  else:
    for x in center.x - ring .. center.x + ring:
      yield (x, center.y - ring)
    for y in center.y - ring + 1 .. center.y + ring:
      yield (center.x + ring, y)
    for x in countdown(center.x + ring - 1, center.x - ring):
      yield (x, center.y + ring)
    for y in countdown(center.y + ring - 1, center.y - ring + 1):
      yield (center.x - ring, y)

proc nearestChokeAnchor(index: BodyRouteIndex,
    chokeIndex: int): int32 =
  let center = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let candidate = index.cellIndex(cell)
      if index.map.cellWalkable(cell):
        return int32(candidate)
  -1'i32

proc differentRoomGoals(index: BodyRouteIndex, chokeIndex,
    room: int): seq[int32] =
  let
    center = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
    x0 = max(0, center.x - PortalCrossingBoxCells)
    x1 = min(index.map.gridWidth - 1, center.x + PortalCrossingBoxCells)
    y0 = max(0, center.y - PortalCrossingBoxCells)
    y1 = min(index.map.gridHeight - 1, center.y + PortalCrossingBoxCells)
  for y in y0 .. y1:
    for x in x0 .. x1:
      let candidate = index.cellIndex((x, y))
      if index.map.cellWalkable((x, y)) and
          index.roomOf[candidate].int != room:
        result.add int32(candidate)

proc fineGridWidth(index: BodyRouteIndex): int {.inline.} =
  (index.map.width + FineNavCell - 1) div FineNavCell

proc fineGridHeight(index: BodyRouteIndex): int {.inline.} =
  (index.map.height + FineNavCell - 1) div FineNavCell

proc fineLayerCells(index: BodyRouteIndex): int {.inline.} =
  index.fineGridWidth * index.fineGridHeight

proc fineIndex(index: BodyRouteIndex, point: BodyPoint): int32 {.inline.} =
  let
    layer = (point.y mod FineNavCell) * FineNavCell +
      point.x mod FineNavCell
    local = (point.y div FineNavCell) * index.fineGridWidth +
      point.x div FineNavCell
  int32(layer * index.fineLayerCells + local)

proc finePoint(index: BodyRouteIndex, fineIndex: int): BodyPoint {.inline.} =
  let
    layer = fineIndex div index.fineLayerCells
    local = fineIndex mod index.fineLayerCells
    offsetX = layer mod FineNavCell
    offsetY = layer div FineNavCell
  (x: (local mod index.fineGridWidth) * FineNavCell + offsetX,
   y: (local div index.fineGridWidth) * FineNavCell + offsetY)

proc routePoint*(index: BodyRouteIndex, pointRef: int32): BodyPoint =
  ## Decode a retained route point. Negative references use a self-decoding
  ## 16-phase 4 px lattice, so every map pixel has one canonical reference.
  if pointRef >= 0:
    if pointRef.int >= index.stats.navCells:
      raise newException(IndexDefect, "coarse route point is out of bounds")
    return cellCenter(index.cellPoint(pointRef.int))
  let decoded = -1'i64 - pointRef.int64
  let fineCells = index.fineLayerCells * FineNavCell * FineNavCell
  if decoded < 0 or decoded >= fineCells.int64:
    raise newException(IndexDefect, "fine route point is out of bounds")
  result = index.finePoint(decoded.int)
  if not index.map.inBounds(result):
    raise newException(IndexDefect, "fine route point is outside the map")

proc routeRefForPoint*(index: BodyRouteIndex, point: BodyPoint): int32 =
  ## Encode an exact map pixel in the same 16-phase representation used by
  ## retained fine anchors and endpoint legs.
  if not index.map.inBounds(point):
    raise newException(IndexDefect, "route point is outside the map")
  -1'i32 - index.fineIndex(point)

proc routeNavCell*(index: BodyRouteIndex, pointRef: int32): int32 =
  ## Dynamic danger, blocked-cell, and hazard state for any route point is
  ## sampled from this containing 8 px navigation cell.
  let cell = index.map.cellOf(index.routePoint(pointRef))
  int32(index.cellIndex(cell))

proc noteCrossingScratch(index: BodyRouteIndex, cellCount: int) =
  let bytes = int64(cellCount) * int64(
    sizeof(uint32) + sizeof(int32) + sizeof(bool) +
    sizeof(BuildHeapNode) + sizeof(int))
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes, bytes)

proc coarseCrossingPath(index: BodyRouteIndex, chokeIndex: int,
    starts, goals: openArray[int32]): CrossingPath =
  let
    chokeCell = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
    x0 = max(0, chokeCell.x - PortalCrossingBoxCells)
    x1 = min(index.map.gridWidth - 1, chokeCell.x + PortalCrossingBoxCells)
    y0 = max(0, chokeCell.y - PortalCrossingBoxCells)
    y1 = min(index.map.gridHeight - 1, chokeCell.y + PortalCrossingBoxCells)
    boxW = x1 - x0 + 1
    boxH = y1 - y0 + 1
  var
    distance = newSeq[uint32](boxW * boxH)
    parent = newSeq[int32](boxW * boxH)
    isGoal = newSeq[bool](boxW * boxH)
    heap = BuildHeap(nodes: newSeq[BuildHeapNode](boxW * boxH),
      positions: newSeq[int](boxW * boxH))
  for offset in 0 ..< distance.len:
    distance[offset] = high(uint32)
    parent[offset] = -1
  template local(cell: BodyPoint): int = (cell.y - y0) * boxW + cell.x - x0
  for goalIndex in goals:
    let goal = index.cellPoint(goalIndex.int)
    if goal.x in x0 .. x1 and goal.y in y0 .. y1:
      isGoal[local(goal)] = true
  heap.reset(distance.len)
  for startIndex in starts:
    let start = index.cellPoint(startIndex.int)
    if start.x notin x0 .. x1 or start.y notin y0 .. y1:
      continue
    let startLocal = local(start)
    if distance[startLocal] != 0:
      distance[startLocal] = 0
      heap.pushOrDecrease(BuildHeapNode(distance: 0,
        cellIndex: startIndex.int, localIndex: startLocal))
  index.noteCrossingScratch(distance.len)
  var pops = 0
  var reached = -1'i32
  while heap.len > 0 and pops < PortalCrossingMaxPops:
    let currentNode = heap.pop()
    if currentNode.distance != distance[currentNode.localIndex]:
      continue
    inc pops
    if isGoal[currentNode.localIndex]:
      reached = int32(currentNode.cellIndex)
      break
    let current = index.cellPoint(currentNode.cellIndex)
    for neighborIndex, delta in NavNeighbors:
      let next: BodyPoint = (current.x + delta.x, current.y + delta.y)
      if next.x < x0 or next.x > x1 or next.y < y0 or next.y > y1 or
          not index.map.legalNavMove(current, next):
        continue
      let candidate = currentNode.distance + neighborIndex.stepCost
      let nextLocal = local(next)
      if candidate < distance[nextLocal]:
        distance[nextLocal] = candidate
        parent[nextLocal] = int32(currentNode.cellIndex)
        heap.pushOrDecrease(BuildHeapNode(distance: candidate,
          cellIndex: index.cellIndex(next), localIndex: nextLocal))
  if reached < 0:
    return
  var cursor = reached
  while true:
    result.cells.add cursor
    let previous = parent[local(index.cellPoint(cursor.int))]
    if previous < 0:
      break
    cursor = previous
  result.cells.reverse()

proc finePathInBox(index: BodyRouteIndex, centerCell: BodyPoint,
    starts, goals: openArray[int32], maxLengthQ4: uint32): CrossingPath =
  let
    coarseX0 = max(0, centerCell.x - PortalCrossingBoxCells)
    coarseX1 = min(index.map.gridWidth - 1,
      centerCell.x + PortalCrossingBoxCells)
    coarseY0 = max(0, centerCell.y - PortalCrossingBoxCells)
    coarseY1 = min(index.map.gridHeight - 1,
      centerCell.y + PortalCrossingBoxCells)
    x0 = cellCenter((coarseX0, coarseY0)).x
    x1 = cellCenter((coarseX1, coarseY1)).x
    y0 = cellCenter((coarseX0, coarseY0)).y
    y1 = cellCenter((coarseX1, coarseY1)).y
    boxW = (x1 - x0) div FineNavCell + 1
    boxH = (y1 - y0) div FineNavCell + 1
  template local(point: BodyPoint): int =
    ((point.y - y0) div FineNavCell) * boxW +
      (point.x - x0) div FineNavCell
  var
    distance = newSeq[uint32](boxW * boxH)
    parent = newSeq[int32](boxW * boxH)
    isGoal = newSeq[bool](boxW * boxH)
    heap = BuildHeap(nodes: newSeq[BuildHeapNode](boxW * boxH),
      positions: newSeq[int](boxW * boxH))
  for offset in 0 ..< distance.len:
    distance[offset] = high(uint32)
    parent[offset] = -1
  for goalCell in goals:
    let point = cellCenter(index.cellPoint(goalCell.int))
    if point.x in x0 .. x1 and point.y in y0 .. y1:
      isGoal[local(point)] = true
  heap.reset(distance.len)
  for startCell in starts:
    let point = cellCenter(index.cellPoint(startCell.int))
    if point.x notin x0 .. x1 or point.y notin y0 .. y1:
      continue
    let pointLocal = local(point)
    if distance[pointLocal] != 0:
      distance[pointLocal] = 0
      heap.pushOrDecrease(BuildHeapNode(distance: 0,
        cellIndex: index.fineIndex(point).int, localIndex: pointLocal))
  index.noteCrossingScratch(distance.len)
  var pops = 0
  var reached = -1'i32
  while heap.len > 0 and pops < FineCrossingMaxPops:
    let currentNode = heap.pop()
    if currentNode.distance != distance[currentNode.localIndex]:
      continue
    inc pops
    if isGoal[currentNode.localIndex]:
      reached = int32(currentNode.cellIndex)
      break
    let current = index.finePoint(currentNode.cellIndex)
    for delta in NavNeighbors:
      let next: BodyPoint = (current.x + delta.x * FineNavCell,
                             current.y + delta.y * FineNavCell)
      if next.x < x0 or next.x > x1 or next.y < y0 or next.y > y1 or
          not index.map.canStand(next) or
          not index.map.segmentClear(current, next):
        continue
      let
        nextLocal = local(next)
        diagonal = delta.x != 0 and delta.y != 0
        step = if diagonal: 91'u32 else: 64'u32
        candidate = currentNode.distance + step
      if candidate <= maxLengthQ4 and candidate < distance[nextLocal]:
        distance[nextLocal] = candidate
        parent[nextLocal] = int32(currentNode.cellIndex)
        heap.pushOrDecrease(BuildHeapNode(distance: candidate,
          cellIndex: index.fineIndex(next).int, localIndex: nextLocal))
  if reached < 0:
    return
  var finePath: seq[int32]
  var cursor = reached
  while true:
    finePath.add cursor
    let previous = parent[local(index.finePoint(cursor.int))]
    if previous < 0:
      break
    cursor = previous
  finePath.reverse()
  if finePath.len < 2:
    return
  result.fine = true
  result.cells = newSeq[int32](finePath.len)
  result.cells[0] = int32(index.cellIndex(index.map.cellOf(
    index.finePoint(finePath[0].int))))
  result.cells[^1] = int32(index.cellIndex(index.map.cellOf(
    index.finePoint(finePath[^1].int))))
  for offset in 1 ..< finePath.high:
    result.cells[offset] = -1'i32 - finePath[offset]

proc fineCrossingPath(index: BodyRouteIndex, chokeIndex: int,
    starts, goals: openArray[int32]): CrossingPath =
  index.finePathInBox(index.map.cellOf(index.map.chokeAt(chokeIndex).pos),
    starts, goals, high(uint32))

proc distanceSquared(a, b: BodyPoint): int {.inline.} =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  dx * dx + dy * dy

proc pixelStepQ4(a, b: BodyPoint): uint32 {.inline.} =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  uint32(round(sqrt(float(dx * dx + dy * dy)) * 16.0))

proc initPixelSearchScratch(index: BodyRouteIndex): PixelSearchScratch =
  result.parent = newSeq[int32](PixelConnectorMaxCells)
  result.visitedGeneration = newSeq[uint32](PixelConnectorMaxCells)
  result.standable = newSeq[bool](PixelConnectorMaxCells)
  result.targetGeneration = newSeq[uint32](PixelConnectorMaxCells)
  result.targetRef = newSeq[int32](PixelConnectorMaxCells)
  result.queue = newSeq[int32](PixelConnectorMaxCells)
  result.standableGeneration = newSeq[uint32](PixelConnectorMaxCells)
  const generationArrays = 3
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
    int64(PixelConnectorMaxCells) *
      int64(sizeof(int32) * 3 + sizeof(uint32) * generationArrays +
        sizeof(bool)))

proc beginSearch(scratch: var PixelSearchScratch) =
  inc scratch.generation
  if scratch.generation == 0:
    for marker in scratch.visitedGeneration.mitems:
      marker = 0
    for marker in scratch.targetGeneration.mitems:
      marker = 0
    for marker in scratch.standableGeneration.mitems:
      marker = 0
    scratch.generation = 1

proc pixelPathInBox(index: BodyRouteIndex, start, center: BodyPoint,
    targets: openArray[int32], scratch: var PixelSearchScratch,
    exactEdges = false): PixelPath =
  let
    x0 = max(0, center.x - ConnectorMaxDistancePx)
    x1 = min(index.map.width - 1, center.x + ConnectorMaxDistancePx)
    y0 = max(0, center.y - ConnectorMaxDistancePx)
    y1 = min(index.map.height - 1, center.y + ConnectorMaxDistancePx)
    boxW = x1 - x0 + 1
    boxH = y1 - y0 + 1
  if boxW * boxH > PixelConnectorMaxCells:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' pixel connector exceeds " &
      &"the {PixelConnectorMaxCells}-pixel search cap")
  when defined(pixelStandabilityCounters):
    inc pixelStandability.searches
    if exactEdges: inc pixelStandability.exactEdgeSearches
    pixelStandability.boxPixels += boxW * boxH
  if start.x < x0 or start.x > x1 or start.y < y0 or start.y > y1 or
      not index.map.canStand(start):
    when defined(pixelStandabilityCounters):
      inc pixelStandability.invalidStartReturns
    return
  template local(point: BodyPoint): int =
    (point.y - y0) * boxW + point.x - x0
  template pointAt(offset: int): BodyPoint =
    (x: offset mod boxW + x0, y: offset div boxW + y0)
  scratch.beginSearch()
  # Box standability read, identical value in every arm: canStand(point) for
  # the same in-box point. Only when/how the byte is fetched differs.
  template standableAt(localIndex: int, point: BodyPoint): bool =
    when defined(pixelStandabilityCounters):
      inc pixelStandability.readRequests
    if scratch.standableGeneration[localIndex] != scratch.generation:
      scratch.standableGeneration[localIndex] = scratch.generation
      scratch.standable[localIndex] = index.map.canStand(point)
      when defined(pixelStandabilityCounters):
        inc pixelStandability.canStandEvaluations
    scratch.standable[localIndex]
  for target in targets:
    let point = index.routePoint(target)
    if point.x < x0 or point.x > x1 or point.y < y0 or point.y > y1:
      continue
    let offset = local(point)
    if scratch.targetGeneration[offset] != scratch.generation:
      scratch.targetGeneration[offset] = scratch.generation
      scratch.targetRef[offset] = target
  var
    head = 0
    tail = 1
    reached = -1
  let
    startLocal = local(start)
  scratch.visitedGeneration[startLocal] = scratch.generation
  scratch.parent[startLocal] = -1
  scratch.queue[0] = int32(startLocal)
  while head < tail:
    let
      currentLocal = scratch.queue[head].int
      current = pointAt(currentLocal)
    inc head
    if scratch.targetGeneration[currentLocal] == scratch.generation:
      reached = currentLocal
      result.targetRef = scratch.targetRef[currentLocal]
      result.reachedTarget = true
    if reached >= 0:
      break
    for delta in NavNeighbors:
      let next: BodyPoint = (current.x + delta.x, current.y + delta.y)
      if next.x < x0 or next.x > x1 or next.y < y0 or next.y > y1:
        continue
      let nextLocal = local(next)
      if scratch.visitedGeneration[nextLocal] == scratch.generation:
        continue
      if not standableAt(nextLocal, next):
        continue
      if exactEdges and delta.x != 0 and delta.y != 0:
        let
          sideX: BodyPoint = (current.x + delta.x, current.y)
          sideY: BodyPoint = (current.x, current.y + delta.y)
        if not standableAt(local(sideX), sideX) or
            not standableAt(local(sideY), sideY):
          continue
      scratch.visitedGeneration[nextLocal] = scratch.generation
      scratch.parent[nextLocal] = int32(currentLocal)
      scratch.queue[tail] = int32(nextLocal)
      inc tail
  if reached < 0:
    return
  var reversed: seq[BodyPoint]
  var cursor = reached
  while true:
    reversed.add pointAt(cursor)
    let previous = scratch.parent[cursor]
    if previous < 0:
      break
    cursor = previous.int
  reversed.reverse()
  result.points.add reversed[0]
  var source = 0
  while source < reversed.high:
    var target = reversed.high
    while target > source + 1 and
        not index.map.segmentClear(reversed[source], reversed[target]):
      dec target
    if not index.map.segmentClear(reversed[source], reversed[target]):
      result.points.setLen(0)
      return
    result.points.add reversed[target]
    source = target

proc exactPixelPathInBox(index: BodyRouteIndex, start, center: BodyPoint,
    targets: openArray[int32], scratch: var PixelSearchScratch): PixelPath =
  result = index.pixelPathInBox(start, center, targets, scratch)
  if result.points.len == 0 and result.reachedTarget:
    result = index.pixelPathInBox(start, center, targets, scratch,
      exactEdges = true)

proc encodedPixelPath(index: BodyRouteIndex, path: PixelPath,
    startRef: int32): CrossingPath =
  if path.points.len == 0:
    return
  if path.points.len == 1:
    result.cells = if startRef == path.targetRef:
      @[startRef]
    else:
      @[startRef, path.targetRef]
    result.fine = startRef < 0 or path.targetRef < 0
    return
  result.cells = newSeq[int32](path.points.len)
  result.cells[0] = startRef
  result.cells[^1] = path.targetRef
  result.fine = startRef < 0 or path.targetRef < 0
  for offset in 1 ..< path.points.high:
    result.cells[offset] = -1'i32 - index.fineIndex(path.points[offset])
    result.fine = true

proc pixelCrossingPath(index: BodyRouteIndex, chokeIndex: int,
    startCell: int32, goals: openArray[int32],
    scratch: var PixelSearchScratch): CrossingPath =
  let center = cellCenter(index.map.cellOf(index.map.chokeAt(chokeIndex).pos))
  let path = index.exactPixelPathInBox(
    cellCenter(index.cellPoint(startCell.int)), center, goals, scratch)
  result = index.encodedPixelPath(path, startCell)

proc buildRoomLayout(index: BodyRouteIndex): int =
  let roomCount = index.map.roomCount
  if roomCount <= 0 or roomCount >= NoRoom.int:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has invalid room count {roomCount}")
  index.roomOf = newSeq[uint16](index.stats.navCells)
  index.localIndex = newSeq[int32](index.stats.navCells)
  index.roomCellStart = newSeq[int32](roomCount + 1)
  var roomCounts = newSeq[int](roomCount)
  for cellIndex in 0 ..< index.stats.navCells:
    index.roomOf[cellIndex] = NoRoom
    index.localIndex[cellIndex] = -1
    let cell = index.cellPoint(cellIndex)
    if not index.map.cellWalkable(cell):
      continue
    inc index.stats.walkableCells
    let room = index.map.roomLabelAt(cellCenter(cell)) - 1
    if room < 0 or room >= roomCount:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' walkable cell " &
        &"({cell.x},{cell.y}) has no room")
    index.roomOf[cellIndex] = uint16(room)
    inc roomCounts[room]
  var cursor = 0
  for room, count in roomCounts:
    index.roomCellStart[room] = int32(cursor)
    cursor += count
    result = max(result, count)
  index.roomCellStart[^1] = int32(cursor)
  index.roomCells = newSeq[int32](cursor)
  var write = newSeq[int](roomCount)
  for room in 0 ..< roomCount:
    write[room] = index.roomCellStart[room].int
  for cellIndex in 0 ..< index.stats.navCells:
    let room = index.roomOf[cellIndex]
    if room == NoRoom:
      continue
    let destination = write[room.int]
    index.roomCells[destination] = int32(cellIndex)
    index.localIndex[cellIndex] = int32(destination - index.roomCellStart[room.int].int)
    inc write[room.int]

proc buildLegalMoves(index: BodyRouteIndex) =
  index.legalMoves = newSeq[uint8](index.stats.navCells)
  for cellIndex in 0 ..< index.stats.navCells:
    let cell = index.cellPoint(cellIndex)
    if not index.map.cellWalkable(cell):
      continue
    # Unit axis/diagonal moves have symmetric endpoint, side-cell and
    # pixel-segment checks. Preserve both bits with one predicate call.
    for (direction, reverse) in [(1, 0), (3, 2), (6, 5), (7, 4)]:
      let delta = NavNeighbors[direction]
      let next = (cell.x + delta.x, cell.y + delta.y)
      if index.map.legalNavMove(cell, next):
        index.legalMoves[cellIndex] = index.legalMoves[cellIndex] or
          uint8(1 shl direction)
        let nextIndex = index.cellIndex(next)
        index.legalMoves[nextIndex] = index.legalMoves[nextIndex] or
          uint8(1 shl reverse)

proc chebyshevCells(a, b: BodyPoint): int {.inline.} =
  max(abs(a.x - b.x), abs(a.y - b.y))

proc betterRepresentative(candidate: BoundaryCluster,
    current: BoundaryCluster): bool {.inline.} =
  candidate.clearance > current.clearance or
    (candidate.clearance == current.clearance and
      (candidate.representativeCell < current.representativeCell or
       (candidate.representativeCell == current.representativeCell and
        candidate.neighborOrder < current.neighborOrder)))

proc boundaryClusters(index: BodyRouteIndex): seq[BoundaryCluster] =
  let separationCells = PortalClusterSeparationPx div NavCell
  for cellIndex in 0 ..< index.stats.navCells:
    let
      cell = index.cellPoint(cellIndex)
      room = index.roomOf[cellIndex]
    if room == NoRoom:
      continue
    for neighborOrder, delta in NavNeighbors:
      if (index.legalMoves[cellIndex] and
          uint8(1 shl neighborOrder)) == 0:
        continue
      let
        next = (cell.x + delta.x, cell.y + delta.y)
        nextIndex = index.cellIndex(next)
        nextRoom = index.roomOf[nextIndex]
      if nextRoom == NoRoom or nextRoom == room:
        continue
      var candidate = BoundaryCluster(
        roomA: room, roomB: nextRoom,
        anchorA: int32(cellIndex), anchorB: int32(nextIndex),
        representativeCell: int32(cellIndex),
        neighborOrder: uint8(neighborOrder),
        clearance: min(index.map.clearanceAt(cellCenter(cell)),
          index.map.clearanceAt(cellCenter(next))))
      if candidate.roomB < candidate.roomA:
        swap(candidate.roomA, candidate.roomB)
        swap(candidate.anchorA, candidate.anchorB)
      var joined = false
      for clusterIndex in 0 ..< result.len:
        if result[clusterIndex].roomA != candidate.roomA or
            result[clusterIndex].roomB != candidate.roomB or
            index.cellPoint(result[clusterIndex].representativeCell.int).
              chebyshevCells(cell) > separationCells:
          continue
        joined = true
        if candidate.betterRepresentative(result[clusterIndex]):
          result[clusterIndex] = candidate
        break
      if not joined:
        result.add candidate

proc passAPortalCovers(index: BodyRouteIndex,
    portals: openArray[PortalBuild], passACount, chokeIndex: int): bool =
  let center = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
  for portalIndex in 0 ..< passACount:
    let portal = portals[portalIndex]
    for anchor in [portal.anchorA, portal.anchorB]:
      if index.cellPoint(anchor.int).chebyshevCells(center) <=
          PortalAnchorRingCells:
        return true

proc canonicalize(portal: var PortalBuild) =
  if portal.roomB < portal.roomA:
    swap(portal.roomA, portal.roomB)
    swap(portal.anchorA, portal.anchorB)
    portal.crossing.cells.reverse()

proc duplicatePassB(portals: openArray[PortalBuild], passA: int,
    candidate: PortalBuild): bool =
  for portalIndex in passA ..< portals.len:
    let portal = portals[portalIndex]
    if portal.roomA == candidate.roomA and portal.roomB == candidate.roomB and
        portal.anchorA == candidate.anchorA and
        portal.anchorB == candidate.anchorB:
      return true

proc buildSides(index: BodyRouteIndex): seq[CrossingPath] =
  let roomCount = index.map.roomCount
  var
    portals: seq[PortalBuild]
    pixelScratch = index.initPixelSearchScratch()
  for cluster in index.boundaryClusters():
    portals.add PortalBuild(
      roomA: cluster.roomA, roomB: cluster.roomB,
      anchorA: cluster.anchorA, anchorB: cluster.anchorB,
      crossing: CrossingPath(cells: @[cluster.anchorA, cluster.anchorB]))
  let passACount = portals.len
  for chokeIndex in 0 ..< index.map.chokeCount:
    if index.passAPortalCovers(portals, passACount, chokeIndex):
      continue
    let anchorA = index.nearestChokeAnchor(chokeIndex)
    if anchorA < 0:
      inc index.stats.droppedChokes
      continue
    let roomA = index.roomOf[anchorA.int]
    let goals = index.differentRoomGoals(chokeIndex, roomA.int)
    if goals.len == 0:
      inc index.stats.droppedChokes
      continue
    var crossing: CrossingPath
    let anchorCell = index.cellPoint(anchorA.int)
    for neighborOrder, delta in NavNeighbors:
      if (index.legalMoves[anchorA.int] and
          uint8(1 shl neighborOrder)) == 0:
        continue
      let neighbor = index.cellIndex(
        (anchorCell.x + delta.x, anchorCell.y + delta.y))
      if index.roomOf[neighbor] != roomA:
        crossing.cells = @[anchorA, int32(neighbor)]
        break
    if crossing.cells.len == 0:
      crossing = index.coarseCrossingPath(chokeIndex, [anchorA], goals)
    if crossing.cells.len == 0:
      crossing = index.fineCrossingPath(chokeIndex, [anchorA], goals)
    if crossing.cells.len == 0:
      crossing = index.pixelCrossingPath(chokeIndex, anchorA, goals,
        pixelScratch)
    if crossing.cells.len < 2 or crossing.cells[0] < 0 or
        crossing.cells[^1] < 0:
      inc index.stats.droppedChokes
      continue
    let roomB = index.roomOf[crossing.cells[^1].int]
    if roomB == NoRoom or roomB == roomA:
      inc index.stats.droppedChokes
      continue
    var portal = PortalBuild(roomA: roomA, roomB: roomB,
      anchorA: crossing.cells[0], anchorB: crossing.cells[^1],
      crossing: crossing)
    portal.canonicalize()
    if not portals.duplicatePassB(passACount, portal):
      portals.add portal

  if portals.len > high(uint16).int or
      portals.len * 2 > high(uint16).int + 1:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has {portals.len} " &
      "portals; portal and side IDs do not fit uint16")
  index.stats.portals = portals.len
  index.stats.sides = portals.len * 2
  index.stats.crossings = portals.len
  index.sides = newSeq[BodyPortalSide](portals.len * 2)
  index.roomSideStart = newSeq[int32](roomCount + 1)
  var sideCounts = newSeq[int](roomCount)
  for portalIndex, portal in portals:
    inc sideCounts[portal.roomA.int]
    inc sideCounts[portal.roomB.int]
    if portal.crossing.fine:
      inc index.stats.fineCrossings
      for pointRef in portal.crossing.cells:
        if pointRef < 0:
          inc index.stats.finePoints
    index.sides[portalIndex * 2] = BodyPortalSide(
      portal: uint16(portalIndex), room: portal.roomA,
      anchorCell: portal.anchorA)
    index.sides[portalIndex * 2 + 1] = BodyPortalSide(
      portal: uint16(portalIndex), room: portal.roomB,
      anchorCell: portal.anchorB)
    result.add portal.crossing
  index.stats.finePointBytes = index.stats.finePoints * sizeof(int32)
  var cursor = 0
  for room, count in sideCounts:
    index.stats.maxRoomDegree = max(index.stats.maxRoomDegree, count)
    index.roomSideStart[room] = int32(cursor)
    cursor += count
  index.roomSideStart[^1] = int32(cursor)
  index.roomSides = newSeq[uint16](cursor)
  var write = newSeq[int](roomCount)
  for room in 0 ..< roomCount:
    write[room] = index.roomSideStart[room].int
  for portalIndex in 0 ..< portals.len:
    for side in [portalIndex * 2, portalIndex * 2 + 1]:
      let room = index.sides[side].room.int
      index.roomSides[write[room]] = uint16(side)
      inc write[room]

proc runSideField(index: BodyRouteIndex, sideIndex: int,
    distance: var seq[uint32], nextHop: var seq[uint8], heap: var BuildHeap) =
  let
    side = index.sides[sideIndex]
    room = side.room.int
    roomStart = index.roomCellStart[room].int
    roomLen = index.roomCellStart[room + 1].int - roomStart
    sourceLocal = index.localIndex[side.anchorCell.int].int
  if sourceLocal < 0 or sourceLocal >= roomLen:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' portal {side.portal} " &
      &"anchor is outside room {room}")
  for local in 0 ..< roomLen:
    distance[local] = high(uint32)
    nextHop[local] = NoHop
  heap.reset(roomLen)
  distance[sourceLocal] = 0
  heap.pushOrDecrease(BuildHeapNode(distance: 0,
    cellIndex: side.anchorCell.int, localIndex: sourceLocal))
  while heap.len > 0:
    let current = heap.pop()
    if current.distance != distance[current.localIndex]:
      continue
    let mask = index.legalMoves[current.cellIndex]
    let currentCell = index.cellPoint(current.cellIndex)
    for neighborIndex, delta in NavNeighbors:
      if (mask and uint8(1 shl neighborIndex)) == 0:
        continue
      let nextCell = (currentCell.x + delta.x, currentCell.y + delta.y)
      let nextIndex = index.cellIndex(nextCell)
      if index.roomOf[nextIndex].int != room:
        continue
      let nextLocal = index.localIndex[nextIndex].int
      let candidate = current.distance + neighborIndex.stepCost
      let direction = uint8(reverseNeighbor(neighborIndex))
      if candidate < distance[nextLocal]:
        distance[nextLocal] = candidate
        nextHop[nextLocal] = direction
        heap.pushOrDecrease(BuildHeapNode(distance: candidate,
          cellIndex: nextIndex, localIndex: nextLocal))
      elif candidate == distance[nextLocal] and direction < nextHop[nextLocal]:
        nextHop[nextLocal] = direction
  let fieldStart = index.sides[sideIndex].fieldStart.int
  for local in 0 ..< roomLen:
    index.portalNext[fieldStart + local] = nextHop[local]

proc fieldReachable(index: BodyRouteIndex, sideIndex, cellIndex: int): bool =
  let side = index.sides[sideIndex]
  if side.anchorCell.int == cellIndex:
    return true
  if index.roomOf[cellIndex] != side.room:
    return false
  let local = index.localIndex[cellIndex]
  local >= 0 and index.portalNext[side.fieldStart.int + local.int] != NoHop

proc chainLength(index: BodyRouteIndex, sideIndex, cellIndex: int): int =
  let side = index.sides[sideIndex]
  var cursor = cellIndex
  result = 1
  while cursor != side.anchorCell.int:
    let local = index.localIndex[cursor].int
    if local < 0:
      return 0
    let direction = index.portalNext[side.fieldStart.int + local]
    if direction == NoHop or result > index.stats.navCells:
      return 0
    let cell = index.cellPoint(cursor)
    let delta = NavNeighbors[direction.int]
    cursor = index.cellIndex((cell.x + delta.x, cell.y + delta.y))
    inc result

proc segmentMetrics(index: BodyRouteIndex, start, length: int): BodyRouteSegment =
  result.cellStart = int32(start)
  result.cellLen = uint16(length)
  result.minX = high(uint16)
  result.minY = high(uint16)
  for offset in 0 ..< length:
    let
      point = index.routePoint(index.cells[start + offset])
      cell = index.map.cellOf(point)
    result.minX = min(result.minX, uint16(cell.x))
    result.minY = min(result.minY, uint16(cell.y))
    result.maxX = max(result.maxX, uint16(cell.x))
    result.maxY = max(result.maxY, uint16(cell.y))
    if offset > 0:
      let
        previous = index.routePoint(index.cells[start + offset - 1])
        dx = point.x - previous.x
        dy = point.y - previous.y
      result.staticLengthQ4 += uint32(round(
        sqrt(float(dx * dx + dy * dy)) * 16.0))

proc buildFieldsAndCountSegments(index: BodyRouteIndex,
    maxRoomCells: int): tuple[intraCount, intraCells: int] =
  var fieldCells = 0
  for sideIndex in 0 ..< index.sides.len:
    let room = index.sides[sideIndex].room.int
    index.sides[sideIndex].fieldStart = int32(fieldCells)
    fieldCells += index.roomCellStart[room + 1].int -
      index.roomCellStart[room].int
  index.portalNext = newSeq[uint8](fieldCells)
  index.stats.portalFieldCells = fieldCells
  var
    distance = newSeq[uint32](maxRoomCells)
    nextHop = newSeq[uint8](maxRoomCells)
    heap = BuildHeap(nodes: newSeq[BuildHeapNode](maxRoomCells),
      positions: newSeq[int](maxRoomCells))
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
    int64(maxRoomCells) * int64(
      sizeof(uint32) + sizeof(uint8) + sizeof(BuildHeapNode) + sizeof(int)))
  for sideIndex in 0 ..< index.sides.len:
    index.runSideField(sideIndex, distance, nextHop, heap)
  for room in 0 ..< index.map.roomCount:
    let
      first = index.roomSideStart[room].int
      after = index.roomSideStart[room + 1].int
    for left in first ..< after:
      for right in left + 1 ..< after:
        let
          sourceSide = index.roomSides[left].int
          targetSide = index.roomSides[right].int
          length = index.chainLength(sourceSide,
            index.sides[targetSide].anchorCell.int)
        if length > 0:
          inc result.intraCount
          result.intraCells += length

proc fillSegmentsAndArcs(index: BodyRouteIndex,
    crossings: openArray[CrossingPath], intraCount, intraCells: int) =
  var crossingCells = 0
  for crossing in crossings:
    crossingCells += crossing.cells.len
  validateRouteEdgeCapacity(index.map.mapLabel, intraCount, crossings.len)
  let segmentCount = intraCount + crossings.len
  index.segments = newSeq[BodyRouteSegment](segmentCount)
  index.cells = newSeq[int32](intraCells + crossingCells)
  var
    segmentCursor = 0
    cellCursor = 0
  for crossing in crossings:
    if crossing.cells.len > high(uint16).int:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' crossing is too long")
    for cell in crossing.cells:
      index.cells[cellCursor] = cell
      inc cellCursor
    index.segments[segmentCursor] = index.segmentMetrics(
      cellCursor - crossing.cells.len, crossing.cells.len)
    inc segmentCursor
  for room in 0 ..< index.map.roomCount:
    let
      first = index.roomSideStart[room].int
      after = index.roomSideStart[room + 1].int
    for left in first ..< after:
      for right in left + 1 ..< after:
        let
          sourceSide = index.roomSides[left].int
          targetSide = index.roomSides[right].int
          targetCell = index.sides[targetSide].anchorCell.int
          length = index.chainLength(sourceSide, targetCell)
        if length == 0:
          continue
        if length > high(uint16).int:
          raise newException(BodyMapError,
            &"body route index map '{index.map.mapLabel}' room {room} " &
            &"portal chain has {length} cells")
        var cursor = targetCell
        for reverseOffset in 0 ..< length:
          index.cells[cellCursor + length - 1 - reverseOffset] = int32(cursor)
          if cursor == index.sides[sourceSide].anchorCell.int:
            break
          let local = index.localIndex[cursor].int
          let direction = index.portalNext[
            index.sides[sourceSide].fieldStart.int + local]
          let cell = index.cellPoint(cursor)
          let delta = NavNeighbors[direction.int]
          cursor = index.cellIndex((cell.x + delta.x, cell.y + delta.y))
        index.segments[segmentCursor] = index.segmentMetrics(cellCursor, length)
        cellCursor += length
        inc segmentCursor
  if segmentCursor != segmentCount or cellCursor != index.cells.len:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' segment count changed during fill")

  index.arcs = newSeq[BodyRouteArc](segmentCount * 2)
  var arcCursor = 0
  for chokeIndex in 0 ..< crossings.len:
    for reversed in [false, true]:
      index.arcs[arcCursor] = BodyRouteArc(
        fromSide: uint16(chokeIndex * 2 + (if reversed: 1 else: 0)),
        toSide: uint16(chokeIndex * 2 + (if reversed: 0 else: 1)),
        segment: uint16(chokeIndex), reversed: reversed)
      inc arcCursor
  segmentCursor = crossings.len
  for room in 0 ..< index.map.roomCount:
    let
      first = index.roomSideStart[room].int
      after = index.roomSideStart[room + 1].int
    for left in first ..< after:
      for right in left + 1 ..< after:
        let
          sourceSide = index.roomSides[left].int
          targetSide = index.roomSides[right].int
        if not index.fieldReachable(sourceSide,
            index.sides[targetSide].anchorCell.int):
          continue
        index.arcs[arcCursor] = BodyRouteArc(fromSide: uint16(sourceSide),
          toSide: uint16(targetSide), segment: uint16(segmentCursor))
        inc arcCursor
        index.arcs[arcCursor] = BodyRouteArc(fromSide: uint16(targetSide),
          toSide: uint16(sourceSide), segment: uint16(segmentCursor), reversed: true)
        inc arcCursor
        inc segmentCursor
  index.arcs.sort(proc(a, b: BodyRouteArc): int =
    result = cmp(a.fromSide, b.fromSide)
    if result == 0: result = cmp(a.toSide, b.toSide)
    if result == 0: result = cmp(a.segment, b.segment))
  index.arcStart = newSeq[int32](index.sides.len + 1)
  for arc in index.arcs:
    inc index.arcStart[arc.fromSide.int + 1]
  for side in 0 ..< index.sides.len:
    index.arcStart[side + 1] += index.arcStart[side]

proc buildGraphComponents(index: BodyRouteIndex) =
  index.sideComponent = newSeq[uint16](index.sides.len)
  var queue = newSeq[int](index.sides.len)
  for start in 0 ..< index.sides.len:
    if index.sideComponent[start] != 0:
      continue
    if index.stats.graphComponents == high(uint16).int:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' has too many graph components")
    inc index.stats.graphComponents
    index.sideComponent[start] = uint16(index.stats.graphComponents)
    var head = 0
    var tail = 1
    queue[0] = start
    while head < tail:
      let current = queue[head]
      inc head
      for arcOffset in index.arcStart[current].int ..<
          index.arcStart[current + 1].int:
        let next = index.arcs[arcOffset].toSide.int
        if index.sideComponent[next] == 0:
          index.sideComponent[next] = uint16(index.stats.graphComponents)
          queue[tail] = next
          inc tail
  index.cellComponent = newSeq[uint16](index.stats.navCells)
  for room in 0 ..< index.map.roomCount:
    let
      cellFirst = index.roomCellStart[room].int
      cellAfter = index.roomCellStart[room + 1].int
      sideFirst = index.roomSideStart[room].int
      sideAfter = index.roomSideStart[room + 1].int
    for position in cellFirst ..< cellAfter:
      let cell = index.roomCells[position].int
      for sidePosition in sideFirst ..< sideAfter:
        let side = index.roomSides[sidePosition].int
        if index.fieldReachable(side, cell):
          let component = index.sideComponent[side]
          if index.cellComponent[cell] != 0 and
              index.cellComponent[cell] != component:
            raise newException(BodyMapError,
              &"body route index map '{index.map.mapLabel}' cell " &
              &"{index.cellPoint(cell)} reaches inconsistent graph components")
          index.cellComponent[cell] = component

proc seedUnrepresentedPixelComponents(index: BodyRouteIndex) =
  var validatorComponent = newSeq[bool](index.map.componentCount + 1)
  for validator in 0 ..< index.map.validatorTableCount:
    validatorComponent[index.map.validatorComponentAt(validator)] = true
  var graphForPixel = newSeq[uint16](index.map.componentCount + 1)
  for cellIndex, graph in index.cellComponent:
    if graph == 0:
      continue
    let pixel = index.map.componentOf(cellCenter(index.cellPoint(cellIndex)))
    if pixel > 0:
      graphForPixel[pixel] = graph
  var queue = newSeq[int32](index.stats.navCells)
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
    int64(queue.len * sizeof(int32) + graphForPixel.len * sizeof(uint16)))
  for start in 0 ..< index.stats.navCells:
    let startCell = index.cellPoint(start)
    if not index.map.cellWalkable(startCell):
      continue
    let pixel = index.map.componentOf(cellCenter(startCell))
    if pixel <= 0 or not validatorComponent[pixel] or
        graphForPixel[pixel] != 0:
      continue
    if index.stats.graphComponents == high(uint16).int:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' has too many graph components")
    inc index.stats.graphComponents
    let graph = uint16(index.stats.graphComponents)
    graphForPixel[pixel] = graph
    var
      head = 0
      tail = 1
    queue[0] = int32(start)
    index.cellComponent[start] = graph
    while head < tail:
      let currentIndex = queue[head].int
      inc head
      let current = index.cellPoint(currentIndex)
      for neighborIndex, delta in NavNeighbors:
        if (index.legalMoves[currentIndex] and
            uint8(1 shl neighborIndex)) == 0:
          continue
        let next = index.cellIndex((current.x + delta.x,
          current.y + delta.y))
        if index.cellComponent[next] == 0 and
            index.map.componentOf(cellCenter(index.cellPoint(next))) == pixel:
          index.cellComponent[next] = graph
          queue[tail] = int32(next)
          inc tail

proc validateValidatorAnchors(index: BodyRouteIndex) =
  var anchored = newSeq[bool](index.map.componentCount + 1)
  for cellIndex, graph in index.cellComponent:
    if graph == 0:
      continue
    let component = index.map.componentOf(cellCenter(index.cellPoint(cellIndex)))
    if component > 0:
      anchored[component] = true
  for validator in 0 ..< index.map.validatorTableCount:
    let component = index.map.validatorComponentAt(validator)
    if not anchored[component]:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' validator component " &
        &"{component} has no anchored coarse cell")
  for spawnIndex in 0 ..< index.map.spawnPointCount:
    let
      spawn = index.map.spawnPointAt(spawnIndex)
      component = index.map.componentOf(spawn)
      cell = index.map.cellOf(spawn)
      cellIndex = index.cellIndex(cell)
    if component <= 0 or not index.map.hasValidatorComponent(component) or
        index.cellComponent[cellIndex] == 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' validator component " &
        &"{component} spawn {spawnIndex} cell {cell} is not anchored")

proc canonicalGraphMapping(index: BodyRouteIndex): tuple[
    byPixel, byGraph: seq[uint16]] =
  ## A coarse raster can split one connected pixel component at a narrow gap.
  ## Keep its first graph as the deterministic representative; a later exact
  ## pixel connector is required before the other graph labels are collapsed.
  result.byPixel = newSeq[uint16](index.map.componentCount + 1)
  result.byGraph = newSeq[uint16](index.stats.graphComponents + 1)
  var graphPixel = newSeq[uint16](index.stats.graphComponents + 1)
  for cellIndex, graph in index.cellComponent:
    if graph == 0:
      continue
    let pixel = index.map.componentOf(cellCenter(index.cellPoint(cellIndex)))
    if pixel <= 0:
      continue
    if graphPixel[graph] notin [0'u16, uint16(pixel)]:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' graph {graph} spans " &
        "multiple pixel components")
    graphPixel[graph] = uint16(pixel)
    if result.byPixel[pixel] == 0 or graph < result.byPixel[pixel]:
      result.byPixel[pixel] = graph
  for graph in 1 .. index.stats.graphComponents:
    let pixel = graphPixel[graph].int
    if pixel <= 0 or result.byPixel[pixel] == 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' graph {graph} has no " &
        "pixel component")
    result.byGraph[graph] = result.byPixel[pixel]

proc collapseGraphComponents(index: BodyRouteIndex,
    canonical: openArray[uint16]) =
  var compact = newSeq[uint16](canonical.len)
  index.stats.graphComponents = 0
  for graph in 1 ..< canonical.len:
    let root = canonical[graph]
    if compact[root] == 0:
      inc index.stats.graphComponents
      compact[root] = uint16(index.stats.graphComponents)
  for graph in index.sideComponent.mitems:
    graph = compact[canonical[graph]]
  for graph in index.cellComponent.mitems:
    if graph != 0:
      graph = compact[canonical[graph]]

proc coarseConnectorGraphComponent(index: BodyRouteIndex,
    point: BodyPoint, maxDistanceSquared =
      ConnectorMaxDistancePx * ConnectorMaxDistancePx,
    requiredGraph = 0): int =
  let
    center = index.map.cellOf(point)
    pixelComponent = index.map.componentOf(point)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let
        candidate = index.cellIndex(cell)
        anchor = cellCenter(cell)
      if point.distanceSquared(anchor) <= maxDistanceSquared and
          index.cellComponent[candidate] != 0 and
          (requiredGraph == 0 or
           index.cellComponent[candidate].int == requiredGraph) and
          index.map.componentOf(anchor) == pixelComponent and
          index.map.segmentClear(point, anchor):
        return index.cellComponent[candidate].int

proc pocketGoals(index: BodyRouteIndex, point: BodyPoint,
    targetGraph: uint16): seq[int32] =
  let
    center = index.map.cellOf(point)
    pixelComponent = index.map.componentOf(point)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let
        candidate = index.cellIndex(cell)
        anchor = cellCenter(cell)
      if index.cellComponent[candidate] == targetGraph and
          index.map.componentOf(anchor) == pixelComponent:
        result.add int32(candidate)

proc initialFineTargets(index: BodyRouteIndex,
    canonical: openArray[uint16]): seq[FineTarget] =
  for segmentIndex in 0 ..< index.stats.crossings:
    let graph = index.sideComponent[segmentIndex * 2]
    if canonical[graph] != graph:
      continue
    let segment = index.segments[segmentIndex]
    for offset in 0 ..< segment.cellLen.int:
      let pointRef = index.cells[segment.cellStart.int + offset]
      if pointRef < 0:
        result.add FineTarget(pointRef: pointRef,
          pathIndex: int32(segmentIndex), pointOffset: uint16(offset),
          kind: ftkCrossing)

proc appendFineTargetSuffix(index: BodyRouteIndex, target: FineTarget,
    paths: openArray[CrossingPath], path: var CrossingPath) =
  case target.kind
  of ftkCrossing:
    let segment = index.segments[target.pathIndex.int]
    for offset in target.pointOffset.int + 1 ..< segment.cellLen.int:
      path.cells.add index.cells[segment.cellStart.int + offset]
  of ftkPocket:
    let source = paths[target.pathIndex.int]
    for offset in target.pointOffset.int + 1 ..< source.cells.len:
      path.cells.add source.cells[offset]

proc pixelPocketPath(index: BodyRouteIndex, point: BodyPoint,
    paths: openArray[CrossingPath], fineTargets: openArray[FineTarget],
    targetGraph: uint16, scratch: var PixelSearchScratch):
    CrossingPath =
  var targets = index.pocketGoals(point, targetGraph)
  let pixelComponent = index.map.componentOf(point)
  for target in fineTargets:
    let targetPoint = index.routePoint(target.pointRef)
    if abs(targetPoint.x - point.x) <= ConnectorMaxDistancePx and
        abs(targetPoint.y - point.y) <= ConnectorMaxDistancePx and
        index.map.componentOf(targetPoint) == pixelComponent:
      targets.add target.pointRef
  if targets.len == 0:
    return
  let pixelPath = index.exactPixelPathInBox(point, point, targets, scratch)
  result = index.encodedPixelPath(pixelPath,
    -1'i32 - index.fineIndex(point))
  if result.cells.len == 0 or result.cells[^1] >= 0:
    return
  for target in fineTargets:
    if target.pointRef == result.cells[^1]:
      index.appendFineTargetSuffix(target, paths, result)
      break
  if result.cells[^1] < 0:
    result.cells.setLen(0)

proc pathLengthQ4(index: BodyRouteIndex,
    cells: openArray[int32]): uint32 =
  for offset in 1 ..< cells.len:
    result += pixelStepQ4(index.routePoint(cells[offset - 1]),
      index.routePoint(cells[offset]))

proc pocketPathComponent(index: BodyRouteIndex, point: BodyPoint,
    path: CrossingPath, maxDistanceSquared =
      ConnectorMaxDistancePx * ConnectorMaxDistancePx): int =
  if path.cells.len < 2:
    return 0
  let
    target = index.routePoint(path.cells[^1])
    targetCell = index.routeNavCell(path.cells[^1]).int
    pixelComponent = index.map.componentOf(point)
  if index.map.componentOf(target) != pixelComponent:
    return 0
  for pointRef in path.cells:
    let attach = index.routePoint(pointRef)
    if point.distanceSquared(attach) <= maxDistanceSquared and
        index.map.componentOf(attach) == pixelComponent and
        index.map.segmentClear(point, attach):
      return index.cellComponent[targetCell].int

proc anchorPocketCells(index: BodyRouteIndex, path: CrossingPath,
    canonical: openArray[uint16]) =
  let
    targetCell = index.routeNavCell(path.cells[^1]).int
    graph = index.cellComponent[targetCell]
    pixelComponent = index.map.componentOf(index.routePoint(path.cells[^1]))
  for pointRef in path.cells:
    let
      attach = index.routePoint(pointRef)
      center = index.map.cellOf(attach)
    for ring in 0 .. PortalAnchorRingCells:
      for cell in ringCells(center, ring):
        if cell.x < 0 or cell.x >= index.map.gridWidth or
            cell.y < 0 or cell.y >= index.map.gridHeight:
          continue
        let
          cellIndex = index.cellIndex(cell)
          anchor = cellCenter(cell)
        let currentGraph = index.cellComponent[cellIndex]
        if (currentGraph != 0 and canonical[currentGraph] != graph) or
            not index.map.cellWalkable(cell) or
            index.map.componentOf(anchor) != pixelComponent:
          continue
        if anchor.distanceSquared(attach) <=
            ConnectorMaxDistancePx * ConnectorMaxDistancePx and
            index.map.segmentClear(anchor, attach):
          index.cellComponent[cellIndex] = graph

proc joinPocketGraph(index: BodyRouteIndex, sourceGraph,
    targetGraph: uint16) =
  for graph in index.sideComponent.mitems:
    if graph == sourceGraph:
      graph = targetGraph
  for graph in index.cellComponent.mitems:
    if graph == sourceGraph:
      graph = targetGraph

proc resolvePocketSeed(index: BodyRouteIndex, point: BodyPoint,
    validatorComponent: openArray[bool], canonicalByPixel: openArray[uint16],
    canonicalByGraph: openArray[uint16], paths: var seq[CrossingPath],
    fineTargets: var seq[FineTarget], pathStart: int,
    scratch: var PixelSearchScratch): PocketSeedResult =
  let pixelComponent = index.map.componentOf(point)
  if pixelComponent == 0 or not validatorComponent[pixelComponent]:
    return psCovered
  let targetGraph = canonicalByPixel[pixelComponent]
  if targetGraph == 0:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' validator component " &
      &"{pixelComponent} has no canonical route graph")
  let
    coarseCell = index.map.cellOf(point)
    coarseIndex = index.cellIndex(coarseCell)
    sourceGraph = index.cellComponent[coarseIndex]
  if index.cellComponent[coarseIndex] == targetGraph:
    let coarseCenter = cellCenter(coarseCell)
    if index.map.componentOf(coarseCenter) == pixelComponent and
        index.map.segmentClear(point, coarseCenter):
      return psCovered
  const InteriorDistanceSquared =
    ConnectorMaxDistancePx * ConnectorMaxDistancePx - 1
  if index.coarseConnectorGraphComponent(point, InteriorDistanceSquared,
      targetGraph.int) != 0:
    return psCovered
  for pathIndex in pathStart ..< paths.len:
    if index.pocketPathComponent(point, paths[pathIndex],
        InteriorDistanceSquared) != 0:
      return psCovered
  let path = index.pixelPocketPath(point, paths, fineTargets, targetGraph,
    scratch)
  if path.cells.len == 0:
    return psUnresolved
  if path.cells.len > high(uint16).int:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' pocket connector " &
      &"has {path.cells.len} points")
  let pathIndex = paths.len
  let joinsSourceGraph = sourceGraph != 0 and sourceGraph != targetGraph and
    canonicalByGraph[sourceGraph] == targetGraph and
    index.coarseConnectorGraphComponent(point,
      ConnectorMaxDistancePx * ConnectorMaxDistancePx,
      sourceGraph.int) == sourceGraph.int
  paths.add path
  for offset, pointRef in path.cells:
    if pointRef < 0:
      fineTargets.add FineTarget(pointRef: pointRef,
        pathIndex: int32(pathIndex), pointOffset: uint16(offset),
        kind: ftkPocket)
  index.anchorPocketCells(path, canonicalByGraph)
  if joinsSourceGraph:
    index.joinPocketGraph(sourceGraph, targetGraph)
  psAdded

proc resolvePocketPending(index: BodyRouteIndex,
    pending: sink seq[PendingPocketPoint],
    validatorComponent: openArray[bool], canonicalByPixel,
    canonicalByGraph: openArray[uint16], failOnStall: bool,
    paths: var seq[CrossingPath], fineTargets: var seq[FineTarget],
    pixelScratch: var PixelSearchScratch): seq[PendingPocketPoint] =
  var unresolved = move(pending)
  while unresolved.len > 0:
    var
      nextUnresolved = newSeqOfCap[PendingPocketPoint](unresolved.len)
      passAdded = 0
    when ProfileTracePath.len > 0:
      inc pocketProfile.resolvePasses
      pocketProfile.resolveSeeds += unresolved.len
    for pendingPoint in unresolved:
      case index.resolvePocketSeed(pendingPoint.point, validatorComponent,
          canonicalByPixel, canonicalByGraph, paths, fineTargets,
          pendingPoint.nextPath.int, pixelScratch)
      of psCovered: discard
      of psAdded: inc passAdded
      of psUnresolved:
        nextUnresolved.add PendingPocketPoint(point: pendingPoint.point,
          nextPath: int32(paths.len))
    index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
      int64((unresolved.len + nextUnresolved.len) *
        sizeof(PendingPocketPoint)))
    if nextUnresolved.len == 0:
      return
    if passAdded == 0:
      if not failOnStall:
        return nextUnresolved
      let firstUnresolved = nextUnresolved[0].point
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' validator component " &
        &"{index.map.componentOf(firstUnresolved)} leaves " &
        &"{nextUnresolved.len} standable pocket " &
        &"pixels unresolved; first={firstUnresolved}; no pixel connector " &
        &"inside +-{ConnectorMaxDistancePx} px box")
    unresolved = move(nextUnresolved)

proc buildPocketCoverage(index: BodyRouteIndex,
    validatorComponent: openArray[bool], canonicalByPixel,
    canonicalByGraph: openArray[uint16], includeSecondary,
    failOnStall: bool,
    paths: var seq[CrossingPath], fineTargets: var seq[FineTarget],
    pixelScratch: var PixelSearchScratch): seq[PendingPocketPoint] =
  var
    needsPixelScan = newSeq[bool](index.stats.navCells)
    secondaryCell = newSeq[bool](index.stats.navCells)
    deferredSecondary: seq[PendingPocketPoint]
    unresolved: seq[PendingPocketPoint]
  indexStage("pocket.coverage.classify"):
   for cellIndex in 0 ..< index.stats.navCells:
    let
      cell = index.cellPoint(cellIndex)
      center = cellCenter(cell)
      xAfter = if cell.x == index.map.gridWidth - 1:
        index.map.width
      else:
        (cell.x + 1) * NavCell
      yAfter = if cell.y == index.map.gridHeight - 1:
        index.map.height
      else:
        (cell.y + 1) * NavCell
      radius = max(
        max(center.x - cell.x * NavCell, xAfter - 1 - center.x),
        max(center.y - cell.y * NavCell, yAfter - 1 - center.y))
      pixelComponent = index.map.componentOf(center)
      targetGraph = if pixelComponent > 0:
        canonicalByPixel[pixelComponent]
      else:
        0'u16
      sourceGraph = index.cellComponent[cellIndex]
      # Clearance at the center proves every pixel in an interior cell has an
      # exact segment to that center. Only boundary cells need a pixel census.
      needsBoundaryProof =
        index.map.clearanceAt(center) <= PlayerHalf + radius
    secondaryCell[cellIndex] = sourceGraph != 0 and
      sourceGraph != targetGraph and needsBoundaryProof
    needsPixelScan[cellIndex] =
      (includeSecondary or sourceGraph == 0 or sourceGraph == targetGraph) and
      (sourceGraph != targetGraph or needsBoundaryProof)
  when ProfileTracePath.len > 0:
    pocketProfile.coverageCells += index.stats.navCells
    for flag in needsPixelScan:
      if flag: inc pocketProfile.pixelScanCells
    for flag in secondaryCell:
      if flag: inc pocketProfile.secondaryCells
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
    int64(needsPixelScan.len * sizeof(bool)))
  indexStage("pocket.coverage.pixelScan"):
   for coarseY in 0 ..< index.map.gridHeight:
    let
      y0 = coarseY * NavCell
      y1 = min(index.map.height, y0 + NavCell) - 1
    for y in y0 .. y1:
      for coarseX in 0 ..< index.map.gridWidth:
        let coarseIndex = coarseY * index.map.gridWidth + coarseX
        if not needsPixelScan[coarseIndex] and
            not secondaryCell[coarseIndex]:
          continue
        let
          x0 = coarseX * NavCell
          x1 = min(index.map.width, x0 + NavCell) - 1
        for x in x0 .. x1:
          let point: BodyPoint = (x, y)
          when ProfileTracePath.len > 0:
            inc pocketProfile.scannedPixels
          if not needsPixelScan[coarseIndex]:
            if index.map.canStand(point):
              deferredSecondary.add PendingPocketPoint(
                point: point, nextPath: 0)
            continue
          case index.resolvePocketSeed(point, validatorComponent,
              canonicalByPixel, canonicalByGraph, paths, fineTargets, 0,
              pixelScratch)
          of psCovered: discard
          of psAdded: discard
          of psUnresolved:
            unresolved.add PendingPocketPoint(point: point,
              nextPath: int32(paths.len))
  when ProfileTracePath.len > 0:
    pocketProfile.deferredSecondary += deferredSecondary.len
    pocketProfile.coverageUnresolved += unresolved.len
  indexStage("pocket.coverage.resolvePending"):
    unresolved = index.resolvePocketPending(move(unresolved),
      validatorComponent, canonicalByPixel, canonicalByGraph, failOnStall,
      paths, fineTargets, pixelScratch)
  result = move(deferredSecondary)
  result.add unresolved
  when ProfileTracePath.len > 0:
    pocketProfile.coveragePending += result.len
  indexStage("pocket.coverage.sort"):
    result.sort(proc(a, b: PendingPocketPoint): int =
      result = cmp(a.point.y, b.point.y)
      if result == 0:
        result = cmp(a.point.x, b.point.x))

proc buildPocketConnectors(index: BodyRouteIndex) =
  if index.stats.graphComponents == 0:
    return
  var canonical: tuple[byPixel, byGraph: seq[uint16]]
  var validatorComponent = newSeq[bool](index.map.componentCount + 1)
  indexStage("pocket.canonicalMapping"):
    canonical = index.canonicalGraphMapping()
    for validator in 0 ..< index.map.validatorTableCount:
      validatorComponent[index.map.validatorComponentAt(validator)] = true
  var
    paths: seq[CrossingPath]
    fineTargets: seq[FineTarget]
    pixelScratch: PixelSearchScratch
    pending: seq[PendingPocketPoint]
  indexStage("pocket.initialTargetsScratch"):
    fineTargets = index.initialFineTargets(canonical.byGraph)
    pixelScratch = index.initPixelSearchScratch()
  indexStage("pocket.coverage"):
    pending = index.buildPocketCoverage(validatorComponent, canonical.byPixel,
      canonical.byGraph, false, false, paths, fineTargets, pixelScratch)
  indexStage("pocket.graphJoins"):
   for sourceGraphIndex in 1 ..< canonical.byGraph.len:
    let
      sourceGraph = uint16(sourceGraphIndex)
      targetGraph = canonical.byGraph[sourceGraphIndex]
    if sourceGraph == targetGraph:
      continue
    for candidate in pending:
      let
        point = candidate.point
        cell = index.map.cellOf(point)
      if index.cellComponent[index.cellIndex(cell)] != sourceGraph:
        continue
      when ProfileTracePath.len > 0:
        inc pocketProfile.joinCandidates
      let path = index.pixelPocketPath(point, paths, fineTargets,
        targetGraph, pixelScratch)
      if path.cells.len == 0 or
          index.coarseConnectorGraphComponent(point,
            ConnectorMaxDistancePx * ConnectorMaxDistancePx,
            sourceGraph.int) != sourceGraph.int:
        continue
      if path.cells.len > high(uint16).int:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' pocket connector " &
          &"has {path.cells.len} points")
      let pathIndex = paths.len
      paths.add path
      for offset, pointRef in path.cells:
        if pointRef < 0:
          fineTargets.add FineTarget(pointRef: pointRef,
            pathIndex: int32(pathIndex), pointOffset: uint16(offset),
            kind: ftkPocket)
      index.anchorPocketCells(path, canonical.byGraph)
      index.joinPocketGraph(sourceGraph, targetGraph)
      when ProfileTracePath.len > 0:
        inc pocketProfile.joinPaths
      break
  when ProfileTracePath.len > 0:
    pocketProfile.finalPending += pending.len
  indexStage("pocket.finalPending"):
    discard index.resolvePocketPending(move(pending), validatorComponent,
      canonical.byPixel, canonical.byGraph, true, paths, fineTargets,
      pixelScratch)
  var pointCount = 0
  indexStage("pocket.pack"):
    for path in paths:
      pointCount += path.cells.len
    index.pockets = newSeq[BodyPocketConnector](paths.len)
    index.pocketCells = newSeq[int32](pointCount)
    var cursor = 0
    for pathIndex, path in paths:
      for pointRef in path.cells:
        index.pocketCells[cursor] = pointRef
        inc cursor
        if pointRef < 0:
          inc index.stats.finePoints
      index.pockets[pathIndex] = BodyPocketConnector(
        sourcePoint: path.cells[0], targetCell: path.cells[^1],
        pointStart: int32(cursor - path.cells.len),
        pointLen: uint16(path.cells.len),
        staticLengthQ4: index.pathLengthQ4(path.cells))
    index.stats.pocketConnectors = paths.len
    index.stats.finePointBytes = index.stats.finePoints * sizeof(int32)
  when ProfileTracePath.len > 0:
    pocketProfile.paths += paths.len
    pocketProfile.pocketPoints += pointCount
  indexStage("pocket.collapse"):
    index.collapseGraphComponents(canonical.byGraph)

proc buildFineAnchorIndex(index: BodyRouteIndex) =
  var pairs: seq[FineAnchorPair]
  for pointRef in index.cells:
    if pointRef < 0:
      pairs.add FineAnchorPair(cellIndex: index.routeNavCell(pointRef),
        pointRef: pointRef)
  for pointRef in index.pocketCells:
    if pointRef < 0:
      pairs.add FineAnchorPair(cellIndex: index.routeNavCell(pointRef),
        pointRef: pointRef)
  pairs.sort(proc(a, b: FineAnchorPair): int =
    result = cmp(a.cellIndex, b.cellIndex)
    if result == 0:
      result = cmp(a.pointRef, b.pointRef))
  var unique: seq[FineAnchorPair]
  for pair in pairs:
    if unique.len == 0 or unique[^1].cellIndex != pair.cellIndex or
        unique[^1].pointRef != pair.pointRef:
      unique.add pair
  index.stats.transientPeakBytes = max(index.stats.transientPeakBytes,
    int64((pairs.len + unique.len) * sizeof(FineAnchorPair)))
  index.fineAnchorStart = newSeq[int32](index.stats.navCells + 1)
  for pair in unique:
    inc index.fineAnchorStart[pair.cellIndex.int + 1]
  for cellIndex in 0 ..< index.stats.navCells:
    index.fineAnchorStart[cellIndex + 1] += index.fineAnchorStart[cellIndex]
  index.fineAnchors = newSeq[int32](unique.len)
  for offset, pair in unique:
    index.fineAnchors[offset] = pair.pointRef

proc retainedBytes(index: BodyRouteIndex): int64 =
  int64(index.legalMoves.capacity * sizeof(uint8) +
    index.roomOf.capacity * sizeof(uint16) +
    index.localIndex.capacity * sizeof(int32) +
    index.roomCellStart.capacity * sizeof(int32) +
    index.roomCells.capacity * sizeof(int32) +
    index.roomSideStart.capacity * sizeof(int32) +
    index.roomSides.capacity * sizeof(uint16) +
    index.sides.capacity * sizeof(BodyPortalSide) +
    index.portalNext.capacity * sizeof(uint8) +
    index.segments.capacity * sizeof(BodyRouteSegment) +
    index.cells.capacity * sizeof(int32) +
    index.arcStart.capacity * sizeof(int32) +
    index.arcs.capacity * sizeof(BodyRouteArc) +
    index.sideComponent.capacity * sizeof(uint16) +
    index.cellComponent.capacity * sizeof(uint16) +
    index.pockets.capacity * sizeof(BodyPocketConnector) +
    index.pocketCells.capacity * sizeof(int32) +
    index.fineAnchorStart.capacity * sizeof(int32) +
    index.fineAnchors.capacity * sizeof(int32))

proc retainedIndexBytes*(index: BodyRouteIndex): int64 =
  ## Retained owner, allocated sequence capacity, and header allowance. Sequence
  ## values themselves live in the fixed owner object counted by sizeof.
  if index == nil:
    return 0
  result = int64(sizeof(index[])) + index.retainedBytes
  for length in [index.legalMoves.capacity, index.roomOf.capacity,
      index.localIndex.capacity, index.roomCellStart.capacity, index.roomCells.capacity,
      index.roomSideStart.capacity, index.roomSides.capacity, index.sides.capacity,
      index.portalNext.capacity, index.segments.capacity, index.cells.capacity,
      index.arcStart.capacity, index.arcs.capacity, index.sideComponent.capacity,
      index.cellComponent.capacity, index.pockets.capacity, index.pocketCells.capacity,
      index.fineAnchorStart.capacity, index.fineAnchors.capacity]:
    if length > 0:
      result += 16

proc followingPayloadBytes*(index: BodyRouteIndex): tuple[
    portalNext, cells, total: int64] =
  ## Diagnostic ledger for the two activation-only following payloads.
  if index == nil:
    return
  result.portalNext = int64(index.portalNext.len * sizeof(uint8))
  result.cells = int64(index.cells.len * sizeof(int32))
  result.total = result.portalNext + result.cells

proc releaseFollowingPayload*(index: BodyRouteIndex): int64 =
  ## The mixed graph owns production reconstruction. These activation-only
  ## fields remain available while the hierarchy, hazard summaries, and query
  ## scratch are built, then are released before gameplay.
  if index == nil:
    return
  result = int64(index.portalNext.len * sizeof(uint8) +
    index.cells.len * sizeof(int32))
  index.portalNext = @[]
  index.cells = @[]
  index.stats.retainedBytes = index.retainedBytes()

proc validateRouteIndex*(index: BodyRouteIndex)

proc newBodyRouteIndex*(map: BodyMap): BodyRouteIndex =
  if map == nil:
    raise newException(ValueError, "body route index requires a BodyMap")
  new(result)
  result.map = map
  result.stats = BodyRouteIndexStats(
    navCells: map.gridWidth * map.gridHeight, rooms: map.roomCount)
  result.buildLegalMoves()
  let maxRoomCells = result.buildRoomLayout()
  let crossings = result.buildSides()
  let counted = result.buildFieldsAndCountSegments(maxRoomCells)
  result.fillSegmentsAndArcs(crossings, counted.intraCount, counted.intraCells)
  result.buildGraphComponents()
  result.seedUnrepresentedPixelComponents()
  result.validateValidatorAnchors()
  result.buildPocketConnectors()
  result.buildFineAnchorIndex()
  result.stats.segments = result.segments.len
  result.stats.segmentCells = result.cells.len
  result.stats.arcs = result.arcs.len
  result.stats.retainedBytes = result.retainedBytes()
  result.validateRouteIndex()

proc legalMovesAt*(index: BodyRouteIndex, cellIndex: int): uint8 =
  if cellIndex < 0 or cellIndex >= index.legalMoves.len:
    raise newException(IndexDefect, "route-index cell is out of bounds")
  index.legalMoves[cellIndex]

proc roomForCell*(index: BodyRouteIndex, cellIndex: int): int =
  if cellIndex < 0 or cellIndex >= index.roomOf.len:
    return -1
  if index.roomOf[cellIndex] == NoRoom: -1 else: index.roomOf[cellIndex].int

proc sideAnchor*(index: BodyRouteIndex, side: int): BodyPoint =
  if side < 0 or side >= index.sides.len:
    raise newException(IndexDefect, "route-index side is out of bounds")
  index.routePoint(index.sides[side].anchorCell)

proc portalSideAt*(index: BodyRouteIndex, side: int): BodyPortalSide =
  if side < 0 or side >= index.sides.len:
    raise newException(IndexDefect, "route-index side is out of bounds")
  index.sides[side]

proc routeSegmentAt*(index: BodyRouteIndex, segment: int): BodyRouteSegment =
  if segment < 0 or segment >= index.segments.len:
    raise newException(IndexDefect, "route-index segment is out of bounds")
  index.segments[segment]

proc routeArcAt*(index: BodyRouteIndex, arc: int): BodyRouteArc =
  if arc < 0 or arc >= index.arcs.len:
    raise newException(IndexDefect, "route-index arc is out of bounds")
  index.arcs[arc]

proc arcRangeForSide*(index: BodyRouteIndex, side: int): Slice[int] =
  if side < 0 or side >= index.sides.len:
    raise newException(IndexDefect, "route-index side is out of bounds")
  index.arcStart[side].int .. index.arcStart[side + 1].int - 1

proc segmentCells*(index: BodyRouteIndex, segment: int,
                   reversed = false): seq[int32] =
  ## Diagnostic snapshot. The live query/follower uses segmentCellAt below so
  ## reverse traversal stays allocation-free.
  let metadata = index.routeSegmentAt(segment)
  result = newSeq[int32](metadata.cellLen.int)
  for offset in 0 ..< result.len:
    let source = if reversed: result.high - offset else: offset
    result[offset] = index.cells[metadata.cellStart.int + source]

proc segmentCellAt*(index: BodyRouteIndex, segment, offset: int,
                    reversed = false): int32 =
  let metadata = index.routeSegmentAt(segment)
  if offset < 0 or offset >= metadata.cellLen.int:
    raise newException(IndexDefect, "route-index segment offset is out of bounds")
  let source = if reversed: metadata.cellLen.int - 1 - offset else: offset
  index.cells[metadata.cellStart.int + source]

proc segmentArrivalExtrema*(index: BodyRouteIndex,
    arrival: openArray[uint16], neverArrives: uint16): tuple[
      minimum, maximum: seq[uint16]] =
  ## Activation-only summary over episode-projected nav-cell arrivals. Fine
  ## crossing points deliberately sample their containing 8 px nav cell.
  if arrival.len != index.stats.navCells:
    raise newException(ValueError,
      "segment arrival surface does not match the route index")
  result.minimum = newSeq[uint16](index.segments.len)
  result.maximum = newSeq[uint16](index.segments.len)
  for segmentIndex, segment in index.segments:
    var
      minimum = neverArrives
      maximum = 0'u16
    for offset in 0 ..< segment.cellLen.int:
      let value = arrival[index.routeNavCell(
        index.segmentCellAt(segmentIndex, offset)).int]
      minimum = min(minimum, value)
      maximum = max(maximum, value)
    result.minimum[segmentIndex] = minimum
    result.maximum[segmentIndex] = maximum

proc pocketConnectorAt*(index: BodyRouteIndex,
    pocket: int): BodyPocketConnector =
  if pocket < 0 or pocket >= index.pockets.len:
    raise newException(IndexDefect, "route-index pocket is out of bounds")
  index.pockets[pocket]

proc pocketConnectorPoints*(index: BodyRouteIndex, pocket: int): seq[int32] =
  let metadata = index.pocketConnectorAt(pocket)
  result = newSeq[int32](metadata.pointLen.int)
  for offset in 0 ..< result.len:
    result[offset] = index.pocketCells[metadata.pointStart.int + offset]

proc pocketConnectorPointAt*(index: BodyRouteIndex,
    pocket, offset: int): int32 =
  let metadata = index.pocketConnectorAt(pocket)
  if offset < 0 or offset >= metadata.pointLen.int:
    raise newException(IndexDefect,
      "route-index pocket connector offset is out of bounds")
  index.pocketCells[metadata.pointStart.int + offset]

proc fineAnchorRangeForCell*(index: BodyRouteIndex,
    cellIndex: int): Slice[int] =
  ## Allocation-free range into the retained fine-anchor table for one coarse
  ## navigation cell. Empty cells return an empty slice.
  if cellIndex < 0 or cellIndex >= index.stats.navCells:
    raise newException(IndexDefect, "route-index cell is out of bounds")
  index.fineAnchorStart[cellIndex].int ..
    index.fineAnchorStart[cellIndex + 1].int - 1

proc fineAnchorAt*(index: BodyRouteIndex, offset: int): int32 =
  if offset < 0 or offset >= index.fineAnchors.len:
    raise newException(IndexDefect, "route-index fine anchor is out of bounds")
  index.fineAnchors[offset]

proc fineAnchorCount*(index: BodyRouteIndex): int = index.fineAnchors.len

proc roomSideRange*(index: BodyRouteIndex, room: int): Slice[int] =
  if room < 0 or room >= index.map.roomCount:
    raise newException(IndexDefect, "route-index room is out of bounds")
  index.roomSideStart[room].int .. index.roomSideStart[room + 1].int - 1

proc roomSideAt*(index: BodyRouteIndex, offset: int): int =
  if offset < 0 or offset >= index.roomSides.len:
    raise newException(IndexDefect, "route-index room-side offset is out of bounds")
  index.roomSides[offset].int

proc nextCellTowardSide*(index: BodyRouteIndex,
    side, cellIndex: int): int32 =
  if side < 0 or side >= index.sides.len or
      cellIndex < 0 or cellIndex >= index.stats.navCells:
    raise newException(IndexDefect, "route-index side field lookup is out of bounds")
  let metadata = index.sides[side]
  if cellIndex == metadata.anchorCell.int:
    return int32(cellIndex)
  if index.roomOf[cellIndex] != metadata.room or index.localIndex[cellIndex] < 0:
    return -1
  let direction = index.portalNext[
    metadata.fieldStart.int + index.localIndex[cellIndex].int]
  if direction == NoHop:
    return -1
  let
    cell = index.cellPoint(cellIndex)
    delta = NavNeighbors[direction.int]
  int32(index.cellIndex((cell.x + delta.x, cell.y + delta.y)))

proc routeIndexStats*(index: BodyRouteIndex): BodyRouteIndexStats = index.stats

proc graphComponentForSide*(index: BodyRouteIndex, side: int): int =
  if side < 0 or side >= index.sideComponent.len: 0
  else: index.sideComponent[side].int

proc graphComponentForCell*(index: BodyRouteIndex, cellIndex: int): int =
  if cellIndex < 0 or cellIndex >= index.cellComponent.len: 0
  else: index.cellComponent[cellIndex].int

proc connectorGraphComponent*(index: BodyRouteIndex, point: BodyPoint): int =
  if not index.map.canStand(point):
    return 0
  result = index.coarseConnectorGraphComponent(point)
  if result != 0:
    return
  let pixelComponent = index.map.componentOf(point)
  for pocket in index.pockets:
    let target = index.routePoint(pocket.targetCell)
    if index.map.componentOf(target) != pixelComponent:
      continue
    for offset in 0 ..< pocket.pointLen.int:
      let attach = index.routePoint(
        index.pocketCells[pocket.pointStart.int + offset])
      if point.distanceSquared(attach) <=
          ConnectorMaxDistancePx * ConnectorMaxDistancePx and
          index.map.componentOf(attach) == pixelComponent and
          index.map.segmentClear(point, attach):
        return index.cellComponent[pocket.targetCell.int].int

proc routeIndexCoverage*(index: BodyRouteIndex): BodyRouteCoverageStats =
  var hash = 1469598103934665603'u64
  var
    validatorComponent = newSeq[bool](index.map.componentCount + 1)
    unreachableSeen = newSeq[bool](index.map.componentCount + 1)
  for validator in 0 ..< index.map.validatorTableCount:
    validatorComponent[index.map.validatorComponentAt(validator)] = true
  for y in 0 ..< index.map.height:
    for x in 0 ..< index.map.width:
      let point = (x, y)
      if not index.map.canStand(point):
        continue
      inc result.standablePixels
      let pixelComponent = index.map.componentOf(point)
      if not validatorComponent[pixelComponent]:
        inc result.unreachablePixels
        if not unreachableSeen[pixelComponent]:
          unreachableSeen[pixelComponent] = true
          inc result.unreachableComponents
        hash = hash * 1099511628211'u64
        continue
      let component = index.connectorGraphComponent(point)
      if component == 0:
        if result.uncoveredPixels == 0:
          result.firstUncovered = point
        inc result.uncoveredPixels
      else:
        inc result.coveredPixels
      hash = (hash xor uint64(component)) * 1099511628211'u64
  result.componentHash = hash

proc routeIndexFingerprint*(index: BodyRouteIndex): uint64 =
  var value = 1469598103934665603'u64
  template mix(item: untyped) =
    value = (value xor uint64(item)) * 1099511628211'u64
  for item in index.legalMoves: mix(item)
  for item in index.roomOf: mix(item)
  for item in index.localIndex: mix(cast[uint32](item))
  for item in index.roomCellStart: mix(cast[uint32](item))
  for item in index.roomCells: mix(cast[uint32](item))
  for item in index.roomSideStart: mix(cast[uint32](item))
  for item in index.roomSides: mix(item)
  for side in index.sides:
    mix(side.portal); mix(side.room); mix(cast[uint32](side.anchorCell))
    mix(cast[uint32](side.fieldStart))
  for item in index.portalNext: mix(item)
  for segment in index.segments:
    mix(cast[uint32](segment.cellStart)); mix(segment.cellLen)
    mix(segment.staticLengthQ4); mix(segment.minX); mix(segment.minY)
    mix(segment.maxX); mix(segment.maxY)
  for item in index.cells: mix(cast[uint32](item))
  for item in index.arcStart: mix(cast[uint32](item))
  for arc in index.arcs:
    mix(arc.fromSide); mix(arc.toSide); mix(arc.segment); mix(ord(arc.reversed))
  for item in index.sideComponent: mix(item)
  for item in index.cellComponent: mix(item)
  for pocket in index.pockets:
    mix(cast[uint32](pocket.sourcePoint))
    mix(cast[uint32](pocket.targetCell))
    mix(cast[uint32](pocket.pointStart))
    mix(pocket.pointLen)
    mix(pocket.staticLengthQ4)
  for item in index.pocketCells: mix(cast[uint32](item))
  for item in index.fineAnchorStart: mix(cast[uint32](item))
  for item in index.fineAnchors: mix(cast[uint32](item))
  value

proc validateRouteIndex*(index: BodyRouteIndex) =
  if index == nil or index.map == nil:
    raise newException(BodyMapError, "body route index is nil")
  if index.legalMoves.len != index.stats.navCells or
      index.roomOf.len != index.stats.navCells or
      index.localIndex.len != index.stats.navCells or
      index.cellComponent.len != index.stats.navCells or
      index.fineAnchorStart.len != index.stats.navCells + 1:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent cell arrays")
  if index.sides.len != index.stats.sides or
      index.stats.sides != index.stats.portals * 2 or
      index.stats.crossings != index.stats.portals:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent portal stats")
  if index.fineAnchorStart[0] != 0 or
      index.fineAnchorStart[^1].int != index.fineAnchors.len:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent fine-anchor bounds")
  for cellIndex in 0 ..< index.stats.navCells:
    var previous = low(int32)
    for offset in index.fineAnchorRangeForCell(cellIndex):
      let pointRef = index.fineAnchorAt(offset)
      if pointRef >= 0 or pointRef <= previous or
          index.routeNavCell(pointRef).int != cellIndex or
          not index.map.canStand(index.routePoint(pointRef)):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' has invalid fine anchor " &
          &"{pointRef} for cell {cellIndex}")
      previous = pointRef
  for cellIndex in 0 ..< index.stats.navCells:
    let cell = index.cellPoint(cellIndex)
    if index.map.cellWalkable(cell) and index.roomOf[cellIndex] == NoRoom:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' walkable cell " &
        &"({cell.x},{cell.y}) has no room")
    for neighborIndex, delta in NavNeighbors:
      if (index.legalMoves[cellIndex] and uint8(1 shl neighborIndex)) == 0:
        continue
      let next: BodyPoint = (cell.x + delta.x, cell.y + delta.y)
      if next.x < 0 or next.x >= index.map.gridWidth or
          next.y < 0 or next.y >= index.map.gridHeight:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' stores illegal move at {cell}")
      let nextIndex = index.cellIndex(next)
      # Every directed bit still needs its reverse. Unit-move geometry is
      # symmetric, so the lower-index endpoint checks it for the pair.
      if cellIndex < nextIndex and not index.map.legalNavMove(cell, next):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' stores illegal move at {cell}")
      let reverse = reverseNeighbor(neighborIndex)
      if (index.legalMoves[nextIndex] and uint8(1 shl reverse)) == 0:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' has asymmetric move at {cell}")
  var
    fineCrossings = 0
    finePoints = 0
  for segmentIndex, segment in index.segments:
    if segment.cellLen == 0 or
        segment.cellStart.int + segment.cellLen.int > index.cells.len:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' segment {segmentIndex} has invalid bounds")
    let crossing = segmentIndex < index.stats.crossings
    var hasFine = false
    for offset in 0 ..< segment.cellLen.int:
      let pointRef = index.segmentCellAt(segmentIndex, offset)
      if pointRef < 0:
        if not crossing:
          raise newException(BodyMapError,
            &"body route index map '{index.map.mapLabel}' non-crossing " &
            &"segment {segmentIndex} contains a fine point")
        hasFine = true
        inc finePoints
      let point = index.routePoint(pointRef)
      if not index.map.canStand(point):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' segment {segmentIndex} " &
          &"contains unstandable point {point}")
    if hasFine:
      if index.segmentCellAt(segmentIndex, 0) < 0 or
          index.segmentCellAt(segmentIndex, segment.cellLen.int - 1) < 0:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' fine crossing " &
          &"segment {segmentIndex} does not end at coarse anchors")
      inc fineCrossings
    for offset in 1 ..< segment.cellLen.int:
      let
        previousRef = index.segmentCellAt(segmentIndex, offset - 1)
        currentRef = index.segmentCellAt(segmentIndex, offset)
        previous = index.routePoint(previousRef)
        current = index.routePoint(currentRef)
        legal = if crossing:
          index.map.segmentClear(previous, current)
        else:
          index.map.legalNavMove(index.cellPoint(previousRef.int),
            index.cellPoint(currentRef.int))
      if not legal:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' segment {segmentIndex} " &
          &"contains illegal move {previous}->{current}")
  if index.pockets.len != index.stats.pocketConnectors:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent pocket count")
  for pocketIndex, pocket in index.pockets:
    if pocket.pointLen < 2 or pocket.pointStart < 0 or
        pocket.pointStart.int + pocket.pointLen.int > index.pocketCells.len:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' pocket connector " &
        &"{pocketIndex} has invalid bounds")
    if index.pocketCells[pocket.pointStart.int] != pocket.sourcePoint or
        index.pocketCells[pocket.pointStart.int + pocket.pointLen.int - 1] !=
          pocket.targetCell or pocket.sourcePoint >= 0 or pocket.targetCell < 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' pocket connector " &
        &"{pocketIndex} has invalid endpoints")
    var connectorLength = 0'u32
    for offset in 0 ..< pocket.pointLen.int:
      let pointRef = index.pocketCells[pocket.pointStart.int + offset]
      if offset < pocket.pointLen.int - 1 and pointRef >= 0:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' pocket connector " &
          &"{pocketIndex} contains a coarse interior point")
      if pointRef < 0:
        inc finePoints
      let current = index.routePoint(pointRef)
      if not index.map.canStand(current):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' pocket connector " &
          &"{pocketIndex} contains unstandable point {current}")
      if offset > 0:
        let previous = index.routePoint(
          index.pocketCells[pocket.pointStart.int + offset - 1])
        if not index.map.segmentClear(previous, current):
          raise newException(BodyMapError,
            &"body route index map '{index.map.mapLabel}' pocket connector " &
            &"{pocketIndex} contains illegal move {previous}->{current}")
        connectorLength += pixelStepQ4(previous, current)
    if connectorLength != pocket.staticLengthQ4 or
        index.cellComponent[pocket.targetCell.int] == 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' pocket connector " &
        &"{pocketIndex} has invalid length or target")
  if fineCrossings != index.stats.fineCrossings or
      finePoints != index.stats.finePoints or
      index.stats.finePointBytes != finePoints * sizeof(int32):
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent fine-point stats")
  for pointRef in index.cells:
    if pointRef < 0:
      let cellIndex = index.routeNavCell(pointRef).int
      var found = false
      for offset in index.fineAnchorRangeForCell(cellIndex):
        if index.fineAnchorAt(offset) == pointRef:
          found = true
          break
      if not found:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' omits retained fine " &
          &"point {pointRef} from its cell index")
  for pointRef in index.pocketCells:
    if pointRef < 0:
      let cellIndex = index.routeNavCell(pointRef).int
      var found = false
      for offset in index.fineAnchorRangeForCell(cellIndex):
        if index.fineAnchorAt(offset) == pointRef:
          found = true
          break
      if not found:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' omits retained fine " &
          &"point {pointRef} from its cell index")
  var pixelForGraph = newSeq[int](index.stats.graphComponents + 1)
  var graphForPixel = newSeq[int](index.map.componentCount + 1)
  for sideIndex, side in index.sides:
    let
      point = cellCenter(index.cellPoint(side.anchorCell.int))
      pixel = index.map.componentOf(point)
      graph = index.sideComponent[sideIndex].int
    if side.room.int != index.roomForCell(side.anchorCell.int):
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' portal {side.portal} " &
        "side room disagrees with its coarse anchor")
    if pixel <= 0 or graph <= 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' portal {side.portal} " &
        "has an unconnected side anchor")
    if pixelForGraph[graph] notin [0, pixel] or
        graphForPixel[pixel] notin [0, graph]:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' portal {side.portal} " &
        &"side {sideIndex} graph {graph} pixel {pixel} disagrees with " &
        &"graph pixel {pixelForGraph[graph]} and pixel graph " &
        &"{graphForPixel[pixel]}")
    pixelForGraph[graph] = pixel
    graphForPixel[pixel] = graph
  for cellIndex, graphValue in index.cellComponent:
    let graph = graphValue.int
    if graph == 0:
      continue
    let pixel = index.map.componentOf(cellCenter(index.cellPoint(cellIndex)))
    if pixel <= 0 or pixelForGraph[graph] notin [0, pixel] or
        graphForPixel[pixel] notin [0, graph]:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' anchored cell " &
        &"{index.cellPoint(cellIndex)} graph connectivity disagrees with " &
        "pixel components")
    pixelForGraph[graph] = pixel
    graphForPixel[pixel] = graph
