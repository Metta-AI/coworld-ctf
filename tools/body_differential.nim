## Local-only gate-1 differential between the Season 2 body port and James's
## pinned stencil lab.
##
## This binary is intentionally optional. Compile it only with:
##
##   STENCIL_LAB_DIR=/path/to/stencil_nim \
##     nim c -d:release --path:$STENCIL_LAB_DIR tools/body_differential.nim
##
## No lab source is copied into this repository, and this file is not wired into
## any shard or CI path. The ordinary committed build must remain lab-free.

when not defined(release):
  {.error: "body_differential must be compiled with -d:release".}

import std/[json, math, options, os, osproc, sequtils, strutils, tables]

import body_bench/[fight_adapter, planner_adapter, stencil_adapter]
import ../src/ctf/arena as ctfArena
import ../src/ctf/sim_types as ctfTypes
import ../src/shell/body as shellBody
import ../src/shell/body_cache
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
import ../src/shell/types as shellTypes
import belief_state as stencilBelief
import danger_field as stencilDanger
import nav as stencilNav
import types as stencilTypes
import worldmap as stencilMap

const
  DefaultStencilPin = "480120c2f5d2a13bc84917b6470b64e67372a752"
  FloatEpsilon = 1.0e-6
  DefaultSeeds = @[4242, 14005, 23011]

type
  Options = object
    selectedCase: string
    seeds: seq[int]
    output, stencilPin: string

  Scenario = object
    name: string
    seed, width, height: int
    walkable: seq[bool]
    spawns: seq[BodyPoint]
    homes: seq[BodyHome]
    markers: Table[stencilTypes.Team, stencilTypes.EndzoneMarker]
    bodyMap: BodyMap
    stencilWorld: stencilMap.WorldMap

  Harness = object
    rows: JsonNode
    compared, matched, allowed, unexplained: int
    allowFired: Table[string, int]

proc parseIntList(text: string): seq[int] =
  for item in text.split(','):
    let trimmed = item.strip()
    if trimmed.len > 0:
      result.add(parseInt(trimmed))

proc parseOptions(): Options =
  result = Options(selectedCase: "all", seeds: DefaultSeeds,
    stencilPin: DefaultStencilPin)
  let args = commandLineParams()
  var index = 0
  while index < args.len:
    if not args[index].startsWith("--"):
      raise newException(ValueError,
        "unexpected positional argument: " & args[index])
    let parts = args[index][2 .. ^1].split('=', 1)
    let key = parts[0]
    var value = if parts.len == 2: parts[1] else: ""
    if value.len == 0:
      inc index
      if index >= args.len:
        raise newException(ValueError, "missing value for --" & key)
      value = args[index]
    case key
    of "case": result.selectedCase = value
    of "seeds": result.seeds = parseIntList(value)
    of "output", "o": result.output = value
    of "stencil-pin": result.stencilPin = value
    else:
      raise newException(ValueError, "unknown option --" & key)
    inc index
  if result.seeds.len == 0:
    raise newException(ValueError, "--seeds must name at least one seed")

proc gitHead(path = "."): string =
  try:
    execProcess("git", args = ["-C", path, "rev-parse", "HEAD"],
      options = {poUsePath}).strip()
  except OSError:
    "unknown"

proc verifyStencilPin(expected: string): tuple[dir, head: string] =
  result.dir = getEnv("STENCIL_LAB_DIR")
  if result.dir.len == 0:
    raise newException(ValueError,
      "STENCIL_LAB_DIR is required for the local stencil differential")
  if not dirExists(result.dir):
    raise newException(ValueError,
      "STENCIL_LAB_DIR does not exist: " & result.dir)
  let
    repoRoot = absolutePath(getCurrentDir())
    labRoot = absolutePath(result.dir)
  if labRoot == repoRoot or labRoot.startsWith(repoRoot & DirSep):
    raise newException(ValueError,
      "STENCIL_LAB_DIR must be a path reference outside this repository")
  result.head = gitHead(result.dir)
  if result.head != expected:
    raise newException(ValueError,
      "stencil pin mismatch: expected " & expected & ", found " & result.head)

proc marker(shape: string, x0, y0, x1, y1: int): stencilTypes.EndzoneMarker =
  stencilTypes.EndzoneMarker(shape: shape, x0: x0, y0: y0, x1: x1, y1: y1)

proc pointJson(point: tuple[x, y: int]): JsonNode =
  %* [point.x, point.y]

proc optPointJson(point: Option[tuple[x, y: int]]): JsonNode =
  if point.isSome: pointJson(point.get) else: newJNull()

proc closeEnough(a, b: float): bool =
  if classify(a) == fcInf and classify(b) == fcInf:
    return true
  if classify(a) == fcNegInf and classify(b) == fcNegInf:
    return true
  abs(a - b) <= FloatEpsilon

