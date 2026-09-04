## Laws for the zone-aware planner: the hazard projection, multi-source field
## minting, the safe-by-time cost term, and the shared zone-safe flow field.
##
## The load-bearing assertions here are the NEGATIVE ones. A dark build must
## produce the same route bit for bit, and an armed build must never let world
## minting take a unit of budget away from a seat plan — that is the round-3633
## failure ("14/16 cogs died standing on spawn") this lane must not re-create.

import std/[algorithm, heapqueue, math, options, sequtils, tables, unittest]
import ../src/shell/body_cache
import ../src/shell/body_hazard
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
import ../src/shell/types as shellTypes

const
  TestSqrt2 = sqrt(2.0)
  TestNeighbors = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1)]
  GunRangePx = 331

# ── fixtures ────────────────────────────────────────────────────────────────

proc openMap(width = 384, height = 160): BodyMap =
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = true
  newBodyMap(walkable, width, height, 2, @[(16, 16), (width - 17, height - 17)])

const
  GateWidth = 320
  GateHeight = 240
  GateWallX0 = 152
  GateWallX1 = 168
  TopGapY0 = 40
  TopGapY1 = 88
  BottomGapY0 = 152
  BottomGapY1 = 200

proc twoGateMap(): BodyMap =
  ## One room, one wall across it, two ways through: a NEAR gate straight
  ## ahead and a FAR gate down the board. Start and goal sit level with the
  ## near gate, so the shipped (zone-blind) planner takes it every time and any
  ## route through the far gate is unambiguously caused by the hazard term.
  var walkable = newSeq[bool](GateWidth * GateHeight)
  for y in 8 ..< GateHeight - 8:
    for x in 8 ..< GateWidth - 8:
      let blocked = x in GateWallX0 .. GateWallX1 and
        y notin TopGapY0 .. TopGapY1 and y notin BottomGapY0 .. BottomGapY1
      walkable[y * GateWidth + x] = not blocked
  newBodyMap(walkable, GateWidth, GateHeight, 2, @[(32, 64), (288, 64)])

proc neverField(map: BodyMap): BodyHazardField =
  ## An installed field on which nothing ever paints: the inert-armed case.
  result = BodyHazardField(values: newSeq[uint16](
    map.gridWidth * map.gridHeight), gridW: map.gridWidth,
    gridH: map.gridHeight, sourceW: map.gridWidth, sourceH: map.gridHeight,
    sourceCellPx: NavCell)
  for value in result.values.mitems:
    value = HazardNeverArrives

proc paintedNearGate(map: BodyMap, arrivalTick: int): BodyHazardField =
  ## Paint exactly the near gate's mouth, early. Everything else stays dry.
  result = neverField(map)
  for cellY in 0 ..< map.gridHeight:
    for cellX in 0 ..< map.gridWidth:
      let center = cellCenter((cellX, cellY))
      if center.x in GateWallX0 - 24 .. GateWallX1 + 24 and
          center.y in TopGapY0 - 8 .. TopGapY1 + 8:
        result.values[cellY * map.gridWidth + cellX] = uint16(arrivalTick)

# ── oracles ─────────────────────────────────────────────────────────────────

proc multiSourceOracle(map: BodyMap,
                       seeds: openArray[BodyPoint]): seq[float] =
  ## An independent multi-source Dijkstra over the nav grid. Used two ways:
  ## directly, and as "min over the per-source single-source fields", which is
  ## the definition multi-source seeding has to satisfy.
  let cells = map.gridWidth * map.gridHeight
  result = newSeq[float](cells)
  for distance in result.mitems:
    distance = Inf
  var queue = initHeapQueue[tuple[distance: float, x, y: int]]()
  for seed in seeds:
    if not map.cellWalkable(seed):
      continue
    result[seed.y * map.gridWidth + seed.x] = 0.0
    queue.push((0.0, seed.x, seed.y))
  while queue.len > 0:
    let current = queue.pop()
    let index = current.y * map.gridWidth + current.x
    if current.distance > result[index]:
      continue
    for delta in TestNeighbors:
      let
        nx = current.x + delta[0]
        ny = current.y + delta[1]
      if not map.cellWalkable((nx, ny)):
        continue
      if delta[0] != 0 and delta[1] != 0 and
          (not map.cellWalkable((nx, current.y)) or
           not map.cellWalkable((current.x, ny))):
        continue
      let nextIndex = ny * map.gridWidth + nx
      let nextDistance = current.distance +
        (if delta[0] != 0 and delta[1] != 0: TestSqrt2 else: 1.0)
      if nextDistance < result[nextIndex]:
        result[nextIndex] = nextDistance
        queue.push((nextDistance, nx, ny))

