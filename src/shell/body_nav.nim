## Seat navigation coordinator: danger cadence, global cold-work scheduler,
## atomic route replacement, and stencil-exact warm follower behavior.
##
## One 256-unit budget PER SEAT per tick, pooled (planBudgetPerTick).
## Plans are spent first, in the existing persisted seat-index round
## robin. Field minting consumes only what the plan pass leaves, through
## its own persisted seat-index cursor, with at most one mint in flight
## server-wide. A play's order moves the cog before it warms the oracle.
##
## WHY the pool scales with seats: the budget was a flat 256 units per
## tick server-wide, sized for one or two seats on a paintball board. A
## Season 2 league episode runs 16 seats on a 2271x1212 generated map,
## where one 900 px route costs ~17k units on the PlanStepPx lattice.
## Sixteen such plans sharing 256 units a tick each got a slice every
## thirty-odd ticks and took over a thousand ticks to finish, and the
## follower holds a cog still while its plan is pending — so hosted cogs
## stood where they spawned until the zone killed them (round 3633,
## 0.7.283). Per-seat pooling keeps every single-seat contract byte-
## identical and lets a full roster plan in parallel; the worst case
## (32 seats, all planning) is ~8k units, a few milliseconds of a 41 ms
## tick, and the planning pass is outside the containment body-tick gate.

import std/[hashes, math, options]
import bitworld/[profile, spriteprotocol]
import ../ctf/sim_types
import body_cache, body_hazard, body_map, body_planner, body_route_index,
  body_route_query
import types as shellTypes

