## Phase-2 laws for bounded per-seat navigation, danger scheduling, and the
## stencil-derived follower.

import std/[algorithm, hashes, json, options, sequtils, unittest]
import bitworld/spriteprotocol
import ../src/ctf/arena
import ../src/shell/body_cache
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
import ../src/shell/types as shellTypes

proc floorModulo(value, modulus: int): int =
  ((value mod modulus) + modulus) mod modulus

proc openMap(width = 384, height = 160): BodyMap =
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = true
  newBodyMap(walkable, width, height, 2, @[(16, 16), (width - 17, height - 17)])

proc fixedCtfBodyMap(): BodyMap =
  let fixture = parseFile("tests/fixtures/shell/body/two-components.json")
  let width = fixture["width"].getInt()
  let height = fixture["height"].getInt()
  let barrier = fixture["barrier"]
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = not (
        x in barrier["x0"].getInt() .. barrier["x1"].getInt() and
        y notin barrier["gap_y0"].getInt() .. barrier["gap_y1"].getInt())
  var spawns: seq[BodyPoint]
  for point in fixture["spawn_points"]:
    spawns.add((point[0].getInt(), point[1].getInt()))
  newBodyMap(walkable, width, height, 2, spawns)

proc stripedMap(): BodyMap =
  const Side = 512
  var walkable = newSeq[bool](Side * Side)
  for y in 1 ..< Side - 1:
    for x in 1 ..< Side - 1:
      walkable[y * Side + x] = x mod 24 != 0
  newBodyMap(walkable, Side, Side, 2, @[(12, 12), (492, 492)])

proc emptyDanger(map: BodyMap): BodyDangerField =
  BodyDangerField(values: newSeq[float32](map.gridWidth * map.gridHeight),
    gridW: map.gridWidth, gridH: map.gridHeight)

proc finishPlan(planner: BodyPlanner, cache: BodySeatCache,
                danger: BodyDangerField, job: var BodyPlanJob) =
  var guard = 0
  while job.planPending:
    var budget = 100_000
    discard planner.stepPlan(cache, danger, job, budget)
    inc guard
    doAssert guard < 100_000

proc readyField(map: BodyMap, cache: BodySeatCache, planner: BodyPlanner,
                start, requested: BodyPoint, revision: uint64): seq[BodyPoint] =
  let goal = map.validateGoal(requested, start).get
  var job: BodyPlanJob
  planner.startPlan(cache, job, revision, start, goal)
  planner.finishPlan(cache, emptyDanger(map), job)
  doAssert job.planSucceeded
  planner.pathSnapshot(job)

proc scheduleInputs(map: BodyMap, tick: int): seq[DangerInput] =
  result = newSeq[DangerInput](32)
  for seat in 0 ..< 32:
    result[seat].selfXy = (80 + (seat mod 4) * 8, 64 + (seat div 4) * 4)
    var count = (tick + seat * 3) mod 10
    if (tick + seat) mod 11 == 0:
      count = 0
    if seat == 0 and tick in [0, 32, 64]:
      count = 7 + tick div 32
    for source in 0 ..< count:
      var candidateSeat = source + 10
      var pos: BodyPoint = (16 + (source mod 6) * 12 + floorModulo(tick, 3),
                            16 + floorModulo(seat * 5 + source * 9 + tick, 32))
      if seat == 0 and tick == 64 and source in [6, 7]:
        pos = (16, 32)
        candidateSeat = if source == 6: 9 else: 2
      result[seat].candidates.add(DangerCandidate(
        seatIndex: candidateSeat, pos: pos))

proc runDangerSchedule(map: BodyMap, order: seq[int]): tuple[
    fields: seq[Hash], trace: seq[DangerRebuild]] =
  let system = newBodyNavSystem(map, 32, 64, DangerCadenceK, 128)
  let reference = newBodyNavSystem(map, 32, 64)
  let initial = scheduleInputs(map, -1)
  system.initializeDanger(initial)
  reference.initializeDanger(initial)
  var previous = newSeq[Hash](32)
  for seat in 0 ..< 32:
    previous[seat] = system.seats[seat].dangerFingerprint
  for tick in 0 ..< 96:
    let inputs = scheduleInputs(map, tick)
    system.rebuildScheduledDanger(tick, inputs, order)
    let due = tick mod DangerCadenceK
    reference.seats[due].rebuildDanger(map, inputs[due], tick)
    for seat in 0 ..< 32:
      check system.seats[seat].dangerFingerprint ==
        reference.seats[seat].dangerFingerprint
      check tick - system.seats[seat].dangerTick <= DangerCadenceK - 1
      if seat != due:
        check system.seats[seat].dangerFingerprint == previous[seat]
      previous[seat] = system.seats[seat].dangerFingerprint
  for seat in system.seats:
    result.fields.add(seat.dangerFingerprint)
  result.trace = system.dangerTraceSnapshot