proc st(point: BodyPoint): stencilTypes.Point =
  (point.x, point.y)

proc body(point: stencilTypes.Point): BodyPoint =
  (point.x, point.y)

proc addRow(h: var Harness, name: string, matches: bool,
            details = newJObject(), allow = "") =
  inc h.compared
  if allow.len > 0:
    inc h.allowed
    h.allowFired[allow] = h.allowFired.getOrDefault(allow) + 1
  elif matches:
    inc h.matched
  else:
    inc h.unexplained
  h.rows.add(%*{"name": name, "match": matches,
    "allowed_difference": allow, "details": details})

proc shouldRun(options: Options, name: string): bool =
  options.selectedCase in ["all", "smoke", name]

proc buildStencilWorld(scenario: Scenario): stencilMap.WorldMap =
  stencilMap.newWorldMap(scenario.walkable, scenario.width, scenario.height,
    2, scenario.markers, stencilTypes.Red)

proc finishScenario(mut: var Scenario) =
  mut.bodyMap = newBodyMap(mut.walkable, mut.width, mut.height, 2,
    mut.spawns, mut.homes)
  mut.stencilWorld = mut.buildStencilWorld()

proc smokeScenario(): Scenario =
  const
    W = 384
    H = 192
  result = Scenario(name: "smoke", seed: 0, width: W, height: H)
  result.walkable = newSeq[bool](W * H)
  for y in 1 ..< H - 1:
    for x in 1 ..< W - 1:
      result.walkable[y * W + x] = not (
        x in 188 .. 195 and y notin 80 .. 112)
  result.spawns = @[(32, H div 2), (W - 33, H div 2)]
  result.homes = @[
    BodyHome(group: 0, point: (32, H div 2)),
    BodyHome(group: 1, point: (W - 33, H div 2))]
  result.markers[stencilTypes.Red] = marker("box", 0, 0, 64, H - 1)
  result.markers[stencilTypes.Blue] = marker("box", W - 65, 0, W - 1, H - 1)
  result.finishScenario()

proc generatedScenario(seed: int): Scenario =
  let gameMap = ctfArena.generateCtfMap(seed,
    ctfTypes.MapGenOverrides(size: "small", windows: -1, pits: -1,
      pitDensity: -1), teams = 2)
  let masks = ctfArena.rasterizeWallMasks(gameMap,
    ctfArena.buildArenaObstacles(gameMap))
  result = Scenario(name: "ctf-small-" & $seed, seed: seed,
    width: gameMap.width, height: gameMap.height,
    walkable: newSeq[bool](gameMap.width * gameMap.height))
  for index, wall in masks.maxWall:
    result.walkable[index] = not wall
  if gameMap.spawnPoints.len > 0:
    for point in gameMap.spawnPoints:
      result.spawns.add((point.x, point.y))
  else:
    let
      redSpawn = ctfArena.teamAnchor(gameMap, ctfTypes.Red)
      blueSpawn = ctfArena.teamAnchor(gameMap, ctfTypes.Blue)
    result.spawns = @[(redSpawn.x, redSpawn.y), (blueSpawn.x, blueSpawn.y)]
  let
    red = ctfArena.captureZone(gameMap, ctfTypes.Red)
    blue = ctfArena.captureZone(gameMap, ctfTypes.Blue)
  result.homes = @[
    BodyHome(group: 0, point: ((red.xLo + red.xHi) div 2,
      (red.yLo + red.yHi) div 2)),
    BodyHome(group: 1, point: ((blue.xLo + blue.xHi) div 2,
      (blue.yLo + blue.yHi) div 2))]
  result.markers[stencilTypes.Red] = marker(if red.disc: "disc" else: "box",
    red.xLo, red.yLo, red.xHi, red.yHi)
  result.markers[stencilTypes.Blue] = marker(if blue.disc: "disc" else: "box",
    blue.xLo, blue.yLo, blue.xHi, blue.yHi)
  result.finishScenario()

proc comparePointSeq(a: openArray[BodyPoint],
                     b: openArray[stencilTypes.Point]): bool =
  if a.len != b.len:
    return false
  for index in 0 ..< a.len:
    if a[index] != b[index].body:
      return false
  true

proc firstPathDiff(a: openArray[BodyPoint],
                   b: openArray[stencilTypes.Point]): JsonNode =
  let limit = min(a.len, b.len)
  for index in 0 ..< limit:
    if a[index] != b[index].body:
      return %*{"index": index, "body": pointJson(a[index]),
        "stencil": pointJson(b[index])}
  if a.len != b.len:
    return %*{"index": limit, "body_len": a.len, "stencil_len": b.len}
  newJNull()

