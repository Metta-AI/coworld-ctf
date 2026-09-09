## Seat navigation coordinator: danger cadence, one shared pop-budgeted
## mixed-grid search, stable SJF admission, and atomic bounded routes.

import std/[hashes, math, options]
when defined(bodyNavBreakdown):
  import std/[monotimes, times]
import bitworld/[profile, spriteprotocol]
import ../ctf/sim_types
import body_cache, body_danger, body_hazard, body_map, body_route_index,
  body_route_query, body_safety_query
import types as shellTypes

const
  DangerCadenceK* = 32
  DangerLosFlatPx = 400
  DangerLosFarFactor = 0.6
  DangerLosRangePx = 1050
  DangerCloseFloor = 0.5
  DangerClosePx = 190
  DangerLosWeight = 1.0
  FollowCorridorPx* = 20.0
  ReplanGoalCells = 2
  PlanMovingReplanTicks = 12
  StuckTicks = 8
  FollowStuckWindowTicks = 48
  FollowBlockTtlTicks = 96
  MaxDangerSources* = 8
  FollowLookaheadK* = 6
  BodyNavigationRetainedCap* = 256'i64 * 1024 * 1024
  SequenceAllocationOverhead = 16'i64

type
  DangerWorkspace = object
    visited: seq[uint32]
    visitGeneration: uint32

  DangerCandidate* = object
    seatIndex*: int
    pos*: BodyPoint

  DangerInput* = object
    selfXy*: BodyPoint
    candidates*: seq[DangerCandidate]

  NavTargetIdentityKind* = enum
    ntiLiteral
    ntiZoneSafeGround

  NavTargetIdentity* = object
    kind*: NavTargetIdentityKind
    sourceCell*: int32

  NavRequestAnchor* = object
    goalCell*: BodyPoint
    identity*: NavTargetIdentity
    profile*: shellTypes.CostProfile
    moving*: bool

  BodyRouteLifecycle* = enum
    brlIdle
    brlPending
    brlInFlight

  BodyPendingRoute* = object
    lifecycle*: BodyRouteLifecycle
    request*: BodyRouteSearchRequest
    firstWaitTick*: int32
    replacements*: uint32

  BodyInstalledRoute* = object
    spans*: array[BodyRouteSpanCap, BodyRouteSpan]
    spanCount*, spanIndex*, stepIndex*: uint16
    revision*, dangerGeneration*: uint64
    failure*: BodyRouteFailure
    pointCount*: int32

  BodyNavigationBytes* = object
    systemOwner*, routeIndex*, safetyScratch*, mixedGraph*: int64
    seatOwners*, seatCaches*, dangerRasters*, dangerWorkspaces*: int64
    packedWeights*, sharedDangerGeometry*, trace*, allocatorOverhead*: int64
    total*: int64

  BodyNavTiming* = object
    weightRefreshNanoseconds*, requestSubmitNanoseconds*: int64
    schedulerRestartNanoseconds*, schedulerSelectNanoseconds*: int64
    requestAttachNanoseconds*, routePopNanoseconds*: int64
    routeFinishNanoseconds*, waypointNanoseconds*: int64
    routeAdvanceNanoseconds*, steeringNanoseconds*: int64
    requestSubmissions*, schedulerRestarts*, requestAdmissions*: int
    routeCompletions*, weightRefreshes*: int

  BodyNavSeat* = ref object
    index*: int
    cache*: BodySeatCache
    danger*: BodyDangerField
    dangerWorkspace: DangerWorkspace
    dangerKernel: seq[float32]
    dangerPerimeter: seq[BodyPoint]
    dangerRadius: int
    dangerRangePx: int
    selectedDangerSeats: array[MaxDangerSources, int]
    selectedDangerPoints: array[MaxDangerSources, BodyPoint]
    selectedDangerCount: int
    dangerTick*: int
    active*: bool
    desiredGoal*: Option[BodyPoint]
    desiredProfile*: shellTypes.CostProfile
    desiredMoving*: bool
    acceptedAnchor*: Option[NavRequestAnchor]
    revision*: uint64
    lastXy*: Option[BodyPoint]
    stuckTicks*: int
    blockedPenalty*: Option[tuple[pos: BodyPoint, untilTick: int]]
    lastFollowReplanTick*: Option[int]
    lastPlanTick*: int
    followReplans*: int
    followStuckEvents*: int
    lastQuerySucceeded*: bool
    lastQueryFailure*: BodyRouteFailure
    packedWeights*: seq[int16]
    dangerGeneration*: uint64
    pendingRoute*: BodyPendingRoute
    installedRoute*: BodyInstalledRoute

  DangerRebuild* = object
    tick*: int
    seat*: int
    sourceCount*: int

  BodyNavSystem* = ref object
    map*: BodyMap
    seats*: seq[BodyNavSeat]
    routeIndex*: BodyRouteIndex
    safetyScratch*: BodySafetyScratch
    hazard: BodyHazardOverlay
    dangerK*: int
    dangerTrace: seq[DangerRebuild]
    dangerTraceLen: int
    mixedGraph*: BodyMixedGraph
    routeWorkspace*: BodyRouteWorkspace
    routeJob*: BodyRouteSearchJob
    routeJobSeat*: int
    routePopsLastTick*: int
    navigationBytes*: BodyNavigationBytes
    when defined(bodyNavBreakdown):
      timing*: BodyNavTiming

when defined(bodyNavBreakdown):
  proc timingElapsed(started: MonoTime): int64 {.inline.} =
    (getMonoTime() - started).inNanoseconds

  proc resetBodyNavTiming*(system: BodyNavSystem) {.inline.} =
    system.timing = BodyNavTiming()

