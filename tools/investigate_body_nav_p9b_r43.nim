## P9B Round 4.3: resumable pop-budgeted FIFO scheduling.

import std/[algorithm, json, math, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

type
  Scenario = enum
    firstGoals = "first_goal_burst"
    movingGoals = "moving_goal_12_tick_cadence"
    stuckReplans = "stuck_replans"

  RunResult = object
    slices: seq[int64]
    routeTicks: seq[int]
    steeringTicks, totalSeatTicks: int
    completed, superseded, goalRestarts, dangerRestarts: int
    fingerprint: uint64

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc percentileInt(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return high(int64)
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc percentileInt(values: openArray[int], fraction: float64): int =
  if values.len == 0: return high(int)
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc hashRoute(value: var uint64, seat, tick: int,
    route: openArray[BodyPoint]) =
  value = (value xor uint64(seat + tick * 257)) * 1_099_511_628_211'u64
  for point in route:
    value = (value xor uint64(point.x * 65_537 + point.y)) *
      1_099_511_628_211'u64

proc simulate(map: BodyMap, graph: MixedGraph, nav: BodyNavSystem,
    farItem, nearItem: NavCorpusCase, refined: seq[uint8],
    combined, hazard: seq[int32], rosterSize, budget: int,
    scenario: Scenario, reverseInput, recordTime: bool): RunResult =
  let maxEdge = graph.maximumEdgeCost(combined, hazard)
  var
    workspace = newDialWorkspace(graph.nodeCount, 1, maxEdge)
    job: DialJob
    activeSeat = -1
    activeIssued = 0
    activeItem = farItem
    pending = newSeq[bool](rosterSize)
    pendingIssued = newSeq[int](rosterSize)
    pendingNear = newSeq[bool](rosterSize)
    routed = newSeq[bool](rosterSize)
    waypoint = newSeq[BodyPoint](rosterSize)
    queue: seq[int]
    tick = 0
    lastWave = case scenario
      of firstGoals: 1
      of movingGoals: 37
      of stuckReplans: 25

  template requestAll(useNear: bool) =
    var arrivals = newSeq[int](rosterSize)
    for seat in 0 ..< rosterSize:
      arrivals[seat] = if reverseInput: rosterSize - 1 - seat else: seat
    arrivals.sort()
    for seat in arrivals:
      routed[seat] = false
      if seat == activeSeat:
        activeIssued = tick
        activeItem = if useNear: nearItem else: farItem
        job.startDialJob(graph, map, activeItem, refined, combined, hazard,
          workspace)
        inc result.goalRestarts
      elif pending[seat]:
        pendingIssued[seat] = tick
        pendingNear[seat] = useNear
        inc result.superseded
      else:
        pending[seat] = true
        pendingIssued[seat] = tick
        pendingNear[seat] = useNear
        queue.add seat

  while tick < 2_000:
    inc tick
    let started = getMonoTime()
    case scenario
    of firstGoals:
      if tick == 1: requestAll(false)
    of movingGoals:
      if tick in [1, 13, 25, 37]: requestAll(((tick - 1) div 12 and 1) != 0)
    of stuckReplans:
      if tick in [1, 9, 17, 25]: requestAll(false)

    let dangerChanged =
      (scenario == movingGoals and tick in [17, 34]) or
      (scenario == stuckReplans and tick == 19)
    if dangerChanged and activeSeat >= 0:
      job.startDialJob(graph, map, activeItem, refined, combined, hazard,
        workspace)
      inc result.dangerRestarts

    var remaining = budget
    while remaining > 0:
      if activeSeat < 0:
        if queue.len == 0: break
        activeSeat = queue[0]
        queue.delete(0)
        pending[activeSeat] = false
        activeIssued = pendingIssued[activeSeat]
        activeItem = if pendingNear[activeSeat]: nearItem else: farItem
        job.startDialJob(graph, map, activeItem, refined, combined, hazard,
          workspace)
      let used = job.stepDialJob(graph, map, refined, combined, hazard,
        workspace, remaining)
      remaining -= used
      if not job.complete: break
      let found = job.finishDialJob(graph, workspace)
      doAssert found.reached and map.routeLegal(activeItem, found.route)
      routed[activeSeat] = true
      waypoint[activeSeat] = if found.route.len > 1:
          found.route[1] else: activeItem.validatedGoal
      result.routeTicks.add tick - activeIssued + 1
      result.fingerprint.hashRoute(activeSeat, tick, found.route)
      inc result.completed
      activeSeat = -1

    for seat in 0 ..< rosterSize:
      inc result.totalSeatTicks
      if seat == activeSeat or pending[seat]:
        let goal = if seat == activeSeat: activeItem.validatedGoal
          elif pendingNear[seat]: nearItem.validatedGoal
          else: farItem.validatedGoal
        result.fingerprint = result.fingerprint xor uint64(
          nav.steeringMask(seat, farItem.start, goal,
            farItem.profile.corpusProfile, tick))
        inc result.steeringTicks
      elif routed[seat]:
        result.fingerprint = result.fingerprint xor uint64(
          octantToward(farItem.start, waypoint[seat]))
    if recordTime:
      result.slices.add (getMonoTime() - started).inNanoseconds
    if tick >= lastWave and activeSeat < 0 and queue.len == 0:
      break
  doAssert tick < 2_000
  result.fingerprint = result.fingerprint xor
    uint64(result.steeringTicks * 17 + result.completed * 31 +
      result.superseded * 43 + result.goalRestarts * 59 +
      result.dangerRestarts * 71)
  for value in result.routeTicks:
    result.fingerprint = result.fingerprint * 1_099_511_628_211'u64 xor
      uint64(value)

proc rowJson(map: BodyMap, graph: MixedGraph, rosterSize, budget: int,
    scenario: Scenario, farItem, nearItem: NavCorpusCase,
    refined: seq[uint8], combined, hazard: seq[int32]): JsonNode =
  let danger = map.buildOracleDanger(farItem)
  let nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats:
    seat.danger = danger
  let
    measured = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, scenario, false, true)
    repeated = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, scenario, false, false)
    permuted = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, scenario, true, false)
  doAssert measured.fingerprint == repeated.fingerprint
  doAssert measured.fingerprint == permuted.fingerprint
  %*{"scenario": $scenario, "roster_size": rosterSize,
    "pop_budget": budget, "workspace_count": 1,
    "sample_ticks": measured.slices.len,
    "navigation_slice_p50_ns": percentileInt(measured.slices, 0.50),
    "navigation_slice_p95_ns": percentileInt(measured.slices, 0.95),
    "navigation_slice_max_ns": max(measured.slices),
    "time_to_route_ticks_p50": percentileInt(measured.routeTicks, 0.50),
    "time_to_route_ticks_p95": percentileInt(measured.routeTicks, 0.95),
    "time_to_route_ticks_max": max(measured.routeTicks),
    "completed_routes": measured.completed,
    "superseded_pending_requests": measured.superseded,
    "goal_change_restarts": measured.goalRestarts,
    "danger_generation_restarts": measured.dangerRestarts,
    "danger_restart_rate_per_completed":
      measured.dangerRestarts.float / max(1, measured.completed).float,
    "steering_fraction":
      measured.steeringTicks.float / measured.totalSeatTicks.float,
    "deterministic_repeat": true,
    "deterministic_permuted_input": true,
    "fingerprint": measured.fingerprint}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r43 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    map = pool.loadMap(15)
    graph = map.buildMixedGraph()
    farDanger = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-danger-far")
    nearDanger = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-danger-near")
    farBlocked = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-blocked-far")
    nearBlocked = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-blocked-near")
    farDanger32 = corpus.findCase(
      "m15-br-gen-22010-r32-s15-default-danger-far")
    nearDanger32 = corpus.findCase(
      "m15-br-gen-22010-r32-s15-default-danger-near")
    farBlocked32 = corpus.findCase(
      "m15-br-gen-22010-r32-s15-default-blocked-far")
    nearBlocked32 = corpus.findCase(
      "m15-br-gen-22010-r32-s15-default-blocked-near")
    danger = map.buildOracleDanger(farDanger)
    dangerRefined = graph.buildRefined(map.buildHot(danger))
    dangerWeights = danger.buildWeights(farDanger.profile)
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
    dangerCombined = buildCombinedCellCost(dangerWeights, hazard)
    noDanger = map.buildOracleDanger(farBlocked)
    blockedRefined = graph.buildRefined(map.buildHot(noDanger))
    blockedCombined = buildCombinedCellCost(
      noDanger.buildWeights(farBlocked.profile), hazard)
  var rows = newJArray()
  for budget in [4_096, 8_192, 12_288]:
    for rosterSize in [16, 32]:
      for scenario in Scenario:
        stderr.writeLine &"R4.3 B={budget} roster={rosterSize} {scenario}"
        if rosterSize == 32 and scenario == stuckReplans:
          rows.add rowJson(map, graph, rosterSize, budget, scenario,
            farBlocked32, nearBlocked32, blockedRefined, blockedCombined, hazard)
        elif rosterSize == 32:
          let
            danger32 = map.buildOracleDanger(farDanger32)
            refined32 = graph.buildRefined(map.buildHot(danger32))
            combined32 = buildCombinedCellCost(
              danger32.buildWeights(farDanger32.profile), hazard)
          rows.add rowJson(map, graph, rosterSize, budget, scenario,
            farDanger32, nearDanger32, refined32, combined32, hazard)
        elif scenario == stuckReplans:
          rows.add rowJson(map, graph, rosterSize, budget, scenario,
            farBlocked, nearBlocked, blockedRefined, blockedCombined, hazard)
        else:
          rows.add rowJson(map, graph, rosterSize, budget, scenario,
            farDanger, nearDanger, dangerRefined, dangerCombined, hazard)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r43", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "queue": "exact Dial width 1 Q4", "rows": rows})