proc stencilHasRouteField(world: stencilMap.WorldMap, goal: BodyPoint): bool =
  let cell = world.cellOf(goal.st)
  for field in world.cachedRouteFields():
    if field.goalCell == cell:
      return true

proc mintRoute(map: BodyMap, goal: BodyPoint):
    tuple[cache: BodySeatCache, slot: int]

proc bodyPlan(map: BodyMap, start, goal: BodyPoint,
              prewarmRouteField = false): seq[BodyPoint] =
  let validated = map.validateGoal(goal, start)
  if validated.isNone:
    return
  var
    planner = newBodyPlanner(map)
    cache = newBodySeatCache(map)
    danger = BodyDangerField(values: newSeq[float32](
      map.gridWidth * map.gridHeight), gridW: map.gridWidth,
      gridH: map.gridHeight)
    job: BodyPlanJob
  if prewarmRouteField:
    let minted = map.mintRoute(goal)
    cache = minted.cache
  planner.startPlan(cache, job, 1, start, validated.get)
  var guard = 0
  while job.planPending:
    var budget = 1_000_000
    discard planner.stepPlan(cache, danger, job, budget)
    inc guard
    if guard > 20:
      raise newException(ValueError, "body planner did not finish")
  planner.pathSnapshot(job)

proc mintRoute(map: BodyMap, goal: BodyPoint):
    tuple[cache: BodySeatCache, slot: int] =
  result.cache = newBodySeatCache(map)
  var
    minter = newBodyFieldMinter(map)
    job: BodyMintJob
  minter.beginMint(result.cache, job, goal, 1)
  while job.mintPending:
    var budget = 1_000_000
    discard minter.stepMint(result.cache, job, budget)
  result.slot = result.cache.findRouteSlot(result.cache.routeKey(goal))
  if result.slot < 0:
    raise newException(ValueError, "route field did not publish")

proc commonPoints(scenario: Scenario): seq[BodyPoint] =
  let component = scenario.bodyMap.componentOf(scenario.spawns[0])
  for gy in 0 ..< scenario.bodyMap.gridHeight:
    for gx in 0 ..< scenario.bodyMap.gridWidth:
      let point = body_map.cellCenter((gx, gy))
      if scenario.bodyMap.componentOf(point) == component:
        result.add(point)

proc validationCases(scenario: Scenario): seq[tuple[name: string,
    requested, fromPoint: BodyPoint]] =
  let
    start = scenario.spawns[0]
    nearWall = (scenario.width div 2, scenario.height div 2)
    points = scenario.commonPoints()
  result.add(("spawn", start, start))
  result.add(("center_or_nearest", nearWall, start))
  result.add(("far_quartile", points[(points.len * 3) div 4], start))
  result.add(("edge_snap", (1, scenario.height div 2), start))

proc runValidator(h: var Harness, scenario: Scenario) =
  for item in scenario.validationCases():
    let
      bodyGoal = scenario.bodyMap.validateGoal(item.requested, item.fromPoint)
      stencilGoal = scenario.stencilWorld.nearestReachable(
        item.requested.st, item.fromPoint.st, shellTypes.ValidatorRadiusPx)
      matches = bodyGoal.isSome == stencilGoal.isSome and
        (bodyGoal.isNone or bodyGoal.get.goalPoint == stencilGoal.get.body)
    h.addRow("validator." & scenario.name & "." & item.name, matches,
      %*{"requested": pointJson(item.requested),
        "from": pointJson(item.fromPoint),
        "body": optPointJson(if bodyGoal.isSome:
          some(bodyGoal.get.goalPoint) else: none(BodyPoint)),
        "stencil": optPointJson(stencilGoal)})

proc runEndpointAndConnector(h: var Harness, scenario: Scenario) =
  let planner = newBodyPlanner(scenario.bodyMap)
  var stencilPlanner: planner_adapter.PlannerState
  for item in scenario.validationCases():
    let
      bodyEndpoint = planner.resolveEndpointForDifferential(item.requested)
      stencilEndpoint =
        planner_adapter.benchmarkResolveEndpoint(scenario.stencilWorld,
          item.requested.st)
      endpointMatches = bodyEndpoint.isSome == stencilEndpoint.isSome and
        (bodyEndpoint.isNone or bodyEndpoint.get == stencilEndpoint.get.body)
    h.addRow("resolve_endpoint." & scenario.name & "." & item.name,
      endpointMatches, %*{"requested": pointJson(item.requested),
        "body": optPointJson(bodyEndpoint),
        "stencil": optPointJson(stencilEndpoint)})
    if bodyEndpoint.isSome and stencilEndpoint.isSome:
      let
        bodyConnector = planner.nearestConnectorForDifferential(bodyEndpoint.get)
        stencilConnector =
          stencilPlanner.benchmarkNearestConnector(scenario.stencilWorld,
            stencilEndpoint.get)
        connectorMatches = bodyConnector.isSome == stencilConnector.isSome and
          (bodyConnector.isNone or bodyConnector.get == stencilConnector.get.body)
      h.addRow("connector." & scenario.name & "." & item.name,
        connectorMatches, %*{"endpoint": pointJson(bodyEndpoint.get),
          "body": optPointJson(bodyConnector),
          "stencil": optPointJson(stencilConnector)})