proc retainedNavigationBytes*(system: BodyNavSystem): BodyNavigationBytes =
  if system == nil:
    return
  result.systemOwner = int64(sizeof(system[]))
  if system.routeIndex != nil:
    result.routeIndex = system.routeIndex.retainedIndexBytes
  if system.safetyScratch != nil:
    result.safetyScratch = system.safetyScratch.retainedBytes
  if system.mixedGraph != nil and system.routeWorkspace != nil:
    let graphBytes = system.mixedGraph.bodyMixedGraphBytes(
      system.routeWorkspace)
    result.mixedGraph = int64(sizeof(system.mixedGraph[]) +
      sizeof(system.routeWorkspace[])) + graphBytes.total -
      graphBytes.allocatorOverhead
    result.allocatorOverhead += graphBytes.allocatorOverhead
  result.trace = int64(system.dangerTrace.len * sizeof(DangerRebuild))
  result.seatOwners = int64(system.seats.len * sizeof(BodyNavSeat))
  if system.seats.len > 0:
    result.allocatorOverhead += SequenceAllocationOverhead
  if system.dangerTrace.len > 0:
    result.allocatorOverhead += SequenceAllocationOverhead
  for seat in system.seats:
    result.seatOwners += int64(sizeof(seat[]))
    if seat.cache != nil:
      result.seatCaches += int64(sizeof(seat.cache[]))
    result.dangerRasters += int64(seat.danger.values.len * sizeof(float32))
    result.dangerWorkspaces += int64(
      seat.dangerWorkspace.visited.len * sizeof(uint32))
    result.packedWeights += int64(seat.packedWeights.len * sizeof(int16))
    for length in [seat.danger.values.len,
        seat.dangerWorkspace.visited.len, seat.packedWeights.len]:
      if length > 0:
        result.allocatorOverhead += SequenceAllocationOverhead
  if system.seats.len > 0:
    result.sharedDangerGeometry = int64(
      system.seats[0].dangerKernel.len * sizeof(float32) +
      system.seats[0].dangerPerimeter.len * sizeof(BodyPoint))
    for length in [system.seats[0].dangerKernel.len,
        system.seats[0].dangerPerimeter.len]:
      if length > 0:
        result.allocatorOverhead += SequenceAllocationOverhead
  result.total = result.systemOwner + result.routeIndex +
    result.safetyScratch + result.mixedGraph + result.seatOwners +
    result.seatCaches + result.dangerRasters + result.dangerWorkspaces +
    result.packedWeights + result.sharedDangerGeometry + result.trace +
    result.allocatorOverhead

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc attenuation(distancePx: float, liveGunRangePx: int): float32 =
  if distancePx > min(DangerLosRangePx, liveGunRangePx).float:
    return 0'f32
  if distancePx <= DangerLosFlatPx.float:
    return 1'f32
  let fraction = (distancePx - DangerLosFlatPx.float) /
    (DangerLosRangePx - DangerLosFlatPx).float
  (1.0 - fraction * (1.0 - DangerLosFarFactor)).float32

proc initDanger(map: BodyMap): tuple[field: BodyDangerField,
                                     workspace: DangerWorkspace] =
  let size = map.gridWidth * map.gridHeight
  result.field = BodyDangerField(values: newSeq[float32](size),
    gridW: map.gridWidth, gridH: map.gridHeight)
  result.workspace.visited = newSeq[uint32](size)

proc initDangerGeometry(liveGunRangePx: int): tuple[kernel: seq[float32],
                                 perimeter: seq[BodyPoint], radius: int] =
  ## Immutable ray geometry shared by all seats; activation-time allocation.
  result.radius = max(1, (liveGunRangePx + NavCell - 1) div NavCell)
  let diameter = result.radius * 2 + 1
  result.kernel = newSeq[float32](diameter * diameter)
  for dy in -result.radius .. result.radius:
    for dx in -result.radius .. result.radius:
      result.kernel[(dy + result.radius) * diameter + dx + result.radius] =
        attenuation(hypot(dx.float, dy.float) * NavCell.float, liveGunRangePx)
  var included = newSeq[bool](diameter * diameter)
  template includeOffset(dx, dy: int) =
    let index = (dy + result.radius) * diameter + dx + result.radius
    if not included[index]:
      included[index] = true
      result.perimeter.add((dx, dy))
  let radiusSquared = result.radius * result.radius
  for dx in -result.radius .. result.radius:
    let dy = pyRound(sqrt(max(0, radiusSquared - dx * dx).float))
    includeOffset(dx, dy)
    includeOffset(dx, -dy)
  for dy in -result.radius .. result.radius:
    let dx = pyRound(sqrt(max(0, radiusSquared - dy * dy).float))
    includeOffset(dx, dy)
    includeOffset(-dx, dy)

proc newBodyNavSystem*(map: BodyMap, seatCount, liveGunRangePx: int,
                       dangerK = DangerCadenceK,
                       traceCapacity = 0,
                       prepareRouteQueries = true,
                       preparedRouteIndex: BodyRouteIndex = nil): BodyNavSystem =
  ## Activation-barrier constructor. The hierarchical query index is built
  ## only for an episode that can issue those queries; direct-input and legacy
  ## body ticks must not pay for an unused route path.
  if seatCount <= 0 or seatCount > MaxPlayers:
    raise newException(ValueError, "body navigation seat count is out of range")
  if dangerK <= 0:
    raise newException(ValueError, "danger cadence must be positive")
  if liveGunRangePx <= 0:
    raise newException(ValueError, "live gun range must be positive")
  if traceCapacity < 0:
    raise newException(ValueError, "trace capacity must not be negative")
  new(result)
  result.map = map
  if prepareRouteQueries:
    if preparedRouteIndex != nil and preparedRouteIndex.map != map:
      raise newException(ValueError,
        "prepared route index belongs to another body map")
    result.routeIndex = if preparedRouteIndex == nil:
      newBodyRouteIndex(map) else: preparedRouteIndex
    result.safetyScratch = newBodySafetyScratch(result.routeIndex)
    result.mixedGraph = newBodyMixedGraph(map)
    result.routeWorkspace = newBodyRouteWorkspace(result.mixedGraph)
    result.routeJobSeat = -1
    discard result.routeIndex.releaseFollowingPayload()
  result.dangerK = dangerK
  result.dangerTrace = newSeq[DangerRebuild](traceCapacity)
  result.seats = newSeq[BodyNavSeat](seatCount)
  let dangerGeometry = initDangerGeometry(liveGunRangePx)
  for index in 0 ..< seatCount:
    let cache = newBodySeatCache(map)
    let danger = initDanger(map)
    result.seats[index] = BodyNavSeat(index: index, cache: cache,
      danger: danger.field,
      dangerWorkspace: danger.workspace, dangerTick: 0, active: true,
      dangerKernel: dangerGeometry.kernel,
      dangerPerimeter: dangerGeometry.perimeter,
      dangerRadius: dangerGeometry.radius,
      dangerRangePx: liveGunRangePx,
      desiredProfile: shellTypes.cpDefault)
    if prepareRouteQueries:
      result.seats[index].dangerGeneration = 1
      result.mixedGraph.rebuildPackedWeights(
        result.seats[index].danger, result.seats[index].packedWeights)
  result.navigationBytes = result.retainedNavigationBytes()
  if prepareRouteQueries and
      result.navigationBytes.total > BodyNavigationRetainedCap:
    raise newException(BodyMapError,
      "body navigation map '" & map.name & "' retains " &
      $result.navigationBytes.total & " bytes, above cap " &
      $BodyNavigationRetainedCap)