const
  DangerCadenceK* = 32
  ColdPlanBudgetPerTick* = 256
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
  RoutePhaseStart = 0'u8
  RoutePhaseEdges = 1'u8
  RoutePhaseGoal = 2'u8
  RoutePhaseEndpoint = 3'u8
  RoutePhaseDone = 4'u8

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

  BodyRouteCursor* = object
    phase*: uint8
    edgeIndex*, cellOffset*: uint16

  BodyNavSeat* = ref object
    index*: int
    cache*: BodySeatCache
    planner*: BodyPlanner
    job*: BodyPlanJob
    mintJob*: BodyMintJob
    mintGoal*: Option[BodyPoint]
    mintRevision*: uint64
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
    path*: seq[BodyPoint]
    pathLen*: int
    pathRevision*: uint64
    cursor*: int
    lastXy*: Option[BodyPoint]
    stuckTicks*: int
    blockedPenalty*: Option[tuple[pos: BodyPoint, untilTick: int]]
    lastFollowReplanTick*: Option[int]
    lastPlanTick*: int
    followReplans*: int
    followStuckEvents*: int
    planVisits*: int   ## planning visits spent on the current revision
    installedDescriptor: BodyRouteDescriptor
    installedEdges: array[RouteEdgeCap, RouteEdgeRef]
    installedStartLeg: array[RouteLocalLegCap, int32]
    installedGoalLeg: array[RouteLocalLegCap, int32]
    installedRevision: uint64
    routeCursor*: BodyRouteCursor
    installedAnchor: BodyPoint
    lastQuerySucceeded*: bool
    lastQueryFailure*: BodyRouteFailure

  PlanningVisit* = object
    tick*: int
    seat*: int
    revision*: uint64
    units*: int
    completed*: bool

  MintVisit* = object
    tick*: int
    seat*: int
    revision*: uint64
    units*: int
    completed*: bool

  DangerRebuild* = object
    tick*: int
    seat*: int
    sourceCount*: int

  PlanBudgetOutcome* = enum
    pboSuspended   ## the pooled budget ran out with this plan still pending
    pboCompleted   ## a plan that needed more than one visit finally landed
    pboFailed      ## a plan that needed more than one visit finally failed

  PlanBudgetEvent* = object
    ## One operator-visible cold-planning budget event (always-on, unlike the
    ## capacity-gated traces above). A plan that fits its first visit produces
    ## no event; every suspension does, and so does the visit that finally
    ## resolves a plan which was suspended at least once, so the log shows
    ## both the stall and how many visits (retries) it took to clear.
    tick*: int
    seat*: int
    revision*: uint64
    visits*: int       ## planning visits spent on this revision so far
    units*: int        ## work units spent on this visit
    outcome*: PlanBudgetOutcome

  BodyNavSystem* = ref object
    map*: BodyMap
    seats*: seq[BodyNavSeat]
    routeIndex*: BodyRouteIndex
    routeScratch*: BodyRouteQueryScratch
    hazard: BodyHazardOverlay
    minter*: BodyFieldMinter
    dangerK*: int
    lastPlanSeat*: int
    lastMintSeat*: int
    planningTrace: seq[PlanningVisit]
    mintTrace: seq[MintVisit]
    dangerTrace: seq[DangerRebuild]
    planningTraceLen: int
    mintTraceLen: int
    dangerTraceLen: int
    planBudgetEvents: seq[PlanBudgetEvent]  ## drained by the episode each tick

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
                       prepareRouteQueries = false,
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
    result.routeScratch = newBodyRouteQueryScratch(result.routeIndex)
  result.minter = newBodyFieldMinter(map)
  result.dangerK = dangerK
  result.lastPlanSeat = -1
  result.lastMintSeat = -1
  result.planningTrace = newSeq[PlanningVisit](traceCapacity)
  result.mintTrace = newSeq[MintVisit](traceCapacity)
  result.dangerTrace = newSeq[DangerRebuild](traceCapacity)
  result.seats = newSeq[BodyNavSeat](seatCount)
  let dangerGeometry = initDangerGeometry(liveGunRangePx)
  for index in 0 ..< seatCount:
    let cache = newBodySeatCache(map)
    let planner = if prepareRouteQueries: nil else: newBodyPlanner(map)
    let danger = initDanger(map)
    result.seats[index] = BodyNavSeat(index: index, cache: cache,
      planner: planner, danger: danger.field,
      dangerWorkspace: danger.workspace, dangerTick: 0, active: true,
      dangerKernel: dangerGeometry.kernel,
      dangerPerimeter: dangerGeometry.perimeter,
      dangerRadius: dangerGeometry.radius,
      dangerRangePx: liveGunRangePx,
      desiredProfile: shellTypes.cpDefault,
      path: newSeq[BodyPoint](planner.workspaceCapacity + 2))

proc seatCount*(system: BodyNavSystem): int = system.seats.len

proc installRoute*(seat: BodyNavSeat, scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult, revision: uint64): bool =
  ## Publish only after every bounded array has copied successfully. The local
  ## staging values keep a typed/stale failure from changing any live bytes.
  if seat == nil or scratch == nil or not route.ok:
    return false
  var
    edges: array[RouteEdgeCap, RouteEdgeRef]
    startLeg: array[RouteLocalLegCap, int32]
    goalLeg: array[RouteLocalLegCap, int32]
  if not scratch.copyResultEdges(route, edges) or
      not scratch.copyResultStartLeg(route, startLeg) or
      not scratch.copyResultGoalLeg(route, goalLeg):
    return false
  seat.installedEdges = edges
  seat.installedStartLeg = startLeg
  seat.installedGoalLeg = goalLeg
  seat.installedDescriptor = route.descriptor
  seat.routeCursor = BodyRouteCursor(phase: RoutePhaseStart)
  seat.installedAnchor = route.descriptor.exactStart
  seat.installedRevision = revision
  true

proc installedRouteRevision*(seat: BodyNavSeat): uint64 =
  if seat == nil: 0 else: seat.installedRevision

proc installedRouteCursor*(seat: BodyNavSeat): int =
  if seat == nil: 0 else: seat.routeCursor.cellOffset.int

proc installedRouteAnchor*(seat: BodyNavSeat): BodyPoint =
  if seat == nil: (0, 0) else: seat.installedAnchor