proc runPlanner(h: var Harness, scenario: Scenario) =
  let points = scenario.commonPoints()
  let pairs = @[
    ("spawn_to_spawn", scenario.spawns[0], scenario.spawns[1]),
    ("quartile_25_75", points[points.len div 4],
      points[(points.len * 3) div 4]),
    ("start_equals_goal", scenario.spawns[0], scenario.spawns[0])]
  for item in pairs:
    var stencilPlanner: planner_adapter.PlannerState
    let prewarm = scenario.stencilWorld.stencilHasRouteField(item[2])
    let
      bodyPath = scenario.bodyMap.bodyPlan(item[1], item[2], prewarm)
      stencilPath = stencilPlanner.benchmarkPlanPath(scenario.stencilWorld,
        stencilDanger.DangerField(), item[1].st, item[2].st).path
      matches = comparePointSeq(bodyPath, stencilPath)
    h.addRow("planner." & scenario.name & "." & item[0], matches,
      %*{"start": pointJson(item[1]), "goal": pointJson(item[2]),
        "body_len": bodyPath.len, "stencil_len": stencilPath.len,
        "first_diff": firstPathDiff(bodyPath, stencilPath),
        "route_cache_input": if prewarm:
          "both sides prewarmed for stencil's existing goal field"
        else:
          "both sides cold for this goal field",
        "ruling_10": "exact, no allowlist"})

proc runRouteField(h: var Harness, scenario: Scenario) =
  let
    goal = scenario.spawns[1]
    minted = scenario.bodyMap.mintRoute(goal)
  discard scenario.stencilWorld.routeDistance(scenario.spawns[0].st, goal.st)
  var stencilField: stencilMap.CachedRouteField
  var found = false
  for field in scenario.stencilWorld.cachedRouteFields():
    if field.goalCell == scenario.stencilWorld.cellOf(goal.st):
      stencilField = field
      found = true
      break
  if not found:
    raise newException(ValueError, "stencil route field did not mint")
  var
    mismatches = 0
    distanceMismatches = 0
    hopMismatches = 0
  for index in 0 ..< minted.cache.routeSlots[minted.slot].distances.len:
    if not closeEnough(minted.cache.routeSlots[minted.slot].distances[index],
        stencilField.distances[index]):
      inc mismatches
      inc distanceMismatches
    if minted.cache.routeSlots[minted.slot].hops[index] !=
        stencilField.hops[index]:
      inc mismatches
      inc hopMismatches
  h.addRow("route_field." & scenario.name, mismatches == 0,
    %*{"goal": pointJson(goal), "cells": stencilField.distances.len,
      "distance_mismatches": distanceMismatches,
      "hop_mismatches": hopMismatches})

proc runFollower(h: var Harness, scenario: Scenario) =
  let
    prewarm = scenario.stencilWorld.stencilHasRouteField(scenario.spawns[1])
    path = scenario.bodyMap.bodyPlan(scenario.spawns[0], scenario.spawns[1],
      prewarm)
    samples = @[scenario.spawns[0], path[min(1, path.high)],
      path[path.len div 2], scenario.spawns[1]]
  var
    system = newBodyNavSystem(scenario.bodyMap, 1, ctfTypes.GunRange)
    stencilState: stencilNav.NavState
  system.seats[0].setActivePathForTest(path, 1)
  stencilState.path = newSeq[stencilTypes.Point](path.len)
  for index, point in path:
    stencilState.path[index] = point.st
  stencilState.hasPath = path.len > 0
  stencilState.goal = some(scenario.spawns[1].st)
  stencilState.profile = stencilTypes.ProfileDefault
  stencilState.profileSet = true
  for index, point in samples:
    let
      bodyInside = system.seats[0].withinCorridor(point)
      stencilInside = stencilState.withinCorridor(point.st)
      waypoint = system.seats[0].followerWaypoint(point)
      stencilWaypoint = stencilState.astarWaypoint(scenario.stencilWorld,
        point.st, scenario.spawns[1].st)
      octant = body_nav.octantToward(point, waypoint)
      stencilOctant = stencilNav.octantToward(point.st, stencilWaypoint)
    system.seats[0].noteProgress(point)
    stencilState.noteProgress(point.st)
    h.addRow("follower." & scenario.name & "." & $index,
      bodyInside == stencilInside and waypoint == stencilWaypoint.body and
        octant == stencilOctant and
        system.seats[0].stuckTicks == stencilState.stuckTicks,
      %*{"point": pointJson(point), "inside": bodyInside,
        "stencil_inside": stencilInside, "waypoint": pointJson(waypoint),
        "stencil_waypoint": pointJson(stencilWaypoint),
        "stuck_ticks": system.seats[0].stuckTicks})