proc seatCount*(system: BodyNavSystem): int = system.seats.len

proc liveWeaponRangePx*(system: BodyNavSystem, seatIndex: int): int =
  ## The live gun range captured at activation. Body weapon scoring uses the
  ## same range as the episode danger fields instead of a hard-coded constant.
  if system == nil or seatIndex < 0 or seatIndex >= system.seats.len:
    raise newException(ValueError, "body navigation seat index is out of range")
  system.seats[seatIndex].dangerRangePx

proc recordDanger(system: BodyNavSystem, value: DangerRebuild) {.inline.} =
  if system.dangerTraceLen < system.dangerTrace.len:
    system.dangerTrace[system.dangerTraceLen] = value
    inc system.dangerTraceLen

proc dangerTraceSnapshot*(system: BodyNavSystem): seq[DangerRebuild] =
  result = newSeq[DangerRebuild](system.dangerTraceLen)
  for index in 0 ..< system.dangerTraceLen:
    result[index] = system.dangerTrace[index]

proc setSeatActive*(system: BodyNavSystem, seat: int, active: bool) =
  system.seats[seat].active = active

proc resetNavigationLife*(system: BodyNavSystem, seatIndex: int) =
  if system == nil or seatIndex < 0 or seatIndex >= system.seats.len:
    raise newException(ValueError, "body navigation seat index is out of range")
  let seat = system.seats[seatIndex]
  doAssert seat.active,
    "navigation life must be cleared before the seat becomes inactive"

  seat.acceptedAnchor = none(NavRequestAnchor)
  seat.desiredGoal = none(BodyPoint)
  seat.revision = 0
  seat.lastXy = none(BodyPoint)
  seat.stuckTicks = 0
  seat.blockedPenalty = none(tuple[pos: BodyPoint, untilTick: int])
  seat.lastPlanTick = 0
  seat.lastFollowReplanTick = none(int)
  seat.followReplans = 0
  seat.followStuckEvents = 0
  seat.desiredProfile = shellTypes.cpDefault
  seat.desiredMoving = false
  seat.lastQuerySucceeded = false
  seat.lastQueryFailure = brfNone
  seat.pendingRoute = BodyPendingRoute()
  seat.installedRoute = BodyInstalledRoute()
  if system.routeJobSeat == seatIndex:
    system.routeJob = BodyRouteSearchJob()
    system.routeJobSeat = -1

proc nextVisitGeneration(seat: BodyNavSeat) =
  if seat.dangerWorkspace.visitGeneration == high(uint32):
    for value in seat.dangerWorkspace.visited.mitems:
      value = 0
    seat.dangerWorkspace.visitGeneration = 1
  else:
    inc seat.dangerWorkspace.visitGeneration

proc addVisibleCell(seat: BodyNavSeat, origin: BodyPoint,
                    kernel: openArray[float32], kernelRadius,
                    gx, gy: int) {.inline.} =
  if gx < 0 or gx >= seat.danger.gridW or
      gy < 0 or gy >= seat.danger.gridH:
    return
  let index = gy * seat.danger.gridW + gx
  if seat.dangerWorkspace.visited[index] ==
      seat.dangerWorkspace.visitGeneration:
    return
  seat.dangerWorkspace.visited[index] =
    seat.dangerWorkspace.visitGeneration
  let diameter = kernelRadius * 2 + 1
  let kernelX = gx - origin.x + kernelRadius
  let kernelY = gy - origin.y + kernelRadius
  seat.danger.values[index] += kernel[kernelY * diameter + kernelX]

proc sightCellBlocked(map: BodyMap, x, y: int): bool {.inline.} =
  if x < 0 or x >= map.gridWidth or y < 0 or y >= map.gridHeight:
    return true
  map.isWall(cellCenter((x, y)))

proc castRay(seat: BodyNavSeat, map: BodyMap, origin: BodyPoint,
             kernel: openArray[float32], kernelRadius,
             targetX, targetY: int) =
  let dx = targetX - origin.x
  let dy = targetY - origin.y
  let nx = abs(dx)
  let ny = abs(dy)
  let stepX = cmp(dx, 0)
  let stepY = cmp(dy, 0)
  var x = origin.x
  var y = origin.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      let sideX = x + stepX
      let sideY = y + stepY
      if map.sightCellBlocked(sideX, y) or map.sightCellBlocked(x, sideY):
        break
      seat.addVisibleCell(origin, kernel, kernelRadius, sideX, y)
      seat.addVisibleCell(origin, kernel, kernelRadius, x, sideY)
      x = sideX
      y = sideY
      inc ix
      inc iy
    elif decision < 0:
      x += stepX
      inc ix
    else:
      y += stepY
      inc iy
    if map.sightCellBlocked(x, y):
      break
    seat.addVisibleCell(origin, kernel, kernelRadius, x, y)

proc rebuildDangerFromPoints(seat: BodyNavSeat, map: BodyMap,
                             sources: openArray[BodyPoint], tick: int) =
  ## Stencil's complete from-scratch LOS field. This scheduled rebuild is not
  ## part of the cold-plan counter; K bounds its server-wide tick burst.
  for value in seat.danger.values.mitems:
    value = 0
  for source in sources:
    let origin = map.cellOf(source)
    seat.nextVisitGeneration()
    seat.addVisibleCell(origin, seat.dangerKernel, seat.dangerRadius,
      origin.x, origin.y)
    for offset in seat.dangerPerimeter:
      seat.castRay(map, origin, seat.dangerKernel, seat.dangerRadius,
        origin.x + offset.x, origin.y + offset.y)
    let closeRange = min(DangerClosePx, seat.dangerRangePx)
    let closeCells = (closeRange + NavCell - 1) div NavCell
    let closeSquared = closeRange * closeRange
    for gy in max(0, origin.y - closeCells) ..
        min(map.gridHeight - 1, origin.y + closeCells):
      for gx in max(0, origin.x - closeCells) ..
          min(map.gridWidth - 1, origin.x + closeCells):
        let center = cellCenter((gx, gy))
        let dx = center.x - source.x
        let dy = center.y - source.y
        if dx * dx + dy * dy <= closeSquared:
          seat.danger.values[gy * map.gridWidth + gx] +=
            DangerCloseFloor.float32
  seat.danger.maximum = 0
  for value in seat.danger.values.mitems:
    if DangerLosWeight != 1.0:
      value *= DangerLosWeight.float32
    seat.danger.maximum = max(seat.danger.maximum, value)
  seat.dangerTick = tick

