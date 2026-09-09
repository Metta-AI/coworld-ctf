## P9B Round 5.2: gameplay cost of steering while a route is pending.

import std/[algorithm, heapqueue, json, math, options, os, sequtils, strformat]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

const
  Budget = 12_288
  SampleTicks = [24, 48, 96, 172]
  DeadEndTicks = 8

type
  MotionState = object
    pos: BodyPoint
    velX, velY: int
    noProgressRun, noProgressTicks: int
    deadEnd: bool

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc percentileFloat(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc staticDistances(table: FineLegality, goal: BodyPoint): seq[int32] =
  result = newSeq[int32](table.legal.len)
  for value in result.mitems: value = high(int32)
  let goalNode = goal.y div 4 * table.width + goal.x div 4
  doAssert goal.x mod 4 == 0 and goal.y mod 4 == 0 and
    table.standable.bitAt(goalNode)
  var queue = initHeapQueue[(int32, int32)]()
  result[goalNode] = 0
  queue.push((0'i32, int32(goalNode)))
  while queue.len > 0:
    let (distance, rawNode) = queue.pop()
    let node = rawNode.int
    if distance != result[node]: continue
    let
      x = node mod table.width
      y = node div table.width
      legal = table.legal[node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let nextNode = (y + delta.y) * table.width + x + delta.x
      let candidate = distance + (if direction >= 4: 91'i32 else: 64'i32)
      if candidate < result[nextNode]:
        result[nextNode] = candidate
        queue.push((candidate, int32(nextNode)))

proc remainingDistance(table: FineLegality, distances: openArray[int32],
    point: BodyPoint): int32 =
  let
    centerX = clamp(int(round(point.x.float / 4.0)), 0, table.width - 1)
    centerY = clamp(int(round(point.y.float / 4.0)), 0, table.height - 1)
  result = high(int32)
  for dy in -2 .. 2:
    for dx in -2 .. 2:
      let x = centerX + dx
      let y = centerY + dy
      if x < 0 or x >= table.width or y < 0 or y >= table.height: continue
      let node = y * table.width + x
      if distances[node] == high(int32): continue
      let attachment = int32(round(hypot(
        (point.x - x * 4).float, (point.y - y * 4).float) * 16.0))
      result = min(result, distances[node] + attachment)

proc geodesicMask(map: BodyMap, table: FineLegality,
    distances: openArray[int32], state: MotionState): uint8 =
  var best = table.remainingDistance(distances, state.pos)
  for delta in NavNeighbors:
    let candidate = (state.pos.x + delta.x * NavCell,
      state.pos.y + delta.y * NavCell)
    if not map.canStand(candidate) or
        not map.segmentClear(state.pos, candidate): continue
    let distance = table.remainingDistance(distances, candidate)
    if distance < best:
      best = distance
      result = 0
      if delta.x < 0: result = result or ButtonLeft
      elif delta.x > 0: result = result or ButtonRight
      if delta.y < 0: result = result or ButtonUp
      elif delta.y > 0: result = result or ButtonDown

proc move(map: BodyMap, state: var MotionState, mask: uint8) =
  let
    inputX = (if (mask and ButtonRight) != 0: 1 else: 0) -
      (if (mask and ButtonLeft) != 0: 1 else: 0)
    inputY = (if (mask and ButtonDown) != 0: 1 else: 0) -
      (if (mask and ButtonUp) != 0: 1 else: 0)
  if inputX != 0:
    state.velX = clamp(state.velX + inputX * Accel, -MaxSpeed, MaxSpeed)
  else:
    state.velX = state.velX * FrictionNum div FrictionDen
  if inputY != 0:
    state.velY = clamp(state.velY + inputY * Accel, -MaxSpeed, MaxSpeed)
  else:
    state.velY = state.velY * FrictionNum div FrictionDen
  let
    dx = state.velX div MotionScale
    dy = state.velY div MotionScale
    diagonal = (state.pos.x + dx, state.pos.y + dy)
    horizontal = (state.pos.x + dx, state.pos.y)
    vertical = (state.pos.x, state.pos.y + dy)
  if map.canStand(diagonal) and map.segmentClear(state.pos, diagonal):
    state.pos = diagonal
  else:
    if map.canStand(horizontal) and map.segmentClear(state.pos, horizontal):
      state.pos = horizontal
    else:
      state.velX = 0
    if map.canStand(vertical) and map.segmentClear(state.pos, vertical):
      state.pos = vertical
    else:
      state.velY = 0

proc rowJson(pool: JsonNode, corpus: NavCorpus, rosterSize: int): JsonNode =
  let
    suffix = if rosterSize == 16: "r16-s15" else: "r32-s15"
    item = corpus.findCase(
      &"m15-br-gen-22010-{suffix}-default-danger-far")
    map = pool.loadMap(item.poolIndex)
    graph = map.buildMixedGraph()
    danger = map.buildOracleDanger(item)
    refined = graph.buildRefined(map.buildHot(danger))
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
    combined = buildCombinedCellCost(danger.buildWeights(item.profile), hazard)
    maxEdge = graph.maximumEdgeCost(combined, hazard)
    fineDistances = graph.legality.staticDistances(item.validatedGoal)
  let nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats: seat.danger = danger
  var
    workspace = newDialWorkspace(graph.nodeCount, 1, maxEdge)
    job: DialJob
    activeSeat = 0
    scheduled = newSeq[MotionState](rosterSize)
    ideal = newSeq[MotionState](rosterSize)
    routeInstalled = newSeq[bool](rosterSize)
    installTicks = newSeq[int](rosterSize)
    samples: array[SampleTicks.len, seq[float64]]
    sampleScheduled: array[SampleTicks.len, seq[int32]]
    sampleIdeal: array[SampleTicks.len, seq[int32]]
  for seat in 0 ..< rosterSize:
    scheduled[seat].pos = item.start
    ideal[seat].pos = item.start
  job.startDialJob(graph, map, item, refined, combined, hazard, workspace)
  for tick in 1 .. SampleTicks[^1]:
    var remaining = Budget
    while activeSeat < rosterSize and remaining > 0:
      let used = job.stepDialJob(graph, map, refined, combined, hazard,
        workspace, remaining)
      remaining -= used
      if not job.complete: break
      let found = job.finishDialJob(graph, workspace)
      doAssert found.reached and map.routeLegal(item, found.route)
      routeInstalled[activeSeat] = true
      installTicks[activeSeat] = tick
      inc activeSeat
      if activeSeat < rosterSize:
        job.startDialJob(graph, map, item, refined, combined, hazard, workspace)
    for seat in 0 ..< rosterSize:
      let before = graph.legality.remainingDistance(fineDistances,
        scheduled[seat].pos)
      let scheduledMask = if routeInstalled[seat]:
          map.geodesicMask(graph.legality, fineDistances, scheduled[seat])
        else:
          nav.steeringMask(seat, scheduled[seat].pos, item.validatedGoal,
            item.profile.corpusProfile, tick)
      map.move(scheduled[seat], scheduledMask)
      let after = graph.legality.remainingDistance(fineDistances,
        scheduled[seat].pos)
      if not routeInstalled[seat]:
        if after >= before:
          inc scheduled[seat].noProgressRun
          inc scheduled[seat].noProgressTicks
          if scheduled[seat].noProgressRun >= DeadEndTicks:
            scheduled[seat].deadEnd = true
        else:
          scheduled[seat].noProgressRun = 0
      let idealMask = map.geodesicMask(graph.legality, fineDistances,
        ideal[seat])
      map.move(ideal[seat], idealMask)
    for sampleIndex, sampleTick in SampleTicks:
      if tick != sampleTick: continue
      for seat in 0 ..< rosterSize:
        let
          scheduledDistance = graph.legality.remainingDistance(
            fineDistances, scheduled[seat].pos)
          idealDistance = graph.legality.remainingDistance(
            fineDistances, ideal[seat].pos)
          ratio = if idealDistance <= 0:
              (if scheduledDistance <= 0: 1.0 else: Inf)
            else: scheduledDistance.float / idealDistance.float
        sampleScheduled[sampleIndex].add scheduledDistance
        sampleIdeal[sampleIndex].add idealDistance
        samples[sampleIndex].add ratio
  var sampleRows = newJArray()
  for sampleIndex, tick in SampleTicks:
    sampleRows.add %*{"tick": tick,
      "remaining_ratio_p50": percentileFloat(samples[sampleIndex], 0.50),
      "remaining_ratio_p95": percentileFloat(samples[sampleIndex], 0.95),
      "remaining_ratio_max": max(samples[sampleIndex]),
      "scheduled_remaining_q4_p50": percentileFloat(
        sampleScheduled[sampleIndex].mapIt(it.float), 0.50),
      "ideal_remaining_q4_p50": percentileFloat(
        sampleIdeal[sampleIndex].mapIt(it.float), 0.50)}
  var deadEnds, noProgressTicks = 0
  for state in scheduled:
    if state.deadEnd: inc deadEnds
    noProgressTicks += state.noProgressTicks
  %*{"roster_size": rosterSize, "pop_budget": Budget,
    "route_install_tail_ticks": max(installTicks),
    "dead_end_threshold_no_progress_ticks": DeadEndTicks,
    "seats_with_dead_end_before_route": deadEnds,
    "total_no_progress_ticks_before_route": noProgressTicks,
    "samples": sampleRows}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r52 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r52", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "motion_model":
      "game constants with collision-checked integer acceleration, friction, and speed",
    "distance_model": "static exact 4 px legality, 64/91 Q4 geodesic",
    "post_install_control":
      "both arms use ideal static-geodesic descent; only pending control differs",
    "rows": [pool.rowJson(corpus, 16), pool.rowJson(corpus, 32)]})