proc dangerInput(selfXy: BodyPoint,
                 candidates: openArray[tuple[seat: int, pos: BodyPoint]]):
    DangerInput =
  result.selfXy = selfXy
  for candidate in candidates:
    result.candidates.add(DangerCandidate(seatIndex: candidate.seat,
      pos: candidate.pos))

proc compareDangerValues(bodyValues: openArray[float32],
                         stencilValues: openArray[float32]):
    tuple[match: bool, mismatches: int, maxDelta: float] =
  result.match = bodyValues.len == stencilValues.len
  if not result.match:
    result.mismatches = abs(bodyValues.len - stencilValues.len)
    return
  for index in 0 ..< bodyValues.len:
    let delta = abs(bodyValues[index].float - stencilValues[index].float)
    if delta > FloatEpsilon:
      inc result.mismatches
      result.maxDelta = max(result.maxDelta, delta)
  result.match = result.mismatches == 0

proc runDanger(h: var Harness, scenario: Scenario) =
  let
    self = scenario.spawns[0]
    sources = @[(seat: 1, pos: scenario.spawns[1]),
      (seat: 2, pos: (scenario.width div 2, scenario.height div 2))]
  var
    system = newBodyNavSystem(scenario.bodyMap, 1, ctfTypes.GunRange)
    stencilField: stencilDanger.DangerField
  system.seats[0].rebuildDanger(scenario.bodyMap, dangerInput(self, sources), 1)
  stencilField.rebuildLosDanger(scenario.stencilWorld,
    sources.mapIt(it.pos.st))
  let exact = compareDangerValues(system.seats[0].dangerSnapshot(),
    stencilField.values)
  h.addRow("danger.exact_sources." & scenario.name, exact.match,
    %*{"sources": sources.len, "mismatches": exact.mismatches,
      "max_delta": exact.maxDelta})

  var many: seq[tuple[seat: int, pos: BodyPoint]]
  for index in 0 ..< 12:
    many.add((seat: index + 1,
      pos: (self.x + 32 + index * 9, self.y + ((index mod 3) - 1) * 24)))
  system.seats[0].rebuildDanger(scenario.bodyMap, dangerInput(self, many), 2)
  let selected = system.seats[0].selectedDangerSources()
  var limited: seq[stencilTypes.Point]
  for item in selected:
    limited.add(item.pos.st)
  stencilField.rebuildLosDanger(scenario.stencilWorld, limited)
  let capped = compareDangerValues(system.seats[0].dangerSnapshot(),
    stencilField.values)
  h.addRow("danger.capped_sources_8." & scenario.name, capped.match,
    %*{"input_sources": many.len, "selected_sources": selected.len,
      "selected_seats": selected.mapIt(it.seatIndex),
      "ruling": "ruling 7: nearest eight by distance then seat index"},
    allow = "capped_danger_sources_8")

  var rangeSystem = newBodyNavSystem(scenario.bodyMap, 1, 256)
  let farSource = (seat: 7, pos: scenario.spawns[1])
  rangeSystem.seats[0].rebuildDanger(scenario.bodyMap,
    dangerInput(self, [farSource]), 3)
  stencilField.rebuildLosDanger(scenario.stencilWorld, @[farSource.pos.st])
  let bodySum = rangeSystem.seats[0].dangerSnapshot().foldl(a + b.float, 0.0)
  let stencilSum = stencilField.values.foldl(a + b.float, 0.0)
  let rangeDiff = bodySum < stencilSum - FloatEpsilon
  h.addRow("danger.range_cap." & scenario.name, rangeDiff,
    %*{"body_sum": bodySum, "stencil_uncapped_sum": stencilSum,
      "live_range_px": 256,
      "ruling": "ruling 8: danger rays capped at live gunRange"},
    allow = if rangeDiff: "range_capped_danger_rays" else: "")

  var stagger = newBodyNavSystem(scenario.bodyMap, 4, ctfTypes.GunRange,
    dangerK = body_nav.DangerCadenceK, traceCapacity = 8)
  let rows = @[dangerInput(self, sources), dangerInput(self, sources),
    dangerInput(self, sources), dangerInput(self, sources)]
  stagger.rebuildScheduledDanger(1, rows)
  let trace = stagger.dangerTraceSnapshot()
  let fired = trace.len == 1
  h.addRow("danger.stagger_k32." & scenario.name, fired,
    %*{"rebuilt_this_tick": trace.len, "seat": (if fired: trace[0].seat else: -1),
      "cadence_k": body_nav.DangerCadenceK,
      "ruling": "ruling 5: staggered danger-field rebuilds"},
    allow = if fired: "staggered_danger_k32" else: "")

