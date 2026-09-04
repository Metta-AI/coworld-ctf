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
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_cache, body_hazard, body_map, body_planner
import types as shellTypes

export body_hazard.BodyHazardField, body_hazard.hasField,
  body_hazard.arrivalAt, body_hazard.staysDryUntil,
  body_hazard.HazardNeverArrives

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

  SafeHorizonBucketTicks* = 48
    ## Re-mint cadence of the zone-safe flow field, in ticks (2 s at 24 fps).
    ## The seed set is a threshold on a STATIC array, so it changes only when
    ## the horizon crosses cell arrivals; bucketing turns "re-solve every tick"
    ## into "re-solve about once per two seconds" and every tick in between
    ## into an O(1) raster readout.
  SafeHorizonCrossingTicks* = 192
    ## Slack for actually walking to the ground the field points at.
  SafeHorizonTicks* = SafeHorizonBucketTicks + SafeHorizonCrossingTicks
    ## INVARIANT: SafeHorizonTicks >= SafeHorizonBucketTicks + a crossing
    ## budget. The field is minted with a FORWARD threshold, so it is
    ## stale-conservative by design: it points at ground that survives
    ## SafeHorizonTicks and is re-minted a full bucket before that guarantee
    ## expires. Shrinking the horizon below the bucket would let the field
    ## recommend ground that paints before the next re-mint.
  WorldFieldClassZoneSafe* = 1
    ## World-field class ordinal, namespaced into the key's high bits so a
    ## world key can never collide with a per-seat route key (a raster cell
    ## index). Class 0 is reserved for "not a world field".

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
    pboWorldSuspended  ## a WORLD field mint ran out of leftover budget (seat -1)
    pboWorldCompleted  ## a world field mint published (seat -1)
      ## World-field outcomes exist so world minting can never starve SILENTLY.
      ## The round-3633 postmortem (a flat server-wide budget starved 16 seats
      ## and 14/16 cogs died standing on spawn) is the reason world fields ride
      ## strictly BEHIND every seat plan and every seat mint, and the reason
      ## their stalls are on the operator-visible channel rather than a
      ## capacity-gated trace.

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

  BodyWorldFields* = ref object
    ## The SERVER-WIDE field tier, beside the per-seat one.
    ##
    ## A class field ("ground that stays dry", later "nearest hopper") is the
    ## SAME field for every seat; minting it per-seat 32x is pure waste, and
    ## MaxRouteFieldsPerSeat = 4 would thrash the seat tier immediately. One
    ## shared store, one shared minter, at most one mint in flight.
    ##
    ## It carries its OWN BodyFieldMinter because BodyFieldMinter owns a single
    ## heap: a world mint sharing the seat minter would clobber a suspended
    ## seat mint's frontier mid-search.
    store*: BodySeatCache
    minter*: BodyFieldMinter
    job*: BodyMintJob
    pendingKey*: int   ## key of the mint in flight, -1 when idle
    readyKey*: int     ## key of the published field, -1 when none
    mintsCompleted*: int
    mintsStarted*: int

  BodyNavSystem* = ref object
    map*: BodyMap
    seats*: seq[BodyNavSeat]
    minter*: BodyFieldMinter
    hazard*: BodyHazardField
      ## Projected zone paint-arrival, empty unless the episode installed one.
      ## READ-ONLY: see body_hazard's module doc for why the nav layer must
      ## never write back to the zone field.
    hazardTickOffset*: int
      ## THE HAZARD FIELD SPEAKS A DIFFERENT CLOCK. Its arrival values are the
      ## ZONE SCHEDULE's elapsed ticks (`sim.tickCount - sim.gameStartTick`,
      ## the clock zonePaintedForDamageAt charges damage against), while every
      ## tick the shell hands the nav layer is the absolute sim tick. Comparing
      ## the two directly makes the whole board read as already painted the
      ## moment a lobby is longer than the schedule. This offset is the ONE
      ## conversion, applied at the two entry points that mint a tick into the
      ## hazard's domain (replacePlan and the world-field horizon).
    hazardAware*: bool
      ## Activation-time arming. Chosen once, at the activation barrier,
      ## because it decides whether the per-seat planners allocate their
      ## path-length column at all.
    world*: BodyWorldFields
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
                       hazardAware = false): BodyNavSystem =
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
  result.minter = newBodyFieldMinter(map)
  result.hazardAware = hazardAware
  if hazardAware:
    result.world = BodyWorldFields(store: newBodySeatCache(map),
      minter: newBodyFieldMinter(map), pendingKey: -1, readyKey: -1)
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
    let planner = newBodyPlanner(map, hazardAware)
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
                  avoid = none(BodyPoint), nowTick = 0) =
  let seat = system.seats[seatIndex]
  if seat.job.planPending:
    seat.cache.cancelPlan(seat.job)
  seat.revision = revision
  seat.desiredGoal = some(goal.goalPoint)
  seat.desiredProfile = profile
  seat.planner.startPlan(seat.cache, seat.job, revision, selfXy,
    goal, profile, avoid, nowTick)
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
      let units = seat.planner.stepPlan(seat.cache, seat.danger, seat.job,
        budget, system.hazard)
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

