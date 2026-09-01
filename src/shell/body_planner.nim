## Resumable route-field Dijkstra, field minting, and weighted A*.
##
## Every potentially map-sized playing-tick operation is a state machine.
## One work unit advances one connector candidate, heap pop/expansion,
## predecessor reconstruction link, or path-reversal swap. All arrays and
## fixed heaps are allocated at the activation barrier. BodyPlanner owns the
## per-seat A* heap; BodyFieldMinter owns the separate server-wide route-field
## Dijkstra heap.

import std/[hashes, math, options]
import body_cache, body_map
import types as shellTypes

const
  PlanStepPx* = 4
  EndpointSnapPx* = 4 * NavCell
  PlanWeight = 1.0
  FollowBlockFactor = 8.0
  Sqrt2 = sqrt(2.0)
  Neighbors = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1)]

type
  PlanCostProfile* = object
    dangerWeight*: float

  BodyDangerField* = object
    values*: seq[float32]
    gridW*, gridH*: int
    maximum*: float32

  HeapNode = object
    priority, cost: float
    tie1, tie2: int
    item: int

  FixedHeap = object
    nodes: seq[HeapNode]
    positions: seq[int]
    positionGeneration: seq[uint64]
    generation: uint64
    len: int

  SearchStore = object
    hashKeys: seq[int]
    hashRecords: seq[int]
    hashGeneration: seq[uint64]
    keys: seq[int]
    closed: seq[bool]
    gScore: seq[float]
    cameFrom: seq[int]
    generation: uint64
    count: int

  ConnectorScan = object
    active, done: bool
    endpoint: BodyPoint
    baseX, baseY, ring, maxRing: int
    x, y, minX, maxX, minY, maxY: int
    bestIndex: int
    bestDistance: int64

  EndpointScan = object
    done, found: bool
    endpoint, best: BodyPoint
    ring: int
    x, y, minX, maxX, minY, maxY: int
    bestDistance: int64
    bestIndex: int

  PlanStage* = enum
    pjsIdle
    pjsStartResolve
    pjsSourceConnector
    pjsTargetConnector
    pjsAstarSearch
    pjsReconstruct
    pjsReverse
    pjsComplete
    pjsFailed

  BodyPlanJob* = object
    stage*: PlanStage
    revision*: uint64
    start*, planStart*, goal*: BodyPoint
    startSnapped*: bool
    profile*: shellTypes.CostProfile
    avoid*: Option[BodyPoint]
    endpointScan: EndpointScan
    connector: ConnectorScan
    sourceIndex, targetIndex: int
    step, latticeW, latticeH: int
    searchGeneration: uint64
    reconstructCursor: int
    reconstructSourceHandled: bool
    resultLen, reverseLeft, reverseRight: int
    workUnits*, astarExpansions*: int
    fallbackStep*: int

  BodyPlanner* = ref object
    map*: BodyMap
    heap: FixedHeap
    search: SearchStore
    resultPath*: seq[BodyPoint]
    resultLen*: int
    capacity*: int

  BodyMintStage* = enum
    mjsIdle
    mjsClear
    mjsSearch
    mjsComplete

  BodyMintJob* = object
    stage*: BodyMintStage
    routeKey*: int
    routeSlot*: int
    goal*: BodyPoint
    goalCell*: BodyPoint
    revision*: uint64
    workUnits*, expansions*: int

  BodyFieldMinter* = ref object
    map*: BodyMap
    heap: FixedHeap

proc planCostProfile*(kind: shellTypes.CostProfile): PlanCostProfile =
  case kind
  of shellTypes.cpDefault: PlanCostProfile(dangerWeight: 1.0)
  of shellTypes.cpCarrier: PlanCostProfile(dangerWeight: 2.5)
  of shellTypes.cpHunter: PlanCostProfile(dangerWeight: 0.25)

proc sample*(field: BodyDangerField, map: BodyMap, point: BodyPoint): float =
  if field.values.len != map.gridWidth * map.gridHeight:
    return 0.0
  let cell = map.cellOf(point)
  field.values[cell.y * map.gridWidth + cell.x].float

