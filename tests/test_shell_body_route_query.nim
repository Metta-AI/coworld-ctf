## Phase-3 laws for bounded hierarchical body-route queries.

import std/[json, options, unittest]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_hazard, body_map, body_nav, body_planner, body_route_index,
  body_route_query]
import ../src/shell/types as shellTypes

proc openMap(): BodyMap =
  const Side = 96
  var walkable = newSeq[bool](Side * Side)
  for y in 1 ..< Side - 1:
    for x in 1 ..< Side - 1:
      walkable[y * Side + x] = true
  newBodyMap(walkable, Side, Side, 2, @[(16, 16), (80, 80)],
    mapName = "route-query-open")

proc twoIslandMap(): BodyMap =
  const
    Width = 128
    Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 55:
      walkable[y * Width + x] = true
    for x in 72 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(24, 48), (104, 48)],
    mapName = "route-query-islands")

proc capFallbackMap(): BodyMap =
  const
    Width = 4000
    Height = 160
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      if x < 3800 or x > 3815 or y in 64 .. 95:
        walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(80, 80), (3920, 80)],
    mapName = "route-query-cap-fallback")

proc goalAt(map: BodyMap, requested, fromPoint: BodyPoint): ValidatedGoal =
  let goal = map.validateGoal(requested, fromPoint)
  doAssert goal.isSome
  goal.get

proc firstCellInGraph(index: BodyRouteIndex, graph: int): BodyPoint =
  for cellIndex in 0 ..< index.routeIndexStats.navCells:
    if index.graphComponentForCell(cellIndex) == graph:
      return index.routePoint(int32(cellIndex))
  raise newException(ValueError, "graph has no coarse cell")

proc firstSeparatedSidePair(index: BodyRouteIndex): tuple[a, b: int] =
  let stats = index.routeIndexStats()
  for a in 0 ..< stats.sides:
    for b in a + 1 ..< stats.sides:
      if index.graphComponentForSide(a) == index.graphComponentForSide(b) and
          index.portalSideAt(a).room != index.portalSideAt(b).room and
          not index.map.segmentClear(index.sideAnchor(a), index.sideAnchor(b)):
        return (a, b)
  raise newException(ValueError, "map has no separated side pair")

proc sameRoomHorizontalPair(index: BodyRouteIndex): tuple[a, b: BodyPoint] =
  let map = index.map
  for y in 1 ..< map.gridHeight - 1:
    for left in 1 ..< map.gridWidth - 9:
      let room = index.roomForCell(y * map.gridWidth + left)
      if room < 0:
        continue
      for right in countdown(map.gridWidth - 2, left + 8):
        if index.roomForCell(y * map.gridWidth + right) == room:
          return (cellCenter((left, y)), cellCenter((right, y)))
  raise newException(ValueError, "map has no wide same-room row")