proc publishDangerGeneration(system: BodyNavSystem; seat: BodyNavSeat) =
  ## Publish only after the complete float raster and exact packed Q8 view are
  ## ready. A search can therefore compare one monotonic generation before it
  ## spends another pop.
  if system.mixedGraph == nil:
    return
  when defined(bodyNavBreakdown):
    let started = getMonoTime()
  system.mixedGraph.rebuildPackedWeights(seat.danger, seat.packedWeights)
  when defined(bodyNavBreakdown):
    system.timing.weightRefreshNanoseconds += timingElapsed(started)
    inc system.timing.weightRefreshes
  inc seat.dangerGeneration
  if seat.dangerGeneration == 0:
    seat.dangerGeneration = 1
  if seat.installedRoute.revision != 0 and
      seat.installedRoute.dangerGeneration != seat.dangerGeneration:
    seat.installedRoute = BodyInstalledRoute()

proc dangerCandidateLess(aDistance: int64, aSeat: int,
                         bDistance: int64, bSeat: int): bool {.inline.} =
  aDistance < bDistance or (aDistance == bDistance and aSeat < bSeat)

proc selectNearestSources*[N: static int](anchor: BodyPoint;
    candidates: openArray[DangerCandidate]; selectedSeats: var array[N, int];
    selectedPoints: var array[N, BodyPoint]): int =
  ## Fixed-size distance/seat ordering shared by danger and fresh cover queries.
  ## Each caller supplies its own filtered current inputs and output storage.
  var distances: array[N, int64]
  for candidate in candidates:
    let dx = int64(candidate.pos.x - anchor.x)
    let dy = int64(candidate.pos.y - anchor.y)
    let distance = dx * dx + dy * dy
    var insertion = result
    while insertion > 0 and dangerCandidateLess(distance,
        candidate.seatIndex, distances[insertion - 1],
        selectedSeats[insertion - 1]):
      dec insertion
    if insertion >= N:
      continue
    let newCount = min(N, result + 1)
    var cursor = newCount - 1
    while cursor > insertion:
      distances[cursor] = distances[cursor - 1]
      selectedSeats[cursor] = selectedSeats[cursor - 1]
      selectedPoints[cursor] = selectedPoints[cursor - 1]
      dec cursor
    distances[insertion] = distance
    selectedSeats[insertion] = candidate.seatIndex
    selectedPoints[insertion] = candidate.pos
    result = newCount

proc selectDangerSources(seat: BodyNavSeat, input: DangerInput) =
  # The caller already applied fog, team, noShoot, protect and liveness filters.
  seat.selectedDangerCount = selectNearestSources(input.selfXy,
    input.candidates, seat.selectedDangerSeats, seat.selectedDangerPoints)

proc rebuildDanger*(seat: BodyNavSeat, map: BodyMap,
                    input: DangerInput, tick: int) =
  seat.selectDangerSources(input)
  if seat.selectedDangerCount == 0:
    seat.rebuildDangerFromPoints(map, [], tick)
  else:
    seat.rebuildDangerFromPoints(map,
      seat.selectedDangerPoints.toOpenArray(0, seat.selectedDangerCount - 1), tick)

proc selectedDangerSourceSeats*(seat: BodyNavSeat): seq[int] =
  ## Diagnostic snapshot; never used by the playing-tick path.
  result = newSeq[int](seat.selectedDangerCount)
  for index in 0 ..< seat.selectedDangerCount:
    result[index] = seat.selectedDangerSeats[index]

proc selectedDangerSources*(seat: BodyNavSeat): seq[DangerCandidate] =
  ## Diagnostic snapshot used by the cap-boundary golden.
  result = newSeq[DangerCandidate](seat.selectedDangerCount)
  for index in 0 ..< seat.selectedDangerCount:
    result[index] = DangerCandidate(seatIndex: seat.selectedDangerSeats[index],
      pos: seat.selectedDangerPoints[index])

proc initializeDanger*(system: BodyNavSystem,
                       sourcesBySeat: openArray[DangerInput],
                       activationTick = 0) =
  if sourcesBySeat.len != system.seats.len:
    raise newException(ValueError, "danger source rows must match seat count")
  for index, seat in system.seats:
    seat.rebuildDanger(system.map, sourcesBySeat[index], activationTick)
    system.publishDangerGeneration(seat)

proc dangerSeatDue*(tick, seat, cadenceK: int): bool =
  cadenceK > 0 and floorMod(tick, cadenceK) == floorMod(seat, cadenceK)

proc rebuildScheduledDanger*(system: BodyNavSystem, tick: int,
    sourcesBySeat: openArray[DangerInput],
    evaluationOrder: openArray[int] = []) =
  when ProfileTracePath.len > 0:
    measurePush("rebuildScheduledDanger")
    defer: measurePop()
  ## evaluationOrder is deliberately irrelevant: schedule and mutation are by
  ## stable seat index. It exists so permutation goldens exercise that law.
  discard evaluationOrder
  if sourcesBySeat.len != system.seats.len:
    raise newException(ValueError, "danger source rows must match seat count")
  for index, seat in system.seats:
    if seat.active and dangerSeatDue(tick, index, system.dangerK):
      seat.rebuildDanger(system.map, sourcesBySeat[index], tick)
      system.publishDangerGeneration(seat)
      system.recordDanger(DangerRebuild(tick: tick, seat: index,
        sourceCount: seat.selectedDangerCount))

proc dangerSnapshot*(seat: BodyNavSeat): seq[float32] =
  result = newSeq[float32](seat.danger.values.len)
  for index, value in seat.danger.values:
    result[index] = value

proc dangerFingerprint*(seat: BodyNavSeat): Hash =
  var value: Hash = hash(seat.dangerTick)
  for sample in seat.danger.values:
    value = value !& hash(sample)
  !$value