proc installedRouteFingerprint*(seat: BodyNavSeat): Hash =
  if seat == nil:
    return 0
  var value = hash(seat.installedDescriptor.edgeCount) !&
    hash(seat.installedDescriptor.startLegLen) !&
    hash(seat.installedDescriptor.goalLegLen) !&
    hash(seat.installedDescriptor.exactStart) !&
    hash(seat.installedDescriptor.exactGoal) !&
    hash(seat.routeCursor.phase) !& hash(seat.routeCursor.edgeIndex) !&
    hash(seat.routeCursor.cellOffset) !& hash(seat.installedAnchor)
  for offset in 0 ..< seat.installedDescriptor.edgeCount.int:
    value = value !& hash(uint16(seat.installedEdges[offset]))
  for offset in 0 ..< seat.installedDescriptor.startLegLen.int:
    value = value !& hash(seat.installedStartLeg[offset])
  for offset in 0 ..< seat.installedDescriptor.goalLegLen.int:
    value = value !& hash(seat.installedGoalLeg[offset])
  !$value

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

proc recordPlanning(system: BodyNavSystem, value: PlanningVisit) {.inline.} =
  if system.planningTraceLen < system.planningTrace.len:
    system.planningTrace[system.planningTraceLen] = value
    inc system.planningTraceLen

proc recordMint(system: BodyNavSystem, value: MintVisit) {.inline.} =
  if system.mintTraceLen < system.mintTrace.len:
    system.mintTrace[system.mintTraceLen] = value
    inc system.mintTraceLen

proc recordPlanBudget(system: BodyNavSystem, tick: int, seat: BodyNavSeat,
                      revision: uint64, units: int) =
  ## Called after every planning visit. Prewarm passes (tick < 0) are silent:
  ## they run before the match and have no tick to join against.
  if tick < 0:
    return
  var outcome: PlanBudgetOutcome
  if seat.job.planPending:
    outcome = pboSuspended
  elif seat.planVisits > 1:
    outcome = if seat.job.planSucceeded: pboCompleted else: pboFailed
  else:
    return
  system.planBudgetEvents.add(PlanBudgetEvent(tick: tick, seat: seat.index,
    revision: revision, visits: seat.planVisits, units: units,
    outcome: outcome))

proc drainPlanBudgetEvents*(system: BodyNavSystem): seq[PlanBudgetEvent] =
  ## Hands the events recorded since the last drain to the caller (the
  ## episode, once per tick) and clears them.
  result = move(system.planBudgetEvents)
  system.planBudgetEvents = @[]

proc followingStalePath*(seat: BodyNavSeat): bool =
  ## True while the follower walks a route planned for an earlier request
  ## because the current request's plan has not landed yet.
  seat.pathLen > 0 and seat.pathRevision != seat.revision

proc hasNoPath*(seat: BodyNavSeat): bool =
  seat.pathLen == 0

proc planningTraceSnapshot*(system: BodyNavSystem): seq[PlanningVisit] =
  result = newSeq[PlanningVisit](system.planningTraceLen)
  for index in 0 ..< system.planningTraceLen:
    result[index] = system.planningTrace[index]

proc mintTraceSnapshot*(system: BodyNavSystem): seq[MintVisit] =
  result = newSeq[MintVisit](system.mintTraceLen)
  for index in 0 ..< system.mintTraceLen:
    result[index] = system.mintTrace[index]

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

  seat.installedDescriptor = BodyRouteDescriptor()
  seat.installedEdges = default(array[RouteEdgeCap, RouteEdgeRef])
  seat.installedStartLeg = default(array[RouteLocalLegCap, int32])
  seat.installedGoalLeg = default(array[RouteLocalLegCap, int32])
  seat.routeCursor = BodyRouteCursor(phase: RoutePhaseDone)
  seat.installedAnchor = (0, 0)
  seat.installedRevision = 0

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

  seat.pathLen = 0
  seat.pathRevision = 0
  seat.cursor = 0
  seat.job = BodyPlanJob()
  seat.mintJob = BodyMintJob()
  seat.mintGoal = none(BodyPoint)
  seat.mintRevision = 0
  seat.planVisits = 0

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