proc mintedDistances(cache: BodySeatCache, map: BodyMap,
                     key: int): seq[float] =
  let slot = cache.findRouteSlot(key)
  doAssert slot >= 0
  result = newSeq[float](map.gridWidth * map.gridHeight)
  for index in 0 ..< result.len:
    result[index] = cache.routeDistanceAt(slot, index)

proc finishMint(minter: BodyFieldMinter, cache: BodySeatCache,
                job: var BodyMintJob, hazard = BodyHazardField()) =
  var guard = 0
  while job.mintPending:
    var budget = 100_000
    discard minter.stepMint(cache, job, budget, hazard)
    inc guard
    doAssert guard < 100_000

proc emptyDanger(map: BodyMap): BodyDangerField =
  BodyDangerField(values: newSeq[float32](map.gridWidth * map.gridHeight),
    gridW: map.gridWidth, gridH: map.gridHeight)

proc plannedPath(map: BodyMap, start, requestedGoal: BodyPoint,
                 hazard: BodyHazardField, hazardAware: bool,
                 nowTick = 0): seq[BodyPoint] =
  let planner = newBodyPlanner(map, hazardAware)
  let cache = newBodySeatCache(map)
  let danger = emptyDanger(map)
  var job: BodyPlanJob
  let goal = map.validateGoal(requestedGoal, start).get
  planner.startPlan(cache, job, 1, start, goal, shellTypes.cpDefault,
    none(BodyPoint), nowTick)
  var guard = 0
  while job.planPending:
    var budget = 100_000
    discard planner.stepPlan(cache, danger, job, budget, hazard)
    inc guard
    doAssert guard < 100_000
  doAssert job.planSucceeded
  planner.pathSnapshot(job)

proc crossingY(path: openArray[BodyPoint]): int =
  ## The y the route was at when it passed through the wall band.
  result = -1
  for point in path:
    if point.x in GateWallX0 .. GateWallX1:
      return point.y

# ── suites ──────────────────────────────────────────────────────────────────