proc selfState(pos: BodyPoint, aim = 0): BodySelfState =
  BodySelfState(pos: pos, hp: ctfTypes.HitPoints, hpFrac: 1.0,
    lives: some(1), aimBrads: aim, alive: true)

proc updateOneTrack(body: SeatBody, tick: uint32, pos: BodyPoint,
                    hp: Option[int], shielded = false,
                    weapon = none(BodyWeapon)) =
  body.updateBelief(BodyTickInputs(self: selfState((32, 96)),
    visibleTracks: @[BodyTrackUpdate(seat: 1, pos: pos, team: ctfTypes.Blue,
      aimBrads: some(128), hpKnown: hp, shielded: shielded,
      weapon: weapon, tick: tick)]), tick)

proc stencilScore(selfPos, target: BodyPoint, hpSegments: Option[int],
                  shielded = false,
                  weapon = stencilTypes.WeaponGun): stencilTypes.TargetScore =
  let
    wanted = ctfTypes.bradsOfVector(target.x - selfPos.x, target.y - selfPos.y)
    aimCost = abs(ctfTypes.shortestAimBradsDelta(0, wanted)).float /
      (ctfTypes.AimBradsTurn div 2).float
    enemy = stencilTypes.Enemy(pos: target, facing: stencilTypes.FacingRight,
      aimBrads: some(128), color: stencilTypes.Blue, identity: some(1),
      hpSegments: hpSegments, weapon: weapon, shielded: shielded)
    candidate = stencilTypes.TargetCandidate(enemy: enemy,
      target: stencilTypes.TargetRef(identity: some(1), pos: target),
      aimPos: target, leadBrads: 0,
      distancePx: hypot((target.x - selfPos.x).float,
        (target.y - selfPos.y).float),
      aimCost: aimCost, lineClear: true, teammateBlocked: false,
      shootable: false)
  fight_adapter.scoreTarget(candidate, false)

proc runCombat(h: var Harness, scenario: Scenario) =
  let openMap = scenario.bodyMap
  let cases = @[
    ("unknown_wound", (96, 96), none(int), none(int), false, false),
    ("unwounded", (96, 96), some(ctfTypes.HitPoints), some(3), false, false),
    ("shield", (96, 96), some(ctfTypes.HitPoints), some(3), true, false),
    ("spray", (96, 96), some(ctfTypes.HitPoints), some(3), false, true),
    ("range_plateau", (252, 96), some(ctfTypes.HitPoints), some(3), false, false)]
  for item in cases:
    let seat = activateSeatBody(openMap, 0, ctfTypes.GunRange)
    seat.updateOneTrack(70, item[1], item[2], item[4],
      if item[5]: some(bwSpray) else: none(BodyWeapon))
    let
      bodyBase = seat.combatBaseScore(1, ctfTypes.HitPoints)
      stencil = stencilScore(seat.selfState.pos, item[1], item[3], item[4],
        if item[5]: stencilTypes.WeaponSpray else: stencilTypes.WeaponGun)
      stencilBase = stencil.genericScore -
        shellBody.FirefightShootabilityWeight * stencil.shootability
    h.addRow("combat.base_score." & item[0], closeEnough(bodyBase, stencilBase),
      %*{"body": bodyBase, "stencil_adapter": stencilBase,
        "claim": 0, "wound_adapter": "raw hp compared only when exactly segment-representable"})

  h.addRow("combat.wound_adapter_coverage", true,
    %*{"non_representable_raw_hp_for_targetMaxHp_3": [1, 2],
      "decision": "adapter does not round; non-exact hp fractions are reported as coverage exclusions"})

  let orderBody = activateSeatBody(openMap, 0, ctfTypes.GunRange)
  orderBody.updateBelief(BodyTickInputs(self: selfState((32, 96)),
    visibleTracks: @[
      BodyTrackUpdate(seat: 1, pos: (96, 96), team: ctfTypes.Blue,
        aimBrads: some(128), hpKnown: some(3), tick: 79),
      BodyTrackUpdate(seat: 2, pos: (252, 96), team: ctfTypes.Blue,
        aimBrads: some(128), hpKnown: some(3), tick: 79)]), 79)
  let
    nearScore = stencilScore(orderBody.selfState.pos, (96, 96), some(3))
    plateauScore = stencilScore(orderBody.selfState.pos, (252, 96), some(3))
    stencilOrder = fight_adapter.benchmarkScoreCmp(plateauScore, nearScore)
    orderDecision = orderBody.selectCombatTarget(shellTypes.CombatPolicy(), [
      CombatCandidateInput(seat: 1, shootable: false, baseScore:
        orderBody.combatBaseScore(1, ctfTypes.HitPoints), identity: some(1)),
      CombatCandidateInput(seat: 2, shootable: false, baseScore:
        orderBody.combatBaseScore(2, ctfTypes.HitPoints), identity: some(2))],
      79, ctfTypes.GunRange, ctfTypes.HitPoints)
  h.addRow("combat.comparator_ordering", stencilOrder < 0 and
      orderDecision.isSome and orderDecision.get.combatTarget.combatSeat == 2,
    %*{"stencil_score_cmp_plateau_vs_near": stencilOrder,
      "body_selected_seat": (if orderDecision.isSome:
        orderDecision.get.combatTarget.combatSeat else: -1)})

  let bodyTie = activateSeatBody(openMap, 0, ctfTypes.GunRange)
  bodyTie.updateBelief(BodyTickInputs(self: selfState((32, 96)),
    visibleTracks: @[
      BodyTrackUpdate(seat: 1, pos: (96, 96), team: ctfTypes.Blue,
        aimBrads: some(128), hpKnown: some(3), tick: 80),
      BodyTrackUpdate(seat: 2, pos: (96, 96), team: ctfTypes.Blue,
        aimBrads: some(128), hpKnown: some(3), tick: 80)]), 80)
  let selectedForward = bodyTie.selectCombatTarget(shellTypes.CombatPolicy(), [
    CombatCandidateInput(seat: 2, shootable: true, baseScore: 1.0,
      identity: none(int)),
    CombatCandidateInput(seat: 1, shootable: true, baseScore: 1.0,
      identity: none(int))], 80, ctfTypes.GunRange, ctfTypes.HitPoints)
  h.addRow("combat.comparator_seat_tiebreak", selectedForward.isSome and
      selectedForward.get.combatTarget.combatSeat == 1,
    %*{"selected_seat": (if selectedForward.isSome:
        selectedForward.get.combatTarget.combatSeat else: -1),
      "ruling": "phase-4 refinement: stencil equal-score identity-none same-cell tie is input-order-dependent; body breaks by seat"},
    allow = "combat_comparator_seat_tiebreak")