proc mintQueuedOrPending*(seat: BodyNavSeat): bool =
  seat.mintGoal.isSome or seat.mintJob.mintPending

proc enqueueMint(seat: BodyNavSeat, goal: BodyPoint, revision: uint64) =
  let key = seat.cache.routeKey(goal)
  if seat.cache.routeSlotReady(key):
    return
  if seat.mintJob.mintPending:
    if seat.mintJob.routeKey != key:
      seat.cache.cancelMint(seat.mintJob)
      seat.mintGoal = some(goal)
      seat.mintRevision = revision
    return
  if seat.mintGoal.isSome and seat.cache.routeKey(seat.mintGoal.get) == key:
    return
  seat.mintGoal = some(goal)
  seat.mintRevision = revision

proc replacePlan*(system: BodyNavSystem, seatIndex: int, revision: uint64,
                  selfXy: BodyPoint, goal: ValidatedGoal,
                  profile = shellTypes.cpDefault,
                  avoid = none(BodyPoint)) =
  let seat = system.seats[seatIndex]
  if seat.job.planPending:
    seat.cache.cancelPlan(seat.job)
  seat.revision = revision
  seat.desiredGoal = some(goal.goalPoint)
  seat.desiredProfile = profile
  seat.planner.startPlan(seat.cache, seat.job, revision, selfXy,
    goal, profile, avoid)
  seat.planVisits = 0
  seat.enqueueMint(goal.goalPoint, revision)

proc installCompletedPath(seat: BodyNavSeat) =
  swap(seat.path, seat.planner.resultPath)
  seat.pathLen = seat.planner.resultLen
  seat.planner.resultLen = 0
  seat.pathRevision = seat.job.revision
  seat.cache.pinStandingGoal(seat.job.goal)
  seat.cursor = 0
  seat.stuckTicks = 0

proc hasPendingPlan(system: BodyNavSystem): bool =
  for seat in system.seats:
    if seat.job.planPending:
      return true

proc pendingPlanCount*(system: BodyNavSystem): int =
  ## Seats whose cold plan is still computing at the end of the tick.
  for seat in system.seats:
    if seat.job.planPending:
      inc result

proc hasPendingMint*(system: BodyNavSystem): bool =
  for seat in system.seats:
    if seat.mintQueuedOrPending:
      return true

proc activeMintSeat(system: BodyNavSystem): int =
  for index, seat in system.seats:
    if seat.mintJob.mintPending:
      return index
  -1

proc nextQueuedMintSeat(system: BodyNavSystem): int =
  var scanned = 0
  var index = floorMod(system.lastMintSeat + 1, system.seats.len)
  while scanned < system.seats.len:
    if system.seats[index].mintGoal.isSome:
      return index
    inc scanned
    index = (index + 1) mod system.seats.len
  -1

