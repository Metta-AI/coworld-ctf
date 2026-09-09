## Production mixed-grid route and scheduler laws.

import std/[json, options, tables, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/body
import ../src/shell/body_danger
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_route_index
import ../src/shell/body_route_query
import ../src/shell/types as shellTypes
import nav_route_corpus_support

proc openMap(): BodyMap =
  const
    Width = 192
    Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2,
    @[(16, 48), (Width - 17, 48)])

proc selfState(pos: BodyPoint): BodySelfState =
  BodySelfState(pos: pos, hp: 2, hpFrac: 2.0 / 3.0, aimBrads: 32,
    alive: true, carrying: false)

proc navigateIntent(point: BodyPoint): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikNavigateTo,
    point: some(MapPoint(x: point.x, y: point.y)),
    profile: shellTypes.cpDefault, combat: shellTypes.CombatPolicy())

proc movementMask(input: InputState): uint8 =
  encodeInputMask(input) and
    (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)

proc runToIdle(nav: BodyNavSystem; startTick = 0; budget =
    BodyRoutePopBudgetPerTick): int =
  var tick = startTick
  while tick - startTick < 10_000:
    var pending = nav.routeJob.active
    for seat in nav.seats:
      pending = pending or seat.pendingRoute.lifecycle != brlIdle
    if not pending:
      return tick
    discard nav.runRouteScheduler(tick, budget)
    inc tick
  raise newException(ValueError, "production route did not settle")

suite "production mixed-grid body navigation":
  test "literal corpus provenance and independent oracle are frozen":
    let
      corpus = loadNavRouteCorpus("tests/fixtures/shell/nav_route_corpus.json")
      poolText = readFile(BrS2MapPoolPath)
      pool = parseJson(poolText)
    check corpus.cases.len == NavCorpusCaseCount
    check corpus.corpusStratumCounts.len == NavCorpusCaseCount
    check corpus.poolSha256 == sha256Text(poolText)

    let
      first = corpus.cases[0]
      mapSpec = $pool[first.poolIndex]["spec"]
      map = newBodyMap(mapFromSpecJson(mapSpec))
    check first.mapName == pool[first.poolIndex]["name"].getStr()
    check first.mapSha256 == sha256Text(mapSpec)
    for item in corpus.cases[0 .. 7]:
      let validated = map.validateGoal(item.requestedGoal, item.start)
      check validated.isSome
      check validated.get.goalPoint == item.validatedGoal
      let danger = map.buildOracleDanger(item)
      check dangerRasterHash(danger) == item.dangerHash
      let route = map.oracleRoute4pxWithDanger(item, danger)
      check routeHash(route) == item.oracleRouteHash
      check abs(oracleFloatCost(route, map, danger,
        item.profile.corpusProfile, item.blockedCell) - item.oracleCost) <= 1e-9

  test "a living valid goal moves on its acceptance tick while route waits":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask != 0
    check body.navState == bnsSteering
    check nav.seats[0].pendingRoute.lifecycle == brlPending
    check nav.runRouteScheduler(0, 0) == 0
    check nav.seats[0].pendingRoute.lifecycle == brlPending

  test "search resumes under an exact pop budget and installs atomically":
    let
      map = openMap()
      graph = newBodyMixedGraph(map)
      workspace = newBodyRouteWorkspace(graph)
      danger = BodyDangerField(values: newSeq[float32](
        map.gridWidth * map.gridHeight), gridW: map.gridWidth,
        gridH: map.gridHeight)
      request = BodyRouteSearchRequest(start: (16, 48), goal: (160, 48),
        profile: shellTypes.cpDefault, blockedCell: -1,
        requestGeneration: 1, dangerGeneration: 1)
    var
      weights: seq[int16]
      job: BodyRouteSearchJob
      calls = 0
      total = 0
    graph.rebuildPackedWeights(danger, weights)
    job.beginBodyRouteSearch(graph, workspace, weights, request)
    while not job.complete:
      let spent = job.spendBodyRoutePops(graph, workspace, weights, nil, 1)
      check spent == 1
      inc total, spent
      inc calls
    let route = job.finishBodyRouteSearch(graph, workspace)
    check calls == total
    check route.ok
    check route.pointCount > 2
    check route.spans[0].start == request.start
    let nav = newBodyNavSystem(map, 1, 331)
    nav.seats[0].installedRoute = BodyInstalledRoute(revision: 99)
    discard nav.navigationWaypoint(0, request.start,
      map.validateGoal(request.goal, request.start).get, 0)
    discard nav.runRouteScheduler(0)
    check nav.seats[0].installedRoute.revision == 1
    check nav.seats[0].installedRoute.pointCount == route.pointCount

  test "one pending slot keeps only the newest request":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      start: BodyPoint = (16, 48)
      first = map.validateGoal((160, 48), start).get
      second = map.validateGoal((80, 48), start).get
    discard nav.navigationWaypoint(0, start, first, 4)
    discard nav.navigationWaypoint(0, start, second, 5)
    check nav.seats[0].pendingRoute.lifecycle == brlPending
    check nav.seats[0].pendingRoute.replacements == 1
    check nav.seats[0].pendingRoute.request.goal == second.goalPoint
    discard nav.runToIdle(5)
    check nav.seats[0].installedRoute.revision == 2
    check nav.seats[0].installedRoutePoints[^1] == second.goalPoint

  test "stable shortest-job-first admission uses seat id as final tie break":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 3, 331)
      starts = [(16, 40), (16, 48), (16, 56)]
      targets = [(160, 40), (80, 48), (80, 56)]
    for seat in 0 .. 2:
      discard nav.navigationWaypoint(seat, starts[seat],
        map.validateGoal(targets[seat], starts[seat]).get, 0)
    discard nav.runRouteScheduler(0, 1)
    check nav.routeJob.active
    check nav.routeJobSeat == 1
    discard nav.runToIdle(1, 32)
    for seat in nav.seats:
      check seat.installedRoute.revision == 1

  test "danger generation cancels stale in-flight work before another pop":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
    discard nav.navigationWaypoint(0, start, goal, 0)
    discard nav.runRouteScheduler(0, 1)
    let staleGeneration = nav.routeJob.request.dangerGeneration
    nav.initializeDanger([DangerInput(selfXy: start,
      candidates: @[DangerCandidate(seatIndex: 4, pos: (80, 48))])], 1)
    check nav.seats[0].dangerGeneration > staleGeneration
    discard nav.runRouteScheduler(1, 1)
    check nav.routeJob.request.dangerGeneration ==
      nav.seats[0].dangerGeneration
    discard nav.runToIdle(2, 32)
    check nav.seats[0].installedRoute.dangerGeneration ==
      nav.seats[0].dangerGeneration

  test "workspace is shared and per-seat route state has fixed layout":
    let nav = newBodyNavSystem(openMap(), 32, 331)
    check nav.routeWorkspace != nil
    check nav.mixedGraph != nil
    check sizeof(BodyRouteSearchRequest) <= 64
    check sizeof(BodyRouteSearchJob) <= 128
    check sizeof(BodyRouteSpan) <= 24
    check sizeof(nav.seats[0].installedRoute) ==
      sizeof(nav.seats[^1].installedRoute)
    check nav.routeIndex.followingPayloadBytes.total == 0

  test "arrived endpoints do not report route progress":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      goal = map.validateGoal(start, start).get
    body.setStandingIntent(navigateIntent(start), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask == 0
    check body.navState == bnsArrived
    check not nav.seats[0].routeAdvancing(start, 0.0)
