## Phase 10.0: one-process-per-row SJF budget measurement.

import std/[algorithm, json, math, monotimes, os, strformat, strutils, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav, body_planner]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

const TargetSliceSamples = 120

type
  Scenario = enum
    firstGoals = "first_goal_burst"
    movingGoals = "moving_goal_12_tick_cadence"
    stuckReplans = "stuck_replans"

  RunResult = object
    totalSlices, searchSlices, steeringSlices: seq[int64]
    routeTicks, nearRouteTicks, farRouteTicks: seq[int]
    inflations: seq[float64]
    completionOrder: seq[int]
    ticks, requests, completed, failed, illegal: int
    nearCompleted, farCompleted: int
    searchPops, settledPops, steeringCalls: int
    steeringCallsPerSlice: seq[int]
    superseded, goalRestarts, dangerRestarts: int
    oldestRequestAge, maximumWaitingStreak: int
    scheduleFingerprint, routeFingerprint: uint64

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc parseScenario(value: string): Scenario =
  case value
  of $firstGoals: firstGoals
  of $movingGoals: movingGoals
  of $stuckReplans: stuckReplans
  else:
    raise newException(ValueError, "unknown P10 scenario: " & value)

proc percentile(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc percentile(values: openArray[int], fraction: float64): int =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return 0.0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc hashRoute(value: var uint64, seat, tick: int,
    route: openArray[BodyPoint]) =
  value = (value xor uint64(seat + tick * 257)) * 1_099_511_628_211'u64
  for point in route:
    value = (value xor uint64(point.x * 65_537 + point.y)) *
      1_099_511_628_211'u64

proc hashRouteOnly(value: var uint64, seat: int,
    route: openArray[BodyPoint]) =
  value = (value xor uint64(seat)) * 1_099_511_628_211'u64
  for point in route:
    value = (value xor uint64(point.x * 65_537 + point.y)) *
      1_099_511_628_211'u64

proc simulate(map: BodyMap, graph: MixedGraph, nav: BodyNavSystem,
    farItem, nearItem: NavCorpusCase, danger: BodyDangerField,
    refined: seq[uint8], combined, hazard: seq[int32], rosterSize, budget: int,
    scenario: Scenario, reverseInput, recordTime: bool): RunResult =
  let maxEdge = graph.maximumEdgeCost(combined, hazard)
  var
    workspace = newDialWorkspace(graph.nodeCount, 1, maxEdge)
    job: DialJob
    activeSeat = -1
    activeIssued = 0
    activeNear = false
    activeItem = farItem
    pending = newSeq[bool](rosterSize)
    pendingIssued = newSeq[int](rosterSize)
    pendingNear = newSeq[bool](rosterSize)
    waitingStreak = newSeq[int](rosterSize)
    queue: seq[int]
    tick = 0
    lastWave = case scenario
      of firstGoals: 1
      of movingGoals: 37
      of stuckReplans: 25

  proc selectPending(): int =
    if queue.len == 0: return -1
    var bestOffset = 0
    for offset in 1 ..< queue.len:
      let
        seat = queue[offset]
        bestSeat = queue[bestOffset]
        item = if pendingNear[seat]: nearItem else: farItem
        bestItem = if pendingNear[bestSeat]: nearItem else: farItem
        estimate = octileQ4(item.start, item.validatedGoal, 90)
        bestEstimate = octileQ4(bestItem.start, bestItem.validatedGoal, 90)
      if estimate < bestEstimate or
          (estimate == bestEstimate and seat < bestSeat):
        bestOffset = offset
    result = queue[bestOffset]
    queue.delete(bestOffset)

  template requestAll(waveNear: bool) =
    for arrivalOffset in 0 ..< rosterSize:
      let seat = if reverseInput: rosterSize - 1 - arrivalOffset
        else: arrivalOffset
      let useNear = if scenario == stuckReplans: false
        else: waveNear xor ((seat and 1) == 0)
      inc result.requests
      if seat == activeSeat:
        activeIssued = tick
        activeNear = useNear
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

  template completeRoute(seat, issued: int, useNear: bool,
      found: DialResult) =
    let selectedItem = if useNear: nearItem else: farItem
    if not found.reached:
      inc result.failed
    else:
      let legal = map.routeLegal(selectedItem, found.route)
      if not legal: inc result.illegal
      let latency = tick - issued + 1
      result.routeTicks.add latency
      if useNear:
        result.nearRouteTicks.add latency
        inc result.nearCompleted
      else:
        result.farRouteTicks.add latency
        inc result.farCompleted
      result.inflations.add routeInflationPct(
        oracleFloatCost(found.route, map, danger,
          selectedItem.profile.corpusProfile, selectedItem.blockedCell),
        selectedItem.oracleCost)
      result.completionOrder.add seat
      result.scheduleFingerprint.hashRoute(seat, tick, found.route)
      result.routeFingerprint.hashRouteOnly(seat, found.route)
      inc result.completed

  while tick < 2_000:
    inc tick
    let totalStarted = getMonoTime()
    case scenario
    of firstGoals:
      if tick == 1: requestAll(false)
    of movingGoals:
      if tick in [1, 13, 25, 37]:
        requestAll(((tick - 1) div 12 and 1) != 0)
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
        activeSeat = selectPending()
        if activeSeat < 0: break
        pending[activeSeat] = false
        activeIssued = pendingIssued[activeSeat]
        activeNear = pendingNear[activeSeat]
        activeItem = if activeNear: nearItem else: farItem
        job.startDialJob(graph, map, activeItem, refined, combined, hazard,
          workspace)
      let beforeSettled = job.pops
      let used = job.stepDialJob(graph, map, refined, combined, hazard,
        workspace, remaining)
      remaining -= used
      result.searchPops += used
      result.settledPops += job.pops - beforeSettled
      if not job.complete: break
      let found = job.finishDialJob(graph, workspace)
      completeRoute(activeSeat, activeIssued, activeNear, found)
      activeSeat = -1

    let
      searchFinished = getMonoTime()
      steeringCallsBefore = result.steeringCalls
    for seat in 0 ..< rosterSize:
      let waiting = seat == activeSeat or pending[seat]
      if waiting:
        inc waitingStreak[seat]
        result.maximumWaitingStreak = max(result.maximumWaitingStreak,
          waitingStreak[seat])
        let issued = if seat == activeSeat: activeIssued
          else: pendingIssued[seat]
        result.oldestRequestAge = max(result.oldestRequestAge,
          tick - issued + 1)
        let
          useNear = if seat == activeSeat: activeNear else: pendingNear[seat]
          item = if useNear: nearItem else: farItem
        result.scheduleFingerprint = result.scheduleFingerprint xor uint64(
          nav.steeringMask(seat, item.start, item.validatedGoal,
            item.profile.corpusProfile, tick))
        inc result.steeringCalls
      else:
        waitingStreak[seat] = 0
    let totalFinished = getMonoTime()
    if recordTime:
      result.searchSlices.add (searchFinished - totalStarted).inNanoseconds
      result.steeringSlices.add (totalFinished - searchFinished).inNanoseconds
      result.totalSlices.add (totalFinished - totalStarted).inNanoseconds
      result.steeringCallsPerSlice.add(
        result.steeringCalls - steeringCallsBefore)
    if tick >= lastWave and activeSeat < 0 and queue.len == 0:
      break
  doAssert tick < 2_000
  result.ticks = tick
  result.scheduleFingerprint = result.scheduleFingerprint xor uint64(
    result.completed * 31 + result.failed * 37 + result.illegal * 41 +
    result.superseded * 43 + result.goalRestarts * 59 +
    result.dangerRestarts * 71)
  for value in result.routeTicks:
    result.scheduleFingerprint =
      result.scheduleFingerprint * 1_099_511_628_211'u64 xor uint64(value)

proc rowJson(map: BodyMap, graph: MixedGraph, rosterSize, budget: int,
    scenario: Scenario, farItem, nearItem: NavCorpusCase,
    danger: BodyDangerField, refined: seq[uint8], combined,
    hazard: seq[int32]): JsonNode =
  let nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats:
    seat.danger = danger
  let
    measured = simulate(map, graph, nav, farItem, nearItem, danger, refined,
      combined, hazard, rosterSize, budget, scenario, false, true)
    repeated = simulate(map, graph, nav, farItem, nearItem, danger, refined,
      combined, hazard, rosterSize, budget, scenario, false, false)
    permuted = simulate(map, graph, nav, farItem, nearItem, danger, refined,
      combined, hazard, rosterSize, budget, scenario, true, false)
  doAssert measured.scheduleFingerprint == repeated.scheduleFingerprint
  doAssert measured.scheduleFingerprint == permuted.scheduleFingerprint
  doAssert measured.routeFingerprint == repeated.routeFingerprint
  doAssert measured.routeFingerprint == permuted.routeFingerprint
  doAssert measured.completionOrder == repeated.completionOrder
  doAssert measured.completionOrder == permuted.completionOrder

  var
    totalSlices = measured.totalSlices
    searchSlices = measured.searchSlices
    steeringSlices = measured.steeringSlices
    steeringCallsPerSlice = measured.steeringCallsPerSlice
    timedRepetitions = 1
  while totalSlices.len < TargetSliceSamples:
    let extra = simulate(map, graph, nav, farItem, nearItem, danger, refined,
      combined, hazard, rosterSize, budget, scenario, false, true)
    doAssert extra.scheduleFingerprint == measured.scheduleFingerprint
    doAssert extra.routeFingerprint == measured.routeFingerprint
    doAssert extra.completionOrder == measured.completionOrder
    totalSlices.add extra.totalSlices
    searchSlices.add extra.searchSlices
    steeringSlices.add extra.steeringSlices
    steeringCallsPerSlice.add extra.steeringCallsPerSlice
    inc timedRepetitions
  totalSlices.setLen(TargetSliceSamples)
  searchSlices.setLen(TargetSliceSamples)
  steeringSlices.setLen(TargetSliceSamples)
  steeringCallsPerSlice.setLen(TargetSliceSamples)
  let sampledSteeringCalls = sum(steeringCallsPerSlice)
  %*{
    "scenario": $scenario,
    "admission": "shortest_job_first",
    "roster_size": rosterSize,
    "pop_budget": budget,
    "workspace_count": 1,
    "process_id": getCurrentProcessId(),
    "scenario_ticks": measured.ticks,
    "sample_ticks": totalSlices.len,
    "timed_repetitions": timedRepetitions,
    "raw_navigation_slice_ns": totalSlices,
    "raw_search_slice_ns": searchSlices,
    "raw_steering_slice_ns": steeringSlices,
    "raw_steering_calls": steeringCallsPerSlice,
    "navigation_slice_p50_ns": percentile(totalSlices, 0.50),
    "navigation_slice_p95_ns": percentile(totalSlices, 0.95),
    "navigation_slice_max_ns": max(totalSlices),
    "search_slice_p50_ns": percentile(searchSlices, 0.50),
    "search_slice_p95_ns": percentile(searchSlices, 0.95),
    "search_slice_max_ns": max(searchSlices),
    "steering_slice_p50_ns": percentile(steeringSlices, 0.50),
    "steering_slice_p95_ns": percentile(steeringSlices, 0.95),
    "steering_slice_max_ns": max(steeringSlices),
    "time_to_route_ticks_p50": percentile(measured.routeTicks, 0.50),
    "time_to_route_ticks_p95": percentile(measured.routeTicks, 0.95),
    "time_to_route_ticks_max": max(measured.routeTicks),
    "near_time_to_route_ticks_p50": percentile(measured.nearRouteTicks, 0.50),
    "near_time_to_route_ticks_p95": percentile(measured.nearRouteTicks, 0.95),
    "near_time_to_route_ticks_max":
      (if measured.nearRouteTicks.len == 0: 0 else: max(measured.nearRouteTicks)),
    "far_time_to_route_ticks_p50": percentile(measured.farRouteTicks, 0.50),
    "far_time_to_route_ticks_p95": percentile(measured.farRouteTicks, 0.95),
    "far_time_to_route_ticks_max":
      (if measured.farRouteTicks.len == 0: 0 else: max(measured.farRouteTicks)),
    "requests": measured.requests,
    "completed_routes": measured.completed,
    "failed_routes": measured.failed,
    "illegal_routes": measured.illegal,
    "near_routes": measured.nearCompleted,
    "far_routes": measured.farCompleted,
    "queue_pops": measured.searchPops,
    "settled_pops": measured.settledPops,
    "superseded_pending_requests": measured.superseded,
    "goal_change_restarts": measured.goalRestarts,
    "danger_generation_restarts": measured.dangerRestarts,
    "oldest_request_age_ticks": measured.oldestRequestAge,
    "maximum_consecutive_wait_ticks": measured.maximumWaitingStreak,
    "steering_calls": sampledSteeringCalls,
    "steering_ns_per_call":
      (if sampledSteeringCalls == 0: 0 else:
        sum(steeringSlices) div sampledSteeringCalls.int64),
    "route_inflation_p95_pct": percentile(measured.inflations, 0.95),
    "route_inflation_max_pct": max(measured.inflations),
    "completion_order": measured.completionOrder,
    "deterministic_repeat": true,
    "deterministic_permuted_input": true,
    "schedule_fingerprint": measured.scheduleFingerprint,
    "route_fingerprint": measured.routeFingerprint
  }

when isMainModule:
  if paramCount() != 4:
    quit("usage: investigate_body_nav_p10 CORPUS BUDGET ROSTER SCENARIO", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    budget = parseInt(paramStr(2))
    rosterSize = parseInt(paramStr(3))
    scenario = parseScenario(paramStr(4))
  if budget notin [12_288, 16_384, 20_480]:
    quit("P10 budget must be 12288, 16384, or 20480", 2)
  if rosterSize notin [16, 32]:
    quit("P10 roster must be 16 or 32", 2)
  let
    pool = loadBrS2PoolRaw()
    map = pool.loadMap(15)
    graph = map.buildMixedGraph()
    suffix = if rosterSize == 16: "r16-s15" else: "r32-s15"
    farDanger = corpus.findCase(
      &"m15-br-gen-22010-{suffix}-default-danger-far")
    nearDanger = corpus.findCase(
      &"m15-br-gen-22010-{suffix}-default-danger-near")
    farBlocked = corpus.findCase(
      &"m15-br-gen-22010-{suffix}-default-blocked-far")
    nearBlocked = corpus.findCase(
      &"m15-br-gen-22010-{suffix}-default-blocked-near")
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
  let row = if scenario == stuckReplans:
    let danger = map.buildOracleDanger(farBlocked)
    let refined = graph.buildRefined(map.buildHot(danger))
    let combined = buildCombinedCellCost(
      danger.buildWeights(farBlocked.profile), hazard)
    rowJson(map, graph, rosterSize, budget, scenario, farBlocked, nearBlocked,
      danger, refined, combined, hazard)
  else:
    let danger = map.buildOracleDanger(farDanger)
    let refined = graph.buildRefined(map.buildHot(danger))
    let combined = buildCombinedCellCost(
      danger.buildWeights(farDanger.profile), hazard)
    rowJson(map, graph, rosterSize, budget, scenario, farDanger, nearDanger,
      danger, refined, combined, hazard)
  stderr.writeLine &"P10.0 B={budget} roster={rosterSize} {scenario}"
  echo pretty(%*{
    "schema": "coworld_body_nav_p10_budget_row",
    "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "queue": "exact Dial width 1 Q4",
    "row": row
  })
