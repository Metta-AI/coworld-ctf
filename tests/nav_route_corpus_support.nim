## Literal shared-navigation corpus reader and independent float oracle.
##
## The checked-in manifest is test truth. Nothing in this module selects
## cases or rewrites the fixture; tools/build_nav_route_corpus.nim is the only
## writer.

import std/[algorithm, heapqueue, json, math, options, sets, strformat, tables]
import crunchy/[common, sha256]
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_danger
import ../src/shell/types as shellTypes

const
  NavCorpusSchema* = "coworld_nav_route_corpus"
  NavCorpusVersion* = 1
  NavCorpusCaseCount* = 3_072
  NavCorpusSourceCommit* = "52103b107832e12f30a719dd299bc7636c3dd12f"
  NavCorpusGunRangePx* = 331
  OracleRuleId* = "weighted_astar_4px_float32_danger_midpoint_block_x8_v1"
  OracleNeighbors = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1)]

type
  NavCorpusProfile* = enum
    ncpDefault = "default"
    ncpCarrier = "carrier"
    ncpHunter = "hunter"

  NavCorpusDynamic* = enum
    ncdNone = "none"
    ncdDanger = "danger"
    ncdBlocked = "blocked"
    ncdBoth = "both"

  NavCorpusDistance* = enum
    ncrNear = "near"
    ncrFar = "far"

  NavCorpusPoint* = object
    x*, y*: int

  NavCorpusCase* = object
    id*, mapName*, mapSha256*: string
    poolIndex*, rosterSize*, seatIndex*: int
    profile*: NavCorpusProfile
    dynamic*: NavCorpusDynamic
    distance*: NavCorpusDistance
    start*, requestedGoal*, validatedGoal*: BodyPoint
    component*: int
    dangerSources*: seq[DangerCandidate]
    dangerHash*: string
    blockedCell*: Option[BodyPoint]
    oracleCost*: float64
    oracleRouteHash*: string

  NavCorpus* = object
    schemaVersion*: int
    sourceCommit*, poolSha256*, oracleRules*: string
    coverHoldTask*: string
    coverHoldEnabled*: bool
    cases*: seq[NavCorpusCase]

  OracleHeapNode = object
    priority, cost: float64
    index: int

