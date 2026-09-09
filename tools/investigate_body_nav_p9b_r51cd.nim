## P9B Round 5.1c/d: Dial-loop micro-optimisation and bounded warm starts.

import std/[algorithm, bitops, json, math, monotimes, options, os, strformat,
  times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

const
  ClosedBit = 0x8000_0000'u32
  WarmNodeCap = 128
  Samples = 15

type
  Scenario = enum
    firstGoals = "first_goal_burst"
    movingGoals = "moving_goal_12_tick_cadence"
    stuckReplans = "stuck_replans"

  LoopKind = enum
    acceptedDial = "accepted_dial"
    stagedNeighbors = "staged_neighbors"
    stagedWarm128 = "staged_neighbors_warm_128"

  RunResult = object
    slices: seq[int64]
    routeTicks: seq[int]
    completed, superseded, goalRestarts, dangerRestarts: int
    queuePops, settledPops, warmSeeds, steeringTicks: int
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

proc stepDialJobStaged(job: var DialJob, graph: MixedGraph, map: BodyMap,
    refined: openArray[uint8], combined: openArray[int32],
    workspace: var DialWorkspace, popBudget: int): int =
  ## The accepted workspace is already structure-of-arrays. This variant
  ## stages legal neighbour indices/stamps before pricing them, walks only set
  ## legality bits, computes midpoint cells arithmetically, and reads queued g
  ## before the stamp on the overwhelmingly-common fresh-pop path.
  if not job.active or job.complete: return
  while result < popBudget and workspace.queue.len > 0:
    let entry = workspace.queue.pop()
    inc result
    let node = entry.node.int
    if workspace.g[node] != entry.g or
        workspace.state[node] != job.generation:
      continue
    if entry.f >= job.bestCost:
      job.complete = true
      break
    workspace.state[node] = job.generation or ClosedBit
    inc job.pops
    let currentG = entry.g
    if workspace.goalStamp[node] == job.generation:
      let total = currentG.int64 + workspace.goalCost[node].int64
      if total < job.bestCost.int64:
        job.bestCost = int32(total)
        job.bestNode = node
    let
      fineX = node mod graph.legality.width
      fineY = node div graph.legality.width
      legal = graph.legality.legal[node]
    var
      directions: array[8, int]
      nextNodes: array[8, int]
      nextStamps: array[8, uint32]
      moveCount = 0
      moves = legal
    while moves != 0:
      let direction = countTrailingZeroBits(moves).int
      moves = moves and (moves - 1)
      let delta = NavNeighbors[direction]
      directions[moveCount] = direction
      nextNodes[moveCount] = (fineY + delta.y) * graph.legality.width +
        fineX + delta.x
      nextStamps[moveCount] = workspace.state[nextNodes[moveCount]]
      inc moveCount
    for offset in 0 ..< moveCount:
      let
        direction = directions[offset]
        delta = NavNeighbors[direction]
        nextNode = nextNodes[offset]
        stamp = nextStamps[offset]
      if graph.active(refined, nextNode, job.startNode, job.goalNode) and
          stamp != (job.generation or ClosedBit):
        let
          cellX = (fineX * 4 + delta.x * 2) div NavCell
          cellY = (fineY * 4 + delta.y * 2) div NavCell
          cell = cellY * map.gridWidth + cellX
          baseCost = stepCost(combined[cell], direction >= 4)
          edgeCost = if cell == job.blockedCell: baseCost * 8 else: baseCost
          candidate = currentG + edgeCost
        if stamp != job.generation or candidate < workspace.g[nextNode]:
          workspace.g[nextNode] = candidate
          workspace.parent[nextNode] = int32(node)
          workspace.parentBridge[nextNode] = -1
          let heuristic = max(0'i32, octileQ4(
            pointAt(nextNode, graph.legality.width),
            job.item.validatedGoal, 90) - job.allowance)
          workspace.queue.push(candidate + heuristic,
            candidate, int32(nextNode))
          workspace.state[nextNode] = job.generation
    if graph.anchorNode[node] != 0:
      let
        sourceCell = graph.cellForNode[node].int
        fromPoint = pointAt(node, graph.legality.width)
      for direction in 0 ..< 8:
        let
          bridgeOffset = graph.bridgeOffset[sourceCell][direction].int
          pathLen = graph.bridgeLen[sourceCell][direction].int
        if bridgeOffset < 0 or pathLen == 0: continue
        let target = graph.bridgeNodes[bridgeOffset + pathLen - 1].int
        if workspace.state[target] == (job.generation or ClosedBit): continue
        var
          edgeCost = 0'i32
          previous = fromPoint
        for pathIndex in 0 ..< pathLen:
          let nextPoint = pointAt(
            graph.bridgeNodes[bridgeOffset + pathIndex].int,
            graph.legality.width)
          let
            dx = abs(nextPoint.x - previous.x)
            dy = abs(nextPoint.y - previous.y)
            cell = map.midpointCell(previous, nextPoint)
            baseCost = stepCost(combined[cell], dx != 0 and dy != 0)
            priced = if cell == job.blockedCell: baseCost * 8 else: baseCost
          edgeCost += priced
          previous = nextPoint
        let candidate = currentG + edgeCost
        if workspace.state[target] != job.generation or
            candidate < workspace.g[target]:
          workspace.g[target] = candidate
          workspace.parent[target] = int32(node)
          workspace.parentBridge[target] = int32(sourceCell * 8 + direction)
          let heuristic = max(0'i32, octileQ4(previous,
            job.item.validatedGoal, 90) - job.allowance)
          workspace.queue.push(candidate + heuristic,
            candidate, int32(target))
          workspace.state[target] = job.generation
  if workspace.queue.len == 0:
    job.complete = true