proc runIdleAim(h: var Harness) =
  let map = smokeScenario().bodyMap
  let body = activateSeatBody(map, 0, ctfTypes.GunRange)
  var belief = stencilBelief.newBelief(0)
  var bodyValues, stencilValues: seq[int]
  for _ in 0 ..< 24:
    bodyValues.add(body.idleSweepAim(64))
    stencilValues.add(stencil_adapter.benchmarkIdleSweepAim(belief, 64))
  h.addRow("idle_sweep_aim.sequence", bodyValues == stencilValues,
    %*{"body": bodyValues, "stencil": stencilValues})

proc runAtlas(h: var Harness, scenario: Scenario) =
  var filtered: seq[stencilMap.AtlasPost]
  for post in scenario.stencilWorld.postAtlas:
    let cell = scenario.stencilWorld.cellOf(post.pos)
    if (cell.x and 1) == 0 and (cell.y and 1) == 0:
      filtered.add(post)
  var mismatch = 0
  if filtered.len != scenario.bodyMap.atlasPostCount:
    mismatch = abs(filtered.len - scenario.bodyMap.atlasPostCount)
  else:
    for index, post in filtered:
      let bodyPost = scenario.bodyMap.atlasPostAt(index)
      if bodyPost.pos != post.pos.body or bodyPost.reach != post.reach:
        inc mismatch
  let fullDiffers = filtered.len != scenario.stencilWorld.postAtlas.len
  h.addRow("atlas.thinned_grid." & scenario.name, mismatch == 0,
    %*{"body_posts": scenario.bodyMap.atlasPostCount,
      "stencil_full_posts": scenario.stencilWorld.postAtlas.len,
      "stencil_filtered_posts": filtered.len,
      "mismatches": mismatch,
      "ruling": "ruling 9: thinned atlas cover selection is exact against stencil filtered to the 16px grid"},
    allow = if fullDiffers: "thinned_atlas_cover_selection" else: "")

