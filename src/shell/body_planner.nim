## Resumable route-field Dijkstra, field minting, and weighted A*.
##
## Every potentially map-sized playing-tick operation is a state machine.
## One work unit advances one connector candidate, heap pop/expansion,
## predecessor reconstruction link, or path-reversal swap. All arrays and
## fixed heaps are allocated at the activation barrier. BodyPlanner owns the
## per-seat A* heap; BodyFieldMinter owns the separate server-wide route-field
## Dijkstra heap.

import std/[hashes, math, options]
import ../ctf/sim_types as ctfTypes
import body_cache, body_hazard, body_map
import types as shellTypes

const
  PlanStepPx* = 4
  EndpointSnapPx* = 4 * NavCell
  PlanWeight = 1.0
  FollowBlockFactor = 8.0
  Sqrt2 = sqrt(2.0)
  Neighbors* = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1)]
    ## Exported so a flow-field reader can decode the parent-direction byte the
    ## minter stores (`1 + reverseNeighborIndex`) without a second copy of the
    ## table; two copies of this array is exactly how a flow field starts
    ## pointing the wrong way.

  MaxMintSeeds* = 64
    ## Fixed in-job seed buffer for an explicit multi-source mint. Bounded so a
    ## mint job allocates nothing on a playing tick, like every other workspace
    ## in this module. The zone-safe field does NOT use this path — its seed set
    ## is the whole dry board, produced by a resumable scan (bmsDryGround).

  PlanSpeedNumerator = ctfTypes.MaxSpeed * 3
  PlanSpeedDenominator = ctfTypes.MotionScale * 4
    ## Estimated-arrival speed: three quarters of top speed
    ## (MaxSpeed/MotionScale = 2.75 px/tick -> 2.0625 px/tick).
    ##
    ## THE DERATE DIRECTION IS THE WHOLE POINT. An OPTIMISTIC ETA (assuming top
    ## speed) makes ground read safer than it is — we would believe we beat the
    ## paint and route into it, which is the exact failure the hazard term
    ## exists to fix. Deratng absorbs acceleration, friction, turning, and the
    ## corridor micro's ±20px wander, so the estimate errs late.

type
  PlanCostProfile* = object
    dangerWeight*: float
    zoneWeight*: float
      ## Weight on the zone paint-arrival risk term (body_hazard.hazardRisk).
      ## Read only while a hazard field is installed; 0 everywhere else, and a
      ## profile with zoneWeight 0 reproduces the pre-hazard route byte for
      ## byte (regression gate: "zoneWeight 0 reproduces the dark route").

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
    gPixels: seq[float]
      ## Raw path LENGTH in px along the best-cost path, tracked beside the
      ## priced gScore only when the planner was activated hazard-aware.
      ## gScore is danger-priced, so it is not a distance; the arrival-time
      ## estimate needs the physical length or a danger-heavy route would read
      ## as arriving impossibly late everywhere. Empty (and untouched) on a
      ## dark activation, which is what keeps the dark path allocation- and
      ## byte-identical.
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
    nowTick*: int
      ## The tick the plan was requested on, the base of every node's
      ## estimated arrival. Negative (the activation-barrier prewarm's -1)
      ## behaves as 0; a prewarm has no match clock to price paint against.
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
    mjsSeed
      ## APPENDED, not inserted: mintFingerprint hashes `ord(job.stage)`, so
      ## renumbering a shipped stage would silently move every recorded
      ## suspension fingerprint. New stages go on the end, always.

  BodyMintSeedMode* = enum
    ## Where a mint's distance-0 sources come from. The route field has always
    ## been a flow field (the parent-direction byte); all multi-source seeding
    ## adds is a loop instead of a single push.
    bmsGoalPoint
      ## The shipped per-seat spelling: exactly the job's own goal cell, seeded
      ## with no charged work unit. Kept on its original zero-charge path so a
      ## seat mint's work-unit accounting stays byte-identical.
    bmsSeedList
      ## An explicit, bounded, PRE-SORTED seed list (see beginMintFromSet). The
      ## sort is not cosmetic: equal-distance ties in the heap break on
      ## (tie1, tie2) = (cellX, cellY), so an unsorted push order would produce
      ## a different — still valid, but different — parent field run to run.
    bmsDryGround
      ## Every nav cell whose hazard arrival is at or after `horizonTick`, found
      ## by a resumable row-major scan. This is the zone-safe field: distance =
      ## geodesic px to ground that survives the horizon, parent byte = a
      ## ready-made flow field pointing at it.

  BodyMintJob* = object
    stage*: BodyMintStage
    routeKey*: int
    routeSlot*: int
    goal*: BodyPoint
    goalCell*: BodyPoint
    revision*: uint64
    workUnits*, expansions*: int
    seedMode*: BodyMintSeedMode
    seedCursor*: int      ## bmsSeedList: next seed index; bmsDryGround: next cell
    seedCount*: int
    seedsFound*: int      ## sources actually pushed, for the oracle tests
    horizonTick*: int     ## bmsDryGround: ground must stay dry at least this long
    seeds: array[MaxMintSeeds, BodyPoint]

  BodyFieldMinter* = ref object
    map*: BodyMap
    heap: FixedHeap