proc distance(a, b: BodyPoint): float =
  hypot((a.x - b.x).float, (a.y - b.y).float)

proc noteProgress*(seat: BodyNavSeat, selfXy: BodyPoint) =
  if seat.lastXy.isSome and distance(selfXy, seat.lastXy.get) < 1.0:
    inc seat.stuckTicks
  else:
    seat.stuckTicks = 0
  seat.lastXy = some(selfXy)

proc resetProgress*(seat: BodyNavSeat, selfXy: BodyPoint) =
  seat.stuckTicks = 0
  seat.lastXy = some(selfXy)

proc shouldQueryRoute*(seat: BodyNavSeat; anchor: NavRequestAnchor;
                       tick: int): bool =
  if seat == nil:
    raise newException(ValueError, "body navigation seat is nil")
  if seat.acceptedAnchor.isNone:
    return true
  let accepted = seat.acceptedAnchor.get
  if anchor.identity.kind != accepted.identity.kind:
    return true
  if anchor.identity.kind == ntiZoneSafeGround and
      anchor.identity.sourceCell != accepted.identity.sourceCell:
    return true
  if abs(anchor.goalCell.x - accepted.goalCell.x) > ReplanGoalCells or
      abs(anchor.goalCell.y - accepted.goalCell.y) > ReplanGoalCells:
    return true
  if anchor.profile != accepted.profile:
    return true
  if seat.pendingRoute.lifecycle != brlIdle:
    return false
  if seat.installedRoute.revision == 0 or
      seat.installedRoute.spanIndex >= seat.installedRoute.spanCount:
    return true
  if seat.stuckTicks >= StuckTicks:
    return true
  anchor.moving and tick - seat.lastPlanTick >= PlanMovingReplanTicks

proc acceptRequestAnchor*(seat: BodyNavSeat; anchor: NavRequestAnchor;
                          tick: int) =
  if seat == nil:
    raise newException(ValueError, "body navigation seat is nil")
  seat.acceptedAnchor = some(anchor)
  seat.desiredMoving = anchor.moving
  seat.lastPlanTick = tick

proc installedPointAt(seat: BodyNavSeat; spanIndex, stepIndex: int): BodyPoint =
  let span = seat.installedRoute.spans[spanIndex]
  (x: span.start.x + span.deltaX.int * stepIndex,
    y: span.start.y + span.deltaY.int * stepIndex)

proc normalizeInstalledCursor(seat: BodyNavSeat) =
  while seat.installedRoute.spanIndex < seat.installedRoute.spanCount:
    let span = seat.installedRoute.spans[seat.installedRoute.spanIndex]
    if seat.installedRoute.stepIndex <= span.steps:
      return
    inc seat.installedRoute.spanIndex
    seat.installedRoute.stepIndex = 1

proc advanceInstalledCursor(seat: BodyNavSeat) =
  inc seat.installedRoute.stepIndex
  seat.normalizeInstalledCursor()

proc installedLookaheadPoint(seat: BodyNavSeat; offset: int): Option[BodyPoint] =
  var
    spanIndex = seat.installedRoute.spanIndex.int
    stepIndex = seat.installedRoute.stepIndex.int
    remaining = offset
  while spanIndex < seat.installedRoute.spanCount.int:
    let span = seat.installedRoute.spans[spanIndex]
    if stepIndex <= span.steps.int:
      if remaining == 0:
        return some(seat.installedPointAt(spanIndex, stepIndex))
      dec remaining
      inc stepIndex
    else:
      inc spanIndex
      stepIndex = 1
  none(BodyPoint)

proc mixedRouteWaypoint(seat: BodyNavSeat; map: BodyMap;
    selfPos: BodyPoint): Option[BodyPoint] =
  if seat.installedRoute.revision == 0:
    return none(BodyPoint)
  seat.normalizeInstalledCursor()
  while seat.installedRoute.spanIndex < seat.installedRoute.spanCount:
    var best = none(BodyPoint)
    var bestOffset = 0
    for offset in countdown(FollowLookaheadK, 0):
      let candidate = seat.installedLookaheadPoint(offset)
      if candidate.isSome and map.segmentClear(selfPos, candidate.get):
        best = candidate
        bestOffset = offset
        break
    if best.isNone:
      return seat.installedLookaheadPoint(0)
    for _ in 0 ..< bestOffset:
      seat.advanceInstalledCursor()
    if distance(selfPos, best.get) >= 1.0:
      return best
    seat.advanceInstalledCursor()
  none(BodyPoint)

proc routeAdvancing*(seat: BodyNavSeat; selfPos: BodyPoint;
    arriveRadius: float): bool =
  if seat == nil:
    return false
  if seat.installedRoute.revision != 0:
    return seat.installedRoute.spanIndex < seat.installedRoute.spanCount and
      distance(selfPos, seat.installedLookaheadPoint(0).get(selfPos)) >
        arriveRadius
  false

proc installMixedRoute(seat: BodyNavSeat; route: BodyRouteBuild;
    request: BodyRouteSearchRequest): bool =
  ## Revision is the publication marker. Copy only the live bounded spans,
  ## then publish the new revision last; clearing/copying the full 4096-span
  ## backing object would make every short route pay for unused capacity.
  if not route.ok or route.spanCount.int > BodyRouteSpanCap:
    return false
  seat.installedRoute.revision = 0
  for offset in 0 ..< route.spanCount.int:
    seat.installedRoute.spans[offset] = route.spans[offset]
  seat.installedRoute.spanCount = route.spanCount
  seat.installedRoute.spanIndex = 0
  seat.installedRoute.stepIndex = 0
  seat.installedRoute.dangerGeneration = request.dangerGeneration
  seat.installedRoute.failure = route.failure
  seat.installedRoute.pointCount = route.pointCount
  seat.installedRoute.revision = request.requestGeneration
  true

proc installedRoutePoints*(seat: BodyNavSeat): seq[BodyPoint] =
  ## Diagnostic snapshot for corpus/qualification gates; never used by play.
  if seat == nil or seat.installedRoute.revision == 0:
    return
  for spanOffset in 0 ..< seat.installedRoute.spanCount.int:
    let span = seat.installedRoute.spans[spanOffset]
    let firstStep = if spanOffset == 0: 0 else: 1
    for step in firstStep .. span.steps.int:
      result.add (x: span.start.x + span.deltaX.int * step,
        y: span.start.y + span.deltaY.int * step)

