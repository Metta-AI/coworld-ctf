## Seat navigation coordinator: danger cadence, global cold-work scheduler,
## atomic route replacement, and stencil-exact warm follower behavior.

import std/[hashes, math, options]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_cache, body_map, body_planner
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

  BodyNavSeat* = ref object
    index*: int
    cache*: BodySeatCache
    planner*: BodyPlanner
    job*: BodyPlanJob
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

  PlanningVisit* = object
    tick*: int
    seat*: int
    revision*: uint64
    units*: int
    completed*: bool

  DangerRebuild* = object
    tick*: int
    seat*: int
    sourceCount*: int

  BodyNavSystem* = ref object
    map*: BodyMap
    seats*: seq[BodyNavSeat]
    dangerK*: int
    lastPlanSeat*: int
    planningTrace: seq[PlanningVisit]
    dangerTrace: seq[DangerRebuild]
    planningTraceLen: int
    dangerTraceLen: int

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
                       traceCapacity = 0): BodyNavSystem =
  ## Activation-barrier constructor: route rasters, planner workspaces,
  ## follower path buffers, and danger buffers are all allocated here.
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
  result.dangerK = dangerK
  result.lastPlanSeat = -1
  result.planningTrace = newSeq[PlanningVisit](traceCapacity)
  result.dangerTrace = newSeq[DangerRebuild](traceCapacity)
  result.seats = newSeq[BodyNavSeat](seatCount)
  let dangerGeometry = initDangerGeometry(liveGunRangePx)
  for index in 0 ..< seatCount:
    let cache = newBodySeatCache(map)
    let planner = newBodyPlanner(map)
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

proc recordDanger(system: BodyNavSystem, value: DangerRebuild) {.inline.} =
  if system.dangerTraceLen < system.dangerTrace.len:
    system.dangerTrace[system.dangerTraceLen] = value
    inc system.dangerTraceLen

proc recordPlanning(system: BodyNavSystem, value: PlanningVisit) {.inline.} =
  if system.planningTraceLen < system.planningTrace.len:
    system.planningTrace[system.planningTraceLen] = value
    inc system.planningTraceLen

proc planningTraceSnapshot*(system: BodyNavSystem): seq[PlanningVisit] =
  result = newSeq[PlanningVisit](system.planningTraceLen)
  for index in 0 ..< system.planningTraceLen:
    result[index] = system.planningTrace[index]

proc dangerTraceSnapshot*(system: BodyNavSystem): seq[DangerRebuild] =
  result = newSeq[DangerRebuild](system.dangerTraceLen)
  for index in 0 ..< system.dangerTraceLen:
    result[index] = system.dangerTrace[index]

proc setSeatActive*(system: BodyNavSystem, seat: int, active: bool) =
  system.seats[seat].active = active

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

proc selectDangerSources(seat: BodyNavSeat, input: DangerInput) =
  ## Fixed-size insertion selection of the nearest eight. The caller has
  ## already applied fog, team, noShoot, protect, and liveness filtering.
  var distances: array[MaxDangerSources, int64]
  seat.selectedDangerCount = 0
  for candidate in input.candidates:
    let dx = int64(candidate.pos.x - input.selfXy.x)
    let dy = int64(candidate.pos.y - input.selfXy.y)
    let distance = dx * dx + dy * dy
    var insertion = seat.selectedDangerCount
    while insertion > 0 and dangerCandidateLess(distance,
        candidate.seatIndex, distances[insertion - 1],
        seat.selectedDangerSeats[insertion - 1]):
      dec insertion
    if insertion >= MaxDangerSources:
      continue
    let newCount = min(MaxDangerSources, seat.selectedDangerCount + 1)
    var cursor = newCount - 1
    while cursor > insertion:
      distances[cursor] = distances[cursor - 1]
      seat.selectedDangerSeats[cursor] = seat.selectedDangerSeats[cursor - 1]
      seat.selectedDangerPoints[cursor] = seat.selectedDangerPoints[cursor - 1]
      dec cursor
    distances[insertion] = distance
    seat.selectedDangerSeats[insertion] = candidate.seatIndex
    seat.selectedDangerPoints[insertion] = candidate.pos
    seat.selectedDangerCount = newCount

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