proc planCostProfile*(kind: shellTypes.CostProfile): PlanCostProfile =
  ## zoneWeight mirrors dangerWeight's ladder on purpose: a carrier is the
  ## profile that most needs to survive the trip and least needs the shortest
  ## one, and a hunter is the profile that is allowed to take the aggressive
  ## line. The ratio, not the absolute value, is the tuning surface; the
  ## saturation lives in body_hazard.HazardRiskMax.
  case kind
  of shellTypes.cpDefault: PlanCostProfile(dangerWeight: 1.0, zoneWeight: 1.0)
  of shellTypes.cpCarrier: PlanCostProfile(dangerWeight: 2.5, zoneWeight: 2.5)
  of shellTypes.cpHunter: PlanCostProfile(dangerWeight: 0.25, zoneWeight: 0.25)

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
  if store.gPixels.len > 0:
    store.gPixels[result] = 0.0
  store.cameFrom[result] = -1

proc newBodyPlanner*(map: BodyMap, hazardAware = false): BodyPlanner =
  ## Activation-barrier constructor. Capacity is the complete primary
  ## PlanStepPx lattice; fallback searches use the same sparse fixed store.
  ##
  ## `hazardAware` allocates the path-length column the zone term reads. It is
  ## a whole extra lattice-sized float array per seat (~1.4 MB on the Season 2
  ## board), so a dark episode does not pay for it — and the dark A* never
  ## touches the column, which is what makes the dark route byte-identical
  ## rather than merely equal.
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
  if hazardAware:
    result.search.gPixels = newSeq[float](result.capacity)
  result.search.cameFrom = newSeq[int](result.capacity)
  result.resultPath = newSeq[BodyPoint](result.capacity + 2)

proc hazardAware*(planner: BodyPlanner): bool {.inline.} =
  planner.search.gPixels.len > 0

proc estimatedArrivalTicks*(nowTick: int, pathPixels: float): int {.inline.} =
  ## etaTicks(n) = nowTick + g(n) / movePxPerTick, all integers out.
  ## Truncation is deliberate: a step function of path length is more stable
  ## across resumed searches than a float tick would be.
  max(0, nowTick) +
    int(pathPixels * float(PlanSpeedDenominator) / float(PlanSpeedNumerator))

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

proc reverseNeighborIndex(dx, dy: int): int =
  for index, delta in Neighbors:
    if delta[0] == -dx and delta[1] == -dy:
      return index

proc pushMintSeed(minter: BodyFieldMinter, cache: BodySeatCache,
                  job: var BodyMintJob, cell: BodyPoint) {.inline.} =
  let index = cell.y * minter.map.gridWidth + cell.x
  cache.setRouteDistance(job.routeSlot, index, 0.0, 0)
  minter.heap.pushOrDecrease(HeapNode(priority: 0.0, cost: 0.0,
    tie1: cell.x, tie2: cell.y, item: index))
  inc job.seedsFound

proc initMintSearch(minter: BodyFieldMinter, cache: BodySeatCache,
                    job: var BodyMintJob) =
  minter.heap.begin()
  minter.pushMintSeed(cache, job, job.goalCell)
  job.stage = mjsSearch

proc initSeedScan(minter: BodyFieldMinter, job: var BodyMintJob) =
  minter.heap.begin()
  job.seedCursor = 0
  job.stage = mjsSeed