proc worldFieldKey*(class, bucket: int): int {.inline.} =
  ## Namespaced world-field key. The per-seat tier keys a field by its goal
  ## cell's raster index (always < 2^40 on any board we can allocate), so the
  ## class ordinal in the high bits keeps the two key spaces disjoint even if a
  ## future field class shares a store.
  (class shl 40) or (bucket and ((1 shl 40) - 1))

proc zoneSafeBucket*(tick: int): int {.inline.} =
  ## The horizon bucket. A PURE FUNCTION OF THE TICK — nothing a play does can
  ## move it, so no play can pump the re-mint rate. That is the whole reason
  ## the seed threshold is bucketed rather than read live (metronome test:
  ## "world re-mint rate is bounded by the horizon bucket").
  (tick + SafeHorizonTicks) div SafeHorizonBucketTicks

proc zoneSafeKey*(tick: int): int {.inline.} =
  worldFieldKey(WorldFieldClassZoneSafe, zoneSafeBucket(tick))

proc zoneClockTick*(system: BodyNavSystem, tick: int): int {.inline.} =
  ## An absolute sim tick expressed in the hazard field's own clock.
  tick - system.hazardTickOffset

proc installZoneHazard*(system: BodyNavSystem,
                        arrival: openArray[uint16],
                        sourceW, sourceH, sourceCellPx: int,
                        clockOffset = 0) =
  ## Installs a projected snapshot of the zone module's paint DAMAGE surface.
  ## Called from the one seam that owns the zone field (ctf/server.nim), once
  ## per actual field build. A dark or hazard-unaware system ignores it, so the
  ## call site needs no second flag test.
  ##
  ## This is the ONLY entry point that writes system.hazard. Everything
  ## downstream reads it.
  if system == nil or not system.hazardAware:
    return
  system.hazard = projectHazardField(system.map.gridWidth,
    system.map.gridHeight, NavCell, sourceW, sourceH, sourceCellPx, arrival)
  system.hazardTickOffset = clockOffset
  # A new hazard surface invalidates every published safe-ground field: the
  # seed predicate reads the array that just changed. Drop the ready key rather
  # than serve a field minted against the previous episode's paint.
  #
  # 🚨 KNOWN DEFECT — NOT FIXED HERE. Dropping readyKey is NOT sufficient.
  # The world store is an LRU over slots keyed by zoneSafeKey(bucket), and
  # `beginMintDryGround` short-circuits to mjsComplete when
  # `routeSlotReady(key)` finds a RESIDENT slot for that key. So if the new
  # hazard arrives inside the same horizon bucket as the old one, the next
  # world mint re-adopts the slot minted against the PREVIOUS paint surface
  # and republishes it as ready — a stale safe field, for up to one bucket
  # (48 ticks).
  #
  # Latent in this commit: nothing consumes the field yet beyond tests. It
  # goes LIVE the moment #409's nav hints or #410's zone_safe_ground target
  # gain a real consumer, where it shows up as a retreat direction pointing at
  # ground the new schedule already floods.
  #
  # FIX SHAPE (deliberately not attempted in a reference branch): fold a
  # HAZARD EPOCH into worldFieldKey alongside the class and the bucket, and
  # derive horizonTick from the bucket rather than from the raw tick, so a key
  # identifies exactly one (surface, horizon) pair and a resident slot can
  # never answer for a different surface. Bump the epoch here.
  if system.world != nil:
    system.world.readyKey = -1