proc installedRouteFingerprint*(seat: BodyNavSeat): Hash =
  var value: Hash
  for point in seat.installedRoutePoints:
    value = value !& hash(point)
  !$value

proc submitMixedRoute(system: BodyNavSystem; seat: BodyNavSeat;
    selfPos: BodyPoint; goal: BodyPoint; profile: shellTypes.CostProfile;
    elapsedZoneTick, tick: int) =
  let replacing = seat.pendingRoute.lifecycle != brlIdle
  let blockedCell = if seat.blockedPenalty.isSome:
      let cell = system.map.cellOf(seat.blockedPenalty.get.pos)
      int32(cell.y * system.map.gridWidth + cell.x)
    else:
      -1'i32
  seat.pendingRoute.request = BodyRouteSearchRequest(start: selfPos,
    goal: goal, profile: profile, blockedCell: blockedCell,
    elapsedZoneTick: int32(elapsedZoneTick),
    requestGeneration: seat.revision,
    dangerGeneration: seat.dangerGeneration)
  seat.pendingRoute.lifecycle = brlPending
  if replacing:
    inc seat.pendingRoute.replacements
  else:
    seat.pendingRoute.firstWaitTick = int32(tick)

proc estimatedRoutePops(request: BodyRouteSearchRequest): int64 {.inline.} =
  let
    dx = abs(request.start.x - request.goal.x) div BodyFineStepPx
    dy = abs(request.start.y - request.goal.y) div BodyFineStepPx
  int64(max(dx, dy))

proc nextPendingSeat(system: BodyNavSystem): int =
  result = -1
  var bestEstimate = high(int64)
  var bestTick = high(int32)
  for seat in system.seats:
    if not seat.active or seat.pendingRoute.lifecycle != brlPending:
      continue
    let estimate = estimatedRoutePops(seat.pendingRoute.request)
    if result < 0 or estimate < bestEstimate or
        (estimate == bestEstimate and
          (seat.pendingRoute.firstWaitTick < bestTick or
           (seat.pendingRoute.firstWaitTick == bestTick and
            seat.index < result))):
      result = seat.index
      bestEstimate = estimate
      bestTick = seat.pendingRoute.firstWaitTick

proc cancelStaleRouteJob(system: BodyNavSystem) =
  if not system.routeJob.active or system.routeJobSeat < 0:
    return
  let seat = system.seats[system.routeJobSeat]
  let request = system.routeJob.request
  if seat.pendingRoute.lifecycle != brlInFlight or
      seat.pendingRoute.request.requestGeneration !=
        request.requestGeneration:
    system.routeJob = BodyRouteSearchJob()
    system.routeJobSeat = -1
  elif request.dangerGeneration != seat.dangerGeneration:
    seat.pendingRoute.request.dangerGeneration = seat.dangerGeneration
    seat.pendingRoute.lifecycle = brlPending
    system.routeJob = BodyRouteSearchJob()
    system.routeJobSeat = -1

proc runRouteScheduler*(system: BodyNavSystem; tick: int;
    popBudget = BodyRoutePopBudgetPerTick): int =
  ## One episode-wide exact-pop allowance. Completed work is published after
  ## the action pass and is therefore first visible on the next action pass.
  if system == nil or system.mixedGraph == nil:
    return
  if popBudget < 0:
    raise newException(ValueError, "body route pop budget must not be negative")
  when defined(bodyNavBreakdown):
    let restartStarted = getMonoTime()
    let activeBeforeRestart = system.routeJob.active
  system.cancelStaleRouteJob()
  when defined(bodyNavBreakdown):
    system.timing.schedulerRestartNanoseconds += timingElapsed(restartStarted)
    if activeBeforeRestart and not system.routeJob.active:
      inc system.timing.schedulerRestarts
  var remaining = popBudget
  while remaining > 0:
    if not system.routeJob.active:
      when defined(bodyNavBreakdown):
        let selectStarted = getMonoTime()
      let seatIndex = system.nextPendingSeat()
      when defined(bodyNavBreakdown):
        system.timing.schedulerSelectNanoseconds += timingElapsed(selectStarted)
      if seatIndex < 0:
        break
      let seat = system.seats[seatIndex]
      if seat.pendingRoute.request.dangerGeneration != seat.dangerGeneration:
        seat.pendingRoute.request.dangerGeneration = seat.dangerGeneration
      system.routeJobSeat = seatIndex
      seat.pendingRoute.lifecycle = brlInFlight
      when defined(bodyNavBreakdown):
        let attachStarted = getMonoTime()
      system.routeJob.beginBodyRouteSearch(system.mixedGraph,
        system.routeWorkspace, seat.packedWeights,
        seat.pendingRoute.request)
      when defined(bodyNavBreakdown):
        system.timing.requestAttachNanoseconds += timingElapsed(attachStarted)
        inc system.timing.requestAdmissions
    let seat = system.seats[system.routeJobSeat]
    when defined(bodyNavBreakdown):
      let popStarted = getMonoTime()
    let spent = system.routeJob.spendBodyRoutePops(system.mixedGraph,
      system.routeWorkspace, seat.packedWeights, system.hazard, remaining)
    when defined(bodyNavBreakdown):
      system.timing.routePopNanoseconds += timingElapsed(popStarted)
    remaining -= spent
    result += spent
    if system.routeJob.complete:
      when defined(bodyNavBreakdown):
        let finishStarted = getMonoTime()
      let request = system.routeJob.request
      let route = system.routeJob.finishBodyRouteSearch(
        system.mixedGraph, system.routeWorkspace)
      if seat.pendingRoute.lifecycle == brlInFlight and
          seat.pendingRoute.request.requestGeneration ==
            request.requestGeneration and
          seat.dangerGeneration == request.dangerGeneration:
        seat.lastQuerySucceeded = route.ok
        seat.lastQueryFailure = route.failure
        if route.ok:
          doAssert seat.installMixedRoute(route, request)
        seat.pendingRoute.lifecycle = brlIdle
      when defined(bodyNavBreakdown):
        system.timing.routeFinishNanoseconds += timingElapsed(finishStarted)
        inc system.timing.routeCompletions
      system.routeJob = BodyRouteSearchJob()
      system.routeJobSeat = -1
      if spent == 0:
        continue
    elif spent == 0:
      raise newException(BodyMapError,
        "in-flight body route made no progress under available pop budget")
  system.routePopsLastTick = result