proc advanceSeedScan(minter: BodyFieldMinter, cache: BodySeatCache,
                     job: var BodyMintJob,
                     hazard: BodyHazardField): bool =
  ## Charges one work unit per candidate inspected, so a whole-board seed scan
  ## is a resumable state machine like every other map-sized loop here rather
  ## than a burst on one tick.
  ##
  ## Row-major order is the determinism contract for multi-source seeding: all
  ## seeds enter at priority 0 and break ties on (cellX, cellY), so a fixed
  ## scan order fixes the parent field exactly.
  case job.seedMode
  of bmsGoalPoint:
    job.stage = mjsSearch
    return false
  of bmsSeedList:
    if job.seedCursor >= job.seedCount:
      job.stage = mjsSearch
      return false
    let cell = job.seeds[job.seedCursor]
    inc job.seedCursor
    if minter.map.cellWalkable(cell):
      minter.pushMintSeed(cache, job, cell)
    return true
  of bmsDryGround:
    let cells = minter.map.gridWidth * minter.map.gridHeight
    if job.seedCursor >= cells:
      job.stage = mjsSearch
      return false
    let
      index = job.seedCursor
      cell: BodyPoint = (index mod minter.map.gridWidth,
                         index div minter.map.gridWidth)
    inc job.seedCursor
    if minter.map.cellWalkable(cell) and
        hazard.staysDryUntil(cell.x, cell.y, job.horizonTick):
      minter.pushMintSeed(cache, job, cell)
    return true

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

proc beginMintFromSet*(minter: BodyFieldMinter, cache: BodySeatCache,
                       job: var BodyMintJob, key: int,
                       seeds: openArray[BodyPoint], revision: uint64) =
  ## Multi-source mint from an explicit, bounded seed set.
  ##
  ## CALLER CONTRACT: `seeds` must already be in row-major cell order
  ## ((y, x) ascending) and deduplicated. Seeding is otherwise identical to the
  ## single-source path — the result is exactly "min over the per-source
  ## single-source fields", which is what the oracle test asserts.
  if seeds.len > MaxMintSeeds:
    raise newException(BodyMapError,
      "multi-source mint exceeds the fixed seed buffer")
  if cache.routeSlotReady(key):
    job = BodyMintJob(stage: mjsComplete, routeKey: key, routeSlot: -1,
      revision: revision, seedMode: bmsSeedList)
    return
  let anchor: BodyPoint = if seeds.len > 0: seeds[0] else: (0, 0)
  let slot = cache.beginRouteFieldKeyed(key, anchor)
  job = BodyMintJob(stage: mjsClear, routeKey: key, routeSlot: slot,
    goalCell: anchor, revision: revision, seedMode: bmsSeedList,
    seedCount: seeds.len)
  for index, seed in seeds:
    job.seeds[index] = seed

proc beginMintDryGround*(minter: BodyFieldMinter, cache: BodySeatCache,
                         job: var BodyMintJob, key, horizonTick: int,
                         revision: uint64) =
  ## The zone-safe flow field: a multi-source Dijkstra seeded from every nav
  ## cell that is still dry at `horizonTick`. The seed set is a THRESHOLD ON A
  ## STATIC ARRAY, so it only changes when the horizon crosses cell arrivals —
  ## which is why the caller buckets the horizon instead of re-minting per tick.
  if cache.routeSlotReady(key):
    job = BodyMintJob(stage: mjsComplete, routeKey: key, routeSlot: -1,
      revision: revision, seedMode: bmsDryGround, horizonTick: horizonTick)
    return
  let slot = cache.beginRouteFieldKeyed(key, (0, 0))
  job = BodyMintJob(stage: mjsClear, routeKey: key, routeSlot: slot,
    revision: revision, seedMode: bmsDryGround, horizonTick: horizonTick)

proc cancelMint*(cache: BodySeatCache, job: var BodyMintJob) =
  if job.stage in {mjsClear, mjsSearch}:
    cache.cancelRouteFieldBuild(job.routeSlot)
  job.stage = mjsIdle

proc mintFinished*(job: BodyMintJob): bool =
  job.stage == mjsComplete

proc mintPending*(job: BodyMintJob): bool =
  job.stage in {mjsClear, mjsSeed, mjsSearch}