suite "zone hazard projection":
  test "min-projection is conservative and never invents a hazard":
    ## 4px source, 8px nav: every nav cell must read the EARLIEST arrival of
    ## the four source cells it covers. Later would be a lie that gets a cog
    ## killed; earlier would be a hazard the sim does not charge.
    const
      SourceW = 16
      SourceH = 8
    var arrival = newSeq[uint16](SourceW * SourceH)
    for index in 0 ..< arrival.len:
      arrival[index] = uint16(100 + index)
    # A wall/never quarter must not raise the block's verdict.
    arrival[SourceW + 1] = HazardNeverArrives
    let field = projectHazardField(SourceW div 2, SourceH div 2, 8,
      SourceW, SourceH, 4, arrival)
    check field.hasField
    check field.gridW == SourceW div 2
    check field.gridH == SourceH div 2
    for cellY in 0 ..< field.gridH:
      for cellX in 0 ..< field.gridW:
        var expected = HazardNeverArrives.int
        for sourceY in cellY * 2 .. cellY * 2 + 1:
          for sourceX in cellX * 2 .. cellX * 2 + 1:
            expected = min(expected, arrival[sourceY * SourceW + sourceX].int)
        check field.arrivalAt(cellX, cellY) == expected
        # The conservatism law, stated directly.
        for sourceY in cellY * 2 .. cellY * 2 + 1:
          for sourceX in cellX * 2 .. cellX * 2 + 1:
            check field.arrivalAt(cellX, cellY) <=
              arrival[sourceY * SourceW + sourceX].int

  test "an all-wall source projects to ground that never paints":
    var arrival = newSeq[uint16](8 * 8)
    for value in arrival.mitems:
      value = HazardNeverArrives
    let field = projectHazardField(4, 4, 8, 8, 8, 4, arrival)
    for cellY in 0 ..< 4:
      for cellX in 0 ..< 4:
        check field.arrivalAt(cellX, cellY) == HazardNeverArrives.int
        check field.staysDryUntil(cellX, cellY, high(int32).int)
        check field.hazardRisk(cellX, cellY, 0) == 0.0

  test "a malformed or absent source arms nothing":
    ## Dark, off-grid, and mis-sized all read as "never paints", so no caller
    ## can turn a missing field into a phantom hazard.
    let dark = BodyHazardField()
    check not dark.hasField
    check dark.arrivalAt(0, 0) == HazardNeverArrives.int
    check dark.hazardRisk(0, 0, 10_000) == 0.0
    check projectHazardField(4, 4, 8, 8, 8, 4, newSeq[uint16](7)).hasField ==
      false
    let field = projectHazardField(4, 4, 8, 8, 8, 4, newSeq[uint16](64))
    check field.arrivalAt(-1, 0) == HazardNeverArrives.int
    check field.arrivalAt(0, 99) == HazardNeverArrives.int

  test "risk is zero far out, ramps in, and saturates on painted ground":
    var arrival = newSeq[uint16](4)
    for value in arrival.mitems:
      value = 1000'u16
    let field = projectHazardField(1, 1, 8, 2, 2, 4, arrival)
    check field.hazardRisk(0, 0, 1000 - HazardRiskRampTicks) == 0.0
    check field.hazardRisk(0, 0, 1000 - HazardRiskRampTicks - 500) == 0.0
    check field.hazardRisk(0, 0, 1000) == HazardRiskMax
    check field.hazardRisk(0, 0, 5000) == HazardRiskMax
    var previous = -1.0
    for eta in 1000 - HazardRiskRampTicks .. 1000:
      let value = field.hazardRisk(0, 0, eta)
      check value >= previous       ## monotone non-decreasing as the ETA slips
      check value <= HazardRiskMax  ## and finite: paint is priced, never banned
      previous = value

