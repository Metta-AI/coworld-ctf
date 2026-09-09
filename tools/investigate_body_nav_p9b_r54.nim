## P9B Round 5.4: equal-budget K=1/2/4 workspace scheduling.

import std/[algorithm, json, math, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

const Quantum = 1_024

type
  Scenario = enum
    firstGoals = "first_goal_burst"
    movingGoals = "moving_goal_12_tick_cadence"
    stuckReplans = "stuck_replans"

  RunResult = object
    slices: seq[int64]
    routeTicks: seq[int]
    completed, superseded, goalRestarts, dangerRestarts: int
    queuePops, steeringTicks: int
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

proc simulate(map: BodyMap, graph: MixedGraph, nav: BodyNavSystem,
    farItem, nearItem: NavCorpusCase, refined: seq[uint8],
    combined, hazard: seq[int32], rosterSize, budget, workspaceCount: int,
    scenario: Scenario, reverseInput, recordTime: bool): RunResult =
  let maxEdge = graph.maximumEdgeCost(combined, hazard)
  var
    workspaces = newSeq[DialWorkspace](workspaceCount)
    jobs = newSeq[DialJob](workspaceCount)
    activeSeats = newSeq[int](workspaceCount)
    activeIssued = newSeq[int](workspaceCount)
    activeNear = newSeq[bool](workspaceCount)
    pending = newSeq[bool](rosterSize)
    pendingIssued = newSeq[int](rosterSize)
    pendingNear = newSeq[bool](rosterSize)
    routed = newSeq[bool](rosterSize)
    waypoint = newSeq[BodyPoint](rosterSize)
    queue: seq[int]
    rrCursor = 0
    tick = 0
    lastWave = case scenario
      of firstGoals: 1
      of movingGoals: 37
      of stuckReplans: 25
  for slot in 0 ..< workspaceCount:
    workspaces[slot] = newDialWorkspace(graph.nodeCount, 1, maxEdge)
    activeSeats[slot] = -1

  proc activeSlot(seat: int): int =
    for slot, activeSeat in activeSeats:
      if activeSeat == seat: return slot
    -1

  template startSlot(slot, seat: int, useNear: bool) =
    activeSeats[slot] = seat
    activeIssued[slot] = pendingIssued[seat]
    activeNear[slot] = useNear
    let item = if useNear: nearItem else: farItem
    jobs[slot].startDialJob(graph, map, item, refined, combined, hazard,
      workspaces[slot])

  template fillSlots() =
    for slot in 0 ..< workspaceCount:
      if activeSeats[slot] >= 0 or queue.len == 0: continue
      let seat = queue[0]
      queue.delete(0)
      pending[seat] = false
      startSlot(slot, seat, pendingNear[seat])

  template requestAll(useNear: bool) =
    var arrivals = newSeq[int](rosterSize)
    for seat in 0 ..< rosterSize:
      arrivals[seat] = if reverseInput: rosterSize - 1 - seat else: seat
    arrivals.sort()
    for seat in arrivals:
      routed[seat] = false
      let slot = activeSlot(seat)
      if slot >= 0:
        activeIssued[slot] = tick
        activeNear[slot] = useNear
        let item = if useNear: nearItem else: farItem
        jobs[slot].startDialJob(graph, map, item, refined, combined, hazard,
          workspaces[slot])
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
      if tick in [1, 13, 25, 37]:
        requestAll(((tick - 1) div 12 and 1) != 0)
    of stuckReplans:
      if tick in [1, 9, 17, 25]: requestAll(false)
    let dangerChanged =
      (scenario == movingGoals and tick in [17, 34]) or
      (scenario == stuckReplans and tick == 19)
    if dangerChanged:
      for slot, seat in activeSeats:
        if seat < 0: continue
        let item = if activeNear[slot]: nearItem else: farItem
        jobs[slot].startDialJob(graph, map, item, refined, combined, hazard,
          workspaces[slot])
        inc result.dangerRestarts
    fillSlots()
    var
      remaining = budget
      idleVisits = 0
    while remaining > 0 and idleVisits < workspaceCount:
      let slot = rrCursor
      rrCursor = (rrCursor + 1) mod workspaceCount
      if activeSeats[slot] < 0:
        inc idleVisits
        continue
      idleVisits = 0
      let use = min(remaining, Quantum)
      let item = if activeNear[slot]: nearItem else: farItem
      let used = jobs[slot].stepDialJob(graph, map, refined, combined, hazard,
        workspaces[slot], use)
      remaining -= used
      result.queuePops += used
      if not jobs[slot].complete: continue
      let found = jobs[slot].finishDialJob(graph, workspaces[slot])
      doAssert found.reached and map.routeLegal(item, found.route)
      let seat = activeSeats[slot]
      routed[seat] = true
      waypoint[seat] = if found.route.len > 1:
          found.route[1] else: item.validatedGoal
      result.routeTicks.add tick - activeIssued[slot] + 1
      result.fingerprint.hashRoute(seat, tick, found.route)
      inc result.completed
      activeSeats[slot] = -1
      fillSlots()
    for seat in 0 ..< rosterSize:
      let slot = activeSlot(seat)
      if slot >= 0 or pending[seat]:
        let goal = if slot >= 0:
            (if activeNear[slot]: nearItem.validatedGoal
             else: farItem.validatedGoal)
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
    var active = false
    for seat in activeSeats: active = active or seat >= 0
    if tick >= lastWave and not active and queue.len == 0: break
  doAssert tick < 2_000
  result.fingerprint = result.fingerprint xor uint64(
    result.completed * 31 + result.superseded * 43 +
    result.goalRestarts * 59 + result.dangerRestarts * 71 +
    result.steeringTicks * 83)
  for value in result.routeTicks:
    result.fingerprint = result.fingerprint * 1_099_511_628_211'u64 xor
      uint64(value)

proc rowJson(map: BodyMap, graph: MixedGraph, rosterSize, budget,
    workspaceCount: int, scenario: Scenario, farItem, nearItem: NavCorpusCase,
    refined: seq[uint8], combined, hazard: seq[int32]): JsonNode =
  let danger = map.buildOracleDanger(farItem)
  let nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats: seat.danger = danger
  let
    measured = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, workspaceCount, scenario,
      false, true)
    repeated = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, workspaceCount, scenario,
      false, false)
    permuted = simulate(map, graph, nav, farItem, nearItem, refined,
      combined, hazard, rosterSize, budget, workspaceCount, scenario,
      true, false)
  doAssert measured.fingerprint == repeated.fingerprint
  doAssert measured.fingerprint == permuted.fingerprint
  let denseBytes = graph.nodeCount * (sizeof(int32) * 4 + sizeof(uint32) * 2)
  %*{"scenario": $scenario, "roster_size": rosterSize,
    "pop_budget": budget, "workspace_count": workspaceCount,
    "round_robin_quantum": Quantum,
    "navigation_slice_p50_ns": percentileInt(measured.slices, 0.50),
    "navigation_slice_p95_ns": percentileInt(measured.slices, 0.95),
    "navigation_slice_max_ns": max(measured.slices),
    "time_to_route_ticks_p50": percentileInt(measured.routeTicks, 0.50),
    "time_to_route_ticks_p95": percentileInt(measured.routeTicks, 0.95),
    "time_to_route_ticks_max": max(measured.routeTicks),
    "queue_pops": measured.queuePops,
    "steering_ticks": measured.steeringTicks,
    "dense_workspace_bytes": denseBytes * workspaceCount,
    "deterministic_repeat": true,
    "deterministic_permuted_input": true,
    "fingerprint": measured.fingerprint}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r54 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    map = pool.loadMap(15)
    graph = map.buildMixedGraph()
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
  var rows = newJArray()
  for workspaceCount in [1, 2, 4]:
    for budget in [4_096, 8_192, 12_288]:
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
          stderr.writeLine &"R5.4 K={workspaceCount} B={budget} roster={rosterSize} {scenario}"
          if scenario == stuckReplans:
            rows.add rowJson(map, graph, rosterSize, budget, workspaceCount,
              scenario, farBlocked, nearBlocked, blockedRefined,
              blockedCombined, hazard)
          else:
            rows.add rowJson(map, graph, rosterSize, budget, workspaceCount,
              scenario, farDanger, nearDanger, dangerRefined,
              dangerCombined, hazard)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r54", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "scheduler": "single-threaded stable round robin, equal total pop budget",
    "rows": rows})