proc runPlanningWork(system: BodyNavSystem, tick, budgetLimit: int,
    evaluationOrder: openArray[int] = []): int =
  ## One persisted seat-index round robin owns the server-wide budget.
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
      system.recordPlanning(PlanningVisit(tick: tick, seat: index,
        revision: revision, units: units, completed: seat.job.planFinished))
      if seat.job.planSucceeded:
        seat.installCompletedPath()
      if budget == 0:
        break
      if units == 0 and seat.job.planPending:
        raise newException(BodyMapError,
          "pending plan made no progress under available budget")
    inc scanned
    index = (index + 1) mod system.seats.len
  budgetLimit - budget

proc runPlanningTick*(system: BodyNavSystem, tick: int,
    evaluationOrder: openArray[int] = []): int =
  system.runPlanningWork(tick, ColdPlanBudgetPerTick, evaluationOrder)

proc prewarmColdPlans*(system: BodyNavSystem) =
  ## Activation-barrier cold-plan drain.
  ##
  ## This is intentionally off-tick work for the §10 activation barrier. The
  ## 256-unit `runPlanningTick` budget still governs PLAYING ticks; this API is
  ## not a playing-tick shortcut. It drains repeated scheduler chunks through
  ## the same persisted seat-index round robin, records barrier visits with
  ## `tick = -1`, and publishes paths through the ordinary completion install
  ## path.
  while system.hasPendingPlan:
    discard system.runPlanningWork(-1, ColdPlanBudgetPerTick)

proc planCursor*(system: BodyNavSystem): int = system.lastPlanSeat

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
    movingTarget = false, profile = shellTypes.cpDefault): BodyPoint =
  let seat = system.seats[seatIndex]
  if seat.blockedPenalty.isSome and
      tick >= seat.blockedPenalty.get.untilTick:
    seat.blockedPenalty = none(tuple[pos: BodyPoint, untilTick: int])
  let desired = goal.goalPoint
  let goalCell = system.map.cellOf(desired)
  let previousCell = if seat.desiredGoal.isSome:
    some(system.map.cellOf(seat.desiredGoal.get)) else: none(BodyPoint)
  let goalMoved = previousCell.isNone or
    abs(goalCell.x - previousCell.get.x) > ReplanGoalCells or
    abs(goalCell.y - previousCell.get.y) > ReplanGoalCells
  let movingReplan = movingTarget and not seat.job.planPending and
    tick - seat.lastPlanTick >= PlanMovingReplanTicks
  let profileChanged = seat.desiredProfile != profile
  let forcedReplan = not seat.job.planPending and seat.stuckTicks >= StuckTicks
  if forcedReplan:
    if seat.lastFollowReplanTick.isSome and
        tick - seat.lastFollowReplanTick.get <= FollowStuckWindowTicks:
      inc seat.followStuckEvents
    seat.lastFollowReplanTick = some(tick)
    seat.blockedPenalty = some((selfXy, tick + FollowBlockTtlTicks))
    inc seat.followReplans
  if goalMoved or profileChanged or
      (seat.pathLen == 0 and not seat.job.planPending) or
      forcedReplan or movingReplan:
    inc seat.revision
    let avoid = if seat.blockedPenalty.isSome:
      some(seat.blockedPenalty.get.pos) else: none(BodyPoint)
    system.replacePlan(seatIndex, seat.revision, selfXy, goal, profile, avoid)
    seat.desiredMoving = movingTarget
    seat.lastPlanTick = tick
    seat.stuckTicks = 0
  seat.followerWaypoint(selfXy)
