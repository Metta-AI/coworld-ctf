## Synchronous bounded queries over the immutable body route index.
##
## The workspace is shared by all seats and allocated at activation. Queries
## build and validate a complete descriptor in that workspace; callers may
## publish it only after success, so a typed failure cannot damage a live route.

import std/[hashes, math, options, tables]
when defined(navQueryProfile):
  import std/[monotimes, times]
import body_hazard, body_map, body_planner, body_route_index
import types as shellTypes

const
  RouteSidePopCap* = 4096
  RouteLocalPopCap* = 4096
  RouteLocalLegCap* = 512
  RouteEdgeCap* = 4096
  RouteSmoothLookahead* = 6
  SafetySearchPopCap* = 512
  EndpointAttachCap = 512
  EndpointPointCap = 8192
  LocalHashCap = 8192
  RouteDirectionBit = 0x8000'u16
  RouteSegmentMask = 0x7fff'u16
  NoRecord = -1'i32
  InfiniteCost = high(int64) div 4
  ArcCostInfinite = high(uint32)

static:
  doAssert (LocalHashCap and (LocalHashCap - 1)) == 0
  doAssert RouteSidePopCap <= RouteEdgeCap
  doAssert RouteLocalPopCap < LocalHashCap

type
  RouteEdgeRef* = distinct uint16

  BodyRouteFailure* = enum
    brfNone
    brfStartAttach
    brfGoalAttach
    brfDisconnected
    brfLocalCap
    brfSideCap
    brfDescriptorOverflow
    brfValidation

  BodyRouteRequest* = object
    start*: BodyPoint
    goal*: ValidatedGoal
    profile*: shellTypes.CostProfile
    danger*: ptr BodyDangerField
    blockedCell*: Option[BodyPoint]
    hazard*: BodyHazardOverlay
    elapsedZoneTick*: int

  BodyRouteDescriptor* = object
    edgeCount*, startLegLen*, goalLegLen*: uint16
    exactStart*, exactGoal*: BodyPoint

  BodyRouteQueryStats* = object
    sidePops*, localPops*: int
    sideCapHits*, localCapHits*: int
    earliestAlternativePops*: int
    selectedEarliestAlternative*: bool
    when defined(navQueryProfile):
      endpointAttachNanoseconds*: int64
      sameRoomNanoseconds*: int64
      sideGraphNanoseconds*: int64
      hazardPricingNanoseconds*: int64
      descriptorAssemblyValidateNanoseconds*: int64
      segmentClearCalls*: int
      localPopsTotal*: int
      arcsRelaxed*: int
      memoFills*: int
      memoCellReads*: int
      chainCellReads*: int
      hazardSteps*: int
      overflowKind*: string
      overflowActualLength*: int

  EndpointAttach = object
    pointStart: int32
    pointLen: uint16
    coarseCell: int32
    room: uint16
    graph: uint16

  EndpointWorkspace = object
    attaches: seq[EndpointAttach]
    points: seq[int32]
    attachCount, pointCount: int
    overflowed: bool

  QueryHeapNode = object
    priority, cost, physical: int64
    item, tie: int32

  QueryHeap = object
    nodes: seq[QueryHeapNode]
    positions: seq[int32]
    positionGeneration: seq[uint32]
    generation: uint32
    len: int

  BodyRouteQueryScratch* = ref object
    index: BodyRouteIndex
    safetyHazard: BodyHazardOverlay
    safetyCache: BodySafeCache
    generation: uint32
    arcMemoGeneration: uint16
    localGeneration: uint32
    heap: QueryHeap
    startAttach, goalAttach: EndpointWorkspace
    startCost, goalCost: seq[int64]
    startPhysical, goalPhysical: seq[int64]
    startAttachForSide, goalAttachForSide: seq[int16]
    sideCost: seq[int64]
    sidePhysical: seq[int64]
    sideParentArc: seq[int32]
    sideParentLabel: seq[uint8]
    sideSourceAttach: seq[int16]
    startGeneration, goalGeneration, sideGeneration: seq[uint32]
    sideClosedGeneration: seq[uint32]
    arcCost: seq[uint32]
    arcCostGeneration: seq[uint16]
    localHashKey: seq[int32]
    localHashRecord: seq[int16]
    localHashGeneration: seq[uint32]
    localCell: seq[int32]
    localCost: seq[int64]
    localParent: seq[int32]
    localClosedGeneration: seq[uint32]
    fineProvenanceKind: seq[uint8]
    fineProvenanceIndex: seq[int32]
    fineProvenanceOffset: seq[uint16]
    localCount: int
    resultEdges: array[RouteEdgeCap, RouteEdgeRef]
    resultStartLeg: array[RouteLocalLegCap, int32]
    resultGoalLeg: array[RouteLocalLegCap, int32]
    tempRefs: array[RouteLocalLegCap, int32]
    bestCost: int64
    resultDescriptor: BodyRouteDescriptor
    resultStats: BodyRouteQueryStats

  BodyRouteQueryResult* = object
    ok*: bool
    failure*: BodyRouteFailure
    descriptor*: BodyRouteDescriptor
    stats*: BodyRouteQueryStats
    owner: BodyRouteQueryScratch
    generation: uint32

  BodyNearestDryResult* = object
    found*: bool
    sourceCell*, firstStep*: int32
    distanceQ4*: uint32

iterator ringCells(center: BodyPoint, ring: int): BodyPoint =
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

proc routeOctileQ4*(a, b: BodyPoint): int64 =
  let
    dx = abs(a.x - b.x)
    dy = abs(a.y - b.y)
    diagonal = min(dx, dy)
  int64(181 * diagonal + 128 * (max(dx, dy) - diagonal))

when defined(navQueryProfile):
  proc profileElapsed(started: MonoTime): int64 {.inline.} =
    (getMonoTime() - started).inNanoseconds

proc querySegmentClear(index: BodyRouteIndex,
    scratch: BodyRouteQueryScratch, a, b: BodyPoint): bool {.inline.} =
  when defined(navQueryProfile):
    inc scratch.resultStats.segmentClearCalls
  index.map.segmentClear(a, b)

proc validateRouteQueryCapacity*(mapName: string, sideCount: int) =
  if sideCount < 0 or sideCount > RouteEdgeCap + 1:
    raise newException(BodyMapError,
      "body route query map '" & mapName & "' has " & $sideCount &
      " sides; a simple path can exceed the 4096-edge descriptor cap")

proc routeEdgeRef(segment: int, reversed: bool): RouteEdgeRef {.inline.} =
  var raw = uint16(segment)
  if reversed:
    raw = raw or RouteDirectionBit
  RouteEdgeRef(raw)

proc routeEdgeSegment*(edge: RouteEdgeRef): int {.inline.} =
  (uint16(edge) and RouteSegmentMask).int

proc routeEdgeReversed*(edge: RouteEdgeRef): bool {.inline.} =
  (uint16(edge) and RouteDirectionBit) != 0

proc nextGeneration(scratch: BodyRouteQueryScratch) =
  var value = scratch.generation
  inc value
  if value == 0:
    for stamp in scratch.startGeneration.mitems: stamp = 0
    for stamp in scratch.goalGeneration.mitems: stamp = 0
    for stamp in scratch.sideGeneration.mitems: stamp = 0
    for stamp in scratch.sideClosedGeneration.mitems: stamp = 0
    for stamp in scratch.arcCostGeneration.mitems: stamp = 0
    for stamp in scratch.localHashGeneration.mitems: stamp = 0
    for stamp in scratch.localClosedGeneration.mitems: stamp = 0
    value = 1
  scratch.generation = value
  inc scratch.arcMemoGeneration
  if scratch.arcMemoGeneration == 0:
    for stamp in scratch.arcCostGeneration.mitems:
      stamp = 0
    scratch.arcMemoGeneration = 1

proc nextLocalGeneration(scratch: BodyRouteQueryScratch) =
  inc scratch.localGeneration
  if scratch.localGeneration == 0:
    for stamp in scratch.localHashGeneration.mitems: stamp = 0
    for stamp in scratch.localClosedGeneration.mitems: stamp = 0
    scratch.localGeneration = 1
  scratch.localCount = 0

proc begin(heap: var QueryHeap) =
  inc heap.generation
  if heap.generation == 0:
    for stamp in heap.positionGeneration.mitems:
      stamp = 0
    heap.generation = 1
  heap.len = 0

proc nodeLess(a, b: QueryHeapNode): bool {.inline.} =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  elif a.physical != b.physical: a.physical < b.physical
  else: a.tie < b.tie

proc setPosition(heap: var QueryHeap, item, position: int) {.inline.} =
  heap.positions[item] = int32(position)
  heap.positionGeneration[item] = heap.generation

proc swapNodes(heap: var QueryHeap, a, b: int) {.inline.} =
  swap(heap.nodes[a], heap.nodes[b])
  heap.setPosition(heap.nodes[a].item.int, a)
  heap.setPosition(heap.nodes[b].item.int, b)

proc siftUp(heap: var QueryHeap, start: int) =
  var current = start
  while current > 0:
    let parent = (current - 1) div 2
    if not nodeLess(heap.nodes[current], heap.nodes[parent]):
      break
    heap.swapNodes(current, parent)
    current = parent

proc siftDown(heap: var QueryHeap, start: int) =
  var current = start
  while true:
    let left = current * 2 + 1
    if left >= heap.len:
      break
    let right = left + 1
    var child = left
    if right < heap.len and nodeLess(heap.nodes[right], heap.nodes[left]):
      child = right
    if not nodeLess(heap.nodes[child], heap.nodes[current]):
      break
    heap.swapNodes(child, current)
    current = child

