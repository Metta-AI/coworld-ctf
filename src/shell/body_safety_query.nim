## Fixed-workspace local and side hints for zone-safe-ground selection.

import std/options
import body_hazard, body_map, body_route_index

const
  SafetySearchPopCap* = 512
  SafetyRecordCap = 4_096
  SafetyHashCap = 8_192
  NoSafetyRecord = -1'i16

static:
  doAssert (SafetyHashCap and (SafetyHashCap - 1)) == 0

type
  BodyNearestDryResult* = object
    found*: bool
    sourceCell*, firstStep*: int32
    distanceQ4*: uint32

  BodySafetyScratch* = ref object
    index: BodyRouteIndex
    hazard: BodyHazardOverlay
    cache: BodySafeCache
    generation: uint32
    hashGeneration: array[SafetyHashCap, uint32]
    hashCell: array[SafetyHashCap, int32]
    hashRecord: array[SafetyHashCap, int16]
    cell: array[SafetyRecordCap, int32]
    cost: array[SafetyRecordCap, uint32]
    parent: array[SafetyRecordCap, int16]
    closedGeneration: array[SafetyRecordCap, uint32]
    heap: array[SafetyRecordCap, int16]
    heapPosition: array[SafetyRecordCap, int16]
    recordCount, heapLen: int

proc newBodySafetyScratch*(index: BodyRouteIndex): BodySafetyScratch =
  if index == nil:
    raise newException(ValueError, "body safety query requires an index")
  new(result)
  result.index = index
  for value in result.heapPosition.mitems:
    value = NoSafetyRecord

proc retainedBytes*(scratch: BodySafetyScratch): int64 =
  if scratch == nil: 0 else: int64(sizeof(scratch[]))

proc routeOctileQ4*(a, b: BodyPoint): int64 =
  let
    dx = abs(a.x - b.x)
    dy = abs(a.y - b.y)
    diagonal = min(dx, dy)
  int64(181 * diagonal + 128 * (max(dx, dy) - diagonal))

proc installSafetyContext*(scratch: BodySafetyScratch;
    hazard: BodyHazardOverlay; cache: BodySafeCache) =
  if scratch == nil or hazard == nil or cache == nil:
    raise newException(ValueError,
      "body route safety context requires scratch, hazard, and cache")
  scratch.hazard = hazard
  scratch.cache = cache

proc safetyReady*(scratch: BodySafetyScratch): bool =
  scratch != nil and scratch.hazard != nil and
    scratch.hazard.state == bhsReady and scratch.cache != nil

proc refreshSafety*(scratch: BodySafetyScratch; elapsedTick: int;
    gameGeneration: uint64) =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.cache.refreshSafeCache(scratch.index, scratch.hazard,
    elapsedTick, gameGeneration)

proc safetyArrivalAt*(scratch: BodySafetyScratch; cellIndex: int): uint16 =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.hazard.arrivalAt(cellIndex)

proc safetyCellDryAt*(scratch: BodySafetyScratch; cellIndex: int): bool =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.cache.cellDryAt(scratch.hazard, cellIndex)

proc safetyRoomHasDryAt*(scratch: BodySafetyScratch; room: int): bool =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.cache.roomHasDryAt(scratch.hazard, room)

proc safetyDistanceQ4At*(scratch: BodySafetyScratch; side: int): uint32 =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.cache.safeDistanceQ4At(scratch.hazard, side)

proc safetyNextSideAt*(scratch: BodySafetyScratch; side: int): Option[int] =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.cache.nextSafeSideAt(scratch.hazard, side)

proc nextGeneration(scratch: BodySafetyScratch) =
  inc scratch.generation
  if scratch.generation == 0:
    for value in scratch.hashGeneration.mitems: value = 0
    for value in scratch.closedGeneration.mitems: value = 0
    scratch.generation = 1
  scratch.recordCount = 0
  scratch.heapLen = 0

proc slotFor(scratch: BodySafetyScratch; cell: int32): int =
  result = (cast[uint32](cell) * 2_654_435_761'u32 and
    uint32(SafetyHashCap - 1)).int
  while scratch.hashGeneration[result] == scratch.generation and
      scratch.hashCell[result] != cell:
    result = (result + 1) and (SafetyHashCap - 1)