proc nodeLess(a, b: HeapNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  elif a.tie1 != b.tie1: a.tie1 < b.tie1
  else: a.tie2 < b.tie2

proc begin(heap: var FixedHeap) =
  inc heap.generation
  heap.len = 0

proc setPosition(heap: var FixedHeap, item, position: int) =
  heap.positions[item] = position
  heap.positionGeneration[item] = heap.generation

proc swapNodes(heap: var FixedHeap, a, b: int) =
  swap(heap.nodes[a], heap.nodes[b])
  heap.setPosition(heap.nodes[a].item, a)
  heap.setPosition(heap.nodes[b].item, b)

proc siftUp(heap: var FixedHeap, start: int) =
  var index = start
  while index > 0:
    let parent = (index - 1) div 2
    if not nodeLess(heap.nodes[index], heap.nodes[parent]):
      break
    heap.swapNodes(index, parent)
    index = parent

proc siftDown(heap: var FixedHeap, start: int) =
  var index = start
  while true:
    let left = index * 2 + 1
    if left >= heap.len:
      break
    let right = left + 1
    var child = left
    if right < heap.len and nodeLess(heap.nodes[right], heap.nodes[left]):
      child = right
    if not nodeLess(heap.nodes[child], heap.nodes[index]):
      break
    heap.swapNodes(index, child)
    index = child

proc pushOrDecrease(heap: var FixedHeap, node: HeapNode) =
  if node.item < 0 or node.item >= heap.positions.len:
    raise newException(BodyMapError, "planner fixed heap item is out of range")
  if heap.positionGeneration[node.item] == heap.generation:
    let position = heap.positions[node.item]
    if not nodeLess(node, heap.nodes[position]):
      return
    heap.nodes[position] = node
    heap.siftUp(position)
    return
  if heap.len >= heap.nodes.len:
    raise newException(BodyMapError, "planner fixed heap capacity exhausted")
  let position = heap.len
  inc heap.len
  heap.nodes[position] = node
  heap.setPosition(node.item, position)
  heap.siftUp(position)

proc pop(heap: var FixedHeap): HeapNode =
  if heap.len == 0:
    raise newException(IndexDefect, "pop from empty planner heap")
  result = heap.nodes[0]
  heap.positionGeneration[result.item] = 0
  dec heap.len
  if heap.len > 0:
    heap.nodes[0] = heap.nodes[heap.len]
    heap.setPosition(heap.nodes[0].item, 0)
    heap.siftDown(0)

proc nextPowerOfTwo(value: int): int =
  result = 1
  while result < value:
    result = result shl 1

proc begin(store: var SearchStore) =
  inc store.generation
  store.count = 0

proc hashSlot(store: SearchStore, key: int): int =
  let mask = store.hashKeys.len - 1
  result = int((uint64(key) * 11400714819323198485'u64) and uint64(mask))
  while store.hashGeneration[result] == store.generation and
      store.hashKeys[result] != key:
    result = (result + 1) and mask

proc findRecord(store: SearchStore, key: int): int =
  let slot = store.hashSlot(key)
  if store.hashGeneration[slot] == store.generation:
    store.hashRecords[slot]
  else:
    -1

proc ensureRecord(store: var SearchStore, key: int): int =
  let slot = store.hashSlot(key)
  if store.hashGeneration[slot] == store.generation:
    return store.hashRecords[slot]
  if store.count >= store.keys.len:
    raise newException(BodyMapError,
      "planner search exceeded its activation-time fixed workspace")
  result = store.count
  inc store.count
  store.hashGeneration[slot] = store.generation
  store.hashKeys[slot] = key
  store.hashRecords[slot] = result
  store.keys[result] = key
  store.closed[result] = false
  store.gScore[result] = Inf
  store.cameFrom[result] = -1

proc newBodyPlanner*(map: BodyMap): BodyPlanner =
  ## Activation-barrier constructor. Capacity is the complete primary
  ## PlanStepPx lattice; fallback searches use the same sparse fixed store.
  new(result)
  result.map = map
  let latticeW = (map.width - 1) div PlanStepPx + 1
  let latticeH = (map.height - 1) div PlanStepPx + 1
  result.capacity = max(map.gridWidth * map.gridHeight, latticeW * latticeH)
  let hashCapacity = nextPowerOfTwo(max(8, result.capacity * 2))
  result.heap.nodes = newSeq[HeapNode](result.capacity)
  result.heap.positions = newSeq[int](result.capacity)
  result.heap.positionGeneration = newSeq[uint64](result.capacity)
  result.search.hashKeys = newSeq[int](hashCapacity)
  result.search.hashRecords = newSeq[int](hashCapacity)
  result.search.hashGeneration = newSeq[uint64](hashCapacity)
  result.search.keys = newSeq[int](result.capacity)
  result.search.closed = newSeq[bool](result.capacity)
  result.search.gScore = newSeq[float](result.capacity)
  result.search.cameFrom = newSeq[int](result.capacity)
  result.resultPath = newSeq[BodyPoint](result.capacity + 2)

proc workspaceCapacity*(planner: BodyPlanner): int = planner.capacity

proc newBodyFieldMinter*(map: BodyMap): BodyFieldMinter =
  ## Activation-barrier constructor. The route-field Dijkstra runs on the
  ## nav-cell grid and owns one server-wide heap, never one heap per seat.
  new(result)
  result.map = map
  let cells = map.gridWidth * map.gridHeight
  result.heap.nodes = newSeq[HeapNode](cells)
  result.heap.positions = newSeq[int](cells)
  result.heap.positionGeneration = newSeq[uint64](cells)

proc distanceSquared(a, b: BodyPoint): int64 =
  let dx = int64(a.x - b.x)
  let dy = int64(a.y - b.y)
  dx * dx + dy * dy

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc segmentClear(map: BodyMap, start, goal: BodyPoint): bool =
  if not map.canStand(start):
    return false
  let dx = goal.x - start.x
  let dy = goal.y - start.y
  let nx = abs(dx)
  let ny = abs(dy)
  let stepX = cmp(dx, 0)
  let stepY = cmp(dy, 0)
  var x = start.x
  var y = start.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      if not map.canStand((x + stepX, y)) or
          not map.canStand((x, y + stepY)):
        return false
      x += stepX
      y += stepY
      inc ix
      inc iy
    elif decision < 0:
      x += stepX
      inc ix
    else:
      y += stepY
      inc iy
    if not map.canStand((x, y)):
      return false
  true

proc latticePoint(job: BodyPlanJob, index: int): BodyPoint =
  ((index mod job.latticeW) * job.step,
   (index div job.latticeW) * job.step)

proc initEndpointScan(scan: var EndpointScan, map: BodyMap,
                      endpoint: BodyPoint) =
  scan = EndpointScan(endpoint: endpoint, ring: 1,
    bestDistance: high(int64), bestIndex: high(int))
  scan.minX = max(0, endpoint.x - 1)
  scan.maxX = min(map.width - 1, endpoint.x + 1)
  scan.minY = max(0, endpoint.y - 1)
  scan.maxY = min(map.height - 1, endpoint.y + 1)
  scan.x = scan.minX
  scan.y = scan.minY

proc advanceEndpointScan(scan: var EndpointScan, map: BodyMap): bool =
  ## Returns true when one charged ring candidate was inspected. Positions
  ## inside a ring are skipped by a fixed-radius loop, never a map-sized loop.
  if scan.done:
    return false
  while not scan.done:
    let candidate: BodyPoint = (scan.x, scan.y)
    let onRing = max(abs(candidate.x - scan.endpoint.x),
                     abs(candidate.y - scan.endpoint.y)) == scan.ring
    inc scan.x
    if scan.x > scan.maxX:
      scan.x = scan.minX
      inc scan.y
    if scan.y > scan.maxY:
      inc scan.ring
      if scan.ring > EndpointSnapPx:
        scan.done = true
      else:
        scan.minX = max(0, scan.endpoint.x - scan.ring)
        scan.maxX = min(map.width - 1, scan.endpoint.x + scan.ring)
        scan.minY = max(0, scan.endpoint.y - scan.ring)
        scan.maxY = min(map.height - 1, scan.endpoint.y + scan.ring)
        scan.x = scan.minX
        scan.y = scan.minY
    if not onRing:
      continue
    let candidateDistance = distanceSquared(candidate, scan.endpoint)
    let candidateIndex = candidate.y * map.width + candidate.x
    if candidateDistance <= int64(EndpointSnapPx * EndpointSnapPx) and
        map.canStand(candidate) and
        (candidateDistance < scan.bestDistance or
         (candidateDistance == scan.bestDistance and
          candidateIndex < scan.bestIndex)):
      scan.found = true
      scan.best = candidate
      scan.bestDistance = candidateDistance
      scan.bestIndex = candidateIndex
    return true

proc initConnector(scan: var ConnectorScan, job: BodyPlanJob,
                   endpoint: BodyPoint) =
  scan = ConnectorScan(active: true, endpoint: endpoint,
    baseX: clamp(pyRound(endpoint.x.float / job.step.float), 0, job.latticeW - 1),
    baseY: clamp(pyRound(endpoint.y.float / job.step.float), 0, job.latticeH - 1),
    maxRing: max(job.latticeW, job.latticeH), bestIndex: -1,
    bestDistance: high(int64))
  scan.minX = scan.baseX
  scan.maxX = scan.baseX
  scan.minY = scan.baseY
  scan.maxY = scan.baseY
  scan.x = scan.baseX
  scan.y = scan.baseY

proc advanceConnector(scan: var ConnectorScan, planner: BodyPlanner,
                      job: BodyPlanJob): bool =
  if scan.done:
    return false
  let x = scan.x
  let y = scan.y
  if max(abs(x - scan.baseX), abs(y - scan.baseY)) == scan.ring:
    let index = y * job.latticeW + x
    let candidate = job.latticePoint(index)
    let candidateDistance = distanceSquared(candidate, scan.endpoint)
    if candidateDistance <= scan.bestDistance and
        planner.map.canStand(candidate) and
        planner.map.segmentClear(scan.endpoint, candidate) and
        (candidateDistance < scan.bestDistance or index < scan.bestIndex):
      scan.bestDistance = candidateDistance
      scan.bestIndex = index
  inc scan.x
  if scan.x > scan.maxX:
    scan.x = scan.minX
    inc scan.y
  if scan.y > scan.maxY:
    if scan.bestIndex >= 0:
      let lowerBound = max(0.0,
        (scan.ring + 1).float * job.step.float - job.step.float / 2.0)
      if scan.bestDistance.float <= lowerBound * lowerBound:
        scan.done = true
        return true
    inc scan.ring
    if scan.ring >= scan.maxRing:
      scan.done = true
      return true
    scan.minX = max(0, scan.baseX - scan.ring)
    scan.maxX = min(job.latticeW - 1, scan.baseX + scan.ring)
    scan.minY = max(0, scan.baseY - scan.ring)
    scan.maxY = min(job.latticeH - 1, scan.baseY + scan.ring)
    scan.x = scan.minX
    scan.y = scan.minY
  true

proc resolveEndpointForDifferential*(planner: BodyPlanner,
                                     endpoint: BodyPoint): Option[BodyPoint] =
  ## Diagnostic snapshot for the local stencil differential. This is the same
  ## start-endpoint resolver used by `startPlan`, drained in one call so the
  ## optional harness can compare it to the pinned lab without copying lab code.
  if planner.map.canStand(endpoint):
    return some(endpoint)
  var scan: EndpointScan
  initEndpointScan(scan, planner.map, endpoint)
  while not scan.done:
    discard scan.advanceEndpointScan(planner.map)
  if scan.found:
    some(scan.best)
  else:
    none(BodyPoint)

proc nearestConnectorForDifferential*(planner: BodyPlanner,
                                      endpoint: BodyPoint,
                                      step = PlanStepPx): Option[BodyPoint] =
  ## Diagnostic snapshot of the connector scan used before A*. The playing
  ## path still owns all budgeting; this helper only exposes the completed
  ## deterministic choice for the local gate-1 differential.
  var job = BodyPlanJob(step: step,
    latticeW: (planner.map.width - 1) div step + 1,
    latticeH: (planner.map.height - 1) div step + 1)
  var scan: ConnectorScan
  initConnector(scan, job, endpoint)
  while not scan.done:
    discard scan.advanceConnector(planner, job)
  if scan.bestIndex >= 0:
    some(job.latticePoint(scan.bestIndex))
  else:
    none(BodyPoint)

proc reverseNeighborIndex(dx, dy: int): int =
  for index, delta in Neighbors:
    if delta[0] == -dx and delta[1] == -dy:
      return index

proc initMintSearch(minter: BodyFieldMinter, cache: BodySeatCache,
                    job: var BodyMintJob) =
  let slot = job.routeSlot
  let cell = job.goalCell
  let index = cell.y * minter.map.gridWidth + cell.x
  cache.setRouteDistance(slot, index, 0.0, 0)
  minter.heap.begin()
  minter.heap.pushOrDecrease(HeapNode(priority: 0.0, cost: 0.0,
    tie1: cell.x, tie2: cell.y, item: index))
  job.stage = mjsSearch

proc advanceMintSearch(minter: BodyFieldMinter, cache: BodySeatCache,
                       job: var BodyMintJob): bool =
  ## Returns true only when a heap pop was consumed.
  if minter.heap.len == 0:
    cache.publishRouteField(job.routeSlot)
    job.stage = mjsComplete
    return false
  let current = minter.heap.pop()
  result = true
  inc job.expansions
  let currentDistance = cache.routeDistanceAt(job.routeSlot, current.item)
  if current.cost > currentDistance:
    return
  let x = current.item mod minter.map.gridWidth
  let y = current.item div minter.map.gridWidth
  for _, delta in Neighbors:
    let nx = x + delta[0]
    let ny = y + delta[1]
    let nextCell = (nx, ny)
    if not minter.map.cellWalkable(nextCell):
      continue
    if delta[0] != 0 and delta[1] != 0 and
        (not minter.map.cellWalkable((nx, y)) or
         not minter.map.cellWalkable((x, ny))):
      continue
    let nextIndex = ny * minter.map.gridWidth + nx
    let nextDistance = currentDistance +
      (if delta[0] != 0 and delta[1] != 0: Sqrt2 else: 1.0)
    if nextDistance < cache.routeDistanceAt(job.routeSlot, nextIndex):
      cache.setRouteDistance(job.routeSlot, nextIndex, nextDistance,
        uint8(1 + reverseNeighborIndex(delta[0], delta[1])))
      minter.heap.pushOrDecrease(HeapNode(priority: nextDistance,
        cost: nextDistance, tie1: nx, tie2: ny, item: nextIndex))

proc beginMint*(minter: BodyFieldMinter, cache: BodySeatCache,
                job: var BodyMintJob, goal: BodyPoint, revision: uint64) =
  let key = cache.routeKey(goal)
  if cache.routeSlotReady(key):
    job = BodyMintJob(stage: mjsComplete, routeKey: key, routeSlot: -1,
      goal: goal, goalCell: minter.map.cellOf(goal), revision: revision)
    return
  let slot = cache.beginRouteField(goal)
  job = BodyMintJob(stage: mjsClear, routeKey: key, routeSlot: slot,
    goal: goal, goalCell: minter.map.cellOf(goal), revision: revision)

proc cancelMint*(cache: BodySeatCache, job: var BodyMintJob) =
  if job.stage in {mjsClear, mjsSearch}:
    cache.cancelRouteFieldBuild(job.routeSlot)
  job.stage = mjsIdle

proc mintPending*(job: BodyMintJob): bool =
  job.stage in {mjsClear, mjsSearch}

proc mintFinished*(job: BodyMintJob): bool =
  job.stage == mjsComplete

proc stepMint*(minter: BodyFieldMinter, cache: BodySeatCache,
               job: var BodyMintJob, budget: var int): int =
  ## Spend at most budget units. This is the former route-field clear/search
  ## state machine lifted out of the plan path unchanged.
  let initial = budget
  block processing:
    while job.mintPending:
      case job.stage
      of mjsClear:
        if budget == 0: break processing
        let cleared = cache.clearRouteCell(job.routeSlot)
        dec budget
        inc job.workUnits
        if cleared:
          minter.initMintSearch(cache, job)
      of mjsSearch:
        if minter.heap.len > 0 and budget == 0: break processing
        if minter.advanceMintSearch(cache, job):
          dec budget
          inc job.workUnits
      of mjsIdle, mjsComplete:
        break processing
  initial - budget

proc mintFingerprint*(minter: BodyFieldMinter, cache: BodySeatCache,
                      job: BodyMintJob): Hash =
  var value: Hash = hash(ord(job.stage)) !& hash(job.revision) !&
    hash(job.routeKey) !& hash(job.routeSlot) !& hash(job.goal) !&
    hash(job.goalCell) !& hash(job.workUnits) !& hash(job.expansions) !&
    hash(minter.heap.len) !& cache.routeStateFingerprint
  for index in 0 ..< minter.heap.len:
    let node = minter.heap.nodes[index]
    value = value !& hash(node.priority) !& hash(node.cost) !&
      hash(node.tie1) !& hash(node.tie2) !& hash(node.item)
  !$value

proc heuristic(planner: BodyPlanner, cache: BodySeatCache,
               point, target, goal: BodyPoint): float =
  result = hypot((point.x - target.x).float, (point.y - target.y).float)
  let cached = cache.peekRouteDistance(point, goal)
  if cached.isSome:
    result = max(result, cached.get * 0.999)
  result *= PlanWeight

proc initAstarSearch(planner: BodyPlanner, cache: BodySeatCache,
                     job: var BodyPlanJob) =
  planner.search.begin()
  planner.heap.begin()
  job.searchGeneration = planner.search.generation
  let sourceRecord = planner.search.ensureRecord(job.sourceIndex)
  planner.search.gScore[sourceRecord] = 0.0
  planner.search.cameFrom[sourceRecord] = -1
  let sourcePoint = job.latticePoint(job.sourceIndex)
  let targetPoint = job.latticePoint(job.targetIndex)
  planner.heap.pushOrDecrease(HeapNode(
    priority: planner.heuristic(cache, sourcePoint, targetPoint, job.goal),
    cost: 0.0, tie1: job.sourceIndex, tie2: 0, item: sourceRecord))
  job.stage = pjsAstarSearch

proc beginSearchAtStep(planner: BodyPlanner, job: var BodyPlanJob, step: int) =
  job.step = step
  job.latticeW = (planner.map.width - 1) div step + 1
  job.latticeH = (planner.map.height - 1) div step + 1
  initConnector(job.connector, job, job.planStart)
  job.stage = pjsSourceConnector

proc startFallback(planner: BodyPlanner, job: var BodyPlanJob): bool =
  if job.step <= 1:
    return false
  let nextStep = max(1, job.step div 2)
  job.fallbackStep = nextStep
  planner.beginSearchAtStep(job, nextStep)
  true

proc advanceAstar(planner: BodyPlanner, cache: BodySeatCache,
                  danger: BodyDangerField, job: var BodyPlanJob): bool =
  ## Returns true only when a heap pop was consumed.
  if planner.heap.len == 0:
    if not planner.startFallback(job):
      job.stage = pjsFailed
    return false
  let current = planner.heap.pop()
  result = true
  inc job.astarExpansions
  let record = current.item
  if planner.search.closed[record] or
      current.cost > planner.search.gScore[record]:
    return
  planner.search.closed[record] = true
  let currentIndex = planner.search.keys[record]
  if currentIndex == job.targetIndex:
    job.reconstructCursor = currentIndex
    job.reconstructSourceHandled = false
    job.resultLen = 0
    job.stage = pjsReconstruct
    return
  let currentPoint = job.latticePoint(currentIndex)
  let targetPoint = job.latticePoint(job.targetIndex)
  for delta in Neighbors:
    let nextPoint: BodyPoint = (currentPoint.x + delta[0] * job.step,
                                currentPoint.y + delta[1] * job.step)
    if nextPoint.x < 0 or nextPoint.x >= planner.map.width or
        nextPoint.y < 0 or nextPoint.y >= planner.map.height or
        not planner.map.canStand(nextPoint) or
        not planner.map.segmentClear(currentPoint, nextPoint):
      continue
    let nextIndex = (nextPoint.y div job.step) * job.latticeW +
      nextPoint.x div job.step
    let nextRecord = planner.search.ensureRecord(nextIndex)
    if planner.search.closed[nextRecord]:
      continue
    let baseCost = job.step.float *
      (if delta[0] != 0 and delta[1] != 0: Sqrt2 else: 1.0)
    let midpoint: BodyPoint = ((currentPoint.x + nextPoint.x) div 2,
                               (currentPoint.y + nextPoint.y) div 2)
    var edgeCost = baseCost * (1.0 +
      planCostProfile(job.profile).dangerWeight * danger.sample(planner.map, midpoint))
    if job.avoid.isSome and
        planner.map.cellOf(midpoint) == planner.map.cellOf(job.avoid.get):
      edgeCost *= FollowBlockFactor
    let nextCost = current.cost + edgeCost
    if nextCost < planner.search.gScore[nextRecord]:
      planner.search.gScore[nextRecord] = nextCost
      planner.search.cameFrom[nextRecord] = currentIndex
      planner.heap.pushOrDecrease(HeapNode(
        priority: nextCost + planner.heuristic(cache, nextPoint, targetPoint, job.goal),
        cost: nextCost, tie1: nextIndex, tie2: 0, item: nextRecord))

proc advanceReconstruct(planner: BodyPlanner, job: var BodyPlanJob): bool =
  result = true
  let cursor = job.reconstructCursor
  if cursor == job.sourceIndex:
    let sourcePoint = job.latticePoint(cursor)
    if not job.reconstructSourceHandled and sourcePoint != job.planStart:
      planner.resultPath[job.resultLen] = sourcePoint
      inc job.resultLen
      job.reconstructSourceHandled = true
      if job.startSnapped:
        return
    elif job.startSnapped:
      planner.resultPath[job.resultLen] = job.planStart
      inc job.resultLen
    job.reverseLeft = 0
    job.reverseRight = job.resultLen - 1
    job.stage = pjsReverse
    return
  if job.resultLen >= planner.resultPath.len - 1:
    raise newException(BodyMapError, "planner result exceeded fixed path capacity")
  planner.resultPath[job.resultLen] = job.latticePoint(cursor)
  inc job.resultLen
  let record = planner.search.findRecord(cursor)
  if record < 0 or planner.search.cameFrom[record] < 0:
    job.stage = pjsFailed
  else:
    job.reconstructCursor = planner.search.cameFrom[record]

proc advanceReverse(planner: BodyPlanner, job: var BodyPlanJob): bool =
  if job.reverseLeft < job.reverseRight:
    swap(planner.resultPath[job.reverseLeft], planner.resultPath[job.reverseRight])
    inc job.reverseLeft
    dec job.reverseRight
    return true
  if job.resultLen == 0 or planner.resultPath[job.resultLen - 1] != job.goal:
    planner.resultPath[job.resultLen] = job.goal
    inc job.resultLen
  planner.resultLen = job.resultLen
  job.stage = pjsComplete
  false

proc beginResolvedPlan(planner: BodyPlanner, cache: BodySeatCache,
                       job: var BodyPlanJob) =
  if planner.map.componentOf(job.planStart) != planner.map.componentOf(job.goal):
    job.stage = pjsFailed
    return
  if job.planStart == job.goal:
    planner.resultPath[0] = job.goal
    planner.resultLen = 1
    job.resultLen = 1
    job.stage = pjsComplete
    return
  planner.beginSearchAtStep(job, PlanStepPx)

proc startPlan*(planner: BodyPlanner, cache: BodySeatCache,
                job: var BodyPlanJob, revision: uint64, start: BodyPoint,
                goal: ValidatedGoal, profile = shellTypes.cpDefault,
                avoid = none(BodyPoint)) =
  if not goal.belongsTo(planner.map):
    raise newException(BodyMapError, "validated goal belongs to another body map")
  let point = goal.goalPoint
  job = BodyPlanJob(stage: pjsIdle, revision: revision,
    start: start, goal: point, profile: profile, avoid: avoid, step: PlanStepPx)
  planner.resultLen = 0
  if planner.map.canStand(start):
    job.planStart = start
    job.startSnapped = false
  else:
    initEndpointScan(job.endpointScan, planner.map, start)
    job.stage = pjsStartResolve
    return
  planner.beginResolvedPlan(cache, job)

proc cancelPlan*(cache: BodySeatCache, job: var BodyPlanJob) =
  discard cache
  job.stage = pjsIdle

proc planPending*(job: BodyPlanJob): bool =
  job.stage notin {pjsIdle, pjsComplete, pjsFailed}

proc planFinished*(job: BodyPlanJob): bool =
  job.stage in {pjsComplete, pjsFailed}

proc planSucceeded*(job: BodyPlanJob): bool = job.stage == pjsComplete

proc stepPlan*(planner: BodyPlanner, cache: BodySeatCache,
               danger: BodyDangerField, job: var BodyPlanJob,
               budget: var int): int =
  ## Spend at most budget units. Constant state transitions do not consume a
  ## unit; every map-sized loop advances only through a charged arm below.
  let initial = budget
  block processing:
    while job.planPending:
      case job.stage
      of pjsStartResolve:
        if job.endpointScan.done:
          if not job.endpointScan.found:
            job.stage = pjsFailed
          else:
            job.planStart = job.endpointScan.best
            job.startSnapped = true
            planner.beginResolvedPlan(cache, job)
        else:
          if budget == 0: break processing
          discard job.endpointScan.advanceEndpointScan(planner.map)
          dec budget
          inc job.workUnits
      of pjsSourceConnector:
        if not job.connector.active:
          initConnector(job.connector, job, job.planStart)
        if job.connector.done:
          if job.connector.bestIndex < 0:
            if not planner.startFallback(job):
              job.stage = pjsFailed
          else:
            job.sourceIndex = job.connector.bestIndex
            initConnector(job.connector, job, job.goal)
            job.stage = pjsTargetConnector
        else:
          if budget == 0: break processing
          discard job.connector.advanceConnector(planner, job)
          dec budget
          inc job.workUnits
      of pjsTargetConnector:
        if job.connector.done:
          if job.connector.bestIndex < 0:
            if not planner.startFallback(job):
              job.stage = pjsFailed
          else:
            job.targetIndex = job.connector.bestIndex
            planner.initAstarSearch(cache, job)
        else:
          if budget == 0: break processing
          discard job.connector.advanceConnector(planner, job)
          dec budget
          inc job.workUnits
      of pjsAstarSearch:
        if planner.heap.len > 0 and budget == 0: break processing
        if planner.advanceAstar(cache, danger, job):
          dec budget
          inc job.workUnits
      of pjsReconstruct:
        if budget == 0: break processing
        if planner.advanceReconstruct(job):
          dec budget
          inc job.workUnits
      of pjsReverse:
        if job.reverseLeft < job.reverseRight and budget == 0:
          break processing
        if planner.advanceReverse(job):
          dec budget
          inc job.workUnits
      of pjsIdle, pjsComplete, pjsFailed:
        break processing
  initial - budget

proc pathSnapshot*(planner: BodyPlanner, job: BodyPlanJob): seq[BodyPoint] =
  if job.stage != pjsComplete:
    return
  result = newSeq[BodyPoint](planner.resultLen)
  for index in 0 ..< planner.resultLen:
    result[index] = planner.resultPath[index]

proc jobFingerprint*(planner: BodyPlanner, cache: BodySeatCache,
                     job: BodyPlanJob): Hash =
  ## Test-only deterministic suspension fingerprint, including frontier and
  ## predecessor state rather than merely counters.
  var value: Hash = hash(ord(job.stage)) !& hash(job.revision) !&
    hash(job.workUnits) !& hash(job.astarExpansions) !& hash(planner.heap.len) !&
    hash(planner.search.count) !& hash(job.planStart) !&
    hash(job.startSnapped) !& hash(job.endpointScan.done) !&
    hash(job.endpointScan.found) !& hash(job.endpointScan.ring) !&
    hash(job.endpointScan.x) !& hash(job.endpointScan.y) !&
    hash(job.endpointScan.best) !& hash(job.endpointScan.bestDistance) !&
    hash(job.endpointScan.bestIndex) !& cache.routeStateFingerprint
  for index in 0 ..< planner.heap.len:
    let node = planner.heap.nodes[index]
    value = value !& hash(node.priority) !& hash(node.cost) !&
      hash(node.tie1) !& hash(node.tie2) !& hash(node.item)
  for index in 0 ..< planner.search.count:
    value = value !& hash(planner.search.keys[index]) !&
      hash(planner.search.closed[index]) !&
      hash(planner.search.gScore[index]) !&
      hash(planner.search.cameFrom[index])
  !$value
