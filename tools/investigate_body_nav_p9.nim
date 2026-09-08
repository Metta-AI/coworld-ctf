## Phase-9 investigation: single-query stage profiles and quality attribution.
## Compile with -d:navQueryProfile so production builds retain no counters.

import std/[algorithm, heapqueue, json, math, monotimes, options, os, sets,
  strformat, tables, times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_hazard, body_map, body_nav, body_planner,
  body_route_index, body_route_query]
import ../tests/nav_route_corpus_support

when not defined(navQueryProfile):
  {.error: "compile investigate_body_nav_p9 with -d:navQueryProfile".}

const ProfileSamples = 7

type RankedCase = object
  id: string
  inflation: float64

type
  CorridorNode = object
    priority, cost: float64
    cell: int

  CorridorScratch = object
    generation: uint32
    cost: seq[float64]
    parent: seq[int32]
    seenGeneration, closedGeneration: seq[uint32]

  CorridorResult = object
    reached: bool
    pops: int
    route: seq[BodyPoint]

proc `<`(a, b: CorridorNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.cell < b.cell

proc initCorridorScratch(cellCount: int): CorridorScratch =
  result.cost = newSeq[float64](cellCount)
  result.parent = newSeq[int32](cellCount)
  result.seenGeneration = newSeq[uint32](cellCount)
  result.closedGeneration = newSeq[uint32](cellCount)

proc beginQuery(scratch: var CorridorScratch) =
  inc scratch.generation
  if scratch.generation == 0:
    for stamp in scratch.seenGeneration.mitems: stamp = 0
    for stamp in scratch.closedGeneration.mitems: stamp = 0
    scratch.generation = 1

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0:
    return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc cmpRank(a, b: RankedCase): int =
  result = cmp(b.inflation, a.inflation)
  if result == 0:
    result = cmp(a.id, b.id)

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc findCase(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id:
      return item
  raise newException(ValueError, "corpus case not found: " & id)

proc blockedPoint(item: NavCorpusCase): Option[BodyPoint] =
  if item.blockedCell.isSome:
    some(cellCenter(item.blockedCell.get))
  else:
    none(BodyPoint)

proc queryRequest(map: BodyMap, item: NavCorpusCase,
    danger: var BodyDangerField): BodyRouteRequest =
  let goal = map.validateGoal(item.requestedGoal, item.start)
  if goal.isNone or goal.get.goalPoint != item.validatedGoal:
    raise newException(ValueError, "goal validation drift: " & item.id)
  BodyRouteRequest(
    start: item.start,
    goal: goal.get,
    profile: item.profile.corpusProfile,
    danger: if item.dynamic in {ncdDanger, ncdBoth}: addr danger else: nil,
    blockedCell: item.blockedPoint,
    hazard: newDarkBodyHazardOverlay())

proc appendUnique(points: var seq[BodyPoint], point: BodyPoint) =
  if points.len == 0 or points[^1] != point:
    points.add point

proc executedRoute(index: BodyRouteIndex, scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult): seq[BodyPoint] =
  let seat = BodyNavSeat()
  if not seat.installRoute(scratch, route, 1):
    return
  var position = route.descriptor.exactStart
  result.add position
  let rawLimit = route.descriptor.startLegLen.int +
    route.descriptor.goalLegLen.int + route.descriptor.edgeCount.int *
    RouteLocalLegCap + 2
  while result.len <= rawLimit:
    let waypoint = seat.routeWaypoint(index, position)
    if waypoint.isNone or waypoint.get == position:
      break
    position = waypoint.get
    result.appendUnique(position)
  if result.len > rawLimit or result[^1] != route.descriptor.exactGoal:
    result.setLen(0)

proc statsJson(stats: BodyRouteQueryStats): JsonNode =
  %*{
    "endpoint_attach_ns": stats.endpointAttachNanoseconds,
    "same_room_ns": stats.sameRoomNanoseconds,
    "side_graph_ns": stats.sideGraphNanoseconds,
    "hazard_pricing_ns_nested": stats.hazardPricingNanoseconds,
    "descriptor_assembly_validate_ns":
      stats.descriptorAssemblyValidateNanoseconds,
    "segment_clear_calls": stats.segmentClearCalls,
    "local_pops_max_search": stats.localPops,
    "local_pops_total": stats.localPopsTotal,
    "side_pops": stats.sidePops,
    "arcs_relaxed": stats.arcsRelaxed,
    "memo_fills": stats.memoFills,
    "memo_cell_reads": stats.memoCellReads,
    "chain_cell_reads": stats.chainCellReads,
    "hazard_steps": stats.hazardSteps,
    "overflow_kind": stats.overflowKind,
    "overflow_actual_length": stats.overflowActualLength,
    "overflow_cycle_prefix": stats.overflowCyclePrefix,
    "overflow_cycle_length": stats.overflowCycleLength
  }

proc profileCase(pool: JsonNode, corpus: NavCorpus, id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    index = newBodyRouteIndex(map)
    scratch = newBodyRouteQueryScratch(index)
  var danger = map.buildOracleDanger(item)
  var request = map.queryRequest(item, danger)
  var samples = newJArray()
  for sample in 0 ..< ProfileSamples:
    let queryStarted = getMonoTime()
    let route = index.queryBodyRoute(scratch, request)
    let queryNs = (getMonoTime() - queryStarted).inNanoseconds
    var installNs = 0'i64
    if route.ok:
      let seat = BodyNavSeat()
      let installStarted = getMonoTime()
      if not seat.installRoute(scratch, route, uint64(sample + 1)):
        raise newException(ValueError, "install failed: " & item.id)
      installNs = (getMonoTime() - installStarted).inNanoseconds
    var row = statsJson(route.stats)
    row["query_ns"] = %queryNs
    row["install_copy_ns"] = %installNs
    row["ok"] = %route.ok
    row["failure"] = %($route.failure)
    if route.ok:
      row["edge_count"] = %route.descriptor.edgeCount.int
      row["start_leg_len"] = %route.descriptor.startLegLen.int
      row["goal_leg_len"] = %route.descriptor.goalLegLen.int
    samples.add row
  %*{
    "id": item.id,
    "map": item.mapName,
    "start_room": map.roomLabelAt(item.start),
    "goal_room": map.roomLabelAt(item.validatedGoal),
    "profile": $item.profile,
    "dynamic": $item.dynamic,
    "distance": $item.distance,
    "samples": samples
  }

proc roomSequence(map: BodyMap, route: openArray[BodyPoint]): seq[int] =
  for point in route:
    let room = map.roomLabelAt(point)
    if result.len == 0 or result[^1] != room:
      result.add room

proc roomsJson(rooms: openArray[int]): JsonNode =
  result = newJArray()
  for room in rooms:
    result.add %room

proc edgeCost(map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, a, b: BodyPoint): float64 =
  oracleFloatCost([a, b], map, danger, item.profile.corpusProfile,
    item.blockedCell)

proc sharedRoomCost(map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, route: openArray[BodyPoint],
    sharedRooms: HashSet[int]): float64 =
  for offset in 1 ..< route.len:
    let
      aRoom = map.roomLabelAt(route[offset - 1])
      bRoom = map.roomLabelAt(route[offset])
    if aRoom == bRoom and aRoom in sharedRooms:
      result += map.edgeCost(danger, item, route[offset - 1], route[offset])

proc corridorRoute(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, item: NavCorpusCase,
    allowedRooms: HashSet[int], popCap: int,
    scratch: var CorridorScratch): CorridorResult =
  scratch.beginQuery()
  let
    startCell = map.cellOf(item.start)
    goalCell = map.cellOf(item.validatedGoal)
    startIndex = startCell.y * map.gridWidth + startCell.x
    goalIndex = goalCell.y * map.gridWidth + goalCell.x
    startCenter = cellCenter(startCell)
    goalCenter = cellCenter(goalCell)
  if (allowedRooms.len > 0 and
      (index.roomForCell(startIndex) notin allowedRooms or
       index.roomForCell(goalIndex) notin allowedRooms)) or
      not map.segmentClear(item.start, startCenter) or
      not map.segmentClear(goalCenter, item.validatedGoal):
    return
  var heap: HeapQueue[CorridorNode]
  scratch.seenGeneration[startIndex] = scratch.generation
  scratch.cost[startIndex] = 0.0
  scratch.parent[startIndex] = -1
  heap.push CorridorNode(
    priority: routeOctileQ4(startCell, goalCell).float / 16.0,
    cost: 0.0, cell: startIndex)
  while heap.len > 0 and result.pops < popCap:
    let current = heap.pop()
    if scratch.closedGeneration[current.cell] == scratch.generation or
        scratch.seenGeneration[current.cell] != scratch.generation or
        current.cost != scratch.cost[current.cell]:
      continue
    scratch.closedGeneration[current.cell] = scratch.generation
    inc result.pops
    if current.cell == goalIndex:
      result.reached = true
      var cursor = goalIndex
      while cursor >= 0:
        result.route.add cellCenter(
          (cursor mod map.gridWidth, cursor div map.gridWidth))
        cursor = scratch.parent[cursor].int
      result.route.reverse()
      if result.route[0] != item.start:
        result.route.insert(item.start, 0)
      if result.route[^1] != item.validatedGoal:
        result.route.add item.validatedGoal
      return
    let
      cell: BodyPoint = (x: current.cell mod map.gridWidth,
        y: current.cell div map.gridWidth)
      legal = index.legalMovesAt(current.cell)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0:
        continue
      let
        nextCell: BodyPoint = (x: cell.x + delta.x, y: cell.y + delta.y)
        nextIndex = nextCell.y * map.gridWidth + nextCell.x
      if (allowedRooms.len > 0 and
          index.roomForCell(nextIndex) notin allowedRooms) or
          scratch.closedGeneration[nextIndex] == scratch.generation:
        continue
      let candidate = current.cost + map.edgeCost(danger, item,
        cellCenter(cell), cellCenter(nextCell))
      if scratch.seenGeneration[nextIndex] != scratch.generation or
          candidate < scratch.cost[nextIndex]:
        scratch.seenGeneration[nextIndex] = scratch.generation
        scratch.cost[nextIndex] = candidate
        scratch.parent[nextIndex] = int32(current.cell)
        heap.push CorridorNode(
          priority: candidate +
            routeOctileQ4(nextCell, goalCell).float / 16.0,
          cost: candidate, cell: nextIndex)

proc selectedRooms(map: BodyMap,
    route: openArray[BodyPoint]): HashSet[int] =
  result = initHashSet[int]()
  for point in route:
    let roomLabel = map.roomLabelAt(point)
    if roomLabel > 0:
      result.incl roomLabel - 1

proc attributeCase(pool: JsonNode, corpus: NavCorpus,
    ranked: RankedCase): JsonNode =
  let
    item = corpus.findCase(ranked.id)
    map = pool.loadMap(item.poolIndex)
    index = newBodyRouteIndex(map)
    scratch = newBodyRouteQueryScratch(index)
  var danger = map.buildOracleDanger(item)
  var request = map.queryRequest(item, danger)
  let candidate = index.queryBodyRoute(scratch, request)
  if not candidate.ok:
    raise newException(ValueError,
      "ranked candidate no longer routes: " & item.id)
  let
    candidateRoute = resampleRoute4px(
      index.executedRoute(scratch, candidate))
    oracleRoute = map.oracleRoute4px(item)
    candidateRooms = map.roomSequence(candidateRoute)
    oracleRooms = map.roomSequence(oracleRoute)
  var
    oracleRoomSet = initHashSet[int]()
    sharedRooms = initHashSet[int]()
  for room in oracleRooms:
    oracleRoomSet.incl room
  for room in candidateRooms:
    if room in oracleRoomSet:
      sharedRooms.incl room
  let
    candidateCost = oracleFloatCost(candidateRoute, map, danger,
      item.profile.corpusProfile, item.blockedCell)
    oracleCost = oracleFloatCost(oracleRoute, map, danger,
      item.profile.corpusProfile, item.blockedCell)
    excess = candidateCost - oracleCost
    candidateShared = map.sharedRoomCost(danger, item, candidateRoute,
      sharedRooms)
    oracleShared = map.sharedRoomCost(danger, item, oracleRoute, sharedRooms)
    sharedDelta = candidateShared - oracleShared
    differentDelta = excess - sharedDelta
  %*{
    "rank_id": item.id,
    "reported_inflation_pct": ranked.inflation,
    "candidate_cost": candidateCost,
    "oracle_cost": oracleCost,
    "excess_cost": excess,
    "same_room_sequence": candidateRooms == oracleRooms,
    "candidate_rooms": roomsJson(candidateRooms),
    "oracle_rooms": roomsJson(oracleRooms),
    "shared_room_excess": sharedDelta,
    "different_room_excess": differentDelta,
    "shared_room_excess_pct_of_total":
      (if excess == 0.0: 0.0 else: sharedDelta / excess * 100.0),
    "different_room_excess_pct_of_total":
      (if excess == 0.0: 0.0 else: differentDelta / excess * 100.0)
  }

proc routeLegal(map: BodyMap, item: NavCorpusCase,
    route: openArray[BodyPoint]): bool =
  if route.len == 0 or route[0] != item.start or
      route[^1] != item.validatedGoal:
    return false
  for point in route:
    if not map.canStand(point) or map.componentOf(point) != item.component:
      return false
  for offset in 1 ..< route.len:
    if not map.segmentClear(route[offset - 1], route[offset]):
      return false
  true

type ExperimentAccum = object
  allInflation: seq[float64]
  strata: Table[string, seq[float64]]
  reached, fallback, illegal: int
  longestPath: int
  pops, nanoseconds: seq[float64]

proc experimentRow(name: string,
    values: openArray[float64]): JsonNode =
  %*{
    "stratum": name,
    "count": values.len,
    "p95_inflation_pct": percentile(values, 0.95),
    "max_inflation_pct": if values.len == 0: Inf else: max(values)
  }

proc experimentJson(accum: ExperimentAccum, popCap: int): JsonNode =
  var rows = newJArray()
  rows.add experimentRow("overall", accum.allInflation)
  for rosterSize in [16, 32]:
    for profile in NavCorpusProfile:
      for dynamic in NavCorpusDynamic:
        for distance in NavCorpusDistance:
          let key = &"r{rosterSize}/{profile}/{dynamic}/{distance}"
          rows.add experimentRow(key, accum.strata.getOrDefault(key))
  %*{
    "pop_cap": popCap,
    "reached": accum.reached,
    "fallback": accum.fallback,
    "illegal": accum.illegal,
    "longest_path_cells": accum.longestPath,
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": if accum.pops.len == 0: 0.0 else: max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95),
    "query_ns_max": if accum.nanoseconds.len == 0: 0.0 else:
      max(accum.nanoseconds),
    "quality": rows
  }

proc corridorExperiments(pool: JsonNode,
    corpus: NavCorpus): JsonNode =
  const Caps = [8_192, 16_384]
  var accum: array[Caps.len, ExperimentAccum]
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"corridor map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      index = newBodyRouteIndex(map)
      queryScratch = newBodyRouteQueryScratch(index)
    var
      corridorScratch = initCorridorScratch(
        map.gridWidth * map.gridHeight)
      dangerByHash = initTable[string, BodyDangerField]()
    for item in corpus.cases:
      if item.poolIndex != poolIndex:
        continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      var danger = dangerByHash[item.dangerHash]
      var request = map.queryRequest(item, danger)
      let base = index.queryBodyRoute(queryScratch, request)
      if not base.ok:
        raise newException(ValueError,
          "fixed base route missing during experiment: " & item.id)
      let
        baseRoute = index.executedRoute(queryScratch, base)
        rooms = map.selectedRooms(baseRoute)
        key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/" &
          &"{item.distance}"
      for capOffset, cap in Caps:
        let started = getMonoTime()
        let corridor = map.corridorRoute(index, danger, item, rooms, cap,
          corridorScratch)
        let elapsed = (getMonoTime() - started).inNanoseconds
        var selected = baseRoute
        if corridor.reached and map.routeLegal(item, corridor.route):
          selected = corridor.route
          inc accum[capOffset].reached
          accum[capOffset].longestPath = max(
            accum[capOffset].longestPath, corridor.route.len)
        else:
          inc accum[capOffset].fallback
          if corridor.reached:
            inc accum[capOffset].illegal
        let inflation = routeInflationPct(
          oracleFloatCost(resampleRoute4px(selected), map, danger,
            item.profile.corpusProfile, item.blockedCell), item.oracleCost)
        accum[capOffset].allInflation.add inflation
        accum[capOffset].strata.mgetOrPut(key, @[]).add inflation
        accum[capOffset].pops.add corridor.pops.float
        accum[capOffset].nanoseconds.add elapsed.float
  result = newJArray()
  for offset, cap in Caps:
    result.add experimentJson(accum[offset], cap)

proc globalExperiments(pool: JsonNode,
    corpus: NavCorpus): JsonNode =
  const Caps = [16_384, 32_768, 65_536]
  var accum: array[Caps.len, ExperimentAccum]
  let unrestricted = initHashSet[int]()
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"global map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      index = newBodyRouteIndex(map)
      queryScratch = newBodyRouteQueryScratch(index)
    var
      globalScratch = initCorridorScratch(map.gridWidth * map.gridHeight)
      dangerByHash = initTable[string, BodyDangerField]()
    for item in corpus.cases:
      if item.poolIndex != poolIndex:
        continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      var danger = dangerByHash[item.dangerHash]
      var request = map.queryRequest(item, danger)
      let base = index.queryBodyRoute(queryScratch, request)
      if not base.ok:
        raise newException(ValueError,
          "fixed base route missing during global experiment: " & item.id)
      let
        baseRoute = index.executedRoute(queryScratch, base)
        key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/" &
          &"{item.distance}"
      for capOffset, cap in Caps:
        let started = getMonoTime()
        let global = map.corridorRoute(index, danger, item, unrestricted,
          cap, globalScratch)
        let elapsed = (getMonoTime() - started).inNanoseconds
        var selected = baseRoute
        if global.reached and map.routeLegal(item, global.route):
          selected = global.route
          inc accum[capOffset].reached
          accum[capOffset].longestPath = max(
            accum[capOffset].longestPath, global.route.len)
        else:
          inc accum[capOffset].fallback
          if global.reached:
            inc accum[capOffset].illegal
        let inflation = routeInflationPct(
          oracleFloatCost(resampleRoute4px(selected), map, danger,
            item.profile.corpusProfile, item.blockedCell), item.oracleCost)
        accum[capOffset].allInflation.add inflation
        accum[capOffset].strata.mgetOrPut(key, @[]).add inflation
        accum[capOffset].pops.add global.pops.float
        accum[capOffset].nanoseconds.add elapsed.float
  result = newJArray()
  for offset, cap in Caps:
    result.add experimentJson(accum[offset], cap)

proc profileCorridorCase(pool: JsonNode, corpus: NavCorpus,
    id: string, popCap: int): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    index = newBodyRouteIndex(map)
    queryScratch = newBodyRouteQueryScratch(index)
  var
    danger = map.buildOracleDanger(item)
    request = map.queryRequest(item, danger)
    corridorScratch = initCorridorScratch(map.gridWidth * map.gridHeight)
    samples = newJArray()
  for sample in 0 ..< ProfileSamples:
    let queryStarted = getMonoTime()
    let route = index.queryBodyRoute(queryScratch, request)
    let queryNs = (getMonoTime() - queryStarted).inNanoseconds
    let baseRoute = index.executedRoute(queryScratch, route)
    let rooms = map.selectedRooms(baseRoute)
    let corridorStarted = getMonoTime()
    let corridor = map.corridorRoute(index, danger, item, rooms, popCap,
      corridorScratch)
    let corridorNs = (getMonoTime() - corridorStarted).inNanoseconds
    var row = statsJson(route.stats)
    row["query_ns"] = %queryNs
    row["corridor_ns"] = %corridorNs
    row["combined_ns"] = %(queryNs + corridorNs)
    row["corridor_pops"] = %corridor.pops
    row["corridor_reached"] = %corridor.reached
    samples.add row
  %*{"id": id, "pop_cap": popCap, "samples": samples}

proc profileGlobalCase(pool: JsonNode, corpus: NavCorpus,
    id: string, popCap: int): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    index = newBodyRouteIndex(map)
    queryScratch = newBodyRouteQueryScratch(index)
    unrestricted = initHashSet[int]()
  var
    danger = map.buildOracleDanger(item)
    request = map.queryRequest(item, danger)
    globalScratch = initCorridorScratch(map.gridWidth * map.gridHeight)
    samples = newJArray()
  for _ in 0 ..< ProfileSamples:
    let baseStarted = getMonoTime()
    let route = index.queryBodyRoute(queryScratch, request)
    let baseNs = (getMonoTime() - baseStarted).inNanoseconds
    let globalStarted = getMonoTime()
    let global = map.corridorRoute(index, danger, item, unrestricted,
      popCap, globalScratch)
    let globalNs = (getMonoTime() - globalStarted).inNanoseconds
    samples.add %*{
      "hierarchical_fallback_ns": baseNs,
      "global_query_ns": globalNs,
      "combined_ns": baseNs + globalNs,
      "global_pops": global.pops,
      "global_reached": global.reached,
      "global_path_cells": global.route.len
    }
  %*{"id": id, "pop_cap": popCap, "samples": samples}

proc rankedCases(artifact: JsonNode): seq[RankedCase] =
  for row in artifact["quality"]["cases"]:
    if row["status"].getStr() == "ok":
      result.add RankedCase(id: row["id"].getStr(),
        inflation: row["inflation_pct"].getFloat())
  result.sort(cmpRank)

proc overflowCases(pool: JsonNode, corpus: NavCorpus,
    artifact: JsonNode): JsonNode =
  result = newJArray()
  for row in artifact["quality"]["cases"]:
    if row["status"].getStr() != "brfDescriptorOverflow":
      continue
    stderr.writeLine "overflow " & row["id"].getStr()
    let
      item = corpus.findCase(row["id"].getStr())
      map = pool.loadMap(item.poolIndex)
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
    var danger = map.buildOracleDanger(item)
    var request = map.queryRequest(item, danger)
    let route = index.queryBodyRoute(scratch, request)
    var output = statsJson(route.stats)
    output["id"] = %item.id
    output["failure"] = %($route.failure)
    if route.ok:
      output["edge_count"] = %route.descriptor.edgeCount.int
      output["start_leg_len"] = %route.descriptor.startLegLen.int
      output["goal_leg_len"] = %route.descriptor.goalLegLen.int
    result.add output

when isMainModule:
  if paramCount() != 2:
    quit("usage: investigate_body_nav_p9 CORPUS CANONICAL_JSON", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    artifact = parseFile(paramStr(2))
    pool = loadBrS2PoolRaw()
    ranked = rankedCases(artifact)
  if ranked.len < 30:
    raise newException(ValueError, "canonical artifact has fewer than 30 routes")
  var attribution = newJArray()
  for offset in 0 ..< 30:
    stderr.writeLine &"attribution {offset + 1}/30 {ranked[offset].id}"
    attribution.add pool.attributeCase(corpus, ranked[offset])
  let median = ranked[ranked.len div 2]
  stderr.writeLine "profile far route"
  let farProfile = pool.profileCase(corpus,
    "m15-br-gen-22010-r16-s15-default-danger-far")
  stderr.writeLine "profile median route"
  let medianProfile = pool.profileCase(corpus, median.id)
  stderr.writeLine "diagnose overflows"
  let overflows = pool.overflowCases(corpus, artifact)
  stderr.writeLine "run corridor experiments"
  let corridor = pool.corridorExperiments(corpus)
  var corridorProfiles = newJArray()
  for cap in [8_192, 16_384]:
    corridorProfiles.add pool.profileCorridorCase(corpus,
      "m15-br-gen-22010-r16-s15-default-danger-far", cap)
    corridorProfiles.add pool.profileCorridorCase(corpus, median.id, cap)
  stderr.writeLine "run global experiments"
  let global = pool.globalExperiments(corpus)
  var globalProfiles = newJArray()
  for cap in [16_384, 32_768, 65_536]:
    globalProfiles.add pool.profileGlobalCase(corpus,
      "m15-br-gen-22010-r16-s15-default-danger-far", cap)
    globalProfiles.add pool.profileGlobalCase(corpus, median.id, cap)
  echo pretty(%*{
    "schema": "coworld_body_nav_p9_investigation",
    "v": 1,
    "profiles": [
      farProfile,
      medianProfile
    ],
    "median_case": {"id": median.id, "inflation_pct": median.inflation},
    "worst_30": attribution,
    "overflows": overflows,
    "corridor_experiments": corridor,
    "corridor_profiles": corridorProfiles,
    "global_experiments": global,
    "global_profiles": globalProfiles
  })