proc runPlanningWork(system: BodyNavSystem, tick, budgetLimit: int,
    evaluationOrder: openArray[int] = [], runMints = true): int =
  ## The plan pass owns the budget first; the field minter can spend only the
  ## unclaimed tail, through its own persisted cursor.
  discard evaluationOrder
  var budget = budgetLimit
  var scanned = 0
  var index = floorMod(system.lastPlanSeat + 1, system.seats.len)
  while budget > 0 and scanned < system.seats.len:
    let seat = system.seats[index]
    if seat.job.planPending:
      let revision = seat.job.revision
      let units = seat.planner.stepPlan(seat.cache, seat.danger, seat.job, budget)
      system.lastPlanSeat = index
      inc seat.planVisits
      system.recordPlanning(PlanningVisit(tick: tick, seat: index,
        revision: revision, units: units, completed: seat.job.planFinished))
      system.recordPlanBudget(tick, seat, revision, units)
      if seat.job.planSucceeded:
        seat.installCompletedPath()
      if budget == 0:
        break
      if units == 0 and seat.job.planPending:
        raise newException(BodyMapError,
          "pending plan made no progress under available budget")
    inc scanned
    index = (index + 1) mod system.seats.len
  if runMints and budget > 0:
    var mintSeat = system.activeMintSeat()
    if mintSeat < 0:
      mintSeat = system.nextQueuedMintSeat()
      if mintSeat >= 0:
        let seat = system.seats[mintSeat]
        system.lastMintSeat = mintSeat
        system.minter.beginMint(seat.cache, seat.mintJob,
          seat.mintGoal.get, seat.mintRevision)
    if mintSeat >= 0:
      let seat = system.seats[mintSeat]
      let revision = seat.mintJob.revision
      let units = system.minter.stepMint(seat.cache, seat.mintJob, budget)
      system.recordMint(MintVisit(tick: tick, seat: mintSeat,
        revision: revision, units: units, completed: seat.mintJob.mintFinished))
      if seat.mintJob.mintFinished:
        seat.mintGoal = none(BodyPoint)
      elif units == 0 and seat.mintJob.mintPending:
        raise newException(BodyMapError,
          "pending mint made no progress under available budget")
  budgetLimit - budget

proc planBudgetPerTick*(system: BodyNavSystem): int =
  ## The pooled cold-work budget for one tick: ColdPlanBudgetPerTick for
  ## every configured seat (see the module comment for why it scales).
  ColdPlanBudgetPerTick * max(1, system.seats.len)

proc runPlanningTick*(system: BodyNavSystem, tick: int,
    evaluationOrder: openArray[int] = []): int =
  when ProfileTracePath.len > 0:
    measurePush("runPlanningTick")
    defer: measurePop()
  system.runPlanningWork(tick, system.planBudgetPerTick, evaluationOrder)

proc prewarmColdPlans*(system: BodyNavSystem) =
  ## Activation-barrier cold-plan drain.
  ##
  ## This is intentionally off-tick work for the §10 activation barrier. The
  ## 256-unit `runPlanningTick` budget still governs PLAYING ticks; this API is
  ## not a playing-tick shortcut. It drains repeated scheduler chunks through
  ## the same persisted seat-index round robin, records barrier visits with
  ## `tick = -1`, and publishes paths through the ordinary completion install
  ## path. It deliberately does not warm route fields: after ruling 10 a plan
  ## never needs a field, and stencil mints fields lazily on demand.
  while system.hasPendingPlan:
    discard system.runPlanningWork(-1, system.planBudgetPerTick, [], false)

proc planCursor*(system: BodyNavSystem): int = system.lastPlanSeat

proc mintCursor*(system: BodyNavSystem): int = system.lastMintSeat

proc activePath*(seat: BodyNavSeat): seq[BodyPoint] =
  result = newSeq[BodyPoint](seat.pathLen)
  for index in 0 ..< seat.pathLen:
    result[index] = seat.path[index]

proc setActivePathForTest*(seat: BodyNavSeat, path: openArray[BodyPoint],
                           revision: uint64) =
  if path.len > seat.path.len:
    raise newException(ValueError, "test path exceeds fixed follower buffer")
  for index, point in path:
    seat.path[index] = point
  seat.pathLen = path.len
  seat.pathRevision = revision
  seat.cursor = 0

proc distance(a, b: BodyPoint): float =
  hypot((a.x - b.x).float, (a.y - b.y).float)

proc pointSegmentDistance(point, start, finish: BodyPoint): float =
  let dx = (finish.x - start.x).float
  let dy = (finish.y - start.y).float
  if dx == 0.0 and dy == 0.0:
    return distance(point, start)
  let projection = clamp(
    ((point.x - start.x).float * dx + (point.y - start.y).float * dy) /
      (dx * dx + dy * dy), 0.0, 1.0)
  hypot(point.x.float - (start.x.float + projection * dx),
        point.y.float - (start.y.float + projection * dy))