proc pushOrDecrease(heap: var QueryHeap, node: QueryHeapNode): bool =
  let item = node.item.int
  if heap.positionGeneration[item] == heap.generation:
    let position = heap.positions[item].int
    if not nodeLess(node, heap.nodes[position]):
      return true
    heap.nodes[position] = node
    heap.siftUp(position)
    return true
  if heap.len >= heap.nodes.len:
    return false
  heap.nodes[heap.len] = node
  heap.setPosition(item, heap.len)
  inc heap.len
  heap.siftUp(heap.len - 1)
  true

proc pop(heap: var QueryHeap): QueryHeapNode =
  result = heap.nodes[0]
  heap.positionGeneration[result.item.int] = 0
  dec heap.len
  if heap.len > 0:
    heap.nodes[0] = heap.nodes[heap.len]
    heap.setPosition(heap.nodes[0].item.int, 0)
    heap.siftDown(0)

proc initEndpointWorkspace(): EndpointWorkspace =
  result.attaches = newSeq[EndpointAttach](EndpointAttachCap)
  result.points = newSeq[int32](EndpointPointCap)

proc reset(workspace: var EndpointWorkspace) =
  workspace.attachCount = 0
  workspace.pointCount = 0
  workspace.overflowed = false

proc pointsEqual(index: BodyRouteIndex, a, b: int32): bool {.inline.} =
  index.routePoint(a) == index.routePoint(b)

proc appendRef(index: BodyRouteIndex,
    refs: var array[RouteLocalLegCap, int32], count: var int, pointRef: int32):
    bool =
  if count > 0 and index.pointsEqual(refs[count - 1], pointRef):
    refs[count - 1] = pointRef
    return true
  if count >= refs.len:
    return false
  refs[count] = pointRef
  inc count
  true

proc addAttach(scratch: BodyRouteQueryScratch,
    workspace: var EndpointWorkspace,
    refs: openArray[int32]): bool =
  let index = scratch.index
  if refs.len == 0 or refs[^1] < 0 or refs.len > RouteLocalLegCap:
    return false
  let
    coarse = refs[^1].int
    room = index.roomForCell(coarse)
    graph = index.graphComponentForCell(coarse)
  if room < 0 or graph <= 0:
    return false
  for offset in 1 ..< refs.len:
    if not index.querySegmentClear(scratch,
        index.routePoint(refs[offset - 1]), index.routePoint(refs[offset])):
      return false
  for attachIndex in 0 ..< workspace.attachCount:
    let existing = workspace.attaches[attachIndex]
    if existing.pointLen.int != refs.len:
      continue
    var equal = true
    for offset, pointRef in refs:
      if workspace.points[existing.pointStart.int + offset] != pointRef:
        equal = false
        break
    if equal:
      return true
  if workspace.attachCount >= workspace.attaches.len or
      workspace.pointCount + refs.len > workspace.points.len:
    workspace.overflowed = true
    return false
  let destination = workspace.pointCount
  for pointRef in refs:
    workspace.points[workspace.pointCount] = pointRef
    inc workspace.pointCount
  workspace.attaches[workspace.attachCount] = EndpointAttach(
    pointStart: int32(destination), pointLen: uint16(refs.len),
    coarseCell: int32(coarse), room: uint16(room), graph: uint16(graph))
  inc workspace.attachCount
  true

proc addCrossingAttachments(scratch: BodyRouteQueryScratch,
    workspace: var EndpointWorkspace, endpointRef, fineRef: int32,
    segment, offset: int,
    refs: var array[RouteLocalLegCap, int32]) =
  let index = scratch.index
  let metadata = index.routeSegmentAt(segment)
  var count = 0
  if not index.appendRef(refs, count, endpointRef) or
      not index.appendRef(refs, count, fineRef):
    return
  for cursor in countdown(offset - 1, 0):
    if not index.appendRef(refs, count, index.segmentCellAt(segment, cursor)):
      break
  if count > 0 and refs[count - 1] >= 0:
    discard scratch.addAttach(workspace, refs.toOpenArray(0, count - 1))
  count = 0
  if not index.appendRef(refs, count, endpointRef) or
      not index.appendRef(refs, count, fineRef):
    return
  for cursor in offset + 1 ..< metadata.cellLen.int:
    if not index.appendRef(refs, count, index.segmentCellAt(segment, cursor)):
      break
  if count > 0 and refs[count - 1] >= 0:
    discard scratch.addAttach(workspace, refs.toOpenArray(0, count - 1))

proc addPocketAttachments(scratch: BodyRouteQueryScratch,
    workspace: var EndpointWorkspace, endpointRef, fineRef: int32,
    pocket, offset: int,
    refs: var array[RouteLocalLegCap, int32]) =
  let index = scratch.index
  let metadata = index.pocketConnectorAt(pocket)
  var count = 0
  if not index.appendRef(refs, count, endpointRef) or
      not index.appendRef(refs, count, fineRef):
    return
  for cursor in offset + 1 ..< metadata.pointLen.int:
    if not index.appendRef(refs, count,
        index.pocketConnectorPointAt(pocket, cursor)):
      break
  if count > 0 and refs[count - 1] >= 0:
    discard scratch.addAttach(workspace, refs.toOpenArray(0, count - 1))

proc collectAttachments(index: BodyRouteIndex, scratch: BodyRouteQueryScratch,
    endpoint: BodyPoint,
    workspace: var EndpointWorkspace,
    refs: var array[RouteLocalLegCap, int32]): BodyRouteFailure =
  workspace.reset()
  if not index.map.canStand(endpoint):
    return brfStartAttach
  let
    center = index.map.cellOf(endpoint)
    endpointRef = index.routeRefForPoint(endpoint)
    component = index.map.componentOf(endpoint)
  for ring in 0 .. PortalAnchorRingCells:
    for cell in ringCells(center, ring):
      if cell.x < 0 or cell.x >= index.map.gridWidth or
          cell.y < 0 or cell.y >= index.map.gridHeight:
        continue
      let coarseRef = int32(cell.y * index.map.gridWidth + cell.x)
      if index.graphComponentForCell(coarseRef.int) != 0:
        let coarsePoint = index.routePoint(coarseRef)
        if index.map.componentOf(coarsePoint) == component and
            index.querySegmentClear(scratch, endpoint, coarsePoint):
          var count = 0
          discard index.appendRef(refs, count, endpointRef)
          discard index.appendRef(refs, count, coarseRef)
          if not scratch.addAttach(workspace, refs.toOpenArray(0, count - 1)):
            return brfDescriptorOverflow
      for anchorOffset in index.fineAnchorRangeForCell(coarseRef.int):
        let fineRef = index.fineAnchorAt(anchorOffset)
        if index.map.componentOf(index.routePoint(fineRef)) == component and
            index.querySegmentClear(scratch, endpoint,
              index.routePoint(fineRef)):
          case scratch.fineProvenanceKind[anchorOffset]
          of 1:
            scratch.addCrossingAttachments(workspace, endpointRef, fineRef,
              scratch.fineProvenanceIndex[anchorOffset].int,
              scratch.fineProvenanceOffset[anchorOffset].int, refs)
          of 2:
            scratch.addPocketAttachments(workspace, endpointRef, fineRef,
              scratch.fineProvenanceIndex[anchorOffset].int,
              scratch.fineProvenanceOffset[anchorOffset].int, refs)
          else:
            return brfValidation
          if workspace.overflowed:
            return brfDescriptorOverflow
  if workspace.attachCount == 0: brfStartAttach else: brfNone