suite "multi-source field minting":
  test "multi-source seeding equals min over the single-source fields":
    let map = openMap()
    var seeds = @[(6, 4), (40, 14), (20, 9)]
    # Row-major order is the caller contract, and the reason ties resolve the
    # same way on every run.
    seeds.sort(proc(a, b: BodyPoint): int =
      result = cmp(a.y, b.y)
      if result == 0: result = cmp(a.x, b.x))
    let cache = newBodySeatCache(map)
    let minter = newBodyFieldMinter(map)
    var job: BodyMintJob
    minter.beginMintFromSet(cache, job, 7, seeds, 1)
    minter.finishMint(cache, job)
    check job.mintFinished
    check job.seedsFound == seeds.len
    let minted = mintedDistances(cache, map, 7)

    var expected = newSeq[float](minted.len)
    for index in 0 ..< expected.len:
      expected[index] = Inf
    for seed in seeds:
      let single = multiSourceOracle(map, [seed])
      for index in 0 ..< expected.len:
        expected[index] = min(expected[index], single[index])
    check minted == expected
    check minted == multiSourceOracle(map, seeds)

  test "multi-source suspension is chunk-independent":
    ## Determinism under resumption: the seed scan and the search must land on
    ## identical state whether they were spent in one slice or twenty.
    let map = openMap()
    let seeds = @[(6, 4), (20, 9), (40, 14)]
    let cacheA = newBodySeatCache(map)
    let cacheB = newBodySeatCache(map)
    let minterA = newBodyFieldMinter(map)
    let minterB = newBodyFieldMinter(map)
    var jobA, jobB: BodyMintJob
    minterA.beginMintFromSet(cacheA, jobA, 11, seeds, 1)
    minterB.beginMintFromSet(cacheB, jobB, 11, seeds, 1)
    var budgetA = 512
    discard minterA.stepMint(cacheA, jobA, budgetA)
    for _ in 0 ..< 8:
      var budgetB = 64
      discard minterB.stepMint(cacheB, jobB, budgetB)
    check jobA.workUnits == 512
    check jobB.workUnits == 512
    check jobA.mintPending  ## still suspended, so the fingerprint has frontier
                            ## state to compare, not just a finished raster
    check minterA.mintFingerprint(cacheA, jobA) ==
      minterB.mintFingerprint(cacheB, jobB)

  test "the seed buffer is bounded rather than allocated on a playing tick":
    let map = openMap()
    let cache = newBodySeatCache(map)
    let minter = newBodyFieldMinter(map)
    var job: BodyMintJob
    var tooMany: seq[BodyPoint]
    for index in 0 .. MaxMintSeeds:
      tooMany.add((1 + index mod 40, 1 + index div 40))
    expect BodyMapError:
      minter.beginMintFromSet(cache, job, 3, tooMany, 1)

  test "dry-ground seeding matches an oracle over the same threshold":
    let map = openMap()
    var hazard = neverField(map)
    # Paint the left half early; the right half never floods.
    for cellY in 0 ..< map.gridHeight:
      for cellX in 0 ..< map.gridWidth div 2:
        hazard.values[cellY * map.gridWidth + cellX] = 50'u16
    let cache = newBodySeatCache(map)
    let minter = newBodyFieldMinter(map)
    var job: BodyMintJob
    minter.beginMintDryGround(cache, job, 5, 100, 1)
    minter.finishMint(cache, job, hazard)
    check job.mintFinished

    var seeds: seq[BodyPoint]
    for cellY in 0 ..< map.gridHeight:
      for cellX in 0 ..< map.gridWidth:
        if map.cellWalkable((cellX, cellY)) and
            hazard.staysDryUntil(cellX, cellY, 100):
          seeds.add((cellX, cellY))
    check seeds.len > 0
    check job.seedsFound == seeds.len
    check mintedDistances(cache, map, 5) == multiSourceOracle(map, seeds)

  test "a seed set with no dry ground publishes an empty field, never a stall":
    let map = openMap()
    var hazard = neverField(map)
    for value in hazard.values.mitems:
      value = 10'u16
    let cache = newBodySeatCache(map)
    let minter = newBodyFieldMinter(map)
    var job: BodyMintJob
    minter.beginMintDryGround(cache, job, 9, 1000, 1)
    minter.finishMint(cache, job, hazard)
    check job.mintFinished
    check job.seedsFound == 0
    check cache.routeSlotReady(9)
    check mintedDistances(cache, map, 9).allIt(it.classify == fcInf)