proc zoneSafeReady*(system: BodyNavSystem): bool =
  system != nil and system.world != nil and system.world.readyKey >= 0 and
    system.world.store.routeSlotReady(system.world.readyKey)

proc zoneSafeSlot(system: BodyNavSystem): int =
  if not system.zoneSafeReady:
    return -1
  system.world.store.findRouteSlot(system.world.readyKey)

proc zoneSafeDistancePx*(system: BodyNavSystem,
                         point: BodyPoint): Option[float] =
  ## Geodesic px from `point` to the nearest ground that stays dry through the
  ## horizon. `none` when the field is not published, or when no safe ground is
  ## reachable from this cell — never a fabricated zero.
  let slot = system.zoneSafeSlot()
  if slot < 0:
    return none(float)
  let cell = system.map.nearestWalkable(system.map.cellOf(point))
  if not system.map.cellWalkable(cell):
    return none(float)
  let distance = system.world.store.routeDistanceAt(slot,
    cell.y * system.map.gridWidth + cell.x)
  if distance.classify == fcInf:
    return none(float)
  some(distance * NavCell.float)

proc zoneSafeStep*(system: BodyNavSystem,
                   point: BodyPoint): Option[BodyPoint] =
  ## One step of the safe-ground FLOW FIELD: the center of the next nav cell
  ## toward dry ground. `none` when the field is not published, when this cell
  ## is already a source (already safe), or when nothing is reachable.
  ##
  ## The parent-direction byte is `1 + reverseNeighborIndex(delta)` of the step
  ## that REACHED this cell, so the parent — the cell one step closer to a
  ## source — is `cell + Neighbors[hop - 1]`.
  let slot = system.zoneSafeSlot()
  if slot < 0:
    return none(BodyPoint)
  let cell = system.map.nearestWalkable(system.map.cellOf(point))
  if not system.map.cellWalkable(cell):
    return none(BodyPoint)
  let index = cell.y * system.map.gridWidth + cell.x
  if system.world.store.routeDistanceAt(slot, index).classify == fcInf:
    return none(BodyPoint)
  let hop = system.world.store.routeHopAt(slot, index).int
  if hop <= 0 or hop > Neighbors.len:
    return none(BodyPoint)
  let delta = Neighbors[hop - 1]
  some(cellCenter((cell.x + delta[0], cell.y + delta[1])))