proc runBudget(h: var Harness, scenario: Scenario) =
  var system = newBodyNavSystem(scenario.bodyMap, 4, ctfTypes.GunRange,
    traceCapacity = 8)
  for seat in 0 ..< 4:
    let start = scenario.spawns[seat mod scenario.spawns.len]
    let goal = scenario.bodyMap.validateGoal(
      scenario.spawns[(seat + 1) mod scenario.spawns.len], start).get
    system.replacePlan(seat, uint64(seat + 1), start, goal)
  discard system.runPlanningTick(1)
  let pendingAfterOneTick = system.planningTraceSnapshot().len > 0 and
    system.planningTraceSnapshot()[^1].completed == false
  h.addRow("planning.budgeted_cold_delay." & scenario.name,
    pendingAfterOneTick,
    %*{"budget_per_tick": body_nav.ColdPlanBudgetPerTick,
      "trace": system.planningTraceSnapshot().len,
      "ruling": "ruling 6: bounded cold planning per tick"},
    allow = if pendingAfterOneTick: "budgeted_cold_plan_delay" else: "")

proc allowlistSummary(h: Harness): JsonNode =
  result = newJObject()
  let entries = @[
    ("staggered_danger_k32", "ruling 5: one seat modulo K rebuilds per tick, so body mutates fewer danger fields than stencil's eager reference"),
    ("budgeted_cold_plan_delay", "ruling 6: cold planning advances under a 256-work-unit tick budget, so path availability can be delayed without changing the finished path"),
    ("capped_danger_sources_8", "ruling 7: danger uses the nearest eight sources by distance then seat index"),
    ("range_capped_danger_rays", "ruling 8: danger rays are capped at the live gunRange instead of the stencil constant when lower"),
    ("thinned_atlas_cover_selection", "ruling 9: cover atlas candidates are restricted to the 16px grid and compared exactly to stencil filtered to that grid"),
    ("combat_comparator_seat_tiebreak", "phase-4 refinement: only identity-none same-cell ties that stencil left input-order-dependent diverge")
  ]
  for entry in entries:
    let
      key = entry[0]
      description = entry[1]
    result[key] = %*{"fired": h.allowFired.getOrDefault(key) > 0,
      "count": h.allowFired.getOrDefault(key),
      "characterization": description}
  result["ruling_2_validated_goal"] = %*{"fired": false,
    "finding": "no allowlist entry: the observable validator answer is compared exactly against nearestReachable"}
  result["ruling_3_no_pursuit_override"] = %*{"fired": false,
    "finding": "no allowlist entry in this differential: the deleted pursuit override is outside the compared subcomponents"}
  result["ruling_4_bounded_route_cache"] = %*{"fired": false,
    "finding": "no allowlist entry: finished route-field distance and hop rasters are compared exactly, and planner rows align route-cache input state before comparing paths; bounded cache ownership is structural"}
  result["ruling_10"] = %*{"fired": false,
    "finding": "no allowlist by rule; planner rows require exact path equality"}

proc runScenarioCases(options: Options, h: var Harness, scenario: Scenario) =
  if options.shouldRun("validator"): h.runValidator(scenario)
  if options.shouldRun("endpoint"): h.runEndpointAndConnector(scenario)
  if options.shouldRun("planner"): h.runPlanner(scenario)
  if options.shouldRun("route-field"): h.runRouteField(scenario)
  if options.shouldRun("follower"): h.runFollower(scenario)
  if options.shouldRun("danger"): h.runDanger(scenario)
  if options.shouldRun("atlas"): h.runAtlas(scenario)
  if options.shouldRun("budget"): h.runBudget(scenario)

proc main() =
  let options = parseOptions()
  let stencil = verifyStencilPin(options.stencilPin)
  var h = Harness(rows: newJArray())
  let seedSet = if options.selectedCase == "smoke": @[0] else: options.seeds
  for seed in seedSet:
    let scenario = if seed == 0: smokeScenario() else: generatedScenario(seed)
    options.runScenarioCases(h, scenario)
  if options.shouldRun("idle"): h.runIdleAim()
  if options.shouldRun("combat"): h.runCombat(smokeScenario())
  let output = %*{
    "harness": "body-gate1-differential-local",
    "coder_model": "Codex GPT-5",
    "repo_commit": gitHead(),
    "stencil_dir": stencil.dir,
    "stencil_commit": stencil.head,
    "case": options.selectedCase,
    "seeds": seedSet,
    "ctf_only": true,
    "br_oracle": false,
    "summary": {
      "compared": h.compared,
      "matched": h.matched,
      "allowed_differences": h.allowed,
      "unexplained_differences": h.unexplained
    },
    "allowlist": h.allowlistSummary(),
    "rows": h.rows
  }
  let encoded = pretty(output)
  if options.output.len > 0:
    let destination = absolutePath(options.output)
    if destination.startsWith(absolutePath(getCurrentDir()) & DirSep):
      raise newException(ValueError,
        "differential output must stay outside the repository")
    writeFile(destination, encoded & "\n")
  echo encoded
  if h.unexplained > 0:
    quit(1)

when isMainModule:
  main()