proc stepMint*(minter: BodyFieldMinter, cache: BodySeatCache,
               job: var BodyMintJob, budget: var int,
               hazard = BodyHazardField()): int =
  ## Spend at most budget units. This is the former route-field clear/search
  ## state machine lifted out of the plan path unchanged; multi-source seeding
  ## adds one charged stage between the clear and the search, and the
  ## single-source (bmsGoalPoint) path still skips it entirely so a seat mint's
  ## work-unit accounting is byte-identical to the shipped one.
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
          if job.seedMode == bmsGoalPoint:
            minter.initMintSearch(cache, job)
          else:
            minter.initSeedScan(job)
      of mjsSeed:
        if budget == 0: break processing
        if minter.advanceSeedScan(cache, job, hazard):
          dec budget
          inc job.workUnits
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
    hash(ord(job.seedMode)) !& hash(job.seedCursor) !& hash(job.seedsFound) !&
    hash(job.horizonTick) !& hash(minter.heap.len) !&
    cache.routeStateFingerprint
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
  if planner.search.gPixels.len > 0:
    planner.search.gPixels[sourceRecord] = 0.0
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
                  danger: BodyDangerField, hazard: BodyHazardField,
                  job: var BodyPlanJob): bool =
  ## Returns true only when a heap pop was consumed.
  ##
  ## SAFE BY TIME — why pricing paint at SETTLE time is sound. This is a
  ## time-dependent shortest-path problem, and the usual objection is that
  ## Dijkstra/A* optimality fails when edge feasibility depends on arrival
  ## time. It holds here because of a monotonicity pair:
  ##
  ##   1. g(n) is non-decreasing along any path (all edge costs > 0), so the
  ##      FIRST time A* settles a node it settles it with the minimum g, hence
  ##      the EARLIEST possible arrival estimate.
  ##   2. The feasible set only ever SHRINKS with time — paint never recedes
  ##      (ctf/zone_field's own contract: "MONOTONE by construction ... arrival
  ##      ticks never produce receding paint").
  ##
  ## Together: arriving later is never better, so waiting never helps and no
  ## time-expanded graph, waiting edge, or re-expansion machinery is needed.
  ## THIS ARGUMENT DIES THE DAY PAINT RECEDES. If the zone ever gains a
  ## receding or re-openable surface, this term must be re-derived, not
  ## re-tuned.
  ##
  ## The term is a PRICE, never a prune — see body_hazard.HazardRiskMax for
  ## why a hard prune was refused.
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
  let zoneArmed = hazard.hasField and planner.search.gPixels.len > 0
  let currentPixels =
    if zoneArmed: planner.search.gPixels[record] else: 0.0
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
    let nextPixels = currentPixels + baseCost
    # The dark expression is spelled EXACTLY as it shipped, and the zone term
    # is a separate addend applied only when a hazard field is installed.
    # `x + 0.0 == x` in IEEE, but the point is not to rely on that: a dark
    # build must execute the same instruction sequence, not merely land on the
    # same number.
    var costFactor = 1.0 +
      planCostProfile(job.profile).dangerWeight * danger.sample(planner.map, midpoint)
    if zoneArmed:
      # The ETA is priced at the cell we would STAND on (nextPoint), not the
      # edge midpoint the danger term samples: arrival time is a property of
      # the node, and the paint verdict is a per-cell threshold.
      let nextCell = planner.map.cellOf(nextPoint)
      costFactor += planCostProfile(job.profile).zoneWeight *
        hazard.hazardRisk(nextCell.x, nextCell.y,
          estimatedArrivalTicks(job.nowTick, nextPixels))
    var edgeCost = baseCost * costFactor
    if job.avoid.isSome and
        planner.map.cellOf(midpoint) == planner.map.cellOf(job.avoid.get):
      edgeCost *= FollowBlockFactor
    let nextCost = current.cost + edgeCost
    if nextCost < planner.search.gScore[nextRecord]:
      planner.search.gScore[nextRecord] = nextCost
      if zoneArmed:
        planner.search.gPixels[nextRecord] = nextPixels
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
                avoid = none(BodyPoint), nowTick = 0) =
  if not goal.belongsTo(planner.map):
    raise newException(BodyMapError, "validated goal belongs to another body map")
  let point = goal.goalPoint
  job = BodyPlanJob(stage: pjsIdle, revision: revision,
    start: start, goal: point, profile: profile, nowTick: nowTick,
    avoid: avoid, step: PlanStepPx)
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
               budget: var int, hazard = BodyHazardField()): int =
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
        if planner.advanceAstar(cache, danger, hazard, job):
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