proc profileWeightQ8(profile: shellTypes.CostProfile): int64 {.inline.} =
  case profile
  of shellTypes.cpDefault: 256
  of shellTypes.cpCarrier: 640
  of shellTypes.cpHunter: 64

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

proc pixelDistanceQ4(a, b: BodyPoint): int64 {.inline.} =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  int64(round(sqrt(float(dx * dx + dy * dy)) * 16.0))

proc steeringDangerCost(seat: BodyNavSeat; map: BodyMap;
    candidate: BodyPoint; profile: shellTypes.CostProfile;
    stepQ4: int64): int64 =
  let sampled = max(0.0, seat.danger.sample(map, candidate))
  let dangerQ8 = int64(pyRound(sampled * 256.0))
  divideRoundTiesEven(
    stepQ4 * profile.profileWeightQ8 * dangerQ8, 65_536)

proc neighborMask(delta: BodyPoint): uint8 {.inline.} =
  if delta.x < 0: result = result or ButtonLeft
  elif delta.x > 0: result = result or ButtonRight
  if delta.y < 0: result = result or ButtonUp
  elif delta.y > 0: result = result or ButtonDown

proc steeringMask*(system: BodyNavSystem; seatIndex: int;
    selfPos, target: BodyPoint; profile: shellTypes.CostProfile;
    elapsedTick: int): uint8 =
  if system == nil or seatIndex < 0 or seatIndex >= system.seats.len:
    raise newException(ValueError, "body navigation seat index is out of range")
  when defined(bodyNavBreakdown):
    let started = getMonoTime()
    defer:
      system.timing.steeringNanoseconds += timingElapsed(started)
  let seat = system.seats[seatIndex]
  doAssert seat.active, "inactive navigation seat queried"
  let currentDistance = pixelDistanceQ4(selfPos, target)
  var
    found = false
    bestScore = low(int64)
  for delta in NavNeighbors:
    let candidate = (selfPos.x + delta.x * NavCell,
      selfPos.y + delta.y * NavCell)
    if not system.map.canStand(candidate) or
        not system.map.segmentClear(selfPos, candidate):
      continue
    if seat.blockedPenalty.isSome and
        system.map.cellOf(candidate) ==
          system.map.cellOf(seat.blockedPenalty.get.pos):
      continue
    let progress = currentDistance - pixelDistanceQ4(candidate, target)
    if progress <= 0:
      continue
    let stepQ4 = if delta.x != 0 and delta.y != 0: 181'i64 else: 128'i64
    var hazardCost = 0'i64
    if system.hazard != nil:
      let cell = system.map.cellOf(candidate)
      hazardCost = system.hazard.hazardStepCostQ4(
        cell.y * system.map.gridWidth + cell.x,
        elapsedTick + (stepQ4.int + HazardEtaSpeedQ4 - 1) div
          HazardEtaSpeedQ4,
        uint32(stepQ4))
    let score = progress -
      seat.steeringDangerCost(system.map, candidate, profile, stepQ4) -
      hazardCost
    if not found or score > bestScore:
      found = true
      bestScore = score
      result = neighborMask(delta)

proc octantToward*(selfXy, waypoint: BodyPoint): uint8 =
  let dx = waypoint.x - selfXy.x
  let dy = waypoint.y - selfXy.y
  if abs(dx) < 1 and abs(dy) < 1:
    return 0'u8
  let angle = arctan2(dy.float, dx.float)
  let cosine = cos(angle)
  let sine = sin(angle)
  if cosine > 0.383: result = result or ButtonRight
  elif cosine < -0.383: result = result or ButtonLeft
  if sine > 0.383: result = result or ButtonDown
  elif sine < -0.383: result = result or ButtonUp

proc navigationWaypoint*(system: BodyNavSystem, seatIndex: int,
    selfXy: BodyPoint, goal: ValidatedGoal, tick: int,
    movingTarget = false, profile = shellTypes.cpDefault,
    targetIdentity = NavTargetIdentity(kind: ntiLiteral,
      sourceCell: -1), elapsedZoneTick = 0): BodyPoint =
  let seat = system.seats[seatIndex]
  doAssert seat.active, "inactive navigation seat queried"
  if seat.blockedPenalty.isSome and
      tick >= seat.blockedPenalty.get.untilTick:
    seat.blockedPenalty = none(tuple[pos: BodyPoint, untilTick: int])
  let desired = goal.goalPoint
  let goalCell = system.map.cellOf(desired)
  let identity = if targetIdentity.sourceCell >= 0:
    targetIdentity
  else:
    NavTargetIdentity(kind: ntiLiteral,
      sourceCell: int32(goalCell.y * system.map.gridWidth + goalCell.x))
  let anchor = NavRequestAnchor(goalCell: goalCell, identity: identity,
    profile: profile, moving: movingTarget)
  let forcedReplan = seat.pendingRoute.lifecycle == brlIdle and
    seat.stuckTicks >= StuckTicks
  if forcedReplan:
    if seat.lastFollowReplanTick.isSome and
        tick - seat.lastFollowReplanTick.get <= FollowStuckWindowTicks:
      inc seat.followStuckEvents
    seat.lastFollowReplanTick = some(tick)
    seat.blockedPenalty = some((selfXy, tick + FollowBlockTtlTicks))
    inc seat.followReplans
  if system.mixedGraph != nil:
    if seat.shouldQueryRoute(anchor, tick):
      when defined(bodyNavBreakdown):
        let requestStarted = getMonoTime()
      inc seat.revision
      seat.desiredGoal = some(goal.goalPoint)
      seat.desiredProfile = profile
      system.submitMixedRoute(seat, selfXy, goal.goalPoint, profile,
        elapsedZoneTick, tick)
      seat.acceptRequestAnchor(anchor, tick)
      seat.stuckTicks = 0
      when defined(bodyNavBreakdown):
        system.timing.requestSubmitNanoseconds += timingElapsed(requestStarted)
        inc system.timing.requestSubmissions
    when defined(bodyNavBreakdown):
      let waypointStarted = getMonoTime()
    let waypoint = seat.mixedRouteWaypoint(system.map, selfXy)
    when defined(bodyNavBreakdown):
      system.timing.waypointNanoseconds += timingElapsed(waypointStarted)
    return if waypoint.isSome: waypoint.get else: selfXy
  selfXy