suite "bounded hierarchical body route query":
  test "fixed caps and octile Q4 heuristic are exact":
    check RouteSidePopCap == 4096
    check RouteLocalPopCap == 4096
    check RouteLocalLegCap == 512
    check RouteEdgeCap == 4096
    check routeOctileQ4((0, 0), (3, 4)) == 3 * 181 + 128
    expect BodyMapError:
      validateRouteQueryCapacity("too-many-sides", RouteEdgeCap + 2)

  test "straight same-room route retains both exact endpoints":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      start: BodyPoint = (16, 16)
      goal = map.goalAt((80, 80), start)
      request = BodyRouteRequest(start: start, goal: goal)
      result = index.queryBodyRoute(scratch, request)
    check result.ok
    check result.failure == brfNone
    check result.descriptor.edgeCount == 0
    check result.descriptor.exactStart == start
    check result.descriptor.exactGoal == goal.goalPoint
    check result.startLegPoint(0) == start
    check result.startLegPoint(result.descriptor.startLegLen.int - 1) ==
      goal.goalPoint
    check index.validateBodyRoute(request, result)
    check result.stats.sidePops <= RouteSidePopCap
    check result.stats.localPops <= RouteLocalPopCap

  test "fine-only validator endpoint attaches through the retained cell index":
    let published = loadBrS2PoolRaw()
    var gameMap = mapFromSpecJson($published[1]["spec"])
    gameMap.name = published[1]["name"].getStr()
    let
      map = newBodyMap(gameMap)
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      fineOnly: BodyPoint = (1884, 648)
      graph = index.connectorGraphComponent(fineOnly)
      start = index.firstCellInGraph(graph)
      goal = map.goalAt(fineOnly, start)
      request = BodyRouteRequest(start: start, goal: goal)
      result = index.queryBodyRoute(scratch, request)
    var coarseAttach = false
    let center = map.cellOf(fineOnly)
    for y in max(0, center.y - PortalAnchorRingCells) ..
        min(map.gridHeight - 1, center.y + PortalAnchorRingCells):
      for x in max(0, center.x - PortalAnchorRingCells) ..
          min(map.gridWidth - 1, center.x + PortalAnchorRingCells):
        let cellIndex = y * map.gridWidth + x
        if index.graphComponentForCell(cellIndex) != 0 and
            map.segmentClear(fineOnly, cellCenter((x, y))):
          coarseAttach = true
    check not coarseAttach
    check goal.goalPoint == fineOnly
    check result.ok
    check index.validateBodyRoute(request, result)
    check result.usesFineAnchor
    for anchorOffset in 0 ..< index.fineAnchorCount:
      let
        anchor = index.routePoint(index.fineAnchorAt(anchorOffset))
        anchorGraph = index.connectorGraphComponent(anchor)
        anchorStart = index.firstCellInGraph(anchorGraph)
        anchorGoal = map.goalAt(anchor, anchorStart)
        anchorRequest = BodyRouteRequest(start: anchorStart, goal: anchorGoal)
        anchorRoute = index.queryBodyRoute(scratch, anchorRequest)
      check anchorRoute.ok
      check index.validateBodyRoute(anchorRequest, anchorRoute)

  test "weighted local candidate routes around a blocked cell":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      pair = index.sameRoomHorizontalPair()
      start = pair.a
      blocked: BodyPoint = ((pair.a.x + pair.b.x) div 2, pair.a.y)
      goal = map.goalAt(pair.b, start)
      request = BodyRouteRequest(start: start, goal: goal,
        blockedCell: some(blocked))
      route = index.queryBodyRoute(scratch, request)
    check route.ok
    check route.descriptor.edgeCount == 0
    check route.descriptor.startLegLen > 2
    check route.stats.localPops > 0
    check route.stats.localPops <= RouteLocalPopCap
    check index.validateBodyRoute(request, route)
    for offset in 1 ..< route.descriptor.startLegLen.int:
      let
        a = route.startLegPoint(offset - 1)
        b = route.startLegPoint(offset)
        midpoint: BodyPoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
      check map.cellOf(midpoint) != map.cellOf(blocked)

  test "a capped same-room candidate leaves bounded fallbacks alive":
    let
      map = capFallbackMap()
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      pair = index.sameRoomHorizontalPair()
    var danger = BodyDangerField(
      values: newSeq[float32](map.gridWidth * map.gridHeight),
      gridW: map.gridWidth, gridH: map.gridHeight)
    let
      goal = map.goalAt(pair.b, pair.a)
      blocked: BodyPoint = ((pair.a.x + pair.b.x) div 2, pair.a.y)
      goalCell = map.cellOf(goal.goalPoint)
    for y in 0 ..< map.gridHeight:
      for x in max(0, goalCell.x - 16) ..< map.gridWidth:
        danger.values[y * map.gridWidth + x] = 1_000_000.0
    let
      request = BodyRouteRequest(start: pair.a, goal: goal,
        danger: addr danger, blockedCell: some(blocked))
      route = index.queryBodyRoute(scratch, request)
    check route.ok
    check route.stats.localCapHits > 0
    check route.stats.localPops <= RouteLocalPopCap
    check route.stats.sidePops > 0
    check route.stats.sidePops <= RouteSidePopCap
    check index.validateBodyRoute(request, route)

  test "side graph routes deterministically through multiple rooms":
    let
      map = newBodyMap(loadCtfMapMetadata("arena"))
      index = newBodyRouteIndex(map)
      pair = index.firstSeparatedSidePair()
      start = index.sideAnchor(pair.a)
      goal = map.goalAt(index.sideAnchor(pair.b), start)
      request = BodyRouteRequest(start: start, goal: goal)
      firstScratch = newBodyRouteQueryScratch(index)
      secondScratch = newBodyRouteQueryScratch(index)
      forward = index.queryBodyRoute(firstScratch, request)
      repeated = index.queryBodyRoute(secondScratch, request)
    check forward.ok
    check forward.descriptor.edgeCount > 0
    check index.validateBodyRoute(request, forward)
    check forward.routeFingerprint == repeated.routeFingerprint
    check forward.stats.sidePops <= RouteSidePopCap
    check forward.stats.localPops <= RouteLocalPopCap

    let
      reverseGoal = map.goalAt(start, goal.goalPoint)
      reverseRequest = BodyRouteRequest(start: goal.goalPoint,
        goal: reverseGoal)
      reverse = index.queryBodyRoute(secondScratch, reverseRequest)
    check reverse.ok
    check index.validateBodyRoute(reverseRequest, reverse)
    check reverse.descriptor.edgeCount > 0
    var sawReverseTraversal = false
    for offset in 0 ..< forward.descriptor.edgeCount.int:
      sawReverseTraversal = sawReverseTraversal or
        forward.resultEdgeAt(offset).routeEdgeReversed
    for offset in 0 ..< reverse.descriptor.edgeCount.int:
      sawReverseTraversal = sawReverseTraversal or
        reverse.resultEdgeAt(offset).routeEdgeReversed
    check sawReverseTraversal

    let
      permutedScratch = newBodyRouteQueryScratch(index)
      reverseFirst = index.queryBodyRoute(permutedScratch, reverseRequest)
      reverseFirstFingerprint = reverseFirst.routeFingerprint
      forwardSecond = index.queryBodyRoute(permutedScratch, request)
    check reverseFirst.ok
    check forwardSecond.ok
    check reverseFirstFingerprint == reverse.routeFingerprint
    check forwardSecond.routeFingerprint == forward.routeFingerprint

  test "directed-arc danger memo is shared generation-stamped and bounded":
    let
      map = newBodyMap(loadCtfMapMetadata("arena"))
      index = newBodyRouteIndex(map)
      pair = index.firstSeparatedSidePair()
      start = index.sideAnchor(pair.a)
      goal = map.goalAt(index.sideAnchor(pair.b), start)
      scratch = newBodyRouteQueryScratch(index)
    var danger = BodyDangerField(
      values: newSeq[float32](map.gridWidth * map.gridHeight),
      gridW: map.gridWidth, gridH: map.gridHeight)
    let request = BodyRouteRequest(start: start, goal: goal,
      danger: addr danger)
    let first = index.queryBodyRoute(scratch, request)
    let firstMemo = scratch.dangerMemoDebug()
    let firstFingerprint = first.routeFingerprint
    check first.ok
    check firstMemo.capacity == index.routeIndexStats.arcs
    check firstMemo.capacity == index.routeIndexStats.segments * 2
    check firstMemo.filled > 0
    check firstMemo.filled <= firstMemo.capacity

    let repeated = index.queryBodyRoute(scratch, request)
    let repeatedMemo = scratch.dangerMemoDebug()
    check repeated.ok
    check repeated.routeFingerprint == firstFingerprint
    check repeatedMemo.generation == firstMemo.generation + 1
    check repeatedMemo.filled == firstMemo.filled

  test "earliest-arrival label preserves the safer two-prefix route":
    let
      map = newBodyMap(loadCtfMapMetadata("arena"))
      index = newBodyRouteIndex(map)
      stats = index.routeIndexStats()
      scratch = newBodyRouteQueryScratch(index)
    var
      danger = BodyDangerField(values: newSeq[float32](stats.navCells),
        gridW: map.gridWidth, gridH: map.gridHeight)
      overlay = BodyHazardOverlay(state: bhsReady, fingerprint: 2,
        arrival: newSeq[uint16](stats.navCells),
        roomMaxArrival: newSeq[uint16](stats.rooms))
    for cell in 0 ..< stats.navCells:
      let
        x = cell mod map.gridWidth
        y = cell div map.gridWidth
        dangerDraw = (x * 97 + y * 193 + 2 * 31) mod 100
      danger.values[cell] =
        if dangerDraw < 15: float32(3 + dangerDraw mod 5) else: 0'f32
      overlay.arrival[cell] = uint16(
        100 + ((x * 17 + y * 29 + 2 * 47) mod 240))
      let room = index.roomForCell(cell)
      if room >= 0:
        overlay.roomMaxArrival[room] = max(overlay.roomMaxArrival[room],
          overlay.arrival[cell])
    let extrema = index.segmentArrivalExtrema(overlay.arrival,
      HazardNeverArrives)
    overlay.segmentArrivalMin = extrema.minimum
    overlay.segmentArrivalMax = extrema.maximum

    # This fixed field has two prefixes to the winning merge side: the
    # minimum-cost prefix is physically later, while a dearer shorter prefix
    # reaches the final painted arc soon enough to win after hazard pricing.
    let
      start = index.sideAnchor(0)
      goal = map.goalAt(index.sideAnchor(65), start)
      route = index.queryBodyRoute(scratch, BodyRouteRequest(start: start,
        goal: goal, profile: shellTypes.cpCarrier, danger: addr danger,
        hazard: overlay, elapsedZoneTick: 120))
    check route.ok
    check route.stats.selectedEarliestAlternative
    check route.stats.earliestAlternativePops > 0
    check route.stats.sidePops <= RouteSidePopCap
    check index.validateBodyRoute(BodyRouteRequest(start: start, goal: goal,
      profile: shellTypes.cpCarrier, danger: addr danger,
      hazard: overlay, elapsedZoneTick: 120), route)

  test "danger blocked-cell and zone hazard costs compose in one query":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      pair = index.sameRoomHorizontalPair()
      blocked: BodyPoint = ((pair.a.x + pair.b.x) div 2, pair.a.y)
      goal = map.goalAt(pair.b, pair.a)
      stats = index.routeIndexStats()
    var
      danger = BodyDangerField(values: newSeq[float32](stats.navCells),
        gridW: map.gridWidth, gridH: map.gridHeight)
      overlay = BodyHazardOverlay(state: bhsReady, fingerprint: 77,
        arrival: newSeq[uint16](stats.navCells),
        roomMaxArrival: newSeq[uint16](stats.rooms))
    for cell in 0 ..< stats.navCells:
      let point = index.routePoint(int32(cell))
      danger.values[cell] = float32((point.x * 3 + point.y * 5) mod 7)
      overlay.arrival[cell] = uint16(40 + (point.x + point.y) mod 80)
      let room = index.roomForCell(cell)
      if room >= 0:
        overlay.roomMaxArrival[room] = max(overlay.roomMaxArrival[room],
          overlay.arrival[cell])
    let extrema = index.segmentArrivalExtrema(overlay.arrival,
      HazardNeverArrives)
    overlay.segmentArrivalMin = extrema.minimum
    overlay.segmentArrivalMax = extrema.maximum
    let request = BodyRouteRequest(start: pair.a, goal: goal,
      profile: shellTypes.cpCarrier, danger: addr danger,
      blockedCell: some(blocked), hazard: overlay, elapsedZoneTick: 24)
    let route = index.queryBodyRoute(scratch, request)
    check route.ok
    check route.failure == brfNone
    check route.stats.localPops > 0
    check route.stats.localPops <= RouteLocalPopCap
    check index.validateBodyRoute(request, route)
    for offset in 1 ..< route.descriptor.startLegLen.int:
      let
        a = route.startLegPoint(offset - 1)
        b = route.startLegPoint(offset)
        midpoint: BodyPoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
      check map.cellOf(midpoint) != map.cellOf(blocked)

  test "typed failure vocabulary is exhaustive and exposes no descriptor":
    var failures: seq[BodyRouteFailure]
    for failure in BodyRouteFailure:
      failures.add failure
    check failures == @[brfNone, brfStartAttach, brfGoalAttach,
      brfDisconnected, brfLocalCap, brfSideCap, brfDescriptorOverflow,
      brfValidation]
    for failure in failures[1 .. ^1]:
      let result = BodyRouteQueryResult(failure: failure)
      check not result.ok
      check result.descriptor.edgeCount == 0
      check result.descriptor.startLegLen == 0
      check result.descriptor.goalLegLen == 0

  test "typed disconnection and validation failures return no descriptor":
    let
      map = twoIslandMap()
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      disconnectedGoal = map.goalAt((104, 48), (104, 48))
      disconnected = index.queryBodyRoute(scratch, BodyRouteRequest(
        start: (24, 48), goal: disconnectedGoal))
    check not disconnected.ok
    check disconnected.failure == brfDisconnected
    check disconnected.descriptor.edgeCount == 0

    let noStart = index.queryBodyRoute(scratch, BodyRouteRequest(
      start: (0, 0), goal: map.goalAt((24, 48), (24, 48))))
    check not noStart.ok
    check noStart.failure == brfStartAttach

    let
      foreignMap = openMap()
      foreignIndex = newBodyRouteIndex(foreignMap)
      foreignGoal = foreignMap.goalAt((80, 80), (16, 16))
      wrongScratch = index.queryBodyRoute(
        newBodyRouteQueryScratch(foreignIndex), BodyRouteRequest(
          start: (24, 48), goal: disconnectedGoal))
      wrongGoal = index.queryBodyRoute(scratch, BodyRouteRequest(
        start: (24, 48), goal: foreignGoal))
    check wrongScratch.failure == brfValidation
    check wrongGoal.failure == brfValidation

  test "install is atomic and a failed query leaves the previous route intact":
    let
      map = openMap()
      idleSystem = newBodyNavSystem(map, 1, 1050)
      system = newBodyNavSystem(map, 1, 1050, prepareRouteQueries = true)
      start: BodyPoint = (16, 16)
      goodRequest = BodyRouteRequest(start: start,
        goal: map.goalAt((80, 80), start))
      good = system.routeIndex.queryBodyRoute(system.routeScratch, goodRequest)
    check idleSystem.routeIndex == nil
    check idleSystem.routeScratch == nil
    check system.routeIndex != nil
    check system.routeScratch != nil
    check system.seats[0].installRoute(system.routeScratch, good, 17)
    let installed = system.seats[0].installedRouteFingerprint
    check system.seats[0].installedRouteRevision == 17
    check system.seats[0].installedRouteCursor == 0
    check system.seats[0].installedRouteAnchor == start

    let failed = system.routeIndex.queryBodyRoute(system.routeScratch,
      BodyRouteRequest(start: (0, 0), goal: goodRequest.goal))
    check not failed.ok
    check not system.seats[0].installRoute(system.routeScratch, failed, 18)
    check system.seats[0].installedRouteFingerprint == installed
    check system.seats[0].installedRouteRevision == 17
    check system.seats[0].installedRouteCursor == 0
    check system.seats[0].installedRouteAnchor == start
    check not system.seats[0].installRoute(system.routeScratch, good, 19)
    check system.seats[0].installedRouteFingerprint == installed
    check system.seats[0].installedRouteRevision == 17
