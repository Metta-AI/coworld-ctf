## P9B Round 5.1a/b: SJF admission and budget-charged two-phase probes.

import std/[algorithm, json, math, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/body_map
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

type
  Scenario = enum
    firstGoals = "first_goal_burst"
    movingGoals = "moving_goal_12_tick_cadence"
    stuckReplans = "stuck_replans"

  Admission = enum
    fifo = "fifo"
    shortestJobFirst = "shortest_job_first"
    twoPhase1024 = "two_phase_1024"

  RunResult = object
    slices: seq[int64]
    routeTicks, nearRouteTicks, farRouteTicks: seq[int]
    completed, nearCompleted, farCompleted: int
    completedInIssueTick, nearCompletedInIssueTick: int
    probeAttempts, discardedProbePops, searchPops: int
    superseded, goalRestarts, dangerRestarts: int
    fingerprint: uint64

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc percentileInt(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc percentileInt(values: openArray[int], fraction: float64): int =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc hashRoute(value: var uint64, seat, tick: int,
    route: openArray[BodyPoint]) =
  value = (value xor uint64(seat + tick * 257)) * 1_099_511_628_211'u64
  for point in route:
    value = (value xor uint64(point.x * 65_537 + point.y)) *
      1_099_511_628_211'u64

proc simulate(map: BodyMap, graph: MixedGraph,
    farItem, nearItem: NavCorpusCase, refined: seq[uint8],
    combined, hazard: seq[int32], rosterSize, budget: int,
    scenario: Scenario, admission: Admission, reverseInput,
    recordTime: bool): RunResult =
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
    queue: seq[int]
    tick = 0
    remaining = 0
    lastWave = case scenario
      of firstGoals: 1
      of movingGoals: 37
      of stuckReplans: 25

  template completeRoute(seat, issued: int, useNear: bool,
      found: DialResult) =
    doAssert found.reached and map.routeLegal(
      (if useNear: nearItem else: farItem), found.route)
    let latency = tick - issued + 1
    result.routeTicks.add latency
    if useNear:
      result.nearRouteTicks.add latency
      inc result.nearCompleted
    else:
      result.farRouteTicks.add latency
      inc result.farCompleted
    if tick == issued:
      inc result.completedInIssueTick
      if useNear: inc result.nearCompletedInIssueTick
    result.fingerprint.hashRoute(seat, tick, found.route)
    inc result.completed

  proc selectPending(): int =
    if queue.len == 0: return -1
    var bestOffset = 0
    if admission == shortestJobFirst:
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
    var arrivals = newSeq[int](rosterSize)
    for seat in 0 ..< rosterSize:
      arrivals[seat] = if reverseInput: rosterSize - 1 - seat else: seat
    arrivals.sort()
    for seat in arrivals:
      let useNear = if scenario == stuckReplans: false
        else: waveNear xor ((seat and 1) == 0)
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
      elif admission == twoPhase1024 and remaining >= 1_024:
        let probeItem = if useNear: nearItem else: farItem
        job.startDialJob(graph, map, probeItem, refined, combined, hazard,
          workspace)
        let used = job.stepDialJob(graph, map, refined, combined, hazard,
          workspace, 1_024)
        remaining -= used
        inc result.probeAttempts
        if job.complete:
          let found = job.finishDialJob(graph, workspace)
          completeRoute(seat, tick, useNear, found)
        else:
          result.discardedProbePops += used
          pending[seat] = true
          pendingIssued[seat] = tick
          pendingNear[seat] = useNear
          queue.add seat
        job = DialJob()
      else:
        pending[seat] = true
        pendingIssued[seat] = tick
        pendingNear[seat] = useNear
        queue.add seat

  while tick < 2_000:
    inc tick
    let started = getMonoTime()
    remaining = budget
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
      let used = job.stepDialJob(graph, map, refined, combined, hazard,
        workspace, remaining)
      remaining -= used
      result.searchPops += used
      if not job.complete: break
      let found = job.finishDialJob(graph, workspace)
      completeRoute(activeSeat, activeIssued, activeNear, found)
      activeSeat = -1

    if recordTime:
      result.slices.add (getMonoTime() - started).inNanoseconds
    if tick >= lastWave and activeSeat < 0 and queue.len == 0:
      break
  doAssert tick < 2_000
  result.fingerprint = result.fingerprint xor uint64(
    result.completed * 31 + result.completedInIssueTick * 43 +
    result.discardedProbePops * 59 + result.superseded * 71 +
    result.goalRestarts * 83 + result.dangerRestarts * 97)
  for value in result.routeTicks:
    result.fingerprint = result.fingerprint * 1_099_511_628_211'u64 xor
      uint64(value)

proc rowJson(map: BodyMap, graph: MixedGraph, rosterSize, budget: int,
    scenario: Scenario, admission: Admission,
    farItem, nearItem: NavCorpusCase,
    refined: seq[uint8], combined, hazard: seq[int32]): JsonNode =
  let
    measured = simulate(map, graph, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, admission, false, true)
    repeated = simulate(map, graph, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, admission, false, false)
    permuted = simulate(map, graph, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, admission, true, false)
  doAssert measured.fingerprint == repeated.fingerprint
  doAssert measured.fingerprint == permuted.fingerprint
  %*{"scenario": $scenario, "admission": $admission,
    "roster_size": rosterSize, "pop_budget": budget,
    "workspace_count": 1, "probe_quota":
      (if admission == twoPhase1024: 1_024 else: 0),
    "navigation_slice_p50_ns": percentileInt(measured.slices, 0.50),
    "navigation_slice_p95_ns": percentileInt(measured.slices, 0.95),
    "navigation_slice_max_ns": max(measured.slices),
    "time_to_route_ticks_p50": percentileInt(measured.routeTicks, 0.50),
    "time_to_route_ticks_p95": percentileInt(measured.routeTicks, 0.95),
    "time_to_route_ticks_max": max(measured.routeTicks),
    "near_time_to_route_ticks_p50": percentileInt(measured.nearRouteTicks, 0.50),
    "near_time_to_route_ticks_p95": percentileInt(measured.nearRouteTicks, 0.95),
    "near_time_to_route_ticks_max":
      (if measured.nearRouteTicks.len == 0: 0 else: max(measured.nearRouteTicks)),
    "far_time_to_route_ticks_p50": percentileInt(measured.farRouteTicks, 0.50),
    "far_time_to_route_ticks_p95": percentileInt(measured.farRouteTicks, 0.95),
    "far_time_to_route_ticks_max":
      (if measured.farRouteTicks.len == 0: 0 else: max(measured.farRouteTicks)),
    "completed_routes": measured.completed,
    "near_routes": measured.nearCompleted, "far_routes": measured.farCompleted,
    "completed_in_issue_tick": measured.completedInIssueTick,
    "near_completed_in_issue_tick": measured.nearCompletedInIssueTick,
    "probe_attempts": measured.probeAttempts,
    "discarded_probe_pops": measured.discardedProbePops,
    "normal_search_pops": measured.searchPops,
    "deterministic_repeat": true,
    "deterministic_permuted_input": true,
    "fingerprint": measured.fingerprint}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r51ab CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    map = pool.loadMap(15)
    graph = map.buildMixedGraph()
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
  var rows = newJArray()
  for admission in Admission:
    for budget in [4_096, 8_192, 12_288, 16_384]:
      for rosterSize in [16, 32]:
        let
          suffix = if rosterSize == 16: "r16-s15" else: "r32-s15"
          farDanger = corpus.findCase(
            &"m15-br-gen-22010-{suffix}-default-danger-far")
          nearDanger = corpus.findCase(
            &"m15-br-gen-22010-{suffix}-default-danger-near")
          farBlocked = corpus.findCase(
            &"m15-br-gen-22010-{suffix}-default-blocked-far")
          nearBlocked = corpus.findCase(
            &"m15-br-gen-22010-{suffix}-default-blocked-near")
          danger = map.buildOracleDanger(farDanger)
          dangerRefined = graph.buildRefined(map.buildHot(danger))
          dangerCombined = buildCombinedCellCost(
            danger.buildWeights(farDanger.profile), hazard)
          noDanger = map.buildOracleDanger(farBlocked)
          blockedRefined = graph.buildRefined(map.buildHot(noDanger))
          blockedCombined = buildCombinedCellCost(
            noDanger.buildWeights(farBlocked.profile), hazard)
        for scenario in Scenario:
          stderr.writeLine &"R5.1 {admission} B={budget} roster={rosterSize} {scenario}"
          if scenario == stuckReplans:
            rows.add rowJson(map, graph, rosterSize, budget, scenario,
              admission, farBlocked, nearBlocked, blockedRefined,
              blockedCombined, hazard)
          else:
            rows.add rowJson(map, graph, rosterSize, budget, scenario,
              admission, farDanger, nearDanger, dangerRefined,
              dangerCombined, hazard)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r51ab", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "first_goal_mix": "even seats near, odd seats far",
    "two_phase_budget_contract":
      "1,024-pop probes share the total tick budget; unfinished probes are discarded",
    "rows": rows})
