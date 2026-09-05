## Immutable episode-shared hierarchical navigation index.
##
## Construction is activation-only. Retained arrays are counted before they
## are allocated and never grow while being filled. Live route queries consume
## this data in body_route_query.nim; they never build a source field.

import std/[algorithm, heapqueue, strformat]
import body_map

const
  PortalAnchorRingCells* = 4
  PortalCrossingBoxCells* = 4
  PortalCrossingMaxPops* = 64
  RouteEdgeIdCapacity* = 32_767
  NoRoom = high(uint16)
  NoHop = high(uint8)
  OrthStepQ4 = uint32(NavCell * 16)
  DiagonalStepQ4 = 181'u32

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

  BodyRouteIndexStats* = object
    navCells*, walkableCells*, rooms*, portals*, sides*: int
    portalFieldCells*, segments*, crossings*, segmentCells*, arcs*: int
    graphComponents*: int
    retainedBytes*, transientPeakBytes*: int64

  BodyRouteCoverageStats* = object
    standablePixels*, coveredPixels*, uncoveredPixels*: int
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

proc sideAnchorCandidates(index: BodyRouteIndex,
    chokeIndex, room: int): seq[int32] =
  let center = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let candidate = index.cellIndex(cell)
      if index.map.cellWalkable(cell) and index.roomOf[candidate].int == room:
        result.add int32(candidate)

proc crossingPath(index: BodyRouteIndex, chokeIndex: int,
                  startIndex, goalIndex: int32): CrossingPath =
  let
    start = index.cellPoint(startIndex.int)
    goal = index.cellPoint(goalIndex.int)
    chokeCell = index.map.cellOf(index.map.chokeAt(chokeIndex).pos)
  if index.map.legalNavMove(start, goal):
    result.cells = @[startIndex, goalIndex]
    return

  let
    x0 = max(0, chokeCell.x - PortalCrossingBoxCells)
    x1 = min(index.map.gridWidth - 1, chokeCell.x + PortalCrossingBoxCells)
    y0 = max(0, chokeCell.y - PortalCrossingBoxCells)
    y1 = min(index.map.gridHeight - 1, chokeCell.y + PortalCrossingBoxCells)
    boxW = x1 - x0 + 1
    boxH = y1 - y0 + 1
  var
    distance = newSeq[uint32](boxW * boxH)
    parent = newSeq[int32](boxW * boxH)
    queue = initHeapQueue[(uint32, int32)]()
  for offset in 0 ..< distance.len:
    distance[offset] = high(uint32)
    parent[offset] = -1
  template local(cell: BodyPoint): int = (cell.y - y0) * boxW + cell.x - x0
  distance[local(start)] = 0
  queue.push((0'u32, startIndex))
  var pops = 0
  while queue.len > 0 and pops < PortalCrossingMaxPops:
    let (currentDistance, currentIndex) = queue.pop()
    let current = index.cellPoint(currentIndex.int)
    if currentDistance != distance[local(current)]:
      continue
    inc pops
    if currentIndex == goalIndex:
      break
    for neighborIndex, delta in NavNeighbors:
      let next: BodyPoint = (current.x + delta.x, current.y + delta.y)
      if next.x < x0 or next.x > x1 or next.y < y0 or next.y > y1 or
          not index.map.legalNavMove(current, next):
        continue
      let candidate = currentDistance + neighborIndex.stepCost
      let nextLocal = local(next)
      if candidate < distance[nextLocal]:
        distance[nextLocal] = candidate
        parent[nextLocal] = currentIndex
        queue.push((candidate, int32(index.cellIndex(next))))
  if distance[local(goal)] == high(uint32):
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' choke {chokeIndex} " &
      &"has no crossing within +-{PortalCrossingBoxCells} cells and " &
      &"{PortalCrossingMaxPops} pops")
  var cursor = goalIndex
  while cursor >= 0:
    result.cells.add cursor
    if cursor == startIndex:
      break
    cursor = parent[local(index.cellPoint(cursor.int))]
  if result.cells.len == 0 or result.cells[^1] != startIndex:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' choke {chokeIndex} " &
      "crossing reconstruction failed")
  result.cells.reverse()

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
    var mask = 0'u8
    for neighborIndex, delta in NavNeighbors:
      let next = (cell.x + delta.x, cell.y + delta.y)
      if index.map.legalNavMove(cell, next):
        mask = mask or uint8(1 shl neighborIndex)
    index.legalMoves[cellIndex] = mask