proc withinCorridor*(seat: BodyNavSeat, point: BodyPoint): bool =
  if seat.pathLen == 0:
    return seat.lastXy.isSome and
      distance(point, seat.lastXy.get) <= FollowCorridorPx
  let cursor = clamp(seat.cursor, 0, seat.pathLen - 1)
  let previous = max(0, cursor - 1)
  let following = min(seat.pathLen - 1, cursor + 1)
  min(pointSegmentDistance(point, seat.path[previous], seat.path[cursor]),
      pointSegmentDistance(point, seat.path[cursor], seat.path[following])) <=
    FollowCorridorPx

proc followerWaypoint*(seat: BodyNavSeat, selfXy: BodyPoint): BodyPoint =
  if seat.pathLen == 0:
    return selfXy
  while seat.cursor < seat.pathLen - 1 and
      distance(selfXy, seat.path[seat.cursor]) < NavCell.float:
    inc seat.cursor
  seat.path[seat.cursor]

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
  if seat.planner == nil:
    if seat.installedRevision == 0 or
        seat.routeCursor.phase >= RoutePhaseDone:
      return true
    if seat.stuckTicks >= StuckTicks:
      return true
    return anchor.moving and tick - seat.lastPlanTick >= PlanMovingReplanTicks
  if seat.job.planPending:
    return false
  if seat.pathLen == 0 or seat.cursor >= seat.pathLen:
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

proc normalizeRouteCursor(seat: BodyNavSeat; index: BodyRouteIndex) =
  while seat.routeCursor.phase < RoutePhaseDone:
    case seat.routeCursor.phase
    of RoutePhaseStart:
      if seat.routeCursor.cellOffset < seat.installedDescriptor.startLegLen:
        return
      seat.routeCursor = BodyRouteCursor(phase: RoutePhaseEdges)
    of RoutePhaseEdges:
      if seat.routeCursor.edgeIndex >= seat.installedDescriptor.edgeCount:
        seat.routeCursor = BodyRouteCursor(phase: RoutePhaseGoal)
        continue
      let edge = seat.installedEdges[seat.routeCursor.edgeIndex]
      let length = index.routeSegmentAt(edge.routeEdgeSegment).cellLen
      if seat.routeCursor.cellOffset < length:
        return
      inc seat.routeCursor.edgeIndex
      seat.routeCursor.cellOffset = 0
    of RoutePhaseGoal:
      if seat.routeCursor.cellOffset < seat.installedDescriptor.goalLegLen:
        return
      seat.routeCursor = BodyRouteCursor(phase: RoutePhaseEndpoint)
    of RoutePhaseEndpoint:
      if seat.routeCursor.cellOffset == 0:
        return
      seat.routeCursor = BodyRouteCursor(phase: RoutePhaseDone)
    else:
      seat.routeCursor.phase = RoutePhaseDone

proc routeCursorPoint(seat: BodyNavSeat; index: BodyRouteIndex;
    offset = 0): Option[BodyPoint] =
  let targetOffset = seat.routeCursor.cellOffset.int + offset
  case seat.routeCursor.phase
  of RoutePhaseStart:
    if targetOffset < seat.installedDescriptor.startLegLen.int:
      return some(index.routePoint(seat.installedStartLeg[targetOffset]))
  of RoutePhaseEdges:
    if seat.routeCursor.edgeIndex < seat.installedDescriptor.edgeCount:
      let edge = seat.installedEdges[seat.routeCursor.edgeIndex]
      let segment = index.routeSegmentAt(edge.routeEdgeSegment)
      if targetOffset < segment.cellLen.int:
        return some(index.routePoint(index.segmentCellAt(
          edge.routeEdgeSegment, targetOffset, edge.routeEdgeReversed)))
  of RoutePhaseGoal:
    if targetOffset < seat.installedDescriptor.goalLegLen.int:
      return some(index.routePoint(seat.installedGoalLeg[targetOffset]))
  of RoutePhaseEndpoint:
    if targetOffset == 0:
      return some(seat.installedDescriptor.exactGoal)
  else:
    discard
  none(BodyPoint)