proc newBodyRouteQueryScratch*(index: BodyRouteIndex): BodyRouteQueryScratch =
  if index == nil:
    raise newException(ValueError, "body route query requires an index")
  let stats = index.routeIndexStats()
  validateRouteQueryCapacity(index.map.name, stats.sides)
  new(result)
  result.index = index
  let heapCapacity = max(RouteLocalPopCap, stats.sides * 2)
  result.heap.nodes = newSeq[QueryHeapNode](heapCapacity)
  result.heap.positions = newSeq[int32](heapCapacity)
  result.heap.positionGeneration = newSeq[uint32](heapCapacity)
  result.startAttach = initEndpointWorkspace()
  result.goalAttach = initEndpointWorkspace()
  result.startCost = newSeq[int64](stats.sides)
  result.goalCost = newSeq[int64](stats.sides)
  result.startPhysical = newSeq[int64](stats.sides)
  result.goalPhysical = newSeq[int64](stats.sides)
  result.startAttachForSide = newSeq[int16](stats.sides)
  result.goalAttachForSide = newSeq[int16](stats.sides)
  result.sideCost = newSeq[int64](stats.sides * 2)
  result.sidePhysical = newSeq[int64](stats.sides * 2)
  result.sideParentArc = newSeq[int32](stats.sides * 2)
  result.sideParentLabel = newSeq[uint8](stats.sides * 2)
  result.sideSourceAttach = newSeq[int16](stats.sides * 2)
  result.startGeneration = newSeq[uint32](stats.sides)
  result.goalGeneration = newSeq[uint32](stats.sides)
  result.sideGeneration = newSeq[uint32](stats.sides * 2)
  result.sideClosedGeneration = newSeq[uint32](stats.sides * 2)
  result.arcCost = newSeq[uint32](stats.arcs)
  result.arcCostGeneration = newSeq[uint16](stats.arcs)
  result.localHashKey = newSeq[int32](LocalHashCap)
  result.localHashRecord = newSeq[int16](LocalHashCap)
  result.localHashGeneration = newSeq[uint32](LocalHashCap)
  result.localCell = newSeq[int32](RouteLocalPopCap)
  result.localCost = newSeq[int64](RouteLocalPopCap)
  result.localParent = newSeq[int32](RouteLocalPopCap)
  result.localClosedGeneration = newSeq[uint32](RouteLocalPopCap)
  result.fineProvenanceKind = newSeq[uint8](index.fineAnchorCount)
  result.fineProvenanceIndex = newSeq[int32](index.fineAnchorCount)
  result.fineProvenanceOffset = newSeq[uint16](index.fineAnchorCount)
  var anchorByRef = initTable[int32, int](index.fineAnchorCount)
  for anchorOffset in 0 ..< index.fineAnchorCount:
    anchorByRef[index.fineAnchorAt(anchorOffset)] = anchorOffset
  for segment in 0 ..< stats.crossings:
    let metadata = index.routeSegmentAt(segment)
    for pointOffset in 0 ..< metadata.cellLen.int:
      let pointRef = index.segmentCellAt(segment, pointOffset)
      if pointRef < 0 and pointRef in anchorByRef:
        let anchorOffset = anchorByRef[pointRef]
        if result.fineProvenanceKind[anchorOffset] == 0:
          result.fineProvenanceKind[anchorOffset] = 1
          result.fineProvenanceIndex[anchorOffset] = int32(segment)
          result.fineProvenanceOffset[anchorOffset] = uint16(pointOffset)
  for pocket in 0 ..< stats.pocketConnectors:
    let metadata = index.pocketConnectorAt(pocket)
    for pointOffset in 0 ..< metadata.pointLen.int:
      let pointRef = index.pocketConnectorPointAt(pocket, pointOffset)
      if pointRef < 0 and pointRef in anchorByRef:
        let anchorOffset = anchorByRef[pointRef]
        if result.fineProvenanceKind[anchorOffset] == 0:
          result.fineProvenanceKind[anchorOffset] = 2
          result.fineProvenanceIndex[anchorOffset] = int32(pocket)
          result.fineProvenanceOffset[anchorOffset] = uint16(pointOffset)
  for anchorOffset in 0 ..< index.fineAnchorCount:
    if result.fineProvenanceKind[anchorOffset] == 0:
      raise newException(BodyMapError,
        "body route query map '" & index.map.name &
        "' has a retained fine anchor with no coarse route")

proc retainedBytes*(scratch: BodyRouteQueryScratch): int64 =
  ## Exact retained owner plus every variable-length workspace payload. Fixed
  ## route/leg buffers and all sequence headers are in sizeof(scratch[]).
  if scratch == nil:
    return 0
  result = int64(sizeof(scratch[]))
  template addPayload(values: untyped) =
    result += int64(values.len * sizeof(values[0]))
  addPayload(scratch.heap.nodes)
  addPayload(scratch.heap.positions)
  addPayload(scratch.heap.positionGeneration)
  addPayload(scratch.startAttach.attaches)
  addPayload(scratch.startAttach.points)
  addPayload(scratch.goalAttach.attaches)
  addPayload(scratch.goalAttach.points)
  addPayload(scratch.startCost)
  addPayload(scratch.goalCost)
  addPayload(scratch.startPhysical)
  addPayload(scratch.goalPhysical)
  addPayload(scratch.startAttachForSide)
  addPayload(scratch.goalAttachForSide)
  addPayload(scratch.sideCost)
  addPayload(scratch.sidePhysical)
  addPayload(scratch.sideParentArc)
  addPayload(scratch.sideParentLabel)
  addPayload(scratch.sideSourceAttach)
  addPayload(scratch.startGeneration)
  addPayload(scratch.goalGeneration)
  addPayload(scratch.sideGeneration)
  addPayload(scratch.sideClosedGeneration)
  addPayload(scratch.arcCost)
  addPayload(scratch.arcCostGeneration)
  addPayload(scratch.localHashKey)
  addPayload(scratch.localHashRecord)
  addPayload(scratch.localHashGeneration)
  addPayload(scratch.localCell)
  addPayload(scratch.localCost)
  addPayload(scratch.localParent)
  addPayload(scratch.localClosedGeneration)
  addPayload(scratch.fineProvenanceKind)
  addPayload(scratch.fineProvenanceIndex)
  addPayload(scratch.fineProvenanceOffset)

proc invalidateArcMemo*(scratch: BodyRouteQueryScratch) =
  ## Benchmark seam for the literal cold-memo scenario. Ordinary queries use
  ## generation stamps and never need to clear this retained array.
  if scratch == nil:
    return
  for stamp in scratch.arcCostGeneration.mitems:
    stamp = 0
  scratch.arcMemoGeneration = 1

proc installSafetyContext*(scratch: BodyRouteQueryScratch;
    hazard: BodyHazardOverlay; cache: BodySafeCache) =
  if scratch == nil or hazard == nil or cache == nil:
    raise newException(ValueError,
      "body route safety context requires scratch, hazard, and cache")
  scratch.safetyHazard = hazard
  scratch.safetyCache = cache

proc safetyReady*(scratch: BodyRouteQueryScratch): bool =
  scratch != nil and scratch.safetyHazard != nil and
    scratch.safetyHazard.state == bhsReady and scratch.safetyCache != nil

proc refreshSafety*(scratch: BodyRouteQueryScratch; elapsedTick: int;
    gameGeneration: uint64) =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyCache.refreshSafeCache(scratch.index, scratch.safetyHazard,
    elapsedTick, gameGeneration)

proc safetyArrivalAt*(scratch: BodyRouteQueryScratch;
    cellIndex: int): uint16 =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyHazard.arrivalAt(cellIndex)

proc safetyCellDryAt*(scratch: BodyRouteQueryScratch;
    cellIndex: int): bool =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyCache.cellDryAt(scratch.safetyHazard, cellIndex)

proc safetyRoomHasDryAt*(scratch: BodyRouteQueryScratch; room: int): bool =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyCache.roomHasDryAt(scratch.safetyHazard, room)

proc safetyDistanceQ4At*(scratch: BodyRouteQueryScratch; side: int): uint32 =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyCache.safeDistanceQ4At(scratch.safetyHazard, side)

proc safetyNextSideAt*(scratch: BodyRouteQueryScratch;
    side: int): Option[int] =
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.safetyCache.nextSafeSideAt(scratch.safetyHazard, side)

proc checkedAdd(a, b: int64): int64 {.inline.} =
  if b > 0 and a > InfiniteCost - b:
    return InfiniteCost
  a + b

proc checkedMultiply(a, b: int64): int64 {.inline.} =
  if a < 0 or b < 0 or (b != 0 and a > InfiniteCost div b):
    return InfiniteCost
  a * b

proc divideRoundTiesEven(numerator, denominator: int64): int64 {.inline.} =
  let
    quotient = numerator div denominator
    remainder = numerator mod denominator
    doubled = remainder * 2
  if doubled > denominator or
      (doubled == denominator and (quotient and 1) != 0):
    quotient + 1
  else:
    quotient

proc quantizeDangerQ8(value: float): int64 {.inline.} =
  if value.classify in {fcNan, fcNegInf} or value <= 0:
    return 0
  if value.classify == fcInf:
    return InfiniteCost
  let scaled = value * 256.0
  if scaled >= InfiniteCost.float:
    return InfiniteCost
  let
    lower = floor(scaled).int64
    fraction = scaled - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0):
    lower + 1
  else:
    lower

proc distanceQ4(a, b: BodyPoint): int64 {.inline.} =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  int64(round(sqrt(float(dx * dx + dy * dy)) * 16.0))

proc profileWeightQ8(profile: shellTypes.CostProfile): int64 {.inline.} =
  case profile
  of shellTypes.cpDefault: 256
  of shellTypes.cpCarrier: 640
  of shellTypes.cpHunter: 64