proc zoneSafeDirBrads*(system: BodyNavSystem,
                       point: BodyPoint): Option[int] =
  ## The retreat flow direction at `point`, in brads (0..255, 0 = east,
  ## counter-clockwise), or `none` when this cell is already safe / no field.
  ##
  ## The brads are computed from the FLOW FIELD's own 8-neighbour step, not
  ## from a bearing to some rect edge — so it points down the corridor rather
  ## than into the wall the corridor runs beside. Eight exact octants, no
  ## trigonometry, no float: a flow step is one of eight deltas, and each maps
  ## to an exact multiple of 32 brads.
  let step = system.zoneSafeStep(point)
  if step.isNone:
    return none(int)
  let
    cell = system.map.nearestWalkable(system.map.cellOf(point))
    target = system.map.cellOf(step.get)
    dx = target.x - cell.x
    dy = target.y - cell.y
  if dx == 0 and dy == 0:
    return none(int)
  # The engine's brad convention (sim_types.Player.aimBrads): 0 = east (+x),
  # counter-clockwise on screen, 64 = north — and screen +y points DOWN, so
  # south is 192. Indexed [dx + 1][dy + 1]; the centre entry is unreachable
  # (dx == dy == 0 returned above).
  const OctantBrads = [
    [96'i32, 128, 160],   ## dx = -1: NW,  W,  SW
    [64,       0, 192],   ## dx =  0:  N,  --,  S
    [32,       0, 224]]   ## dx = +1: NE,  E,  SE
  some(OctantBrads[dx + 1][dy + 1].int)

proc zoneSafeTarget*(system: BodyNavSystem,
                     point: BodyPoint): Option[BodyPoint] =
  ## The nearest ground that stays dry through the horizon, as a POINT the
  ## planner can be given as a goal.
  ##
  ## Walking the flow field's parent chain to its source: the distance
  ## strictly decreases at every step (that is what a Dijkstra parent IS), so
  ## the walk terminates, and the cell it terminates on is a SEED — ground
  ## that survives the horizon.
  ##
  ## THE BOUND IS THE CELL COUNT, NOT W + H. An earlier draft bounded the walk
  ## at gridWidth + gridHeight + 2, which is the length of a straight line
  ## across the board and nothing like the length of a geodesic through a
  ## maze. On a real Season 2 board the parent chain out of a pocket routinely
  ## exceeds it. A simple path visits each cell at most once, so the only
  ## honest bound is the cell count.
  ##
  ## AND A TRUNCATED WALK MUST RETURN NOTHING. The same earlier draft returned
  ## `some(cell)` after breaking on the bound — mid-chain ground that is still
  ## on the flooding side of the board, handed to the planner as a "safe"
  ## goal. That is worst exactly where it matters: late-game, in the mazes
  ## where the chain is longest and the paint is closest. The post-loop check
  ## below demands `routeHopAt == 0` (a genuine source) and otherwise returns
  ## none, so a corrupted or truncated field degrades to "no answer" instead
  ## of to "a confident wrong answer".
  ##
  ## `none` means "already standing on surviving ground", or no field, or
  ## nothing reachable, or the walk did not reach a source — all of them cases
  ## where the caller must keep the play's own goal rather than invent one.
  let slot = system.zoneSafeSlot()
  if slot < 0:
    return none(BodyPoint)
  var cell = system.map.nearestWalkable(system.map.cellOf(point))
  if not system.map.cellWalkable(cell):
    return none(BodyPoint)
  var index = cell.y * system.map.gridWidth + cell.x
  if system.world.store.routeDistanceAt(slot, index).classify == fcInf:
    return none(BodyPoint)
  var steps = 0
  # A simple path visits each cell at most once.
  let bound = system.map.gridWidth * system.map.gridHeight
  var truncated = false
  while true:
    let hop = system.world.store.routeHopAt(slot, index).int
    if hop <= 0 or hop > Neighbors.len:
      break
    let delta = Neighbors[hop - 1]
    cell = (cell.x + delta[0], cell.y + delta[1])
    index = cell.y * system.map.gridWidth + cell.x
    inc steps
    if steps > bound:
      truncated = true
      break
  if truncated or system.world.store.routeHopAt(slot, index) != 0'u8:
    # Not a source cell: we ran out of walk before reaching dry ground. Say so
    # rather than hand back the flooding cell we happened to stop on.
    return none(BodyPoint)
  if steps == 0:
    return none(BodyPoint)   ## already a source cell: already safe
  some(cellCenter(cell))

proc navHintsFor*(system: BodyNavSystem, point: BodyPoint, tick: int):
    tuple[ticksUntilPaintHere, ticksToSafety, safeDistPx,
          zoneSafeDirBrads: int] =
  ## The four integers the play view's nav section carries, all in the
  ## engine's own units and all spelling "not available" as -1.
  result = (-1, -1, -1, -1)
  if system == nil or not system.hazard.hasField:
    return
  let
    zoneTick = system.zoneClockTick(tick)
    cell = system.map.cellOf(point)
    arrival = system.hazard.arrivalAt(cell.x, cell.y)
  if arrival < HazardNeverArrives.int:
    result.ticksUntilPaintHere = max(0, arrival - zoneTick)
  let distance = system.zoneSafeDistancePx(point)
  if distance.isSome:
    result.safeDistPx = int(distance.get)
    result.ticksToSafety =
      estimatedArrivalTicks(0, distance.get)
  let brads = system.zoneSafeDirBrads(point)
  if brads.isSome:
    result.zoneSafeDirBrads = brads.get

proc recordWorldBudget(system: BodyNavSystem, tick, units: int,
                       outcome: PlanBudgetOutcome) =
  if tick < 0 or units == 0:
    return
  system.planBudgetEvents.add(PlanBudgetEvent(tick: tick, seat: -1,
    revision: uint64(system.world.job.routeKey), visits: system.world.mintsStarted,
    units: units, outcome: outcome))

proc runWorldFieldWork(system: BodyNavSystem, tick: int, budget: var int) =
  ## World-field minting, on whatever the seat plans AND the seat mints left
  ## behind. Strictly lowest priority, by construction: this proc is only
  ## reached with the leftover tail.
  ##
  ## A mint in flight is NEVER cancelled when the horizon bucket rolls over.
  ## Cancel-and-restart on every bucket boundary is how a field that takes
  ## longer than a bucket to solve never publishes at all; letting it finish
  ## and publishing a bucket-stale field is exactly the "stale but published is
  ## still served" rule, and SafeHorizonCrossingTicks is the slack that pays
  ## for it.
  let world = system.world
  if world == nil or not system.hazard.hasField:
    return
  let zoneTick = system.zoneClockTick(tick)
  if not world.job.mintPending:
    let desired = zoneSafeKey(zoneTick)
    if desired == world.readyKey or budget <= 0:
      return
    world.minter.beginMintDryGround(world.store, world.job, desired,
      zoneTick + SafeHorizonTicks, uint64(desired))
    world.pendingKey = desired
    inc world.mintsStarted
    if world.job.mintFinished:
      # The slot was already published for this key (LRU hit).
      world.readyKey = desired
      world.pendingKey = -1
      return
  if budget <= 0:
    return
  let units = world.minter.stepMint(world.store, world.job, budget,
    system.hazard)
  if world.job.mintFinished:
    world.readyKey = world.pendingKey
    world.pendingKey = -1
    inc world.mintsCompleted
    system.recordWorldBudget(tick, units, pboWorldCompleted)
  else:
    system.recordWorldBudget(tick, units, pboWorldSuspended)

proc planBudgetPerTick*(system: BodyNavSystem): int =
  ## The pooled cold-work budget for one tick: ColdPlanBudgetPerTick for
  ## every configured seat (see the module comment for why it scales).
  ColdPlanBudgetPerTick * max(1, system.seats.len)

proc runPlanningTick*(system: BodyNavSystem, tick: int,
    evaluationOrder: openArray[int] = []): int =
  let limit = system.planBudgetPerTick
  var leftover = limit - system.runPlanningWork(tick, limit, evaluationOrder)
  # World fields spend ONLY what the seat pass left. Calling this here rather
  # than inside runPlanningWork is the structural guarantee that no world mint
  # can ever be scheduled ahead of a pending seat plan or seat mint.
  if leftover > 0:
    system.runWorldFieldWork(tick, leftover)
  limit - leftover

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
  # The last requested plan was cancelled before it landed (setStandingIntent
  # drops the plan in flight on every new order) and the loaded path
  # predates that request: ask again rather than follow the stale route.
  # Idle only — a FAILED plan keeps the historical retry rules (empty path
  # or a stuck follower), because re-requesting a doomed plan every tick
  # for every seat is real body-tick time on a 32-seat board.
  let planLost = seat.job.stage == pjsIdle and
    seat.pathRevision != seat.revision
  if forcedReplan:
    if seat.lastFollowReplanTick.isSome and
        tick - seat.lastFollowReplanTick.get <= FollowStuckWindowTicks:
      inc seat.followStuckEvents
    seat.lastFollowReplanTick = some(tick)
    seat.blockedPenalty = some((selfXy, tick + FollowBlockTtlTicks))
    inc seat.followReplans
  if goalMoved or profileChanged or
      (seat.pathLen == 0 and not seat.job.planPending) or
      forcedReplan or movingReplan or planLost:
    inc seat.revision
    let avoid = if seat.blockedPenalty.isSome:
      some(seat.blockedPenalty.get.pos) else: none(BodyPoint)
    system.replacePlan(seatIndex, seat.revision, selfXy, goal, profile, avoid,
      system.zoneClockTick(tick))
    seat.desiredMoving = movingTarget
    seat.lastPlanTick = tick
    seat.stuckTicks = 0
  seat.followerWaypoint(selfXy)