suite "safe-by-time planner term":
  test "a dark planner and an inert-armed planner produce the same route":
    ## The regression gate. Three spellings of "nothing paints" must all
    ## reproduce the shipped route: no hazard field at all, a hazard-aware
    ## planner handed an empty field, and a hazard-aware planner handed a field
    ## on which every cell never arrives.
    let map = twoGateMap()
    let start: BodyPoint = (32, 64)
    let goal: BodyPoint = (288, 64)
    let shipped = plannedPath(map, start, goal, BodyHazardField(), false)
    check shipped.len > 0
    check plannedPath(map, start, goal, BodyHazardField(), true) == shipped
    check plannedPath(map, start, goal, neverField(map), true) == shipped
    # And on a plain open map, where the route is a straight line.
    let open = openMap()
    let openShipped = plannedPath(open, (16, 80), (352, 80),
      BodyHazardField(), false)
    check plannedPath(open, (16, 80), (352, 80), neverField(open), true) ==
      openShipped

  test "an armed planner routes around ground that paints before it arrives":
    let map = twoGateMap()
    let start: BodyPoint = (32, 64)
    let goal: BodyPoint = (288, 64)
    let shipped = plannedPath(map, start, goal, BodyHazardField(), false)
    check shipped.crossingY in TopGapY0 .. TopGapY1

    let armed = plannedPath(map, start, goal, paintedNearGate(map, 5), true)
    check armed.crossingY in BottomGapY0 .. BottomGapY1
    check armed[^1] == shipped[^1]  ## same goal, different way there

  test "paint stays crossable when it is the only way through":
    ## HazardRiskMax is finite ON PURPOSE. A desperate cog must still be able
    ## to plan through paint; an infinite price (or a hard prune) would hand
    ## the follower hasNoPath and stand it still, which is exactly how round
    ## 3633 killed 14 of 16 cogs.
    let map = twoGateMap()
    let start: BodyPoint = (32, 64)
    let goal: BodyPoint = (288, 64)
    var everywhere = neverField(map)
    for value in everywhere.values.mitems:
      value = 1'u16
    let armed = plannedPath(map, start, goal, everywhere, true, nowTick = 500)
    check armed.len > 0
    check armed[^1] == map.validateGoal(goal, start).get.goalPoint

  test "the arrival estimate is late, never early":
    ## An optimistic ETA under-prices ground that paints before we get there —
    ## the exact failure this term exists to fix — so the derate must keep the
    ## estimate at or behind top-speed travel.
    let topSpeedTicks = 1000.0 / (704.0 / 256.0)
    check estimatedArrivalTicks(0, 1000.0).float >= topSpeedTicks
    check estimatedArrivalTicks(0, 0.0) == 0
    check estimatedArrivalTicks(-1, 100.0) == estimatedArrivalTicks(0, 100.0)
    var previous = 0
    for pixels in 0 .. 400:
      let value = estimatedArrivalTicks(17, pixels.float)
      check value >= previous
      previous = value