proc edgeBaseCost(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest,
    aRef, bRef: int32): int64 =
  let index = scratch.index
  when defined(navQueryProfile):
    let profileStarted = getMonoTime()
    defer:
      scratch.resultStats.hazardPricingNanoseconds +=
        profileElapsed(profileStarted)
  let
    a = index.routePoint(aRef)
    b = index.routePoint(bRef)
    base = distanceQ4(a, b)
    midpoint: BodyPoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
  var dangerQ8 = 0'i64
  if request.danger != nil:
    let sampled = request.danger[].sample(index.map, midpoint)
    dangerQ8 = sampled.quantizeDangerQ8
  let weighted = checkedMultiply(request.profile.profileWeightQ8, dangerQ8)
  if weighted == InfiniteCost:
    return InfiniteCost
  let numerator = checkedAdd(65_536'i64, weighted)
  let product = checkedMultiply(base, numerator)
  if product == InfiniteCost:
    return InfiniteCost
  result = divideRoundTiesEven(product, 65_536)
  if request.blockedCell.isSome and
      index.map.cellOf(midpoint) == index.map.cellOf(request.blockedCell.get):
    if result > InfiniteCost div 8:
      return InfiniteCost
    result *= 8

proc hazardEdgeCost(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest,
    bRef: int32, entryPhysicalQ4, stepPhysicalQ4: int64): int64 =
  let index = scratch.index
  if request.hazard == nil or request.hazard.state == bhsDark:
    return 0
  when defined(navQueryProfile):
    let profileStarted = getMonoTime()
    defer:
      inc scratch.resultStats.hazardSteps
      scratch.resultStats.hazardPricingNanoseconds +=
        profileElapsed(profileStarted)
  let cumulative = checkedAdd(entryPhysicalQ4, stepPhysicalQ4)
  if cumulative == InfiniteCost:
    return InfiniteCost
  let eta = request.elapsedZoneTick +
    int((cumulative + HazardEtaSpeedQ4 - 1) div HazardEtaSpeedQ4)
  request.hazard.hazardStepCostQ4(index.routeNavCell(bRef).int,
    eta, uint32(stepPhysicalQ4))

proc edgeCost(scratch: BodyRouteQueryScratch, request: BodyRouteRequest,
    aRef, bRef: int32, entryPhysicalQ4: int64): int64 =
  let physical = distanceQ4(scratch.index.routePoint(aRef),
    scratch.index.routePoint(bRef))
  checkedAdd(scratch.edgeBaseCost(request, aRef, bRef),
    scratch.hazardEdgeCost(request, bRef, entryPhysicalQ4, physical))

type LocalSearchState = enum
  lssFound
  lssDisconnected
  lssCap
  lssOverflow

proc localSlot(scratch: BodyRouteQueryScratch, cell: int32): int {.inline.} =
  var slot = (cast[uint32](cell) * 2_654_435_761'u32 and
    uint32(LocalHashCap - 1)).int
  while scratch.localHashGeneration[slot] == scratch.localGeneration and
      scratch.localHashKey[slot] != cell:
    slot = (slot + 1) and (LocalHashCap - 1)
  slot

proc localRecord(scratch: BodyRouteQueryScratch, cell: int32,
    create: bool): int =
  let slot = scratch.localSlot(cell)
  if scratch.localHashGeneration[slot] == scratch.localGeneration:
    return scratch.localHashRecord[slot].int
  if not create or scratch.localCount >= RouteLocalPopCap:
    return NoRecord.int
  result = scratch.localCount
  inc scratch.localCount
  scratch.localHashGeneration[slot] = scratch.localGeneration
  scratch.localHashKey[slot] = cell
  scratch.localHashRecord[slot] = int16(result)
  scratch.localCell[result] = cell
  scratch.localCost[result] = InfiniteCost
  scratch.localParent[result] = NoRecord
  scratch.localClosedGeneration[result] = 0

proc nearestDryCell*(scratch: BodyRouteQueryScratch; startCell, room: int):
    BodyNearestDryResult =
  ## Reuse the activation-allocated route workspace for the bounded safety
  ## query. Safety views and route planning run serially on the game thread.
  doAssert scratch.safetyReady, "body route safety context is not ready"
  scratch.nextLocalGeneration()
  scratch.heap.begin()
  let startRecord = scratch.localRecord(int32(startCell), true)
  scratch.localCost[startRecord] = 0
  if not scratch.heap.pushOrDecrease(QueryHeapNode(priority: 0, cost: 0,
      physical: 0, item: int32(startRecord), tie: int32(startCell))):
    return
  var pops = 0
  while scratch.heap.len > 0 and pops < SafetySearchPopCap:
    let node = scratch.heap.pop()
    let record = node.item.int
    if scratch.localClosedGeneration[record] == scratch.localGeneration or
        node.cost != scratch.localCost[record]:
      continue
    scratch.localClosedGeneration[record] = scratch.localGeneration
    inc pops
    let currentCell = scratch.localCell[record]
    if scratch.safetyCellDryAt(currentCell.int):
      result.found = true
      result.sourceCell = currentCell
      result.firstStep = -1
      result.distanceQ4 = uint32(node.cost)
      var firstRecord = record
      while scratch.localParent[firstRecord] >= 0 and
          scratch.localParent[firstRecord] != startRecord.int32:
        firstRecord = scratch.localParent[firstRecord].int
      if firstRecord != startRecord:
        result.firstStep = scratch.localCell[firstRecord]
      return
    let
      currentPoint = scratch.index.map.cellOf(
        scratch.index.routePoint(currentCell))
      legal = scratch.index.legalMovesAt(currentCell.int)
    for direction, delta in NavNeighbors:
      if (legal and (1'u8 shl direction)) == 0:
        continue
      let
        nextPoint = (x: currentPoint.x + delta.x,
          y: currentPoint.y + delta.y)
        nextCell = int32(nextPoint.y * scratch.index.map.gridWidth +
          nextPoint.x)
      if scratch.index.roomForCell(nextCell.int) != room:
        continue
      let nextRecord = scratch.localRecord(nextCell, true)
      if nextRecord < 0:
        continue
      let
        step = if direction < 4: int64(NavCell * 16) else: 181'i64
        candidate = node.cost + step
        previousParent = scratch.localParent[nextRecord].int
      if candidate < scratch.localCost[nextRecord] or
          (candidate == scratch.localCost[nextRecord] and
           (previousParent < 0 or
            currentCell < scratch.localCell[previousParent])):
        scratch.localCost[nextRecord] = candidate
        scratch.localParent[nextRecord] = int32(record)
        discard scratch.heap.pushOrDecrease(QueryHeapNode(
          priority: candidate, cost: candidate, physical: 0,
          item: int32(nextRecord), tie: nextCell))

proc runLocalPath(scratch: BodyRouteQueryScratch, request: BodyRouteRequest,
    fromCell, toCell: int32,
    destination: var array[RouteLocalLegCap, int32], length: var int,
    cost: var int64, entryPhysicalQ4 = 0'i64): LocalSearchState =
  ## Weighted A* within one immutable room. This is the only live cell search;
  ## its records, hash table, and heap are fixed at activation.
  length = 0
  cost = InfiniteCost
  if fromCell == toCell:
    destination[0] = fromCell
    length = 1
    cost = 0
    return lssFound
  let
    index = scratch.index
    room = index.roomForCell(fromCell.int)
  if room < 0 or index.roomForCell(toCell.int) != room:
    return lssDisconnected
  scratch.nextLocalGeneration()
  scratch.heap.begin()
  let startRecord = scratch.localRecord(fromCell, true)
  scratch.localCost[startRecord] = 0
  if not scratch.heap.pushOrDecrease(QueryHeapNode(
      priority: routeOctileQ4(index.map.cellOf(index.routePoint(fromCell)),
        index.map.cellOf(index.routePoint(toCell))),
      cost: 0, physical: entryPhysicalQ4,
      item: int32(startRecord), tie: fromCell)):
    return lssCap
  var
    targetRecord = NoRecord.int
    pops = 0
  while scratch.heap.len > 0:
    if pops >= RouteLocalPopCap:
      scratch.resultStats.localPops = max(scratch.resultStats.localPops, pops)
      when defined(navQueryProfile):
        scratch.resultStats.localPopsTotal += pops
      return lssCap
    let node = scratch.heap.pop()
    let record = node.item.int
    if scratch.localClosedGeneration[record] == scratch.localGeneration or
        node.cost != scratch.localCost[record]:
      continue
    scratch.localClosedGeneration[record] = scratch.localGeneration
    inc pops
    let currentCell = scratch.localCell[record]
    if currentCell == toCell:
      targetRecord = record
      break
    let
      currentPoint = index.map.cellOf(index.routePoint(currentCell))
      legal = index.legalMovesAt(currentCell.int)
    for direction, delta in NavNeighbors:
      if (legal and (1'u8 shl direction)) == 0:
        continue
      let
        nextPoint: BodyPoint = (currentPoint.x + delta.x,
          currentPoint.y + delta.y)
        nextCell = int32(nextPoint.y * index.map.gridWidth + nextPoint.x)
      if index.roomForCell(nextCell.int) != room:
        continue
      let nextRecord = scratch.localRecord(nextCell, true)
      if nextRecord < 0:
        scratch.resultStats.localPops = max(scratch.resultStats.localPops, pops)
        when defined(navQueryProfile):
          scratch.resultStats.localPopsTotal += pops
        return lssCap
      let candidate = checkedAdd(node.cost,
        scratch.edgeCost(request, currentCell, nextCell, node.physical))
      let previousParent = scratch.localParent[nextRecord].int
      if candidate < scratch.localCost[nextRecord] or
          (candidate < InfiniteCost and
           candidate == scratch.localCost[nextRecord] and
           (previousParent < 0 or
            currentCell < scratch.localCell[previousParent])):
        scratch.localCost[nextRecord] = candidate
        scratch.localParent[nextRecord] = int32(record)
        let heuristic = routeOctileQ4(nextPoint,
          index.map.cellOf(index.routePoint(toCell)))
        if not scratch.heap.pushOrDecrease(QueryHeapNode(
            priority: checkedAdd(candidate, heuristic), cost: candidate,
            physical: checkedAdd(node.physical,
              distanceQ4(index.routePoint(currentCell),
                index.routePoint(nextCell))),
            item: int32(nextRecord), tie: nextCell)):
          scratch.resultStats.localPops = max(scratch.resultStats.localPops, pops)
          when defined(navQueryProfile):
            scratch.resultStats.localPopsTotal += pops
          return lssCap
  scratch.resultStats.localPops = max(scratch.resultStats.localPops, pops)
  when defined(navQueryProfile):
    scratch.resultStats.localPopsTotal += pops
  if targetRecord < 0:
    return lssDisconnected
  cost = scratch.localCost[targetRecord]
  var record = targetRecord
  while record >= 0:
    if length >= destination.len:
      length = 0
      return lssOverflow
    destination[length] = scratch.localCell[record]
    inc length
    record = scratch.localParent[record].int
  for left in 0 ..< length div 2:
    swap(destination[left], destination[length - 1 - left])
  lssFound

proc pathCost(scratch: BodyRouteQueryScratch, request: BodyRouteRequest,
    points: openArray[int32], entryPhysicalQ4 = 0'i64,
    reversed = false): int64 =
  let index = scratch.index
  var physical = entryPhysicalQ4
  for offset in 1 ..< points.len:
    let
      source = if reversed: points.len - offset else: offset - 1
      target = if reversed: points.len - 1 - offset else: offset
      step = distanceQ4(index.routePoint(points[source]),
        index.routePoint(points[target]))
    result = checkedAdd(result,
      scratch.edgeCost(request, points[source], points[target], physical))
    physical = checkedAdd(physical, step)

proc pathPhysical(index: BodyRouteIndex, points: openArray[int32]): int64 =
  for offset in 1 ..< points.len:
    result = checkedAdd(result, distanceQ4(index.routePoint(points[offset - 1]),
      index.routePoint(points[offset])))

proc attachPoints(workspace: EndpointWorkspace,
    attach: EndpointAttach): Slice[int] =
  attach.pointStart.int .. attach.pointStart.int + attach.pointLen.int - 1

proc attachCost(scratch: BodyRouteQueryScratch, request: BodyRouteRequest,
    workspace: EndpointWorkspace, attach: EndpointAttach,
    entryPhysicalQ4 = 0'i64, reversed = false): int64 =
  scratch.pathCost(request, workspace.points.toOpenArray(
    attach.pointStart.int, attach.pointStart.int + attach.pointLen.int - 1),
    entryPhysicalQ4, reversed)

proc chainCost(scratch: BodyRouteQueryScratch, request: BodyRouteRequest,
    fromCell, side: int, entryPhysicalQ4 = 0'i64): int64 =
  let index = scratch.index
  var cursor = fromCell
  var physical = entryPhysicalQ4
  while cursor != index.portalSideAt(side).anchorCell.int:
    when defined(navQueryProfile):
      inc scratch.resultStats.chainCellReads
    let next = index.nextCellTowardSide(side, cursor)
    if next < 0 or next.int == cursor:
      return InfiniteCost
    let step = distanceQ4(index.routePoint(int32(cursor)), index.routePoint(next))
    result = checkedAdd(result,
      scratch.edgeCost(request, int32(cursor), next, physical))
    physical = checkedAdd(physical, step)
    cursor = next.int

proc chainPhysical(scratch: BodyRouteQueryScratch,
    fromCell, side: int): int64 =
  let index = scratch.index
  var cursor = fromCell
  while cursor != index.portalSideAt(side).anchorCell.int:
    when defined(navQueryProfile):
      inc scratch.resultStats.chainCellReads
    let next = index.nextCellTowardSide(side, cursor)
    if next < 0 or next.int == cursor:
      return InfiniteCost
    result = checkedAdd(result,
      distanceQ4(index.routePoint(int32(cursor)), index.routePoint(next)))
    cursor = next.int

proc buildConnections(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, workspace: EndpointWorkspace,
    start: bool): bool =
  let index = scratch.index
  var scoring = request
  if not start:
    # Goal connections are traversed side -> endpoint, and their entry ETA is
    # only known when A* reaches that side. Retain the ETA-independent part;
    # runSideSearch adds directional hazard at goal evaluation.
    scoring.hazard = nil
  for attachIndex in 0 ..< workspace.attachCount:
    let attach = workspace.attaches[attachIndex]
    let base = scratch.attachCost(scoring, workspace, attach)
    let basePhysical = index.pathPhysical(workspace.points.toOpenArray(
      attach.pointStart.int, attach.pointStart.int + attach.pointLen.int - 1))
    for roomOffset in index.roomSideRange(attach.room.int):
      let
        side = index.roomSideAt(roomOffset)
        chain = scratch.chainCost(scoring, attach.coarseCell.int, side,
          basePhysical)
        physical = checkedAdd(basePhysical,
          scratch.chainPhysical(attach.coarseCell.int, side))
      if index.graphComponentForSide(side) != attach.graph.int or
          chain == InfiniteCost:
        continue
      let total = checkedAdd(base, chain)
      if start:
        if scratch.startGeneration[side] != scratch.generation or
            total < scratch.startCost[side] or
            (total == scratch.startCost[side] and
             (physical < scratch.startPhysical[side] or
              (physical == scratch.startPhysical[side] and
               attachIndex < scratch.startAttachForSide[side].int))):
          scratch.startGeneration[side] = scratch.generation
          scratch.startCost[side] = total
          scratch.startPhysical[side] = physical
          scratch.startAttachForSide[side] = int16(attachIndex)
      else:
        if scratch.goalGeneration[side] != scratch.generation or
            total < scratch.goalCost[side] or
            (total == scratch.goalCost[side] and
             (physical < scratch.goalPhysical[side] or
              (physical == scratch.goalPhysical[side] and
               attachIndex < scratch.goalAttachForSide[side].int))):
          scratch.goalGeneration[side] = scratch.generation
          scratch.goalCost[side] = total
          scratch.goalPhysical[side] = physical
          scratch.goalAttachForSide[side] = int16(attachIndex)
  true

proc sideHeuristic(scratch: BodyRouteQueryScratch, side: int): int64 =
  let source = scratch.index.map.cellOf(scratch.index.sideAnchor(side))
  result = InfiniteCost
  for target in 0 ..< scratch.index.routeIndexStats.sides:
    if scratch.goalGeneration[target] == scratch.generation:
      result = min(result, routeOctileQ4(source,
        scratch.index.map.cellOf(scratch.index.sideAnchor(target))))
  if result == InfiniteCost:
    result = 0

proc segmentBaseCost(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, arcOffset: int): int64 =
  if scratch.arcCostGeneration[arcOffset] == scratch.arcMemoGeneration:
    return if scratch.arcCost[arcOffset] == ArcCostInfinite:
      InfiniteCost else: scratch.arcCost[arcOffset].int64
  when defined(navQueryProfile):
    inc scratch.resultStats.memoFills
  let
    arc = scratch.index.routeArcAt(arcOffset)
    metadata = scratch.index.routeSegmentAt(arc.segment.int)
  when defined(navQueryProfile):
    scratch.resultStats.memoCellReads += max(0, metadata.cellLen.int - 1)
  for offset in 1 ..< metadata.cellLen.int:
    let
      previous = scratch.index.segmentCellAt(
        arc.segment.int, offset - 1, arc.reversed)
      current = scratch.index.segmentCellAt(
        arc.segment.int, offset, arc.reversed)
    result = checkedAdd(result,
      scratch.edgeBaseCost(request, previous, current))
  if result >= ArcCostInfinite.int64:
    result = InfiniteCost
    scratch.arcCost[arcOffset] = ArcCostInfinite
  else:
    scratch.arcCost[arcOffset] = uint32(result)
  scratch.arcCostGeneration[arcOffset] = scratch.arcMemoGeneration

proc segmentHazardCost(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, arcOffset: int,
    entryPhysicalQ4: int64): int64 =
  let arc = scratch.index.routeArcAt(arcOffset)
  when defined(navQueryProfile):
    let profileStarted = getMonoTime()
  result = request.hazard.hazardSegmentCostQ4(scratch.index, arc.segment.int,
    arc.reversed, request.elapsedZoneTick, entryPhysicalQ4)
  when defined(navQueryProfile):
    inc scratch.resultStats.hazardSteps
    scratch.resultStats.hazardPricingNanoseconds +=
      profileElapsed(profileStarted)

proc segmentCost(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, arcOffset: int,
    entryPhysicalQ4: int64): int64 =
  checkedAdd(scratch.segmentBaseCost(request, arcOffset),
    scratch.segmentHazardCost(request, arcOffset, entryPhysicalQ4))

proc dangerMemoDebug*(scratch: BodyRouteQueryScratch): tuple[
    generation: uint16, capacity, filled: int] =
  result.generation = scratch.arcMemoGeneration
  result.capacity = scratch.arcCost.len
  for stamp in scratch.arcCostGeneration:
    if stamp == scratch.arcMemoGeneration:
      inc result.filled

proc reverseChainHazard(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, fromCell, side: int,
    entryPhysicalQ4: int64): int64 =
  if request.hazard == nil or request.hazard.state == bhsDark:
    return 0
  let total = scratch.chainPhysical(fromCell, side)
  if total == InfiniteCost:
    return InfiniteCost
  var
    cursor = fromCell
    prefix = 0'i64
  while cursor != scratch.index.portalSideAt(side).anchorCell.int:
    when defined(navQueryProfile):
      inc scratch.resultStats.chainCellReads
    let next = scratch.index.nextCellTowardSide(side, cursor)
    if next < 0 or next.int == cursor:
      return InfiniteCost
    let step = distanceQ4(scratch.index.routePoint(int32(cursor)),
      scratch.index.routePoint(next))
    prefix = checkedAdd(prefix, step)
    result = checkedAdd(result, scratch.hazardEdgeCost(
      request, int32(cursor), entryPhysicalQ4 + total - prefix, step))
    cursor = next.int

proc reverseAttachHazard(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, attach: EndpointAttach,
    entryPhysicalQ4: int64): int64 =
  if request.hazard == nil or request.hazard.state == bhsDark:
    return 0
  let first = attach.pointStart.int
  var physical = entryPhysicalQ4
  for offset in countdown(attach.pointLen.int - 1, 1):
    let
      source = scratch.goalAttach.points[first + offset]
      target = scratch.goalAttach.points[first + offset - 1]
      step = distanceQ4(scratch.index.routePoint(source),
        scratch.index.routePoint(target))
    result = checkedAdd(result, scratch.hazardEdgeCost(
      request, target, physical, step))
    physical = checkedAdd(physical, step)

proc goalConnectionHazard(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest, side, attachIndex: int,
    entryPhysicalQ4: int64): int64 =
  let
    attach = scratch.goalAttach.attaches[attachIndex]
    chainPhysical = scratch.chainPhysical(attach.coarseCell.int, side)
  result = scratch.reverseChainHazard(request, attach.coarseCell.int,
    side, entryPhysicalQ4)
  result = checkedAdd(result, scratch.reverseAttachHazard(request, attach,
    checkedAdd(entryPhysicalQ4, chainPhysical)))

type SideLabel = object
  valid: bool
  cost, physical: int64
  parentArc: int32
  parentLabel: uint8
  sourceAttach: int16

proc sameLabel(a, b: SideLabel): bool {.inline.} =
  a.valid == b.valid and (not a.valid or
    (a.cost == b.cost and a.physical == b.physical and
     a.parentArc == b.parentArc and a.parentLabel == b.parentLabel and
     a.sourceAttach == b.sourceAttach))

proc costLess(a, b: SideLabel): bool {.inline.} =
  a.cost < b.cost or (a.cost == b.cost and
    (a.physical < b.physical or (a.physical == b.physical and
     (a.parentArc < b.parentArc or (a.parentArc == b.parentArc and
      (a.parentLabel < b.parentLabel or (a.parentLabel == b.parentLabel and
       a.sourceAttach < b.sourceAttach)))))))

proc physicalLess(a, b: SideLabel): bool {.inline.} =
  a.physical < b.physical or (a.physical == b.physical and a.costLess(b))

proc storedLabel(scratch: BodyRouteQueryScratch, slot: int): SideLabel =
  if scratch.sideGeneration[slot] != scratch.generation:
    return
  SideLabel(valid: true, cost: scratch.sideCost[slot],
    physical: scratch.sidePhysical[slot],
    parentArc: scratch.sideParentArc[slot],
    parentLabel: scratch.sideParentLabel[slot],
    sourceAttach: scratch.sideSourceAttach[slot])

proc writeLabel(scratch: BodyRouteQueryScratch, side, label: int,
    value: SideLabel): bool =
  let slot = side * 2 + label
  let previous = scratch.storedLabel(slot)
  if value.sameLabel(previous):
    return true
  if not value.valid:
    scratch.sideGeneration[slot] = 0
    scratch.sideClosedGeneration[slot] = 0
    return true
  scratch.sideGeneration[slot] = scratch.generation
  scratch.sideClosedGeneration[slot] = 0
  scratch.sideCost[slot] = value.cost
  scratch.sidePhysical[slot] = value.physical
  scratch.sideParentArc[slot] = value.parentArc
  scratch.sideParentLabel[slot] = value.parentLabel
  scratch.sideSourceAttach[slot] = value.sourceAttach
  scratch.heap.pushOrDecrease(QueryHeapNode(
    priority: checkedAdd(value.cost, scratch.sideHeuristic(side)),
    cost: value.cost, physical: value.physical,
    item: int32(slot), tie: int32(slot)))

proc considerSideLabel(scratch: BodyRouteQueryScratch, side: int,
    candidate: SideLabel): bool =
  var choices = [scratch.storedLabel(side * 2),
    scratch.storedLabel(side * 2 + 1), candidate]
  var cheapest = -1
  for index, choice in choices:
    if choice.valid and (cheapest < 0 or choice.costLess(choices[cheapest])):
      cheapest = index
  var earliest = -1
  for index, choice in choices:
    if not choice.valid or index == cheapest or
        choice.physical >= choices[cheapest].physical:
      continue
    if earliest < 0 or choice.physicalLess(choices[earliest]):
      earliest = index
  if not scratch.writeLabel(side, 0, choices[cheapest]):
    return false
  scratch.writeLabel(side, 1,
    if earliest < 0: SideLabel() else: choices[earliest])

proc runSideSearch(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest): tuple[found, capHit: bool,
    goalSide, goalLabel, sourceAttach, goalAttach: int,
    cost, physical: int64] =
  let sideCount = scratch.index.routeIndexStats.sides
  scratch.heap.begin()
  for side in 0 ..< sideCount:
    if scratch.startGeneration[side] != scratch.generation:
      continue
    if not scratch.considerSideLabel(side, SideLabel(valid: true,
        cost: scratch.startCost[side], physical: scratch.startPhysical[side],
        parentArc: -1, sourceAttach: scratch.startAttachForSide[side])):
      return (false, true, -1, -1, -1, -1,
        InfiniteCost, InfiniteCost)
  result.cost = InfiniteCost
  result.physical = InfiniteCost
  result.goalSide = -1
  result.goalLabel = -1
  while scratch.heap.len > 0:
    if scratch.resultStats.sidePops >= RouteSidePopCap:
      result.capHit = true
      return
    let current = scratch.heap.pop()
    let
      slot = current.item.int
      side = slot div 2
      label = slot mod 2
    if scratch.sideClosedGeneration[slot] == scratch.generation or
        scratch.sideGeneration[slot] != scratch.generation or
        current.cost != scratch.sideCost[slot] or
        current.physical != scratch.sidePhysical[slot]:
      continue
    scratch.sideClosedGeneration[slot] = scratch.generation
    inc scratch.resultStats.sidePops
    if label == 1:
      inc scratch.resultStats.earliestAlternativePops
    if scratch.goalGeneration[side] == scratch.generation:
      let
        goalAttach = scratch.goalAttachForSide[side].int
        goalHazard = scratch.goalConnectionHazard(request, side, goalAttach,
          scratch.sidePhysical[slot])
        total = checkedAdd(current.cost,
          checkedAdd(scratch.goalCost[side], goalHazard))
      let totalPhysical = checkedAdd(scratch.sidePhysical[slot],
        scratch.goalPhysical[side])
      if total < result.cost or
          (total == result.cost and
           (totalPhysical < result.physical or
            (totalPhysical == result.physical and side < result.goalSide))):
        result.found = true
        result.cost = total
        result.physical = totalPhysical
        result.goalSide = side
        result.goalLabel = label
        scratch.resultStats.selectedEarliestAlternative = label == 1
        result.sourceAttach = scratch.sideSourceAttach[slot].int
        result.goalAttach = goalAttach
    if result.found and current.priority > result.cost:
      break
    for arcOffset in scratch.index.arcRangeForSide(side):
      when defined(navQueryProfile):
        inc scratch.resultStats.arcsRelaxed
      let
        arc = scratch.index.routeArcAt(arcOffset)
        next = arc.toSide.int
      let candidate = checkedAdd(current.cost,
        scratch.segmentCost(request, arcOffset,
          scratch.sidePhysical[slot]))
      let candidatePhysical = checkedAdd(scratch.sidePhysical[slot],
        scratch.index.routeSegmentAt(arc.segment.int).staticLengthQ4.int64)
      if not scratch.considerSideLabel(next, SideLabel(valid: true,
          cost: candidate, physical: candidatePhysical,
          parentArc: int32(arcOffset), parentLabel: uint8(label),
          sourceAttach: scratch.sideSourceAttach[slot])):
        result.capHit = true
        return

proc copyAttach(scratch: BodyRouteQueryScratch,
    workspace: EndpointWorkspace, attachIndex: int,
    destination: var array[RouteLocalLegCap, int32], count: var int): bool =
  let attach = workspace.attaches[attachIndex]
  for offset in workspace.attachPoints(attach):
    if count >= destination.len:
      return false
    destination[count] = workspace.points[offset]
    inc count
  true

proc tryDirectLocal(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest): tuple[state: LocalSearchState, cost: int64] =
  var
    bestStart = -1
    bestGoal = -1
    bestEstimate = InfiniteCost
  for startIndex in 0 ..< scratch.startAttach.attachCount:
    let startAttach = scratch.startAttach.attaches[startIndex]
    for goalIndex in 0 ..< scratch.goalAttach.attachCount:
      let goalAttach = scratch.goalAttach.attaches[goalIndex]
      if startAttach.room != goalAttach.room:
        continue
      let estimate = checkedAdd(
        scratch.attachCost(request, scratch.startAttach, startAttach),
        checkedAdd(routeOctileQ4(
          scratch.index.map.cellOf(scratch.index.routePoint(startAttach.coarseCell)),
          scratch.index.map.cellOf(scratch.index.routePoint(goalAttach.coarseCell))),
          scratch.attachCost(request, scratch.goalAttach, goalAttach)))
      if estimate < bestEstimate or
          (estimate == bestEstimate and
           (startIndex < bestStart or
            (startIndex == bestStart and goalIndex < bestGoal))):
        bestEstimate = estimate
        bestStart = startIndex
        bestGoal = goalIndex
  if bestStart < 0:
    return (lssDisconnected, InfiniteCost)
  let
    startAttach = scratch.startAttach.attaches[bestStart]
    goalAttach = scratch.goalAttach.attaches[bestGoal]
    startPhysical = scratch.index.pathPhysical(
      scratch.startAttach.points.toOpenArray(startAttach.pointStart.int,
        startAttach.pointStart.int + startAttach.pointLen.int - 1))
  var
    localLen = 0
    localCost = InfiniteCost
  result.state = scratch.runLocalPath(request, startAttach.coarseCell,
    goalAttach.coarseCell, scratch.tempRefs, localLen, localCost,
    startPhysical)
  if result.state != lssFound:
    result.cost = InfiniteCost
    return
  var outputLen = 0
  if not scratch.copyAttach(scratch.startAttach, bestStart,
      scratch.resultStartLeg, outputLen):
    return (lssOverflow, InfiniteCost)
  for offset in 1 ..< localLen:
    if not scratch.index.appendRef(scratch.resultStartLeg, outputLen,
        scratch.tempRefs[offset]):
      return (lssOverflow, InfiniteCost)
  for offset in countdown(goalAttach.pointLen.int - 2, 0):
    if not scratch.index.appendRef(scratch.resultStartLeg, outputLen,
        scratch.goalAttach.points[goalAttach.pointStart.int + offset]):
      return (lssOverflow, InfiniteCost)
  scratch.resultDescriptor = BodyRouteDescriptor(
    startLegLen: uint16(outputLen), exactStart: request.start,
    exactGoal: request.goal.goalPoint)
  result.cost = scratch.pathCost(request,
    scratch.resultStartLeg.toOpenArray(0, outputLen - 1))

proc appendChain(scratch: BodyRouteQueryScratch, fromCell, side: int,
    destination: var array[RouteLocalLegCap, int32], count: var int): bool =
  var cursor = fromCell
  while cursor != scratch.index.portalSideAt(side).anchorCell.int:
    let next = scratch.index.nextCellTowardSide(side, cursor)
    if next < 0 or not scratch.index.appendRef(destination, count, next):
      return false
    cursor = next.int
  true

when defined(navQueryProfile):
  proc chainStepCount(scratch: BodyRouteQueryScratch,
      fromCell, side: int): int =
    var cursor = fromCell
    while cursor != scratch.index.portalSideAt(side).anchorCell.int:
      let next = scratch.index.nextCellTowardSide(side, cursor)
      if next < 0 or next.int == cursor:
        return high(int)
      inc result
      cursor = next.int

proc assembleSideRoute(scratch: BodyRouteQueryScratch,
    search: tuple[found, capHit: bool, goalSide, goalLabel,
      sourceAttach, goalAttach: int, cost, physical: int64]): LocalSearchState =
  var reverseCount = 0
  var
    cursor = search.goalSide
    label = search.goalLabel
    slot = cursor * 2 + label
  while scratch.sideParentArc[slot] >= 0:
    if reverseCount >= RouteEdgeCap:
      when defined(navQueryProfile):
        var
          overflowCursor = cursor
          overflowLabel = label
          overflowCount = reverseCount
          overflowSlot = slot
        while scratch.sideParentArc[overflowSlot] >= 0:
          let overflowArc = scratch.index.routeArcAt(
            scratch.sideParentArc[overflowSlot].int)
          inc overflowCount
          overflowCursor = overflowArc.fromSide.int
          overflowLabel = scratch.sideParentLabel[overflowSlot].int
          overflowSlot = overflowCursor * 2 + overflowLabel
        scratch.resultStats.overflowKind = "edge_count"
        scratch.resultStats.overflowActualLength = overflowCount
      return lssOverflow
    let
      arcOffset = scratch.sideParentArc[slot].int
      parentLabel = scratch.sideParentLabel[slot].int
    let arc = scratch.index.routeArcAt(arcOffset)
    scratch.resultEdges[reverseCount] = routeEdgeRef(
      arc.segment.int, arc.reversed)
    inc reverseCount
    cursor = arc.fromSide.int
    label = parentLabel
    slot = cursor * 2 + label
  for left in 0 ..< reverseCount div 2:
    swap(scratch.resultEdges[left], scratch.resultEdges[reverseCount - 1 - left])
  var startLen = 0
  let startAttach = scratch.startAttach.attaches[search.sourceAttach]
  when defined(navQueryProfile):
    let requiredStartLen = startAttach.pointLen.int +
      scratch.chainStepCount(startAttach.coarseCell.int, cursor)
    if requiredStartLen > RouteLocalLegCap:
      scratch.resultStats.overflowKind = "start_leg"
      scratch.resultStats.overflowActualLength = requiredStartLen
      return lssOverflow
  if not scratch.copyAttach(scratch.startAttach, search.sourceAttach,
      scratch.resultStartLeg, startLen) or
      not scratch.appendChain(startAttach.coarseCell.int, cursor,
        scratch.resultStartLeg, startLen):
    return lssOverflow
  let goalAttach = scratch.goalAttach.attaches[search.goalAttach]
  when defined(navQueryProfile):
    let requiredGoalLen = goalAttach.pointLen.int +
      scratch.chainStepCount(goalAttach.coarseCell.int, search.goalSide)
    if requiredGoalLen > RouteLocalLegCap:
      scratch.resultStats.overflowKind = "goal_leg"
      scratch.resultStats.overflowActualLength = requiredGoalLen
      return lssOverflow
  var goalForwardLen = 0
  if not scratch.index.appendRef(scratch.tempRefs, goalForwardLen,
      goalAttach.coarseCell) or
      not scratch.appendChain(goalAttach.coarseCell.int, search.goalSide,
        scratch.tempRefs, goalForwardLen):
    return lssOverflow
  var goalLen = 0
  for offset in countdown(goalForwardLen - 1, 0):
    if not scratch.index.appendRef(scratch.resultGoalLeg, goalLen,
        scratch.tempRefs[offset]):
      return lssOverflow
  for offset in countdown(goalAttach.pointLen.int - 2, 0):
    if not scratch.index.appendRef(scratch.resultGoalLeg, goalLen,
        scratch.goalAttach.points[goalAttach.pointStart.int + offset]):
      return lssOverflow
  if reverseCount == 0:
    for offset in 1 ..< goalLen:
      if not scratch.index.appendRef(scratch.resultStartLeg, startLen,
          scratch.resultGoalLeg[offset]):
        return lssOverflow
    goalLen = 0
  scratch.resultDescriptor = BodyRouteDescriptor(
    edgeCount: uint16(reverseCount), startLegLen: uint16(startLen),
    goalLegLen: uint16(goalLen))
  result = lssFound

proc installStraight(scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest): int64 =
  let
    startRef = scratch.index.routeRefForPoint(request.start)
    goalRef = scratch.index.routeRefForPoint(request.goal.goalPoint)
  scratch.resultStartLeg[0] = startRef
  var count = 1
  if not scratch.index.pointsEqual(startRef, goalRef):
    scratch.resultStartLeg[1] = goalRef
    count = 2
  scratch.resultDescriptor = BodyRouteDescriptor(
    startLegLen: uint16(count), exactStart: request.start,
    exactGoal: request.goal.goalPoint)
  scratch.pathCost(request,
    scratch.resultStartLeg.toOpenArray(0, count - 1))

proc validateBodyRoute*(index: BodyRouteIndex, request: BodyRouteRequest,
    route: BodyRouteQueryResult): bool

proc queryBodyRoute*(index: BodyRouteIndex, scratch: BodyRouteQueryScratch,
    request: BodyRouteRequest): BodyRouteQueryResult =
  if scratch == nil or scratch.index != index or
      not request.goal.belongsTo(index.map):
    return BodyRouteQueryResult(failure: brfValidation)
  if not index.map.hasValidatorComponent(request.goal.goalComponent):
    return BodyRouteQueryResult(failure: brfGoalAttach)
  scratch.nextGeneration()
  scratch.resultStats = BodyRouteQueryStats()
  scratch.resultDescriptor = BodyRouteDescriptor(
    exactStart: request.start, exactGoal: request.goal.goalPoint)
  scratch.bestCost = InfiniteCost
  if not index.map.canStand(request.start):
    return BodyRouteQueryResult(failure: brfStartAttach)
  if index.map.componentOf(request.start) != request.goal.goalComponent:
    return BodyRouteQueryResult(failure: brfDisconnected)
  when defined(navQueryProfile):
    let endpointStarted = getMonoTime()
  var failure = index.collectAttachments(scratch, request.start,
    scratch.startAttach, scratch.tempRefs)
  if failure != brfNone:
    when defined(navQueryProfile):
      scratch.resultStats.endpointAttachNanoseconds +=
        profileElapsed(endpointStarted)
    return BodyRouteQueryResult(failure: failure,
      stats: scratch.resultStats)
  failure = index.collectAttachments(scratch, request.goal.goalPoint,
    scratch.goalAttach, scratch.tempRefs)
  if failure != brfNone:
    when defined(navQueryProfile):
      scratch.resultStats.endpointAttachNanoseconds +=
        profileElapsed(endpointStarted)
    return BodyRouteQueryResult(failure:
      if failure == brfStartAttach: brfGoalAttach else: failure,
      stats: scratch.resultStats)
  when defined(navQueryProfile):
    scratch.resultStats.endpointAttachNanoseconds +=
      profileElapsed(endpointStarted)
    let sameRoomStarted = getMonoTime()
  let straightClear = index.querySegmentClear(scratch, request.start,
    request.goal.goalPoint)
  if straightClear and request.danger == nil and request.blockedCell.isNone and
      (request.hazard == nil or request.hazard.state == bhsDark):
    scratch.bestCost = scratch.installStraight(request)
  else:
    let direct = scratch.tryDirectLocal(request)
    if direct.state == lssFound:
      scratch.bestCost = direct.cost
    elif direct.state == lssCap:
      inc scratch.resultStats.localCapHits
    elif direct.state == lssOverflow:
      return BodyRouteQueryResult(failure: brfDescriptorOverflow,
        stats: scratch.resultStats)
    if straightClear:
      let straightCost = scratch.edgeCost(request,
        scratch.index.routeRefForPoint(request.start),
        scratch.index.routeRefForPoint(request.goal.goalPoint), 0)
      if straightCost <= scratch.bestCost:
        scratch.bestCost = scratch.installStraight(request)
  discard scratch.buildConnections(request, scratch.startAttach, true)
  discard scratch.buildConnections(request, scratch.goalAttach, false)
  when defined(navQueryProfile):
    scratch.resultStats.sameRoomNanoseconds +=
      profileElapsed(sameRoomStarted)
    let sideGraphStarted = getMonoTime()
  let sideSearch = scratch.runSideSearch(request)
  when defined(navQueryProfile):
    scratch.resultStats.sideGraphNanoseconds +=
      profileElapsed(sideGraphStarted)
  if sideSearch.capHit:
    inc scratch.resultStats.sideCapHits
  if sideSearch.found and sideSearch.cost < scratch.bestCost:
    when defined(navQueryProfile):
      let assemblyStarted = getMonoTime()
    let assembled = scratch.assembleSideRoute(sideSearch)
    when defined(navQueryProfile):
      scratch.resultStats.descriptorAssemblyValidateNanoseconds +=
        profileElapsed(assemblyStarted)
    if assembled == lssOverflow:
      return BodyRouteQueryResult(failure: brfDescriptorOverflow,
        stats: scratch.resultStats)
    if assembled == lssCap:
      inc scratch.resultStats.localCapHits
      if scratch.bestCost == InfiniteCost:
        return BodyRouteQueryResult(failure: brfLocalCap,
          stats: scratch.resultStats)
    elif assembled == lssFound:
      scratch.resultDescriptor.exactStart = request.start
      scratch.resultDescriptor.exactGoal = request.goal.goalPoint
      scratch.bestCost = sideSearch.cost
  if scratch.bestCost == InfiniteCost:
    return BodyRouteQueryResult(failure:
      if sideSearch.capHit: brfSideCap else: brfDisconnected,
      stats: scratch.resultStats)
  result = BodyRouteQueryResult(ok: true, failure: brfNone,
    descriptor: scratch.resultDescriptor, stats: scratch.resultStats,
    owner: scratch, generation: scratch.generation)
  when defined(navQueryProfile):
    let validationStarted = getMonoTime()
  if not index.validateBodyRoute(request, result):
    result = BodyRouteQueryResult(failure: brfValidation,
      stats: scratch.resultStats)
  when defined(navQueryProfile):
    scratch.resultStats.descriptorAssemblyValidateNanoseconds +=
      profileElapsed(validationStarted)
    result.stats = scratch.resultStats

proc resultCurrent(route: BodyRouteQueryResult): bool {.inline.} =
  route.ok and route.owner != nil and
    route.generation == route.owner.generation

proc resultEdgeAt*(route: BodyRouteQueryResult, offset: int): RouteEdgeRef =
  if not route.resultCurrent or offset < 0 or
      offset >= route.descriptor.edgeCount.int:
    raise newException(IndexDefect, "route query edge is out of bounds")
  route.owner.resultEdges[offset]

proc startLegRef(route: BodyRouteQueryResult, offset: int): int32 =
  route.owner.resultStartLeg[offset]

proc goalLegRef(route: BodyRouteQueryResult, offset: int): int32 =
  route.owner.resultGoalLeg[offset]

proc startLegPoint*(route: BodyRouteQueryResult, offset: int): BodyPoint =
  if not route.resultCurrent or offset < 0 or
      offset >= route.descriptor.startLegLen.int:
    raise newException(IndexDefect, "route query start leg is out of bounds")
  route.owner.index.routePoint(route.startLegRef(offset))

proc goalLegPoint*(route: BodyRouteQueryResult, offset: int): BodyPoint =
  if not route.resultCurrent or offset < 0 or
      offset >= route.descriptor.goalLegLen.int:
    raise newException(IndexDefect, "route query goal leg is out of bounds")
  route.owner.index.routePoint(route.goalLegRef(offset))

proc usesFineAnchor*(route: BodyRouteQueryResult): bool =
  if not route.resultCurrent:
    return false
  let index = route.owner.index
  for legOffset in 0 ..< route.descriptor.startLegLen.int:
    let pointRef = route.startLegRef(legOffset)
    if pointRef < 0:
      for anchorOffset in index.fineAnchorRangeForCell(
          index.routeNavCell(pointRef).int):
        if index.fineAnchorAt(anchorOffset) == pointRef:
          return true
  for legOffset in 0 ..< route.descriptor.goalLegLen.int:
    let pointRef = route.goalLegRef(legOffset)
    if pointRef < 0:
      for anchorOffset in index.fineAnchorRangeForCell(
          index.routeNavCell(pointRef).int):
        if index.fineAnchorAt(anchorOffset) == pointRef:
          return true

proc validateBodyRoute*(index: BodyRouteIndex, request: BodyRouteRequest,
    route: BodyRouteQueryResult): bool =
  if not route.resultCurrent or route.owner.index != index or
      not request.goal.belongsTo(index.map) or
      route.descriptor.exactStart != request.start or
      route.descriptor.exactGoal != request.goal.goalPoint or
      route.descriptor.startLegLen == 0 or
      route.descriptor.edgeCount.int > RouteEdgeCap or
      route.descriptor.startLegLen.int > RouteLocalLegCap or
      route.descriptor.goalLegLen.int > RouteLocalLegCap:
    return false
  for offset in 1 ..< route.descriptor.startLegLen.int:
    if not index.querySegmentClear(route.owner,
        index.routePoint(route.startLegRef(offset - 1)),
        index.routePoint(route.startLegRef(offset))):
      return false
  for offset in 1 ..< route.descriptor.goalLegLen.int:
    if not index.querySegmentClear(route.owner,
        index.routePoint(route.goalLegRef(offset - 1)),
        index.routePoint(route.goalLegRef(offset))):
      return false
  if route.startLegPoint(0) != request.start:
    return false
  if route.descriptor.edgeCount == 0:
    return route.descriptor.goalLegLen == 0 and
      route.startLegPoint(route.descriptor.startLegLen.int - 1) ==
        request.goal.goalPoint
  let firstEdge = route.resultEdgeAt(0)
  let firstRef = index.segmentCellAt(firstEdge.routeEdgeSegment, 0,
    firstEdge.routeEdgeReversed)
  if route.startLegPoint(route.descriptor.startLegLen.int - 1) !=
      index.routePoint(firstRef):
    return false
  var lastRef = firstRef
  for edgeOffset in 0 ..< route.descriptor.edgeCount.int:
    let edge = route.resultEdgeAt(edgeOffset)
    let metadata = index.routeSegmentAt(edge.routeEdgeSegment)
    let segmentFirst = index.segmentCellAt(edge.routeEdgeSegment, 0,
      edge.routeEdgeReversed)
    if edgeOffset > 0 and index.routePoint(lastRef) !=
        index.routePoint(segmentFirst):
      return false
    for pointOffset in 1 ..< metadata.cellLen.int:
      let
        previous = index.segmentCellAt(edge.routeEdgeSegment,
          pointOffset - 1, edge.routeEdgeReversed)
        current = index.segmentCellAt(edge.routeEdgeSegment,
          pointOffset, edge.routeEdgeReversed)
      if not index.querySegmentClear(route.owner,
          index.routePoint(previous), index.routePoint(current)):
        return false
    lastRef = index.segmentCellAt(edge.routeEdgeSegment,
      metadata.cellLen.int - 1, edge.routeEdgeReversed)
  route.descriptor.goalLegLen > 0 and
    route.goalLegPoint(0) == index.routePoint(lastRef) and
    route.goalLegPoint(route.descriptor.goalLegLen.int - 1) ==
      request.goal.goalPoint

proc routeFingerprint*(route: BodyRouteQueryResult): Hash =
  if not route.resultCurrent:
    return 0
  var value = hash(route.descriptor.edgeCount) !&
    hash(route.descriptor.startLegLen) !& hash(route.descriptor.goalLegLen) !&
    hash(route.descriptor.exactStart) !& hash(route.descriptor.exactGoal)
  for offset in 0 ..< route.descriptor.edgeCount.int:
    value = value !& hash(uint16(route.resultEdgeAt(offset)))
  for offset in 0 ..< route.descriptor.startLegLen.int:
    value = value !& hash(route.startLegRef(offset))
  for offset in 0 ..< route.descriptor.goalLegLen.int:
    value = value !& hash(route.goalLegRef(offset))
  !$value

proc copyResultEdges*(scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult,
    destination: var array[RouteEdgeCap, RouteEdgeRef]): bool =
  if not route.resultCurrent or route.owner != scratch:
    return false
  for offset in 0 ..< route.descriptor.edgeCount.int:
    destination[offset] = scratch.resultEdges[offset]
  true

proc copyResultStartLeg*(scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult,
    destination: var array[RouteLocalLegCap, int32]): bool =
  if not route.resultCurrent or route.owner != scratch:
    return false
  for offset in 0 ..< route.descriptor.startLegLen.int:
    destination[offset] = scratch.resultStartLeg[offset]
  true

proc copyResultGoalLeg*(scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult,
    destination: var array[RouteLocalLegCap, int32]): bool =
  if not route.resultCurrent or route.owner != scratch:
    return false
  for offset in 0 ..< route.descriptor.goalLegLen.int:
    destination[offset] = scratch.resultGoalLeg[offset]
  true
