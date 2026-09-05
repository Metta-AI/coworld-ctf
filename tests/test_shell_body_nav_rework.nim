## Deliberately-red Phase 1 contract for the shared navigation rework.
##
## Keep this standalone until Phase 7 makes the three liveness/no-live-search
## assertions green. Corpus provenance and oracle checks below must stay green.

import std/[json, options, tables, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/body
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
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
      nav = newBodyNavSystem(map, 1, 331)
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
      nav = newBodyNavSystem(map, 1, 331)
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
      nav = newBodyNavSystem(map, 1, 331)
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