proc buildSides(index: BodyRouteIndex): seq[CrossingPath] =
  let
    roomCount = index.map.roomCount
    chokeCount = index.map.chokeCount
  index.sides = newSeq[BodyPortalSide](chokeCount * 2)
  result = newSeq[CrossingPath](chokeCount)
  index.roomSideStart = newSeq[int32](roomCount + 1)
  var sideCounts = newSeq[int](roomCount)
  for chokeIndex in 0 ..< chokeCount:
    let choke = index.map.chokeAt(chokeIndex)
    if choke.roomA < 0 or choke.roomA >= roomCount or
        choke.roomB < 0 or choke.roomB >= roomCount or
        choke.roomA == choke.roomB:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' choke {chokeIndex} " &
        "has invalid incident rooms")
    inc sideCounts[choke.roomA]
    inc sideCounts[choke.roomB]
    let
      candidatesA = index.sideAnchorCandidates(chokeIndex, choke.roomA)
      candidatesB = index.sideAnchorCandidates(chokeIndex, choke.roomB)
    if candidatesA.len == 0 or candidatesB.len == 0:
      let missingRoom = if candidatesA.len == 0: choke.roomA else: choke.roomB
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' choke {chokeIndex} " &
        &"has no side anchor for room {missingRoom} within " &
        &"{PortalAnchorRingCells} cells")
    var
      anchorA = candidatesA[0]
      anchorB = candidatesB[0]
      crossing: CrossingPath
      found = false
    block directPair:
      for candidateA in candidatesA:
        for candidateB in candidatesB:
          if index.map.legalNavMove(index.cellPoint(candidateA.int),
              index.cellPoint(candidateB.int)):
            anchorA = candidateA
            anchorB = candidateB
            crossing.cells = @[candidateA, candidateB]
            found = true
            break directPair
    if not found:
      block boundedPair:
        for candidateA in candidatesA:
          for candidateB in candidatesB:
            try:
              crossing = index.crossingPath(chokeIndex, candidateA, candidateB)
              anchorA = candidateA
              anchorB = candidateB
              found = true
              break boundedPair
            except BodyMapError:
              discard
    if not found:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' choke {chokeIndex} " &
        &"has no crossing within +-{PortalCrossingBoxCells} cells and " &
        &"{PortalCrossingMaxPops} pops")
    index.sides[chokeIndex * 2] = BodyPortalSide(
      portal: uint16(chokeIndex), room: uint16(choke.roomA),
      anchorCell: anchorA)
    index.sides[chokeIndex * 2 + 1] = BodyPortalSide(
      portal: uint16(chokeIndex), room: uint16(choke.roomB),
      anchorCell: anchorB)
    result[chokeIndex] = crossing
  var cursor = 0
  for room, count in sideCounts:
    index.roomSideStart[room] = int32(cursor)
    cursor += count
  index.roomSideStart[^1] = int32(cursor)
  index.roomSides = newSeq[uint16](cursor)
  var write = newSeq[int](roomCount)
  for room in 0 ..< roomCount:
    write[room] = index.roomSideStart[room].int
  for chokeIndex in 0 ..< chokeCount:
    for side in [chokeIndex * 2, chokeIndex * 2 + 1]:
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
      &"body route index map '{index.map.mapLabel}' choke {side.portal} " &
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
    let cell = index.cellPoint(index.cells[start + offset].int)
    result.minX = min(result.minX, uint16(cell.x))
    result.minY = min(result.minY, uint16(cell.y))
    result.maxX = max(result.maxX, uint16(cell.x))
    result.maxY = max(result.maxY, uint16(cell.y))
    if offset > 0:
      let previous = index.cellPoint(index.cells[start + offset - 1].int)
      let diagonal = previous.x != cell.x and previous.y != cell.y
      result.staticLengthQ4 +=
        (if diagonal: DiagonalStepQ4 else: OrthStepQ4)

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
  index.stats.transientPeakBytes = int64(maxRoomCells) *
    int64(sizeof(uint32) + sizeof(uint8) + sizeof(BuildHeapNode) + sizeof(int))
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

proc retainedBytes(index: BodyRouteIndex): int64 =
  int64(index.legalMoves.len * sizeof(uint8) +
    index.roomOf.len * sizeof(uint16) +
    index.localIndex.len * sizeof(int32) +
    index.roomCellStart.len * sizeof(int32) +
    index.roomCells.len * sizeof(int32) +
    index.roomSideStart.len * sizeof(int32) +
    index.roomSides.len * sizeof(uint16) +
    index.sides.len * sizeof(BodyPortalSide) +
    index.portalNext.len * sizeof(uint8) +
    index.segments.len * sizeof(BodyRouteSegment) +
    index.cells.len * sizeof(int32) +
    index.arcStart.len * sizeof(int32) +
    index.arcs.len * sizeof(BodyRouteArc) +
    index.sideComponent.len * sizeof(uint16) +
    index.cellComponent.len * sizeof(uint16))