proc advanceRouteCursor(seat: BodyNavSeat; index: BodyRouteIndex) =
  inc seat.routeCursor.cellOffset
  seat.normalizeRouteCursor(index)

proc routeWaypoint*(seat: BodyNavSeat; index: BodyRouteIndex;
    selfPos: BodyPoint): Option[BodyPoint] =
  if seat == nil or index == nil or seat.installedRevision == 0:
    return none(BodyPoint)
  seat.normalizeRouteCursor(index)
  while seat.routeCursor.phase < RoutePhaseDone:
    var
      found = false
      best = selfPos
      bestOffset = 0
    for offset in 0 .. FollowLookaheadK:
      let candidate = seat.routeCursorPoint(index, offset)
      if candidate.isNone:
        break
      if index.map.segmentClear(selfPos, candidate.get):
        found = true
        best = candidate.get
        bestOffset = offset
    if not found:
      seat.installedAnchor = selfPos
      return seat.routeCursorPoint(index)
    seat.routeCursor.cellOffset = uint16(
      seat.routeCursor.cellOffset.int + bestOffset)
    if distance(selfPos, best) >= 1.0:
      seat.installedAnchor = best
      return some(best)
    seat.advanceRouteCursor(index)
  seat.installedAnchor = seat.installedDescriptor.exactGoal
  none(BodyPoint)

proc routeAdvancing*(seat: BodyNavSeat; selfPos: BodyPoint;
    arriveRadius: float): bool =
  seat != nil and seat.installedRevision != 0 and
    seat.routeCursor.phase < RoutePhaseDone and
    distance(selfPos, seat.installedAnchor) > arriveRadius

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
  let forcedReplan = not seat.job.planPending and
    seat.stuckTicks >= StuckTicks
  if forcedReplan:
    if seat.lastFollowReplanTick.isSome and
        tick - seat.lastFollowReplanTick.get <= FollowStuckWindowTicks:
      inc seat.followStuckEvents
    seat.lastFollowReplanTick = some(tick)
    seat.blockedPenalty = some((selfXy, tick + FollowBlockTtlTicks))
    inc seat.followReplans
  if system.routeIndex != nil:
    if seat.shouldQueryRoute(anchor, tick):
      inc seat.revision
      seat.desiredGoal = some(goal.goalPoint)
      seat.desiredProfile = profile
      let request = BodyRouteRequest(start: selfXy, goal: goal,
        profile: profile, danger: addr seat.danger,
        blockedCell: if seat.blockedPenalty.isSome:
          some(seat.blockedPenalty.get.pos) else: none(BodyPoint),
        hazard: system.hazard, elapsedZoneTick: elapsedZoneTick)
      let route = system.routeIndex.queryBodyRoute(system.routeScratch, request)
      seat.acceptRequestAnchor(anchor, tick)
      seat.lastQuerySucceeded = route.ok
      seat.lastQueryFailure = route.failure
      if route.ok:
        doAssert seat.installRoute(system.routeScratch, route, seat.revision)
      seat.stuckTicks = 0
    let waypoint = seat.routeWaypoint(system.routeIndex, selfXy)
    return if waypoint.isSome: waypoint.get else: selfXy
  if seat.shouldQueryRoute(anchor, tick):
    inc seat.revision
    let avoid = if seat.blockedPenalty.isSome:
      some(seat.blockedPenalty.get.pos) else: none(BodyPoint)
    system.replacePlan(seatIndex, seat.revision, selfXy, goal, profile, avoid)
    seat.acceptRequestAnchor(anchor, tick)
    seat.stuckTicks = 0
  seat.followerWaypoint(selfXy)