suite "the shared zone-safe field":
  test "a dark system allocates no world tier and no path-length column":
    let map = openMap()
    let dark = newBodyNavSystem(map, 4, GunRangePx)
    check dark.world == nil
    check not dark.hazardAware
    check not dark.seats[0].planner.hazardAware
    check not dark.zoneSafeReady
    check dark.zoneSafeStep((64, 64)).isNone
    check dark.zoneSafeDistancePx((64, 64)).isNone
    # Installing on a dark system is a no-op, not a silent arming.
    dark.installZoneHazard(newSeq[uint16](64), 8, 8, 4)
    check not dark.hazard.hasField

  test "the flow field points at dry ground and shortens every step":
    let map = openMap()
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    var hazard = neverField(map)
    for cellY in 0 ..< map.gridHeight:
      for cellX in 0 ..< map.gridWidth div 2:
        hazard.values[cellY * map.gridWidth + cellX] = 20'u16
    system.hazard = hazard
    var tick = 0
    while not system.zoneSafeReady:
      discard system.runPlanningTick(tick)
      inc tick
      doAssert tick < 10_000
    var here: BodyPoint = (24, 80)
    var distance = system.zoneSafeDistancePx(here)
    check distance.isSome
    check distance.get > 0.0
    var steps = 0
    while system.zoneSafeStep(here).isSome:
      let next = system.zoneSafeStep(here).get
      let nextDistance = system.zoneSafeDistancePx(next)
      check nextDistance.isSome
      check nextDistance.get < distance.get
      here = next
      distance = nextDistance
      inc steps
      doAssert steps < 10_000
    check steps > 0
    # Terminating means we stand on a source cell: ground that stays dry.
    let cell = map.cellOf(here)
    check hazard.staysDryUntil(cell.x, cell.y, tick + SafeHorizonTicks)

  test "the world re-mint rate is bounded by the horizon bucket":
    ## The metronome gate. The re-mint key is a pure function of the tick, so
    ## nothing a play does can pump it; over a long run the number of mints
    ## STARTED can never exceed the number of bucket boundaries crossed.
    check zoneSafeBucket(0) == zoneSafeBucket(0)
    check zoneSafeBucket(0) == zoneSafeBucket(SafeHorizonBucketTicks - 1)
    check zoneSafeBucket(SafeHorizonBucketTicks) != zoneSafeBucket(0)
    check zoneSafeKey(0) != worldFieldKey(0, zoneSafeBucket(0))
    check SafeHorizonTicks >= SafeHorizonBucketTicks + SafeHorizonCrossingTicks

    let map = openMap(192, 96)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    system.hazard = neverField(map)
    const Ticks = 600
    for tick in 0 ..< Ticks:
      discard system.runPlanningTick(tick)
    let buckets = zoneSafeBucket(Ticks - 1) - zoneSafeBucket(0) + 1
    check system.world.mintsStarted <= buckets
    check system.world.mintsStarted >= 1
    check system.world.mintsCompleted >= 1

  test "world minting never delays a seat plan":
    ## The round-3633 regression gate, stated as an equality rather than a
    ## threshold: an armed roster must reach its plans on exactly the same tick
    ## a dark roster does, because world fields only ever spend the tail the
    ## seat pass left behind.
    const Seats = 16
    let map = openMap(512, 256)
    let start: BodyPoint = (16, 128)
    let requested: BodyPoint = (480, 128)

    proc ticksToAllPlans(hazardAware: bool): int =
      let system = newBodyNavSystem(map, Seats, GunRangePx,
        hazardAware = hazardAware)
      if hazardAware:
        system.hazard = neverField(map)
      let goal = map.validateGoal(requested, start).get
      for seat in 0 ..< Seats:
        system.replacePlan(seat, 1, start, goal)
      var tick = 0
      while system.pendingPlanCount > 0:
        discard system.runPlanningTick(tick)
        inc tick
        doAssert tick < 100_000
      for seat in 0 ..< Seats:
        check not system.seats[seat].hasNoPath
      tick

    check ticksToAllPlans(true) == ticksToAllPlans(false)

  test "the hazard field's own clock is the zone schedule's, not the sim's":
    ## The arrival values are ZONE-ELAPSED ticks; the shell hands the nav layer
    ## absolute sim ticks. Without the offset, any episode whose lobby runs
    ## longer than the schedule reads as entirely painted the moment it starts.
    let map = openMap(192, 96)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    var arrival = newSeq[uint16]((map.width div 4) * (map.height div 4))
    for value in arrival.mitems:
      value = HazardNeverArrives
    system.installZoneHazard(arrival, map.width div 4, map.height div 4, 4,
      clockOffset = 7200)
    check system.zoneClockTick(7200) == 0
    check system.zoneClockTick(7500) == 300
    # And the world field's horizon bucket follows the zone clock, so a long
    # lobby cannot silently push the seed threshold past every arrival value.
    var tick = 7200
    while not system.zoneSafeReady:
      discard system.runPlanningTick(tick)
      inc tick
      doAssert tick < 20_000
    check system.world.readyKey == zoneSafeKey(system.zoneClockTick(7200))

  test "installing a fresh hazard retires the published safe field":
    let map = openMap(192, 96)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    var arrival = newSeq[uint16]((map.width div 4) * (map.height div 4))
    for value in arrival.mitems:
      value = HazardNeverArrives
    system.installZoneHazard(arrival, map.width div 4, map.height div 4, 4)
    check system.hazard.hasField
    var tick = 0
    while not system.zoneSafeReady:
      discard system.runPlanningTick(tick)
      inc tick
      doAssert tick < 10_000
    system.installZoneHazard(arrival, map.width div 4, map.height div 4, 4)
    check not system.zoneSafeReady

  test "NAVHINTS: the engine's four answers are honest integers":
    let map = openMap(256, 128)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    # Dark: every answer is "not available", never a fabricated zero.
    block:
      let hints = system.navHintsFor((64, 64), 0)
      check hints == (-1, -1, -1, -1)

    var hazard = neverField(map)
    # The left half floods inside the engine's own forward horizon, so it is
    # NOT seed ground; the right half never floods, so it is.
    for cellY in 0 ..< map.gridHeight:
      for cellX in 0 ..< map.gridWidth div 2:
        hazard.values[cellY * map.gridWidth + cellX] = 100'u16
    system.hazard = hazard
    system.hazardTickOffset = 1000    ## a lobby, then the schedule's own clock
    var tick = 1000
    while not system.zoneSafeReady:
      discard system.runPlanningTick(tick)
      inc tick
      doAssert tick < 20_000

    # Standing in the flooding half at zone-elapsed tick 0: paint arrives at
    # 100, so 100 ticks of warning -- measured on the ZONE clock, not the sim's
    # (absolute tick 1000 is zone-elapsed 0 here).
    let inPaint = system.navHintsFor((24, 64), 1000)
    check inPaint.ticksUntilPaintHere == 100
    check inPaint.safeDistPx > 0
    check inPaint.ticksToSafety > 0
    check inPaint.zoneSafeDirBrads in 0 .. 255
    # The retreat direction points EAST, toward the dry half.
    check inPaint.zoneSafeDirBrads in [0, 32, 224]

    # Standing on dry ground: never paints, zero distance, no direction needed.
    let onDry = system.navHintsFor((240, 64), 1000)
    check onDry.ticksUntilPaintHere == -1
    check onDry.safeDistPx == 0
    check onDry.ticksToSafety == 0
    check onDry.zoneSafeDirBrads == -1

    # Past the arrival tick the warning saturates at 0 rather than going
    # negative -- a play testing `<= n` must never see a wraparound.
    check system.navHintsFor((24, 64), 1000 + 900).ticksUntilPaintHere == 0

  test "NAVHINTS: the retreat brads are exact octants, never trigonometry":
    ## Eight deltas, eight exact multiples of 32 brads, in the engine's own
    ## convention (0 = east, counter-clockwise, 64 = north, screen +y = down).
    ## An approximate bearing here would be a float in the observation path.
    let map = openMap(256, 128)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    var hazard = neverField(map)
    for value in hazard.values.mitems:
      value = 10'u16
    # Exactly one dry cell: every other cell's flow points toward it, so each
    # of the eight neighbours exercises one octant.
    const SafeCell = (16, 8)
    hazard.values[SafeCell[1] * map.gridWidth + SafeCell[0]] =
      HazardNeverArrives
    system.hazard = hazard
    var tick = 0
    while not system.zoneSafeReady:
      discard system.runPlanningTick(tick)
      inc tick
      doAssert tick < 20_000
    check system.navHintsFor(cellCenter(SafeCell), 0).zoneSafeDirBrads == -1
    const Expected = {
      (1, 0): 128, (-1, 0): 0, (0, 1): 64, (0, -1): 192,
      (1, 1): 96, (-1, -1): 224, (1, -1): 160, (-1, 1): 32}
    for (delta, brads) in Expected.items:
      let here = cellCenter((SafeCell[0] + delta[0], SafeCell[1] + delta[1]))
      check system.navHintsFor(here, 0).zoneSafeDirBrads == brads

  test "world budget stalls reach the operator channel":
    let map = openMap(512, 256)
    let system = newBodyNavSystem(map, 1, GunRangePx, hazardAware = true)
    system.hazard = neverField(map)
    var outcomes: seq[PlanBudgetOutcome]
    for tick in 0 ..< 400:
      discard system.runPlanningTick(tick)
      for event in system.drainPlanBudgetEvents():
        if event.outcome in {pboWorldSuspended, pboWorldCompleted}:
          check event.seat == -1
          outcomes.add event.outcome
    check pboWorldSuspended in outcomes
    check pboWorldCompleted in outcomes