proc safetyCellPoint(system: BodyNavSystem;
    cellIndex: int): BodyPoint {.inline.} =
  (cellIndex mod system.map.gridWidth, cellIndex div system.map.gridWidth)

proc installSafetyContext*(system: BodyNavSystem; hazard: BodyHazardOverlay;
    cache: BodySafeCache) =
  if system == nil or system.safetyScratch == nil:
    raise newException(ValueError,
      "body navigation safety context requires route query scratch")
  system.hazard = hazard
  system.safetyScratch.installSafetyContext(hazard, cache)

proc safetyHintsReady*(system: BodyNavSystem): bool =
  system != nil and system.safetyScratch.safetyReady

proc chainToSide(system: BodyNavSystem; startCell, side: int): tuple[
    found: bool, firstStep: int32, distanceQ4: uint32] =
  let target = system.routeIndex.portalSideAt(side).anchorCell.int
  if system.routeIndex.roomForCell(startCell) !=
      system.routeIndex.portalSideAt(side).room.int:
    return
  let
    startPoint = cellCenter(system.safetyCellPoint(startCell))
    targetPoint = system.routeIndex.routePoint(int32(target))
    estimate = routeOctileQ4(startPoint, targetPoint)
  result.distanceQ4 = uint32(min(high(uint32).int64, estimate))
  result.firstStep = if target == startCell: -1'i32 else: int32(target)
  result.found = true

proc safeSourceSide(system: BodyNavSystem; startSide: int): int =
  var current = startSide
  let sideCount = system.routeIndex.routeIndexStats.sides
  for _ in 0 ..< sideCount:
    let next = system.safetyScratch.safetyNextSideAt(current)
    if next.isNone:
      return -1
    if next.get == current:
      return current
    current = next.get
  -1

proc graphFirstPoint(system: BodyNavSystem; side: int): Option[BodyPoint] =
  let next = system.safetyScratch.safetyNextSideAt(side)
  if next.isNone or next.get == side:
    return none(BodyPoint)
  some(system.routeIndex.sideAnchor(next.get))

proc safetyOctantToward(origin, target: BodyPoint): int8 =
  let
    dx = cmp(target.x, origin.x)
    dy = cmp(target.y, origin.y)
  case (dy + 1) * 3 + dx + 1
  of 5: 0
  of 2: 1
  of 1: 2
  of 0: 3
  of 3: 4
  of 6: 5
  of 7: 6
  of 8: 7
  else: -1

proc ceilSafetyMetric(value: uint64; denominator: uint64): int32 =
  min(uint64(high(int32)), (value + denominator - 1) div denominator).int32

proc safetyHintsFor*(system: BodyNavSystem; selfPos: BodyPoint;
    elapsedTick: int; gameGeneration: uint64): BodySafetyHints =
  result = BodySafetyHints(ticksUntilPaintHere: -1, ticksToSafety: -1,
    safeDistPx: -1, retreatOctant: -1, sourceCell: none(int32))
  if not system.safetyHintsReady:
    return
  system.safetyScratch.refreshSafety(elapsedTick, gameGeneration)
  let
    start = system.map.cellOf(selfPos)
    startCell = start.y * system.map.gridWidth + start.x
    arrival = system.safetyScratch.safetyArrivalAt(startCell)
  if arrival != HazardNeverArrives:
    result.ticksUntilPaintHere = int32(max(0, arrival.int - elapsedTick))
  if not system.map.cellWalkable(start):
    return
  if system.safetyScratch.safetyCellDryAt(startCell):
    result.ticksToSafety = 0
    result.safeDistPx = 0
    result.sourceCell = some(int32(startCell))
    return
  let room = system.routeIndex.roomForCell(startCell)
  if room < 0:
    return

  var
    found = false
    sourceCell = -1'i32
    firstPoint = none(BodyPoint)
    distanceQ4 = high(uint64)
  if system.safetyScratch.safetyRoomHasDryAt(room):
    let local = system.safetyScratch.nearestDryCell(startCell, room)
    if local.found and system.safetyScratch.safetyCellDryAt(
        local.sourceCell.int):
      found = true
      sourceCell = local.sourceCell
      distanceQ4 = local.distanceQ4.uint64
      if local.firstStep >= 0:
        firstPoint = some(cellCenter(
          system.safetyCellPoint(local.firstStep.int)))
  else:
    for sideOffset in system.routeIndex.roomSideRange(room):
      let side = system.routeIndex.roomSideAt(sideOffset)
      let safeDistance = system.safetyScratch.safetyDistanceQ4At(side)
      if safeDistance == high(uint32):
        continue
      let chain = system.chainToSide(startCell, side)
      if not chain.found:
        continue
      let sourceSide = system.safeSourceSide(side)
      if sourceSide < 0:
        continue
      let candidateSource =
        system.routeIndex.portalSideAt(sourceSide).anchorCell
      if not system.safetyScratch.safetyCellDryAt(candidateSource.int):
        continue
      let candidate = chain.distanceQ4.uint64 + safeDistance.uint64
      if not found or candidate < distanceQ4 or
          (candidate == distanceQ4 and candidateSource < sourceCell):
        found = true
        sourceCell = candidateSource
        distanceQ4 = candidate
        if chain.firstStep >= 0:
          firstPoint = some(cellCenter(
            system.safetyCellPoint(chain.firstStep.int)))
        else:
          firstPoint = system.graphFirstPoint(side)

  if not found or sourceCell < 0 or
      not system.safetyScratch.safetyCellDryAt(sourceCell.int):
    return
  result.sourceCell = some(sourceCell)
  result.safeDistPx = ceilSafetyMetric(distanceQ4, 16)
  result.ticksToSafety = ceilSafetyMetric(distanceQ4,
    HazardEtaSpeedQ4.uint64)
  if firstPoint.isSome:
    result.retreatOctant = safetyOctantToward(cellCenter(start), firstPoint.get)

proc zoneSafeTarget*(system: BodyNavSystem; selfPos: BodyPoint;
    elapsedTick: int; gameGeneration: uint64): Option[BodyPoint] =
  let hints = system.safetyHintsFor(selfPos, elapsedTick, gameGeneration)
  if hints.sourceCell.isNone:
    none(BodyPoint)
  else:
    some(system.routeIndex.routePoint(hints.sourceCell.get))
