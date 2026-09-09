## Explicit writer for tests/fixtures/shell/nav_route_corpus.json.
##
## Ordinary tests only read the literal fixture. Run this tool deliberately
## from the repository root when the approved corpus itself changes.

import std/[algorithm, json, math, options, os, strformat]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/body_danger
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_route_query
import ../tests/nav_route_corpus_support

const
  DefaultOutput = "tests/fixtures/shell/nav_route_corpus.json"
  CandidateCount = 17

type
  SelectedPair = object
    start, goal: BodyPoint
    route: seq[BodyPoint]
    length: float64

proc pathLength(route: openArray[BodyPoint]): float64 =
  for index in 1 ..< route.len:
    result += hypot((route[index].x - route[index - 1].x).float,
                    (route[index].y - route[index - 1].y).float)

proc selectPairs(map: BodyMap): array[NavCorpusDistance, SelectedPair] =
  ## Selection runs only in this explicit writer. The checked-in coordinates,
  ## not this sampling procedure, are corpus truth.
  var start: BodyPoint
  var foundStart = false
  for y in countup(0, map.height - 1, PlanStepPx):
    for x in countup(0, map.width - 1, PlanStepPx):
      let candidate = (x, y)
      if map.canStand(candidate) and map.validateGoal(candidate, candidate).isSome:
        start = candidate
        foundStart = true
        break
    if foundStart:
      break
  if not foundStart:
    raise newException(ValueError, "map has no validated 4px lattice start")
  let component = map.componentOf(start)
  var targets: seq[BodyPoint]
  for y in countup(0, map.height - 1, PlanStepPx):
    for x in countup(0, map.width - 1, PlanStepPx):
      let candidate = (x, y)
      if candidate != start and map.canStand(candidate) and
          map.componentOf(candidate) == component:
        targets.add candidate
  if targets.len < CandidateCount:
    raise newException(ValueError, "map has too few same-component lattice points")

  let nav = newBodyNavSystem(map, 1, NavCorpusGunRangePx)
  var successful: seq[SelectedPair]
  for sample in 0 ..< CandidateCount:
    let target = targets[sample * (targets.len - 1) div (CandidateCount - 1)]
    let validated = map.validateGoal(target, start)
    if validated.isNone or validated.get.goalPoint != target:
      continue
    nav.resetNavigationLife(0)
    discard nav.navigationWaypoint(0, start, validated.get, sample)
    var guard = 0
    while (nav.routeJob.active or
        nav.seats[0].pendingRoute.lifecycle != brlIdle) and guard < 100_000:
      discard nav.runRouteScheduler(sample)
      inc guard
    if nav.seats[0].lastQuerySucceeded:
      let route = nav.seats[0].installedRoutePoints
      successful.add SelectedPair(start: start, goal: target,
        route: route, length: route.pathLength)
  if successful.len < 4:
    raise newException(ValueError, "map has fewer than four successful sampled routes")
  successful.sort(proc(a, b: SelectedPair): int =
    result = cmp(a.length, b.length)
    if result == 0: result = cmp(a.goal.y, b.goal.y)
    if result == 0: result = cmp(a.goal.x, b.goal.x))
  let
    nearIndex = (successful.len - 1) div 4
    farIndex = ((successful.len - 1) * 3 + 3) div 4
  result[ncrNear] = successful[nearIndex]
  result[ncrFar] = successful[farIndex]

proc dangerSources(pair: SelectedPair, seatIndex, rosterSize: int): seq[DangerCandidate] =
  let
    lo = pair.route.len div 3
    hi = pair.route.len * 2 div 3
  for index in 0 ..< MaxDangerSources:
    let routeIndex = lo + index * max(1, hi - lo) div (MaxDangerSources - 1)
    let sourceSeat = (seatIndex + index + 1) mod rosterSize
    result.add DangerCandidate(seatIndex: sourceSeat,
      pos: pair.route[min(routeIndex, pair.route.high)])
  let start = pair.start
  result.sort(proc(a, b: DangerCandidate): int =
    let
      adx = int64(a.pos.x - start.x)
      ady = int64(a.pos.y - start.y)
      bdx = int64(b.pos.x - start.x)
      bdy = int64(b.pos.y - start.y)
      aDistance = adx * adx + ady * ady
      bDistance = bdx * bdx + bdy * bdy
    result = cmp(aDistance, bDistance)
    if result == 0: result = cmp(a.seatIndex, b.seatIndex))

proc profileName(profile: NavCorpusProfile): string = $profile
proc dynamicName(dynamic: NavCorpusDynamic): string = $dynamic
proc distanceName(distance: NavCorpusDistance): string = $distance

proc pointNode(point: BodyPoint): JsonNode = %*[point.x, point.y]