proc validateRouteIndex*(index: BodyRouteIndex)

proc newBodyRouteIndex*(map: BodyMap): BodyRouteIndex =
  if map == nil:
    raise newException(ValueError, "body route index requires a BodyMap")
  new(result)
  result.map = map
  result.stats = BodyRouteIndexStats(
    navCells: map.gridWidth * map.gridHeight,
    rooms: map.roomCount, portals: map.chokeCount, sides: map.chokeCount * 2,
    crossings: map.chokeCount)
  result.buildLegalMoves()
  let maxRoomCells = result.buildRoomLayout()
  let crossings = result.buildSides()
  let counted = result.buildFieldsAndCountSegments(maxRoomCells)
  result.fillSegmentsAndArcs(crossings, counted.intraCount, counted.intraCells)
  result.buildGraphComponents()
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
  index.cellPoint(index.sides[side].anchorCell.int)

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
  let center = index.map.cellOf(point)
  let pixelComponent = index.map.componentOf(point)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let candidate = index.cellIndex(cell)
      if index.cellComponent[candidate] != 0 and
          index.map.componentOf(cellCenter(cell)) == pixelComponent and
          index.map.segmentClear(point, cellCenter(cell)):
        return index.cellComponent[candidate].int

proc routeIndexCoverage*(index: BodyRouteIndex): BodyRouteCoverageStats =
  var hash = 1469598103934665603'u64
  for y in 0 ..< index.map.height:
    for x in 0 ..< index.map.width:
      let point = (x, y)
      if not index.map.canStand(point):
        continue
      inc result.standablePixels
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
  value

proc validateRouteIndex*(index: BodyRouteIndex) =
  if index == nil or index.map == nil:
    raise newException(BodyMapError, "body route index is nil")
  if index.legalMoves.len != index.stats.navCells or
      index.roomOf.len != index.stats.navCells or
      index.localIndex.len != index.stats.navCells or
      index.cellComponent.len != index.stats.navCells:
    raise newException(BodyMapError,
      &"body route index map '{index.map.mapLabel}' has inconsistent cell arrays")
  for cellIndex in 0 ..< index.stats.navCells:
    let cell = index.cellPoint(cellIndex)
    if index.map.cellWalkable(cell) and index.roomOf[cellIndex] == NoRoom:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' walkable cell " &
        &"({cell.x},{cell.y}) has no room")
    for neighborIndex, delta in NavNeighbors:
      if (index.legalMoves[cellIndex] and uint8(1 shl neighborIndex)) == 0:
        continue
      let next = (cell.x + delta.x, cell.y + delta.y)
      if not index.map.legalNavMove(cell, next):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' stores illegal move at {cell}")
      let reverse = reverseNeighbor(neighborIndex)
      if (index.legalMoves[index.cellIndex(next)] and uint8(1 shl reverse)) == 0:
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' has asymmetric move at {cell}")
  for segmentIndex, segment in index.segments:
    if segment.cellLen == 0 or
        segment.cellStart.int + segment.cellLen.int > index.cells.len:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' segment {segmentIndex} has invalid bounds")
    for offset in 1 ..< segment.cellLen.int:
      let
        previous = index.cellPoint(index.segmentCellAt(segmentIndex, offset - 1).int)
        current = index.cellPoint(index.segmentCellAt(segmentIndex, offset).int)
      if not index.map.legalNavMove(previous, current):
        raise newException(BodyMapError,
          &"body route index map '{index.map.mapLabel}' segment {segmentIndex} " &
          &"contains illegal move {previous}->{current}")
  var pixelForGraph = newSeq[int](index.stats.graphComponents + 1)
  var graphForPixel = newSeq[int](index.map.componentCount + 1)
  for sideIndex, side in index.sides:
    let
      point = cellCenter(index.cellPoint(side.anchorCell.int))
      pixel = index.map.componentOf(point)
      graph = index.sideComponent[sideIndex].int
    if pixel <= 0 or graph <= 0:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' choke {side.portal} " &
        "has an unconnected side anchor")
    if pixelForGraph[graph] notin [0, pixel] or
        graphForPixel[pixel] notin [0, graph]:
      raise newException(BodyMapError,
        &"body route index map '{index.map.mapLabel}' choke {side.portal} " &
        "graph connectivity disagrees with pixel components")
    pixelForGraph[graph] = pixel
    graphForPixel[pixel] = graph