proc safetyCellPoint(system: BodyNavSystem;
    cellIndex: int): BodyPoint {.inline.} =
  (cellIndex mod system.map.gridWidth, cellIndex div system.map.gridWidth)

proc installSafetyContext*(system: BodyNavSystem; hazard: BodyHazardOverlay;
    cache: BodySafeCache) =
  if system == nil or system.routeScratch == nil:
    raise newException(ValueError,
      "body navigation safety context requires route query scratch")
  system.hazard = hazard
  system.routeScratch.installSafetyContext(hazard, cache)

proc safetyHintsReady*(system: BodyNavSystem): bool =
  system != nil and system.routeScratch.safetyReady

proc chainToSide(system: BodyNavSystem; startCell, side: int): tuple[
    found: bool, firstStep: int32, distanceQ4: uint32] =
  var current = startCell
  let target = system.routeIndex.portalSideAt(side).anchorCell.int
  var visits = 0
  while current != target:
    if visits >= system.routeIndex.routeIndexStats.navCells:
      return
    let next = system.routeIndex.nextCellTowardSide(side, current)
    if next < 0 or next.int == current:
      return
    if result.firstStep < 0:
      result.firstStep = next
    let
      a = system.safetyCellPoint(current)
      b = system.safetyCellPoint(next.int)
      diagonal = a.x != b.x and a.y != b.y
      step = if diagonal: 181'u32 else: uint32(NavCell * 16)
    if result.distanceQ4 > high(uint32) - step:
      return
    result.distanceQ4 += step
    current = next.int
    inc visits
  result.found = true

proc safeSourceSide(system: BodyNavSystem; startSide: int): int =
  var current = startSide
  let sideCount = system.routeIndex.routeIndexStats.sides
  for _ in 0 ..< sideCount:
    let next = system.routeScratch.safetyNextSideAt(current)
    if next.isNone:
      return -1
    if next.get == current:
      return current
    current = next.get
  -1

proc graphFirstPoint(system: BodyNavSystem; side: int): Option[BodyPoint] =
  let next = system.routeScratch.safetyNextSideAt(side)
  if next.isNone or next.get == side:
    return none(BodyPoint)
  for arcOffset in system.routeIndex.arcRangeForSide(side):
    let arc = system.routeIndex.routeArcAt(arcOffset)
    if arc.toSide.int != next.get:
      continue
    let segment = system.routeIndex.routeSegmentAt(arc.segment.int)
    if segment.cellLen.int < 2:
      return none(BodyPoint)
    let origin = system.routeIndex.routePoint(
      system.routeIndex.segmentCellAt(arc.segment.int, 0, arc.reversed))
    for offset in 1 ..< segment.cellLen.int:
      let point = system.routeIndex.routePoint(
        system.routeIndex.segmentCellAt(arc.segment.int, offset, arc.reversed))
      if point != origin:
        return some(point)
    return none(BodyPoint)
  none(BodyPoint)

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
  system.routeScratch.refreshSafety(elapsedTick, gameGeneration)
  let
    start = system.map.cellOf(selfPos)
    startCell = start.y * system.map.gridWidth + start.x
    arrival = system.routeScratch.safetyArrivalAt(startCell)
  if arrival != HazardNeverArrives:
    result.ticksUntilPaintHere = int32(max(0, arrival.int - elapsedTick))
  if not system.map.cellWalkable(start):
    return
  if system.routeScratch.safetyCellDryAt(startCell):
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
  if system.routeScratch.safetyRoomHasDryAt(room):
    let local = system.routeScratch.nearestDryCell(startCell, room)
    if local.found and system.routeScratch.safetyCellDryAt(
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
      let safeDistance = system.routeScratch.safetyDistanceQ4At(side)
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
      if not system.routeScratch.safetyCellDryAt(candidateSource.int):
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
      not system.routeScratch.safetyCellDryAt(sourceCell.int):
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