proc `<`(a, b: OracleHeapNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.index < b.index

proc sha256Text*(value: string): string = sha256(value).toHex()

proc point(node: JsonNode, field: string): BodyPoint =
  if node.kind != JArray or node.len != 2:
    raise newException(ValueError, field & " must be a two-integer array")
  (node[0].getInt(), node[1].getInt())

proc profile(value: string): NavCorpusProfile =
  case value
  of "default": ncpDefault
  of "carrier": ncpCarrier
  of "hunter": ncpHunter
  else: raise newException(ValueError, "unknown corpus profile: " & value)

proc dynamic(value: string): NavCorpusDynamic =
  case value
  of "none": ncdNone
  of "danger": ncdDanger
  of "blocked": ncdBlocked
  of "both": ncdBoth
  else: raise newException(ValueError, "unknown corpus dynamic: " & value)

proc distance(value: string): NavCorpusDistance =
  case value
  of "near": ncrNear
  of "far": ncrFar
  else: raise newException(ValueError, "unknown corpus distance: " & value)

proc loadNavRouteCorpus*(path: string): NavCorpus =
  let root = parseFile(path)
  if root.kind != JObject or root{"schema"}.getStr() != NavCorpusSchema:
    raise newException(ValueError, "wrong navigation corpus schema")
  result.schemaVersion = root{"v"}.getInt()
  if result.schemaVersion != NavCorpusVersion:
    raise newException(ValueError, "unsupported navigation corpus version")
  result.sourceCommit = root{"source_commit"}.getStr()
  result.poolSha256 = root{"pool_sha256"}.getStr()
  result.oracleRules = root{"oracle_rules"}.getStr()
  if result.sourceCommit != NavCorpusSourceCommit or result.poolSha256.len != 64 or
      result.oracleRules != OracleRuleId:
    raise newException(ValueError, "navigation corpus provenance is malformed")
  let todo = root{"todos"}{"cover_hold_cold_transition"}
  result.coverHoldTask = todo{"task"}.getStr()
  result.coverHoldEnabled = todo{"enabled"}.getBool()
  if result.coverHoldTask != "1218165969208626" or result.coverHoldEnabled:
    raise newException(ValueError, "cover-hold TODO contract changed")

  var ids = initHashSet[string]()
  var strata = initCountTable[string]()
  let rows = root{"cases"}
  if rows.kind != JArray:
    raise newException(ValueError, "navigation corpus cases must be an array")
  for node in rows:
    var item: NavCorpusCase
    item.id = node{"id"}.getStr()
    item.mapName = node{"map_name"}.getStr()
    item.mapSha256 = node{"map_sha256"}.getStr()
    item.poolIndex = node{"pool_index"}.getInt()
    item.rosterSize = node{"roster_size"}.getInt()
    item.seatIndex = node{"seat_index"}.getInt()
    item.profile = profile(node{"profile"}.getStr())
    item.dynamic = dynamic(node{"dynamic"}.getStr())
    item.distance = distance(node{"distance"}.getStr())
    item.start = point(node{"start"}, "start")
    item.requestedGoal = point(node{"requested_goal"}, "requested_goal")
    item.validatedGoal = point(node{"validated_goal"}, "validated_goal")
    item.component = node{"component"}.getInt()
    item.dangerHash = node{"danger_hash"}.getStr()
    item.oracleCost = node{"oracle_cost"}.getFloat()
    item.oracleRouteHash = node{"oracle_route_hash"}.getStr()
    if node.hasKey("blocked_cell"):
      item.blockedCell = some(point(node["blocked_cell"], "blocked_cell"))
    for source in node{"danger_sources"}:
      item.dangerSources.add DangerCandidate(
        seatIndex: source{"seat"}.getInt(),
        pos: (source{"x"}.getInt(), source{"y"}.getInt()))

    if item.id.len == 0 or item.id in ids:
      raise newException(ValueError, "duplicate or empty corpus case id: " & item.id)
    ids.incl item.id
    if item.poolIndex notin 0 ..< 64 or item.mapSha256.len != 64 or
        item.rosterSize notin [16, 32] or
        item.seatIndex notin 0 ..< item.rosterSize or
        item.component <= 0 or item.dangerSources.len > MaxDangerSources or
        item.dangerHash.len != 64 or item.oracleRouteHash.len != 64 or
        item.oracleCost.classify notin {fcNormal, fcSubnormal, fcZero}:
      raise newException(ValueError, "malformed navigation corpus case: " & item.id)
    for source in item.dangerSources:
      if source.seatIndex notin 0 ..< item.rosterSize:
        raise newException(ValueError, "danger source outside case roster: " & item.id)
    case item.dynamic
    of ncdNone:
      if item.dangerSources.len != 0 or item.blockedCell.isSome:
        raise newException(ValueError, "none case carries dynamic state: " & item.id)
    of ncdDanger:
      if item.dangerSources.len == 0 or item.blockedCell.isSome:
        raise newException(ValueError, "danger case has wrong dynamic state: " & item.id)
    of ncdBlocked:
      if item.dangerSources.len != 0 or item.blockedCell.isNone:
        raise newException(ValueError, "blocked case has wrong dynamic state: " & item.id)
    of ncdBoth:
      if item.dangerSources.len == 0 or item.blockedCell.isNone:
        raise newException(ValueError, "both case has wrong dynamic state: " & item.id)
    strata.inc &"{item.poolIndex}:{item.rosterSize}:{item.profile}:" &
      &"{item.dynamic}:{item.distance}"
    result.cases.add item

  if result.cases.len != NavCorpusCaseCount or strata.len != NavCorpusCaseCount:
    raise newException(ValueError,
      &"navigation corpus must contain exactly {NavCorpusCaseCount} unique strata")
  for count in strata.values:
    if count != 1:
      raise newException(ValueError, "navigation corpus stratum is not singular")

proc corpusStratumCounts*(corpus: NavCorpus): CountTable[string] =
  for item in corpus.cases:
    result.inc &"{item.poolIndex}:{item.rosterSize}:{item.profile}:" &
      &"{item.dynamic}:{item.distance}"

proc dangerRasterHash*(danger: BodyDangerField): string =
  var bytes = newStringOfCap(danger.values.len * 4)
  for value in danger.values:
    let bits = cast[uint32](value)
    for shift in [0, 8, 16, 24]:
      bytes.add char((bits shr shift) and 0xff'u32)
  sha256Text(bytes)

proc buildOracleDanger*(map: BodyMap; item: NavCorpusCase): BodyDangerField =
  let system = newBodyNavSystem(map, 1, NavCorpusGunRangePx)
  system.seats[0].rebuildDanger(map, DangerInput(
    selfXy: item.start, candidates: item.dangerSources), 0)
  result = BodyDangerField(values: system.seats[0].dangerSnapshot,
    gridW: map.gridWidth, gridH: map.gridHeight)
  for value in result.values:
    result.maximum = max(result.maximum, value)

proc oracleSegmentClear(map: BodyMap, start, goal: BodyPoint): bool =
  if not map.canStand(start):
    return false
  let
    dx = goal.x - start.x
    dy = goal.y - start.y
    nx = abs(dx)
    ny = abs(dy)
    stepX = cmp(dx, 0)
    stepY = cmp(dy, 0)
  var x = start.x
  var y = start.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      if not map.canStand((x + stepX, y)) or not map.canStand((x, y + stepY)):
        return false
      x += stepX
      y += stepY
      inc ix
      inc iy
    elif decision < 0:
      x += stepX
      inc ix
    else:
      y += stepY
      inc iy
    if not map.canStand((x, y)):
      return false
  true

proc corpusProfile*(profile: NavCorpusProfile): shellTypes.CostProfile =
  case profile
  of ncpDefault: shellTypes.cpDefault
  of ncpCarrier: shellTypes.cpCarrier
  of ncpHunter: shellTypes.cpHunter

proc oracleRoute4pxWithDanger*(map: BodyMap; item: NavCorpusCase;
    danger: BodyDangerField): seq[BodyPoint] =
  ## Independent dense A*: it deliberately does not call BodyPlanner.
  let
    step = PlanStepPx
    latticeW = (map.width - 1) div step + 1
    latticeH = (map.height - 1) div step + 1
    start = item.start
    goal = item.validatedGoal
  if start.x mod step != 0 or start.y mod step != 0 or
      goal.x mod step != 0 or goal.y mod step != 0 or
      not map.canStand(start) or not map.canStand(goal) or
      map.componentOf(start) != item.component or
      map.componentOf(goal) != item.component:
    return
  let
    startIndex = (start.y div step) * latticeW + start.x div step
    goalIndex = (goal.y div step) * latticeW + goal.x div step
    profileWeight = planCostProfile(item.profile.corpusProfile).dangerWeight
  var
    costs = newSeq[float64](latticeW * latticeH)
    cameFrom = newSeq[int](latticeW * latticeH)
    closed = newSeq[bool](latticeW * latticeH)
    heap: HeapQueue[OracleHeapNode]
  for index in 0 ..< costs.len:
    costs[index] = Inf
    cameFrom[index] = -1
  costs[startIndex] = 0.0
  heap.push OracleHeapNode(
    priority: hypot((start.x - goal.x).float, (start.y - goal.y).float),
    cost: 0.0, index: startIndex)
  while heap.len > 0:
    let current = heap.pop()
    if closed[current.index] or current.cost > costs[current.index]:
      continue
    closed[current.index] = true
    if current.index == goalIndex:
      var cursor = goalIndex
      while cursor >= 0:
        result.add((x: (cursor mod latticeW) * step,
                    y: (cursor div latticeW) * step))
        if cursor == startIndex:
          break
        cursor = cameFrom[cursor]
      if result.len == 0 or result[^1] != start:
        result.setLen(0)
        return
      result.reverse()
      return
    let currentPoint = (x: (current.index mod latticeW) * step,
                        y: (current.index div latticeW) * step)
    for delta in OracleNeighbors:
      let nextPoint = (x: currentPoint.x + delta[0] * step,
                       y: currentPoint.y + delta[1] * step)
      if nextPoint.x < 0 or nextPoint.x >= map.width or
          nextPoint.y < 0 or nextPoint.y >= map.height or
          not map.canStand(nextPoint) or
          not map.oracleSegmentClear(currentPoint, nextPoint):
        continue
      let nextIndex = (nextPoint.y div step) * latticeW + nextPoint.x div step
      if closed[nextIndex]:
        continue
      let baseCost = hypot((nextPoint.x - currentPoint.x).float,
                           (nextPoint.y - currentPoint.y).float)
      let midpoint = ((currentPoint.x + nextPoint.x) div 2,
                      (currentPoint.y + nextPoint.y) div 2)
      var edgeCost = baseCost * (1.0 + profileWeight * danger.sample(map, midpoint))
      if item.blockedCell.isSome and map.cellOf(midpoint) == item.blockedCell.get:
        edgeCost *= 8.0
      let nextCost = current.cost + edgeCost
      if nextCost < costs[nextIndex]:
        costs[nextIndex] = nextCost
        cameFrom[nextIndex] = current.index
        heap.push OracleHeapNode(
          priority: nextCost + hypot((nextPoint.x - goal.x).float,
                                     (nextPoint.y - goal.y).float),
          cost: nextCost, index: nextIndex)

proc oracleRoute4px*(map: BodyMap; item: NavCorpusCase): seq[BodyPoint] =
  let danger = map.buildOracleDanger(item)
  map.oracleRoute4pxWithDanger(item, danger)

proc resampleRoute4px*(route: openArray[BodyPoint]): seq[BodyPoint] =
  if route.len == 0:
    return
  result.add route[0]
  for index in 1 ..< route.len:
    let
      start = route[index - 1]
      finish = route[index]
      dx = finish.x - start.x
      dy = finish.y - start.y
      steps = max(1, (max(abs(dx), abs(dy)) + PlanStepPx - 1) div PlanStepPx)
    for part in 1 .. steps:
      let next = (
        x: start.x + int(round(dx.float * part.float / steps.float)),
        y: start.y + int(round(dy.float * part.float / steps.float)))
      if next != result[^1]:
        result.add next

proc oracleFloatCost*(route: openArray[BodyPoint]; map: BodyMap;
    danger: BodyDangerField; profile: shellTypes.CostProfile;
    blockedCell: Option[BodyPoint]): float64 =
  if route.len == 0:
    return Inf
  let profileWeight = planCostProfile(profile).dangerWeight
  for index in 1 ..< route.len:
    let
      start = route[index - 1]
      finish = route[index]
      midpoint = ((start.x + finish.x) div 2, (start.y + finish.y) div 2)
    var edgeCost = hypot((finish.x - start.x).float,
                         (finish.y - start.y).float) *
      (1.0 + profileWeight * danger.sample(map, midpoint))
    if blockedCell.isSome and map.cellOf(midpoint) == blockedCell.get:
      edgeCost *= 8.0
    result += edgeCost

proc routeHash*(route: openArray[BodyPoint]): string =
  var bytes = newStringOfCap(route.len * 16)
  for point in route:
    bytes.add $point.x
    bytes.add ','
    bytes.add $point.y
    bytes.add ';'
  sha256Text(bytes)

proc routeInflationPct*(candidateCost, oracleCost: float64): float64 =
  if oracleCost <= 0.0:
    if candidateCost <= 0.0: 0.0 else: Inf
  else:
    (candidateCost / oracleCost - 1.0) * 100.0