type MassPlanResult = object
  paths: seq[seq[BodyPoint]]
  routeKeys: seq[seq[int]]
  trace: seq[PlanningVisit]
  ticks, workUnits, cursor: int

proc referencePath(map: BodyMap, start: BodyPoint,
                   goal: ValidatedGoal): seq[BodyPoint] =
  let cache = newBodySeatCache(map)
  let planner = newBodyPlanner(map)
  var job: BodyPlanJob
  planner.startPlan(cache, job, 1, start, goal)
  planner.finishPlan(cache, emptyDanger(map), job)
  doAssert job.planSucceeded
  planner.pathSnapshot(job)

proc runMassPlan(map: BodyMap, start: BodyPoint,
                 requestedGoals: seq[BodyPoint], order: seq[int]): MassPlanResult =
  let system = newBodyNavSystem(map, 32, 331, DangerCadenceK, 100_000)
  let standing = @[(24, 16), (32, 16)]
  for seat in 0 ..< 32:
    let goal = map.validateGoal(requestedGoals[seat], start).get
    system.seats[seat].setActivePathForTest(standing, 100)
    system.replacePlan(seat, uint64(200 + seat), start, goal)
    doAssert system.seats[seat].activePath == standing
  var pending = 32
  while pending > 0:
    let spent = system.runPlanningTick(result.ticks, order)
    doAssert spent <= ColdPlanBudgetPerTick
    if result.ticks == 0:
      for seat in 0 ..< 32:
        doAssert system.seats[seat].activePath == standing
    inc result.ticks
    doAssert result.ticks < 100_000
    pending = 0
    for seat in system.seats:
      if seat.job.planPending:
        inc pending
  result.paths = newSeq[seq[BodyPoint]](32)
  result.routeKeys = newSeq[seq[int]](32)
  for seat in 0 ..< 32:
    doAssert system.seats[seat].job.planSucceeded
    doAssert system.seats[seat].pathRevision == uint64(200 + seat)
    result.paths[seat] = system.seats[seat].activePath
    result.routeKeys[seat] = system.seats[seat].cache.routeKeys
    result.workUnits += system.seats[seat].job.workUnits
  result.trace = system.planningTraceSnapshot
  result.cursor = system.planCursor

proc collectMassPlan(system: BodyNavSystem): MassPlanResult =
  result.paths = newSeq[seq[BodyPoint]](32)
  result.routeKeys = newSeq[seq[int]](32)
  for seat in 0 ..< 32:
    doAssert system.seats[seat].job.planSucceeded
    doAssert system.seats[seat].pathRevision == uint64(200 + seat)
    result.paths[seat] = system.seats[seat].activePath
    result.routeKeys[seat] = system.seats[seat].cache.routeKeys
    result.workUnits += system.seats[seat].job.workUnits
  result.trace = system.planningTraceSnapshot
  result.cursor = system.planCursor

proc runPrewarmMassPlan(map: BodyMap, start: BodyPoint,
                        requestedGoals: seq[BodyPoint],
                        planOrder: seq[int]): MassPlanResult =
  let system = newBodyNavSystem(map, 32, 331, DangerCadenceK, 100_000)
  let standing = @[(24, 16), (32, 16)]
  for seat in planOrder:
    let goal = map.validateGoal(requestedGoals[seat], start).get
    system.seats[seat].setActivePathForTest(standing, 100)
    system.replacePlan(seat, uint64(200 + seat), start, goal)
    doAssert system.seats[seat].activePath == standing
  system.prewarmColdPlans()
  result = collectMassPlan(system)

