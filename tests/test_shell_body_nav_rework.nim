## Phase 1's frozen shared-navigation laws, made live and shard-wired in Phase 7.

import std/[json, options, tables, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/body
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
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
  encodeInputMask(input) and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)

proc firstSeparatedSidePair(index: BodyRouteIndex): tuple[a, b: int] =
  let stats = index.routeIndexStats()
  for a in 0 ..< stats.sides:
    for b in a + 1 ..< stats.sides:
      if index.graphComponentForSide(a) == index.graphComponentForSide(b) and
          index.portalSideAt(a).room != index.portalSideAt(b).room and
          not index.map.segmentClear(index.sideAnchor(a), index.sideAnchor(b)):
        return (a, b)
  raise newException(ValueError, "map has no separated side pair")

suite "shared navigation rework Phase 1 contract":
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
      check validated.get.goalComponent == item.component
      let danger = map.buildOracleDanger(item)
      check dangerRasterHash(danger) == item.dangerHash
      let route = map.oracleRoute4pxWithDanger(item, danger)
      check route.len > 0
      check route[0] == item.start
      check route[^1] == item.validatedGoal
      check routeHash(route) == item.oracleRouteHash
      let cost = oracleFloatCost(route, map, danger,
        item.profile.corpusProfile, item.blockedCell)
      check abs(cost - item.oracleCost) <= 1e-9

  test "a new valid goal moves on its acceptance tick":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask != 0

  test "an exhausted old endpoint does not stall a replacement goal":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      seat = nav.seats[0]
      start: BodyPoint = (48, 48)
      oldGoal: BodyPoint = start
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
    seat.desiredGoal = some(oldGoal)
    seat.revision = 1
    seat.setActivePathForTest(@[oldGoal], 1)
    body.setStandingIntent(navigateIntent(target), some(goal), 2)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 1)
    check body.actFromBelief(1).movementMask != 0

  test "active action ticks perform no full-board route search":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      seat = nav.seats[0]
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
      latticeCells = ((map.width - 1) div PlanStepPx + 1) *
        ((map.height - 1) div PlanStepPx + 1)
      mapSizedCapacities = [map.width * map.height,
        map.gridWidth * map.gridHeight, latticeCells]
    body.setStandingIntent(navigateIntent(target), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    let
      workBefore = seat.job.workUnits
      mintBefore = seat.mintJob.workUnits
    discard body.actFromBelief(0)
    let scheduledFullBoardPlan = seat.job.planPending
    discard nav.runPlanningTick(0)
    check not scheduledFullBoardPlan and
      seat.job.workUnits == workBefore and
      seat.mintJob.workUnits == mintBefore and
      seat.planner.workspaceCapacity notin mapSizedCapacities

  test "steering is deterministic when a bounded query has no route":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
    nav.routeScratch = nil
    body.setStandingIntent(navigateIntent(target), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    let first = body.actFromBelief(0)
    check first.movementMask == ButtonRight
    check body.navState == bnsSteering
    check nav.seats[0].lastQueryFailure == brfValidation
    for tick in 1 .. 8:
      body.updateBelief(BodyTickInputs(self: selfState(start)), uint32(tick))
      check body.actFromBelief(uint32(tick)).movementMask == ButtonRight

  test "steering keeps NavNeighbors order when best scores tie":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      seat = nav.seats[0]
      start: BodyPoint = (48, 48)
      target: BodyPoint = (96, 0)
    seat.blockedPenalty = some((pos: (56, 40), untilTick: 20))
    check nav.steeringMask(0, start, target, shellTypes.cpDefault, 0) ==
      ButtonRight

  test "follower smooths no farther than six exact-clear local cells":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      seat = nav.seats[0]
      start: BodyPoint = (16, 48)
      target: BodyPoint = (160, 48)
      goal = map.validateGoal(target, start).get
      blocked: BodyPoint = (88, 48)
      request = BodyRouteRequest(start: start, goal: goal,
        blockedCell: some(blocked))
      route = nav.routeIndex.queryBodyRoute(nav.routeScratch, request)
    check route.ok
    check route.descriptor.edgeCount == 0
    check route.descriptor.startLegLen.int > FollowLookaheadK + 3
    check seat.installRoute(nav.routeScratch, route, 1)

    var expected = 0
    for offset in 0 .. min(FollowLookaheadK,
        route.descriptor.startLegLen.int - 1):
      if map.segmentClear(start, route.startLegPoint(offset)):
        expected = offset
    let waypoint = seat.routeWaypoint(nav.routeIndex, start)
    check waypoint == some(route.startLegPoint(expected))
    check seat.installedRouteCursor == expected
    check expected == FollowLookaheadK

  test "follower streams indexed middle segments to the exact endpoint":
    let
      map = newBodyMap(loadCtfMapMetadata("arena"))
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      pair = nav.routeIndex.firstSeparatedSidePair()
      start = nav.routeIndex.sideAnchor(pair.a)
      goal = map.validateGoal(nav.routeIndex.sideAnchor(pair.b), start).get
      request = BodyRouteRequest(start: start, goal: goal)
      route = nav.routeIndex.queryBodyRoute(nav.routeScratch, request)
      seat = nav.seats[0]
    check route.ok
    check route.descriptor.edgeCount > 0
    check route.descriptor.startLegLen > 0
    check route.descriptor.goalLegLen > 0
    check seat.installRoute(nav.routeScratch, route, 1)

    var
      pos = start
      hops = 0
    while hops < 4096:
      let waypoint = seat.routeWaypoint(nav.routeIndex, pos)
      if waypoint.isNone:
        break
      check waypoint.get != pos
      check map.segmentClear(pos, waypoint.get)
      pos = waypoint.get
      inc hops
    check hops > 0
    check hops < 4096
    check pos == goal.goalPoint
    check not seat.routeAdvancing(pos, 0.0)

  test "a failed replacement retains an old route only while it advances":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      oldTarget: BodyPoint = (80, 48)
      newTarget: BodyPoint = (160, 48)
      oldGoal = map.validateGoal(oldTarget, start).get
      newGoal = map.validateGoal(newTarget, start).get
    body.setStandingIntent(navigateIntent(oldTarget), some(oldGoal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask == ButtonRight

    nav.routeScratch = nil
    body.setStandingIntent(navigateIntent(newTarget), some(newGoal), 2)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 1)
    check body.actFromBelief(1).movementMask == ButtonRight
    check body.navState == bnsFollowing
    check nav.seats[0].lastQueryFailure == brfValidation

    body.updateBelief(BodyTickInputs(self: selfState(oldTarget)), 2)
    check body.actFromBelief(2).movementMask == ButtonRight
    check body.navState == bnsSteering

  test "no physically progressing octant reports no-progress":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (183, 48)
      target: BodyPoint = (184, 48)
      goal = map.validateGoal(target, start).get
    nav.routeScratch = nil
    body.setStandingIntent(navigateIntent(target), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask == 0
    check body.navState == bnsNoProgress

  test "an arrived endpoint is never an advancing route":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true)
      body = activateSeatBody(nav, 0)
      start: BodyPoint = (16, 48)
      goal = map.validateGoal(start, start).get
    body.setStandingIntent(navigateIntent(start), some(goal), 1)
    body.updateBelief(BodyTickInputs(self: selfState(start)), 0)
    check body.actFromBelief(0).movementMask == 0
    check body.navState == bnsArrived
    check not nav.seats[0].routeAdvancing(start, 0.0)