proc caseNode(item: NavCorpusCase): JsonNode =
  result = newJObject()
  result["id"] = %item.id
  result["map_name"] = %item.mapName
  result["map_sha256"] = %item.mapSha256
  result["pool_index"] = %item.poolIndex
  result["roster_size"] = %item.rosterSize
  result["seat_index"] = %item.seatIndex
  result["profile"] = %item.profile.profileName
  result["dynamic"] = %item.dynamic.dynamicName
  result["distance"] = %item.distance.distanceName
  result["start"] = pointNode(item.start)
  result["requested_goal"] = pointNode(item.requestedGoal)
  result["validated_goal"] = pointNode(item.validatedGoal)
  result["component"] = %item.component
  result["danger_sources"] = newJArray()
  for source in item.dangerSources:
    result["danger_sources"].add %*{
      "seat": source.seatIndex, "x": source.pos.x, "y": source.pos.y}
  result["danger_hash"] = %item.dangerHash
  if item.blockedCell.isSome:
    result["blocked_cell"] = pointNode(item.blockedCell.get)
  result["oracle_cost"] = %item.oracleCost
  result["oracle_route_hash"] = %item.oracleRouteHash

proc compactCorpus(root: JsonNode): string =
  ## Keep provenance readable while making every literal case one compact
  ## line. This preserves useful line attribution without spending ~50 lines
  ## of pretty-printing on each mechanical row.
  result = "{\n"
  for key in ["schema", "v", "source_commit", "pool_sha256", "oracle_rules"]:
    result.add "  " & escapeJson(key) & ": " & $root[key] & ",\n"
  result.add "  \"todos\": " & $root["todos"] & ",\n"
  result.add "  \"cases\": [\n"
  for index in 0 ..< root["cases"].len:
    let item = root["cases"][index]
    result.add "    " & $item
    if index < root["cases"].len - 1:
      result.add ','
    result.add '\n'
  result.add "  ]\n}\n"

proc writeCorpus(outputPath: string) =
  let
    poolText = readFile(BrS2MapPoolPath)
    pool = parseJson(poolText)
    sourceCommit = NavCorpusSourceCommit
  if pool.kind != JArray or pool.len != 64:
    raise newException(ValueError, "published Season 2 pool must contain 64 maps")
  if sourceCommit.len != 40:
    raise newException(ValueError, "could not resolve source commit")

  var root = newJObject()
  root["schema"] = %NavCorpusSchema
  root["v"] = %NavCorpusVersion
  root["source_commit"] = %sourceCommit
  root["pool_sha256"] = %sha256Text(poolText)
  root["oracle_rules"] = %OracleRuleId
  root["todos"] = %*{
    "cover_hold_cold_transition": {
      "task": "1218165969208626",
      "enabled": false
    }
  }
  root["cases"] = newJArray()

  for poolIndex in 0 ..< pool.len:
    let entry = pool[poolIndex]
    let
      mapName = entry["name"].getStr()
      specText = $entry["spec"]
      mapSha = sha256Text(specText)
      gameMap = mapFromSpecJson(specText)
      map = newBodyMap(gameMap)
      pairs = map.selectPairs()
    echo &"map {poolIndex + 1}/64 {mapName}"
    for rosterSize in [16, 32]:
      let seatIndex = poolIndex mod rosterSize
      for profile in NavCorpusProfile:
        for dynamic in NavCorpusDynamic:
          for distance in NavCorpusDistance:
            let pair = pairs[distance]
            var item = NavCorpusCase(
              id: &"m{poolIndex:02}-{mapName}-r{rosterSize}-s{seatIndex}-" &
                &"{profile.profileName}-{dynamic.dynamicName}-{distance.distanceName}",
              mapName: mapName, mapSha256: mapSha, poolIndex: poolIndex,
              rosterSize: rosterSize, seatIndex: seatIndex, profile: profile,
              dynamic: dynamic, distance: distance, start: pair.start,
              requestedGoal: pair.goal, validatedGoal: pair.goal,
              component: map.componentOf(pair.start))
            if dynamic in {ncdDanger, ncdBoth}:
              item.dangerSources = pair.dangerSources(seatIndex, rosterSize)
            if dynamic in {ncdBlocked, ncdBoth}:
              item.blockedCell = some(map.cellOf(pair.route[pair.route.len div 2]))
            let danger = map.buildOracleDanger(item)
            item.dangerHash = dangerRasterHash(danger)
            let route = map.oracleRoute4pxWithDanger(item, danger)
            if route.len == 0 or route[0] != item.start or route[^1] != item.validatedGoal:
              raise newException(ValueError, "oracle failed case " & item.id)
            item.oracleCost = oracleFloatCost(route, map, danger,
              item.profile.corpusProfile, item.blockedCell)
            item.oracleRouteHash = routeHash(route)
            root["cases"].add caseNode(item)

  if root["cases"].len != NavCorpusCaseCount:
    raise newException(ValueError, "writer produced wrong case count")
  writeFile(outputPath, compactCorpus(root))
  discard loadNavRouteCorpus(outputPath)
  echo &"wrote {root[\"cases\"].len} cases to {outputPath}"

when isMainModule:
  let outputPath = if paramCount() == 0: DefaultOutput else: paramStr(1)
  writeCorpus(outputPath)