suite "shell body seat navigation":
  test "route and duck caches are bounded, pinned, LRU, and non-minting":
    let map = openMap()
    let cache = newBodySeatCache(map)
    let planner = newBodyPlanner(map)
    let start = (16, 16)
    let missGoal = (320, 120)
    check cache.peekRouteDistance(start, missGoal).isNone
    check cache.routeFieldCount == 0
    let goals = [(80, 32), (144, 32), (208, 32), (272, 32)]
    for index, goal in goals:
      discard readyField(map, cache, planner, start, goal, uint64(index + 1))
    check cache.readyRouteFieldCount == shellTypes.MaxRouteFieldsPerSeat
    cache.pinStandingGoal(goals[0])
    discard cache.peekRouteDistance(start, goals[1])
    discard readyField(map, cache, planner, start, (336, 96), 10)
    check cache.readyRouteFieldCount == shellTypes.MaxRouteFieldsPerSeat
    check cache.routeKey(goals[0]) in cache.routeKeys
    check cache.routeKey(goals[2]) notin cache.routeKeys
    check cache.peekRouteDistance(start, missGoal).isNone
    check cache.routeFieldCount == shellTypes.MaxRouteFieldsPerSeat

    let duckMap = stripedMap()
    check duckMap.atlasPostCount > shellTypes.MaxDuckEntriesPerSeat
    let duckCache = newBodySeatCache(duckMap)
    for index in 0 .. shellTypes.MaxDuckEntriesPerSeat:
      discard duckCache.duckFor(index)
    check duckCache.duckEntryCount == shellTypes.MaxDuckEntriesPerSeat
    let firstKey = duckMap.routeKey(duckMap.atlasPostAt(0).pos)
    check firstKey notin duckCache.duckKeys

  test "danger_schedule_k32_fixed_seed":
    let map = fixedCtfBodyMap()
    var forward = toSeq(0 ..< 32)
    var reverse = forward
    reverse.reverse()
    let permutation = @[7, 1, 29, 3, 18, 0, 31, 12, 4, 25, 6, 22, 9,
      15, 2, 27, 11, 20, 5, 30, 14, 8, 24, 17, 10, 28, 13, 21, 16, 26, 19, 23]
    let baseline = runDangerSchedule(map, forward)
    check baseline.trace.len == 96
    for tick, rebuild in baseline.trace:
      check rebuild.tick == tick
      check rebuild.seat == tick mod DangerCadenceK
    check baseline.trace[0].sourceCount == 7
    check baseline.trace[32].sourceCount == 8
    check baseline.trace[64].sourceCount == 8
    let reversed = runDangerSchedule(map, reverse)
    let permuted = runDangerSchedule(map, permutation)
    check baseline.fields == reversed.fields
    check baseline.fields == permuted.fields
    check baseline.trace == reversed.trace
    check baseline.trace == permuted.trace

    let capSystem = newBodyNavSystem(map, 1, 64)
    let capInput = scheduleInputs(map, 64)[0]
    capSystem.seats[0].rebuildDanger(map, capInput, 64)
    var ranked = capInput.candidates
    ranked.sort(proc(a, b: DangerCandidate): int =
      let adx = int64(a.pos.x - capInput.selfXy.x)
      let ady = int64(a.pos.y - capInput.selfXy.y)
      let bdx = int64(b.pos.x - capInput.selfXy.x)
      let bdy = int64(b.pos.y - capInput.selfXy.y)
      result = cmp(adx * adx + ady * ady, bdx * bdx + bdy * bdy)
      if result == 0: result = cmp(a.seatIndex, b.seatIndex))
    ranked.setLen(MaxDangerSources)
    check capSystem.seats[0].selectedDangerSourceSeats ==
      ranked.mapIt(it.seatIndex)
    check capSystem.seats[0].selectedDangerSourceSeats.len == MaxDangerSources
    let exact = DangerInput(selfXy: capInput.selfXy,
      candidates: capSystem.seats[0].selectedDangerSources)
    let exactSystem = newBodyNavSystem(map, 1, 64)
    exactSystem.seats[0].rebuildDanger(map, exact, 64)
    check capSystem.seats[0].danger.values == exactSystem.seats[0].danger.values

  test "danger_range_cap_boundary reads the live gun range":
    let map = openMap(256, 128)
    let source = DangerCandidate(seatIndex: 3, pos: (68, 68))
    proc fieldAt(range: int, probe: BodyPoint): float =
      let system = newBodyNavSystem(map, 1, range)
      system.seats[0].rebuildDanger(map,
        DangerInput(selfXy: (16, 16), candidates: @[source]), 0)
      system.seats[0].danger.sample(map, probe)
    check fieldAt(64, (124, 68)) > 0.0
    check fieldAt(64, (132, 68)) > 0.0
    check fieldAt(64, (140, 68)) == 0.0
    check fieldAt(56, (132, 68)) == 0.0
    check fieldAt(72, (140, 68)) > 0.0

  test "start endpoint resolution and equal endpoint match stencil":
    let map = openMap(128, 64)
    let danger = emptyDanger(map)

    block equalEndpoint:
      let cache = newBodySeatCache(map)
      let planner = newBodyPlanner(map)
      let point: BodyPoint = (16, 16)
      let goal = map.validateGoal(point, point).get
      var job: BodyPlanJob
      planner.startPlan(cache, job, 1, point, goal)
      check job.stage == pjsComplete
      check job.workUnits == 0
      check cache.routeFieldCount == 0
      check planner.pathSnapshot(job) == @[point]

    block snappedStart:
      let cache = newBodySeatCache(map)
      let planner = newBodyPlanner(map)
      let start: BodyPoint = (2, 32)
      let expectedStart: BodyPoint = (7, 32)
      check not map.canStand(start)
      check map.canStand(expectedStart)
      let goal = map.validateGoal((112, 32), (16, 32)).get
      var job: BodyPlanJob
      planner.startPlan(cache, job, 2, start, goal)
      planner.finishPlan(cache, danger, job)
      check job.planSucceeded
      check job.startSnapped
      check job.planStart == expectedStart
      let path = planner.pathSnapshot(job)
      check path.len > 1
      check path[0] == expectedStart

    block resumableResolution:
      let start: BodyPoint = (2, 32)
      let goal = map.validateGoal((112, 32), (16, 32)).get
      let cacheA = newBodySeatCache(map)
      let cacheB = newBodySeatCache(map)
      let plannerA = newBodyPlanner(map)
      let plannerB = newBodyPlanner(map)
      var jobA, jobB: BodyPlanJob
      plannerA.startPlan(cacheA, jobA, 3, start, goal)
      plannerB.startPlan(cacheB, jobB, 3, start, goal)
      var budgetA = 64
      discard plannerA.stepPlan(cacheA, danger, jobA, budgetA)
      for _ in 0 ..< 2:
        var budgetB = 32
        discard plannerB.stepPlan(cacheB, danger, jobB, budgetB)
      check jobA.stage == pjsStartResolve
      check jobA.workUnits == 64
      check jobB.workUnits == 64
      check plannerA.jobFingerprint(cacheA, jobA) ==
        plannerB.jobFingerprint(cacheB, jobB)

  test "charged suspension is chunk-independent and replacement is atomic":
    let map = openMap()
    let start = (16, 16)
    let goal = map.validateGoal((352, 128), start).get
    let cacheA = newBodySeatCache(map)
    let cacheB = newBodySeatCache(map)
    let plannerA = newBodyPlanner(map)
    let plannerB = newBodyPlanner(map)
    var jobA, jobB: BodyPlanJob
    plannerA.startPlan(cacheA, jobA, 1, start, goal)
    plannerB.startPlan(cacheB, jobB, 1, start, goal)
    var budgetA = 256
    discard plannerA.stepPlan(cacheA, emptyDanger(map), jobA, budgetA)
    for _ in 0 ..< 2:
      var budgetB = 128
      discard plannerB.stepPlan(cacheB, emptyDanger(map), jobB, budgetB)
    check jobA.workUnits == 256
    check jobB.workUnits == 256
    check plannerA.jobFingerprint(cacheA, jobA) ==
      plannerB.jobFingerprint(cacheB, jobB)

    let system = newBodyNavSystem(map, 1, 64)
    system.seats[0].setActivePathForTest(@[(40, 16), (80, 16)], 7)
    system.replacePlan(0, 8, start, goal)
    check system.seats[0].activePath == @[(40, 16), (80, 16)]
    check system.navigationWaypoint(0, start, goal, 1) == (40, 16)
    discard system.runPlanningTick(1)
    check system.seats[0].activePath == @[(40, 16), (80, 16)]
    let replacement = map.validateGoal((240, 112), start).get
    system.replacePlan(0, 9, start, replacement)
    check system.seats[0].job.revision == 9
    check system.seats[0].job.workUnits == 0
    check system.seats[0].activePath == @[(40, 16), (80, 16)]

  test "cold_plan_budget_256_round_robin":
    let gameMap = mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json"))
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (16, 16)
    check map.canStand(start)
    var requestedGoals: seq[BodyPoint]
    for seat in 0 ..< 32:
      requestedGoals.add((3194 - (seat mod 8) * 16,
                          1696 - (seat div 8) * 16))
    check map.validateGoal(requestedGoals[0], start).get.goalPoint == (3194, 1696)

    var references = newSeq[seq[BodyPoint]](32)
    for seat in 0 ..< 32:
      references[seat] = referencePath(map, start,
        map.validateGoal(requestedGoals[seat], start).get)

    let forward = toSeq(0 ..< 32)
    let permutation = @[7, 1, 29, 3, 18, 0, 31, 12, 4, 25, 6, 22, 9,
      15, 2, 27, 11, 20, 5, 30, 14, 8, 24, 17, 10, 28, 13, 21, 16, 26, 19, 23]
    let baseline = runMassPlan(map, start, requestedGoals, forward)
    check baseline.paths == references
    check baseline.workUnits == baseline.trace.mapIt(it.units).foldl(a + b, 0)
    check baseline.trace.len > baseline.ticks
    for visit in baseline.trace:
      check visit.units >= 0
      check visit.units <= ColdPlanBudgetPerTick
    let permuted = runMassPlan(map, start, requestedGoals, permutation)
    check permuted.paths == baseline.paths
    check permuted.routeKeys == baseline.routeKeys
    check permuted.trace == baseline.trace
    check permuted.ticks == baseline.ticks
    check permuted.workUnits == baseline.workUnits

    let prewarmed = runPrewarmMassPlan(map, start, requestedGoals, forward)
    check prewarmed.paths == baseline.paths
    check prewarmed.routeKeys == baseline.routeKeys
    check prewarmed.workUnits == baseline.workUnits
    check prewarmed.cursor == baseline.cursor
    check prewarmed.trace.len == baseline.trace.len
    for index, visit in prewarmed.trace:
      let budgeted = baseline.trace[index]
      check visit.tick == -1
      check visit.seat == budgeted.seat
      check visit.revision == budgeted.revision
      check visit.units == budgeted.units
      check visit.completed == budgeted.completed

    let prewarmedPermuted = runPrewarmMassPlan(map, start, requestedGoals,
      permutation)
    check prewarmedPermuted.paths == prewarmed.paths
    check prewarmedPermuted.routeKeys == prewarmed.routeKeys
    check prewarmedPermuted.trace == prewarmed.trace
    check prewarmedPermuted.cursor == prewarmed.cursor
    check prewarmedPermuted.workUnits == prewarmed.workUnits

  test "prewarmed activation has no playing-tick cold work until new intent":
    let gameMap = mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json"))
    let map = newBodyMap(gameMap)
    let start: BodyPoint = (16, 16)
    let firstGoal = map.validateGoal((3194, 1696), start).get
    let secondGoal = map.validateGoal((3162, 1664), start).get
    let system = newBodyNavSystem(map, 2, 331, DangerCadenceK, 100_000)
    system.replacePlan(0, 10, start, firstGoal)
    system.replacePlan(1, 11, start, secondGoal)
    system.prewarmColdPlans()
    let barrierTrace = system.planningTraceSnapshot
    check barrierTrace.len > 2
    check barrierTrace.allIt(it.tick == -1)
    check system.seats[0].job.planSucceeded
    check system.seats[1].job.planSucceeded
    check barrierTrace.anyIt(it.seat == 0 and it.completed)
    check barrierTrace.anyIt(it.seat == 1 and it.completed)

    check system.runPlanningTick(12) == 0
    check system.planningTraceSnapshot == barrierTrace

    system.replacePlan(0, 12, start, secondGoal)
    let spent = system.runPlanningTick(13)
    check spent > 0
    let playingTrace = system.planningTraceSnapshot
    check playingTrace.len > barrierTrace.len
    check playingTrace[^1].tick == 13
    check playingTrace[^1].seat == 0

  test "follower corridor, octants, and stuck state match stencil":
    let map = openMap()
    let system = newBodyNavSystem(map, 1, 64)
    let seat = system.seats[0]
    seat.setActivePathForTest(@[(24, 24), (64, 24), (96, 56)], 1)
    check seat.withinCorridor((50, 39))
    check not seat.withinCorridor((50, 50))
    check seat.followerWaypoint((24, 24)) == (64, 24)
    check octantToward((16, 16), (32, 8)) == (ButtonRight or ButtonUp)
    for _ in 0 ..< 9:
      seat.noteProgress((24, 24))
    check seat.stuckTicks == 8
    seat.resetProgress((25, 24))
    check seat.stuckTicks == 0