proc seedWarmRoute(job: var DialJob, graph: MixedGraph, map: BodyMap,
    refined: openArray[uint8], combined: openArray[int32],
    workspace: var DialWorkspace, route: openArray[BodyPoint]): int =
  ## Insert at most 128 nodes from a previously-installed legal route. Each
  ## seeded g is recomputed under the new table and retains a concrete parent
  ## chain from an ordinary start attachment, so it is a valid A* upper path,
  ## not a heuristic shortcut.
  if route.len < 2 or route[0] != job.item.start: return
  var
    previousNode = -1
    previousPoint = route[0]
  for point in route:
    if result >= WarmNodeCap: break
    if point.x mod 4 != 0 or point.y mod 4 != 0:
      previousPoint = point
      continue
    let node = point.y div 4 * graph.legality.width + point.x div 4
    if node < 0 or node >= graph.nodeCount or
        not graph.active(refined, node, job.startNode, job.goalNode):
      break
    if previousNode < 0:
      if workspace.state[node] == job.generation:
        previousNode = node
        inc result
      previousPoint = point
      continue
    let
      cell = map.midpointCell(previousPoint, point)
      diagonal = previousPoint.x != point.x and previousPoint.y != point.y
      baseCost = stepCost(combined[cell], diagonal)
      edgeCost = if cell == job.blockedCell: baseCost * 8 else: baseCost
      candidate = workspace.g[previousNode] + edgeCost
    if workspace.state[node] != job.generation or
        candidate < workspace.g[node]:
      workspace.g[node] = candidate
      workspace.parent[node] = int32(previousNode)
      workspace.parentBridge[node] = -1
      let heuristic = max(0'i32, octileQ4(point,
        job.item.validatedGoal, 90) - job.allowance)
      workspace.queue.push(candidate + heuristic, candidate, int32(node))
      workspace.state[node] = job.generation
    previousNode = node
    previousPoint = point
    inc result

proc advance(job: var DialJob, kind: LoopKind, graph: MixedGraph,
    map: BodyMap, refined: openArray[uint8], combined,
    hazard: openArray[int32], workspace: var DialWorkspace,
    budget: int): int =
  if kind == acceptedDial:
    job.stepDialJob(graph, map, refined, combined, hazard, workspace, budget)
  else:
    job.stepDialJobStaged(graph, map, refined, combined, workspace, budget)