proc recordFor(scratch: BodySafetyScratch; cell: int32): int =
  let slot = scratch.slotFor(cell)
  if scratch.hashGeneration[slot] == scratch.generation:
    return scratch.hashRecord[slot].int
  if scratch.recordCount >= SafetyRecordCap:
    return -1
  result = scratch.recordCount
  inc scratch.recordCount
  scratch.hashGeneration[slot] = scratch.generation
  scratch.hashCell[slot] = cell
  scratch.hashRecord[slot] = int16(result)
  scratch.cell[result] = cell
  scratch.cost[result] = high(uint32)
  scratch.parent[result] = NoSafetyRecord
  scratch.heapPosition[result] = NoSafetyRecord

proc heapLess(scratch: BodySafetyScratch; a, b: int): bool =
  scratch.cost[a] < scratch.cost[b] or
    (scratch.cost[a] == scratch.cost[b] and scratch.cell[a] < scratch.cell[b])

proc swapHeap(scratch: BodySafetyScratch; a, b: int) =
  swap scratch.heap[a], scratch.heap[b]
  scratch.heapPosition[scratch.heap[a]] = int16(a)
  scratch.heapPosition[scratch.heap[b]] = int16(b)

proc pushOrDecrease(scratch: BodySafetyScratch; record: int): bool =
  var position = scratch.heapPosition[record].int
  if position < 0:
    if scratch.heapLen >= SafetyRecordCap:
      return false
    position = scratch.heapLen
    inc scratch.heapLen
    scratch.heap[position] = int16(record)
    scratch.heapPosition[record] = int16(position)
  while position > 0:
    let parent = (position - 1) div 2
    if not scratch.heapLess(scratch.heap[position].int,
        scratch.heap[parent].int):
      break
    scratch.swapHeap(position, parent)
    position = parent
  true

proc pop(scratch: BodySafetyScratch): int =
  result = scratch.heap[0].int
  scratch.heapPosition[result] = NoSafetyRecord
  dec scratch.heapLen
  if scratch.heapLen == 0:
    return
  scratch.heap[0] = scratch.heap[scratch.heapLen]
  scratch.heapPosition[scratch.heap[0]] = 0
  var position = 0
  while true:
    let left = position * 2 + 1
    if left >= scratch.heapLen:
      break
    let right = left + 1
    let child = if right < scratch.heapLen and
        scratch.heapLess(scratch.heap[right].int, scratch.heap[left].int):
      right else: left
    if not scratch.heapLess(scratch.heap[child].int,
        scratch.heap[position].int):
      break
    scratch.swapHeap(position, child)
    position = child

proc nearestDryCell*(scratch: BodySafetyScratch; startCell, room: int):
    BodyNearestDryResult =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.nextGeneration()
  let start = scratch.recordFor(int32(startCell))
  if start < 0:
    return
  scratch.cost[start] = 0
  if not scratch.pushOrDecrease(start):
    return
  var pops = 0
  while scratch.heapLen > 0 and pops < SafetySearchPopCap:
    let record = scratch.pop()
    if scratch.closedGeneration[record] == scratch.generation:
      continue
    scratch.closedGeneration[record] = scratch.generation
    inc pops
    let currentCell = scratch.cell[record]
    if scratch.safetyCellDryAt(currentCell.int):
      result.found = true
      result.sourceCell = currentCell
      result.firstStep = -1
      result.distanceQ4 = scratch.cost[record]
      var first = record
      while scratch.parent[first] >= 0 and scratch.parent[first].int != start:
        first = scratch.parent[first].int
      if first != start:
        result.firstStep = scratch.cell[first]
      return
    let
      current = scratch.index.map.cellOf(
        scratch.index.routePoint(currentCell))
      legal = scratch.index.legalMovesAt(currentCell.int)
    for direction, delta in NavNeighbors:
      if (legal and (1'u8 shl direction)) == 0:
        continue
      let
        point = (x: current.x + delta.x, y: current.y + delta.y)
        nextCell = int32(point.y * scratch.index.map.gridWidth + point.x)
      if scratch.index.roomForCell(nextCell.int) != room:
        continue
      let next = scratch.recordFor(nextCell)
      if next < 0 or scratch.closedGeneration[next] == scratch.generation:
        continue
      let
        step = if direction < 4: uint32(NavCell * 16) else: 181'u32
        candidate = scratch.cost[record] + step
      if candidate < scratch.cost[next] or
          (candidate == scratch.cost[next] and
           (scratch.parent[next] < 0 or
            currentCell < scratch.cell[scratch.parent[next]])):
        scratch.cost[next] = candidate
        scratch.parent[next] = int16(record)
        discard scratch.pushOrDecrease(next)