proc profileCase(pool: JsonNode, corpus: NavCorpus, id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    graph = map.buildMixedGraph()
    danger = map.buildOracleDanger(item)
    refined = graph.buildRefined(map.buildHot(danger))
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
    combined = buildCombinedCellCost(danger.buildWeights(item.profile), hazard)
    maxEdge = graph.maximumEdgeCost(combined, hazard)
  var rows = newJArray()
  for kind in [acceptedDial, stagedNeighbors]:
    var
      workspace = newDialWorkspace(graph.nodeCount, 1, maxEdge)
      samplesNs, samplesQueuePops, samplesSettledPops, nsPerPop: seq[int64]
      routeHash = 0'u64
    for _ in 0 ..< Samples:
      var job: DialJob
      job.startDialJob(graph, map, item, refined, combined, hazard, workspace)
      let started = getMonoTime()
      let used = job.advance(kind, graph, map, refined, combined, hazard,
        workspace, high(int))
      let elapsed = (getMonoTime() - started).inNanoseconds
      let found = job.finishDialJob(graph, workspace)
      doAssert found.reached and map.routeLegal(item, found.route)
      samplesNs.add elapsed
      samplesQueuePops.add used.int64
      samplesSettledPops.add found.pops.int64
      nsPerPop.add elapsed div max(1, found.pops).int64
      for point in found.route:
        routeHash = routeHash * 1_099_511_628_211'u64 xor
          uint64(point.x * 65_537 + point.y)
    rows.add %*{"loop": $kind,
      "query_ns_p50": percentileInt(samplesNs, 0.50),
      "query_ns_p95": percentileInt(samplesNs, 0.95),
      "queue_pops_p50": percentileInt(samplesQueuePops, 0.50),
      "queue_pops_p95": percentileInt(samplesQueuePops, 0.95),
      "settled_pops_p50": percentileInt(samplesSettledPops, 0.50),
      "settled_pops_p95": percentileInt(samplesSettledPops, 0.95),
      "ns_per_settled_pop_p50": percentileInt(nsPerPop, 0.50),
      "ns_per_settled_pop_p95": percentileInt(nsPerPop, 0.95),
      "route_hash": routeHash}
  %*{"id": id, "rows": rows}

proc simulate(map: BodyMap, graph: MixedGraph, nav: BodyNavSystem,
    farItem, nearItem: NavCorpusCase, refined: seq[uint8],
    combined, hazard: seq[int32], rosterSize, budget: int,
    scenario: Scenario, kind: LoopKind, reverseInput,
    recordTime: bool): RunResult =
  let maxEdge = graph.maximumEdgeCost(combined, hazard)
  var
    workspace = newDialWorkspace(graph.nodeCount, 1, maxEdge)
    job: DialJob
    activeSeat = -1
    activeIssued = 0
    activeItem = farItem
    activeRoute: seq[BodyPoint]
    pending = newSeq[bool](rosterSize)
    pendingIssued = newSeq[int](rosterSize)
    pendingNear = newSeq[bool](rosterSize)
    routes = newSeq[seq[BodyPoint]](rosterSize)
    waypoint = newSeq[BodyPoint](rosterSize)
    queue: seq[int]
    tick = 0
    lastWave = case scenario
      of firstGoals: 1
      of movingGoals: 37
      of stuckReplans: 25

  template beginJob(seat: int, item: NavCorpusCase) =
    job.startDialJob(graph, map, item, refined, combined, hazard, workspace)
    if kind == stagedWarm128:
      let seeded = job.seedWarmRoute(graph, map, refined, combined,
        workspace, routes[seat])
      result.warmSeeds += seeded

  template requestAll(useNear: bool) =
    var arrivals = newSeq[int](rosterSize)
    for seat in 0 ..< rosterSize:
      arrivals[seat] = if reverseInput: rosterSize - 1 - seat else: seat
    arrivals.sort()
    for seat in arrivals:
      if seat == activeSeat:
        activeIssued = tick
        activeItem = if useNear: nearItem else: farItem
        beginJob(seat, activeItem)
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
    if dangerChanged and activeSeat >= 0:
      beginJob(activeSeat, activeItem)
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
        beginJob(activeSeat, activeItem)
      let used = job.advance(kind, graph, map, refined, combined, hazard,
        workspace, remaining)
      remaining -= used
      result.queuePops += used
      if not job.complete: break
      let found = job.finishDialJob(graph, workspace)
      doAssert found.reached and map.routeLegal(activeItem, found.route)
      routes[activeSeat] = found.route
      activeRoute = found.route
      waypoint[activeSeat] = if found.route.len > 1:
          found.route[1] else: activeItem.validatedGoal
      result.routeTicks.add tick - activeIssued + 1
      result.fingerprint.hashRoute(activeSeat, tick, activeRoute)
      result.settledPops += found.pops
      inc result.completed
      activeSeat = -1
    for seat in 0 ..< rosterSize:
      if seat == activeSeat or pending[seat]:
        let goal = if seat == activeSeat: activeItem.validatedGoal
          elif pendingNear[seat]: nearItem.validatedGoal
          else: farItem.validatedGoal
        result.fingerprint = result.fingerprint xor uint64(
          nav.steeringMask(seat, farItem.start, goal,
            farItem.profile.corpusProfile, tick))
        inc result.steeringTicks
      elif routes[seat].len > 0:
        result.fingerprint = result.fingerprint xor uint64(
          octantToward(farItem.start, waypoint[seat]))
    if recordTime:
      result.slices.add (getMonoTime() - started).inNanoseconds
    if tick >= lastWave and activeSeat < 0 and queue.len == 0: break
  doAssert tick < 2_000
  result.fingerprint = result.fingerprint xor uint64(
    result.completed * 31 + result.superseded * 43 +
    result.goalRestarts * 59 + result.dangerRestarts * 71 +
    result.warmSeeds * 83 + result.steeringTicks * 97)
  for value in result.routeTicks:
    result.fingerprint = result.fingerprint * 1_099_511_628_211'u64 xor
      uint64(value)

proc rowJson(map: BodyMap, graph: MixedGraph, rosterSize, budget: int,
    scenario: Scenario, kind: LoopKind, farItem, nearItem: NavCorpusCase,
    refined: seq[uint8], combined, hazard: seq[int32]): JsonNode =
  let danger = map.buildOracleDanger(farItem)
  let nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats:
    seat.danger = danger
  let
    measured = simulate(map, graph, nav, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, kind, false, true)
    repeated = simulate(map, graph, nav, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, kind, false, false)
    permuted = simulate(map, graph, nav, farItem, nearItem, refined, combined,
      hazard, rosterSize, budget, scenario, kind, true, false)
  doAssert measured.fingerprint == repeated.fingerprint
  doAssert measured.fingerprint == permuted.fingerprint
  %*{"scenario": $scenario, "loop": $kind,
    "roster_size": rosterSize, "pop_budget": budget,
    "navigation_slice_p50_ns": percentileInt(measured.slices, 0.50),
    "navigation_slice_p95_ns": percentileInt(measured.slices, 0.95),
    "navigation_slice_max_ns": max(measured.slices),
    "time_to_route_ticks_p50": percentileInt(measured.routeTicks, 0.50),
    "time_to_route_ticks_p95": percentileInt(measured.routeTicks, 0.95),
    "time_to_route_ticks_max": max(measured.routeTicks),
    "queue_pops": measured.queuePops,
    "settled_pops": measured.settledPops,
    "warm_seed_nodes": measured.warmSeeds,
    "steering_ticks": measured.steeringTicks,
    "completed_routes": measured.completed,
    "deterministic_repeat": true,
    "deterministic_permuted_input": true,
    "fingerprint": measured.fingerprint}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r51cd CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    map = pool.loadMap(15)
    graph = map.buildMixedGraph()
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
  var rows = newJArray()
  for kind in LoopKind:
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
          stderr.writeLine &"R5.1 {kind} B={budget} roster={rosterSize} {scenario}"
          if scenario == stuckReplans:
            rows.add rowJson(map, graph, rosterSize, budget, scenario, kind,
              farBlocked, nearBlocked, blockedRefined, blockedCombined, hazard)
          else:
            rows.add rowJson(map, graph, rosterSize, budget, scenario, kind,
              farDanger, nearDanger, dangerRefined, dangerCombined, hazard)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r51cd", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "warm_node_cap": WarmNodeCap,
    "profiles": [
      pool.profileCase(corpus,
        "m09-br-gen-21450-r32-s9-default-blocked-far"),
      pool.profileCase(corpus,
        "m15-br-gen-22010-r16-s15-default-danger-far")],
    "rows": rows})
