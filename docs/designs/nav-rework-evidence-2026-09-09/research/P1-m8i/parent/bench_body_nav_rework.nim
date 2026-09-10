## Production qualification harness for the resumable mixed-grid body route.

{.define: bodyNavBreakdown.}

import std/[algorithm, json, math, monotimes, options, os, osproc, strformat,
  sequtils, strutils, tables, times]
import crunchy/[common, sha256]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types, zone_field]
import ../src/shell/[body, body_danger, body_hazard, body_map, body_nav,
  body_route_index, body_route_query, episode, standing_order]
import ../tests/nav_route_corpus_support

const
  CanonicalPlatform = "linux/amd64"
  CanonicalFlags = "-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on"
  QualityP95Limit = 0.5
  QualityMaxLimit = 3.0
  TickWarmups = 5
  TickSamples = 120
  TickP95LimitNs = 4_000_000'i64
  TickMaxLimitNs = 5_000_000'i64

type
  MapGate = object
    label: string
    gameMap: CtfMap
    colossal: bool
  NavGateScenario = enum
    ngsFirstGoals = "first_goals"
    ngsMovingGoals = "moving_goals"
    ngsStuckReplans = "stuck_replans"

proc sha256Text(value: string): string = sha256(value).toHex()
proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc percentile[T](values: openArray[T], fraction: float64): T =
  if values.len == 0: return default(T)
  var ordered = @values
  ordered.sort()
  ordered[max(0, min(ordered.high,
    int(ceil(fraction * ordered.len.float)) - 1))]

proc nsArray(values: openArray[int64]): JsonNode =
  result = newJArray()
  for value in values: result.add %value

proc rssBytes(): int64 =
  if fileExists("/proc/self/statm"):
    let fields = readFile("/proc/self/statm").splitWhitespace()
    if fields.len >= 2: return parseBiggestInt(fields[1]) * 4096
  let value = execProcess("ps", args = ["-o", "rss=", "-p",
    $getCurrentProcessId()], options = {poUsePath}).strip
  if value.len > 0: return parseBiggestInt(value) * 1024
  -1

proc loadPoolMap(pool: JsonNode, poolIndex: int): MapGate =
  let entry = pool[poolIndex]
  result.label = &"published:{poolIndex:02}:{entry[\"name\"].getStr()}"
  result.gameMap = mapFromSpecJson($entry["spec"])
  result.gameMap.name = entry["name"].getStr()

proc colossalMap(): MapGate =
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  result = MapGate(label: "size:colossal", colossal: true)
  result.gameMap = generateCtfMap(4242, overrides, 4)
  result.gameMap.name = result.label

proc routeLegal(map: BodyMap; item: NavCorpusCase;
    route: openArray[BodyPoint]): bool =
  if route.len == 0 or route[0] != item.start or
      route[^1] != item.validatedGoal: return false
  for point in route:
    if not map.canStand(point) or map.componentOf(point) != item.component:
      return false
  for index in 1 ..< route.len:
    if not map.segmentClear(route[index - 1], route[index]): return false
  true

proc pointsJson(points: openArray[BodyPoint]): JsonNode =
  result = newJArray()
  for point in points:
    result.add %*[point.x, point.y]

proc qualityRow(name: string, values: openArray[float64], missing,
    illegal: int): JsonNode =
  let p95 = values.percentile(0.95)
  let maximum = if values.len == 0: 0.0 else: max(values)
  %*{"name": name, "scored": values.len, "missing": missing,
    "illegal": illegal, "inflation_p95_pct": p95,
    "inflation_max_pct": maximum,
    "pass": missing == 0 and illegal == 0 and
      p95 <= QualityP95Limit and maximum <= QualityMaxLimit}

proc runRouteCorpusGate(corpus: NavCorpus, pool: JsonNode,
    onlyPool: int): JsonNode =
  var
    allInflation: seq[float64]
    strata = initTable[string, seq[float64]]()
    missingByStratum = initCountTable[string]()
    illegalByStratum = initCountTable[string]()
    cases = newJArray()
    routeIdentities = ""
    missing, illegal, totalPops, maximumTicks, maximumSpans: int
  for poolIndex in 0 ..< pool.len:
    if onlyPool >= 0 and poolIndex != onlyPool: continue
    stderr.writeLine &"quality pool {poolIndex + 1}/{pool.len}"
    let loaded = loadPoolMap(pool, poolIndex)
    let map = newBodyMap(loaded.gameMap)
    let nav = newBodyNavSystem(map, 1, NavCorpusGunRangePx)
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      let key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      nav.resetNavigationLife(0)
      nav.initializeDanger([DangerInput(selfXy: item.start,
        candidates: item.dangerSources)], 0)
      let danger = BodyDangerField(values: nav.seats[0].dangerSnapshot,
        gridW: map.gridWidth, gridH: map.gridHeight)
      if dangerRasterHash(danger) != item.dangerHash:
        raise newException(ValueError, "production danger differs: " & item.id)
      if item.blockedCell.isSome:
        nav.seats[0].blockedPenalty = some((
          pos: cellCenter(item.blockedCell.get), untilTick: high(int)))
      let goal = map.validateGoal(item.requestedGoal, item.start)
      if goal.isNone or goal.get.goalPoint != item.validatedGoal:
        raise newException(ValueError, "production goal differs: " & item.id)
      discard nav.navigationWaypoint(0, item.start, goal.get, 0,
        profile = item.profile.corpusProfile)
      var ticks = 0
      while (nav.routeJob.active or
          nav.seats[0].pendingRoute.lifecycle != brlIdle) and ticks < 10_000:
        totalPops += nav.runRouteScheduler(ticks)
        inc ticks
      maximumTicks = max(maximumTicks, ticks)
      let route = nav.seats[0].installedRoutePoints
      maximumSpans = max(maximumSpans,
        nav.seats[0].installedRoute.spanCount.int)
      if ticks >= 10_000 or route.len == 0:
        inc missing; missingByStratum.inc key
        routeIdentities.add item.id & ":missing;"
        cases.add %*{"id": item.id, "status": "missing", "ticks": ticks}
        continue
      if not map.routeLegal(item, route):
        inc illegal; illegalByStratum.inc key
        routeIdentities.add item.id & ":illegal;"
        cases.add %*{"id": item.id, "status": "illegal", "ticks": ticks}
        continue
      let sampled = resampleRoute4px(route)
      let inflation = routeInflationPct(oracleFloatCost(sampled, map, danger,
        item.profile.corpusProfile, item.blockedCell), item.oracleCost)
      let candidateHash = routeHash(sampled)
      allInflation.add inflation
      strata.mgetOrPut(key, @[]).add inflation
      routeIdentities.add item.id & ":" & candidateHash & ";"
      var caseRow = %*{"id": item.id, "status": "ok", "ticks": ticks,
        "spans": nav.seats[0].installedRoute.spanCount, "points": route.len,
        "inflation_pct": inflation, "route_hash": candidateHash}
      if inflation > QualityMaxLimit:
        caseRow["candidate_route"] = pointsJson(sampled)
        caseRow["oracle_route"] = pointsJson(
          map.oracleRoute4pxWithDanger(item, danger))
      cases.add caseRow
  var rows = newJArray()
  rows.add qualityRow("overall", allInflation, missing, illegal)
  for rosterSize in [16, 32]:
    for profile in NavCorpusProfile:
      for dynamic in NavCorpusDynamic:
        for distance in NavCorpusDistance:
          let key = &"r{rosterSize}/{profile}/{dynamic}/{distance}"
          rows.add qualityRow(key, strata.getOrDefault(key),
            missingByStratum.getOrDefault(key),
            illegalByStratum.getOrDefault(key))
  result = %*{"case_count": if onlyPool < 0: corpus.cases.len else: cases.len,
    "scored_count": allInflation.len, "missing": missing, "illegal": illegal,
    "total_pops": totalPops, "maximum_route_ticks": maximumTicks,
    "maximum_span_count": maximumSpans,
    "route_hash": sha256Text(routeIdentities), "cases": cases,
    "strata": rows, "pass": rows.elems.allIt(it["pass"].getBool())}

proc bytesJson(bytes: BodyNavigationBytes): JsonNode =
  %*{"system_owner": bytes.systemOwner, "route_index": bytes.routeIndex,
    "safety_scratch": bytes.safetyScratch, "mixed_graph": bytes.mixedGraph,
    "seat_owners": bytes.seatOwners, "seat_caches": bytes.seatCaches,
    "danger_rasters": bytes.dangerRasters,
    "danger_workspaces": bytes.dangerWorkspaces,
    "packed_int16_weights": bytes.packedWeights,
    "shared_danger_geometry": bytes.sharedDangerGeometry,
    "trace": bytes.trace, "allocator_overhead": bytes.allocatorOverhead,
    "total": bytes.total}

proc activationRow(gate: MapGate): JsonNode =
  GC_fullCollect()
  let rssBefore = rssBytes()
  let mapStarted = getMonoTime()
  let map = newBodyMap(gate.gameMap)
  let mapNs = mapStarted.elapsedNs
  let indexStarted = getMonoTime()
  let index = newBodyRouteIndex(map)
  let indexNs = indexStarted.elapsedNs
  let deleted = index.followingPayloadBytes
  let navStarted = getMonoTime()
  let nav = newBodyNavSystem(map, 32, 331, preparedRouteIndex = index)
  let navNs = navStarted.elapsedNs
  GC_fullCollect()
  let rssAfter = rssBytes()
  var start, goal: BodyPoint
  var component = -1
  block findEndpoints:
    for y in countup(0, map.height - 1, BodyFineStepPx):
      for x in countup(0, map.width - 1, BodyFineStepPx):
        let point: BodyPoint = (x, y)
        if map.canStand(point):
          start = point; component = map.componentOf(point); break findEndpoints
  var bestDistance = -1'i64
  for y in countup(0, map.height - 1, BodyFineStepPx):
    for x in countup(0, map.width - 1, BodyFineStepPx):
      let point: BodyPoint = (x, y)
      if map.canStand(point) and map.componentOf(point) == component:
        let distance = int64(point.x - start.x) * int64(point.x - start.x) +
          int64(point.y - start.y) * int64(point.y - start.y)
        if distance > bestDistance: bestDistance = distance; goal = point
  let validated = map.validateGoal(goal, start)
  if validated.isNone:
    raise newException(ValueError, "activation query has no valid goal")
  var querySamples, queryPops: seq[int64]
  for sample in 0 ..< 12:
    let seat = sample mod nav.seats.len
    nav.resetNavigationLife(seat)
    let started = getMonoTime()
    discard nav.navigationWaypoint(seat, start, validated.get, sample)
    var pops = 0
    while nav.routeJob.active or nav.seats[seat].pendingRoute.lifecycle != brlIdle:
      pops += nav.runRouteScheduler(sample)
    querySamples.add started.elapsedNs
    queryPops.add int64(pops)
  %*{"map": gate.label, "colossal": gate.colossal,
    "body_map_activation_ns": mapNs, "route_index_activation_ns": indexNs,
    "mixed_nav_activation_ns": navNs,
    "total_activation_ns": mapNs + indexNs + navNs,
    "rss_delta_bytes": max(0'i64, rssAfter - rssBefore),
    "deleted_following_portal_next_bytes": deleted.portalNext,
    "deleted_following_cells_bytes": deleted.cells,
    "deleted_following_total_bytes": deleted.total,
    "retained_cap_bytes": BodyNavigationRetainedCap,
    "retained": bytesJson(nav.navigationBytes),
    "far_query_samples_ns": querySamples.nsArray, "far_query_pops": queryPops,
    "far_query_p50_ns": querySamples.percentile(0.5),
    "far_query_p95_ns": querySamples.percentile(0.95),
    "far_query_max_ns": max(querySamples),
    "far_query_p50_pops": queryPops.percentile(0.5),
    "far_query_max_pops": max(queryPops),
    "far_query_span_count": nav.seats[11].installedRoute.spanCount,
    "far_query_point_count": nav.seats[11].installedRoute.pointCount,
    "pass": nav.navigationBytes.total <= BodyNavigationRetainedCap}

proc runActivationGate(pool: JsonNode; onlyPool: int): JsonNode =
  var rows = newJArray()
  for poolIndex in 0 ..< pool.len:
    if onlyPool >= 0 and poolIndex != onlyPool: continue
    stderr.writeLine &"activation {poolIndex + 1}/{pool.len}"
    rows.add activationRow(loadPoolMap(pool, poolIndex))
  stderr.writeLine "activation colossal"
  rows.add activationRow(colossalMap())
  %*{"maps": rows, "pass": rows.elems.allIt(it["pass"].getBool())}

proc armedSnapshot(map: BodyMap): ZoneDamageSnapshot =
  let sourceW = (map.width + NavCell - 1) div NavCell
  let sourceH = (map.height + NavCell - 1) div NavCell
  result = ZoneDamageSnapshot(gridW: sourceW, gridH: sourceH,
    cellPx: NavCell, fingerprint: 0x50395a4e4156'u64,
    damage: newSeq[uint16](sourceW * sourceH))
  for index in 0 ..< result.damage.len:
    result.damage[index] = if index mod 11 == 0: HazardNeverArrives
      else: uint16(96 + index mod 1024)

proc playControls(count: int): seq[SlotControl] =
  result = newSeq[SlotControl](count)
  for control in result.mitems: control = scPlay

proc tickFrames(map: BodyMap, positions: openArray[BodyPoint],
    navigationTarget, threatCenter: BodyPoint, tick: int): seq[ShellSeatFrame] =
  for seat in 0 ..< positions.len:
    var tracks: seq[BodyTrackUpdate]
    for threat in 0 ..< 8:
      tracks.add BodyTrackUpdate(seat: (seat + threat + 1) mod positions.len,
        pos: (threatCenter.x + (threat mod 3 - 1) * 16,
          threatCenter.y + (threat div 3 - 1) * 16), team: Blue,
        aimBrads: some(0), hpKnown: some(3), weapon: some(bwGun),
        tick: uint32(tick))
    result.add ShellSeatFrame(seat: uint8(seat), playerIndex: seat,
      present: true, playing: true, alive: true, aliveTeams: 16,
      motionScale: 1, velocity: 1,
      bodyInputs: BodyTickInputs(self: BodySelfState(pos: positions[seat],
        hp: 4, hpFrac: 1.0, lives: some(1), aimBrads: seat mod 256,
        alive: true), visibleTracks: tracks),
      defaultFallbacks: BrDefaultFallbacks(
        currentZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        nextZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        ticksToNextShrink: BrRotateLeadTicks, zonePhase: 1, zoneDps: 2,
        rotateTarget: some(navigationTarget)))

proc tickRow(gameMap: CtfMap, rosterSize: int, scenario: NavGateScenario,
    start, nearGoal, farGoal: BodyPoint): JsonNode =
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  let overlay = newBodyHazardOverlay(index, map.armedSnapshot)
  var episode = initShellEpisode(true, true, playControls(rosterSize), map,
    331, hazard = overlay, preparedRouteIndex = index)
  var tick = 1
  var positions = newSeq[BodyPoint](rosterSize)
  var samples, navSamples, routeSearchSamples, requestSamples,
    weightSamples, waypointSamples, routeAdvanceSamples, steeringSamples,
    followerSamples, weaponSamples, dangerSamples, planningSamples,
    requestSubmitSamples, restartSamples, selectSamples, attachSamples,
    finishSamples, nonNavSamples, pops,
    searchNsPerPop, requestSubmissions, requestAdmissions,
    routeCompletions, weightRefreshes: seq[int64]
  for position in positions.mitems: position = start
  discard episode.step(tickFrames(map, positions, nearGoal, farGoal, tick),
    uint32(tick), 0)
  for sample in 0 ..< TickWarmups + TickSamples:
    inc tick
    let target = if scenario == ngsMovingGoals and
        ((sample div 12) and 1) != 0: nearGoal else: farGoal
    case scenario
    of ngsFirstGoals:
      for seat in 0 ..< rosterSize: episode.nav.resetNavigationLife(seat)
    of ngsStuckReplans:
      for seat in episode.nav.seats: seat.stuckTicks = 8
    of ngsMovingGoals: discard
    let output = episode.step(tickFrames(map, positions, target, farGoal, tick),
      uint32(tick), sample)
    if scenario != ngsStuckReplans:
      for mask in output.masks:
        let bits = encodeInputMask(mask.input)
        var next = positions[mask.seat.int]
        if (bits and ButtonLeft) != 0: next.x -= 4
        if (bits and ButtonRight) != 0: next.x += 4
        if (bits and ButtonUp) != 0: next.y -= 4
        if (bits and ButtonDown) != 0: next.y += 4
        if map.canStand(next): positions[mask.seat.int] = next
    if sample >= TickWarmups:
      samples.add output.bodySliceNanoseconds
      let
        timing = episode.nav.timing
        routeSearch = timing.routePopNanoseconds
        requestOverhead = timing.requestSubmitNanoseconds +
          timing.schedulerRestartNanoseconds +
          timing.schedulerSelectNanoseconds +
          timing.requestAttachNanoseconds + timing.routeFinishNanoseconds
        navigation = routeSearch + requestOverhead +
          timing.weightRefreshNanoseconds + timing.waypointNanoseconds +
          timing.routeAdvanceNanoseconds + timing.steeringNanoseconds
        popCount = int64(episode.nav.routePopsLastTick)
      routeSearchSamples.add routeSearch
      requestSamples.add requestOverhead
      weightSamples.add timing.weightRefreshNanoseconds
      waypointSamples.add timing.waypointNanoseconds
      routeAdvanceSamples.add timing.routeAdvanceNanoseconds
      steeringSamples.add timing.steeringNanoseconds
      followerSamples.add output.stageNanoseconds[ssFollower]
      weaponSamples.add output.stageNanoseconds[ssWeapon]
      dangerSamples.add output.stageNanoseconds[ssDanger]
      planningSamples.add output.stageNanoseconds[ssPlanning]
      requestSubmitSamples.add timing.requestSubmitNanoseconds
      restartSamples.add timing.schedulerRestartNanoseconds
      selectSamples.add timing.schedulerSelectNanoseconds
      attachSamples.add timing.requestAttachNanoseconds
      finishSamples.add timing.routeFinishNanoseconds
      navSamples.add navigation
      nonNavSamples.add output.bodySliceNanoseconds - navigation
      pops.add popCount
      if popCount > 0:
        searchNsPerPop.add routeSearch div popCount
      requestSubmissions.add int64(timing.requestSubmissions)
      requestAdmissions.add int64(timing.requestAdmissions)
      routeCompletions.add int64(timing.routeCompletions)
      weightRefreshes.add int64(timing.weightRefreshes)
  episode.closeShellEpisode()
  let p95 = samples.percentile(0.95)
  let maximum = max(samples)
  %*{"roster_size": rosterSize, "scenario": $scenario,
    "warmups": TickWarmups, "sample_count": TickSamples,
    "samples_ns": samples.nsArray, "pops_per_tick": pops,
    "nav_samples_ns": navSamples.nsArray,
    "route_search_samples_ns": routeSearchSamples.nsArray,
    "request_overhead_samples_ns": requestSamples.nsArray,
    "weight_refresh_samples_ns": weightSamples.nsArray,
    "waypoint_samples_ns": waypointSamples.nsArray,
    "route_advance_samples_ns": routeAdvanceSamples.nsArray,
    "steering_samples_ns": steeringSamples.nsArray,
    "follower_samples_ns": followerSamples.nsArray,
    "weapon_samples_ns": weaponSamples.nsArray,
    "danger_samples_ns": dangerSamples.nsArray,
    "planning_samples_ns": planningSamples.nsArray,
    "request_submit_samples_ns": requestSubmitSamples.nsArray,
    "restart_samples_ns": restartSamples.nsArray,
    "sjf_select_samples_ns": selectSamples.nsArray,
    "attach_samples_ns": attachSamples.nsArray,
    "finish_install_samples_ns": finishSamples.nsArray,
    "non_nav_samples_ns": nonNavSamples.nsArray,
    "route_search_ns_per_pop_samples": searchNsPerPop.nsArray,
    "request_submissions_per_tick": requestSubmissions.nsArray,
    "request_admissions_per_tick": requestAdmissions.nsArray,
    "route_completions_per_tick": routeCompletions.nsArray,
    "weight_refreshes_per_tick": weightRefreshes.nsArray,
    "p50_ns": samples.percentile(0.5), "p95_ns": p95, "max_ns": maximum,
    "nav_p50_ns": navSamples.percentile(0.5),
    "nav_p95_ns": navSamples.percentile(0.95), "nav_max_ns": max(navSamples),
    "route_search_p50_ns": routeSearchSamples.percentile(0.5),
    "route_search_p95_ns": routeSearchSamples.percentile(0.95),
    "route_search_max_ns": max(routeSearchSamples),
    "route_search_ns_per_pop_p50": searchNsPerPop.percentile(0.5),
    "route_search_ns_per_pop_p95": searchNsPerPop.percentile(0.95),
    "request_overhead_p50_ns": requestSamples.percentile(0.5),
    "request_overhead_p95_ns": requestSamples.percentile(0.95),
    "request_overhead_max_ns": max(requestSamples),
    "weight_refresh_p50_ns": weightSamples.percentile(0.5),
    "weight_refresh_p95_ns": weightSamples.percentile(0.95),
    "weight_refresh_max_ns": max(weightSamples),
    "waypoint_p50_ns": waypointSamples.percentile(0.5),
    "waypoint_p95_ns": waypointSamples.percentile(0.95),
    "waypoint_max_ns": max(waypointSamples),
    "route_advance_p50_ns": routeAdvanceSamples.percentile(0.5),
    "route_advance_p95_ns": routeAdvanceSamples.percentile(0.95),
    "route_advance_max_ns": max(routeAdvanceSamples),
    "steering_p50_ns": steeringSamples.percentile(0.5),
    "steering_p95_ns": steeringSamples.percentile(0.95),
    "steering_max_ns": max(steeringSamples),
    "follower_p95_ns": followerSamples.percentile(0.95),
    "weapon_p95_ns": weaponSamples.percentile(0.95),
    "danger_p95_ns": dangerSamples.percentile(0.95),
    "planning_p95_ns": planningSamples.percentile(0.95),
    "request_submit_p95_ns": requestSubmitSamples.percentile(0.95),
    "restart_p95_ns": restartSamples.percentile(0.95),
    "sjf_select_p95_ns": selectSamples.percentile(0.95),
    "attach_p95_ns": attachSamples.percentile(0.95),
    "finish_install_p95_ns": finishSamples.percentile(0.95),
    "finish_install_max_ns": max(finishSamples),
    "non_nav_p50_ns": nonNavSamples.percentile(0.5),
    "non_nav_p95_ns": nonNavSamples.percentile(0.95),
    "non_nav_max_ns": max(nonNavSamples),
    "p95_limit_ns": TickP95LimitNs, "max_limit_ns": TickMaxLimitNs,
    "pass": p95 <= TickP95LimitNs and maximum <= TickMaxLimitNs}

proc runTickGate(corpus: NavCorpus, pool: JsonNode): JsonNode =
  let loaded = loadPoolMap(pool, 15)
  var start, nearGoal, farGoal: BodyPoint
  var foundNear, foundFar: bool
  for item in corpus.cases:
    if item.poolIndex == 15 and item.rosterSize == 16 and
        item.profile == ncpDefault and item.dynamic == ncdNone:
      start = item.start
      if item.distance == ncrNear: nearGoal = item.validatedGoal; foundNear = true
      else: farGoal = item.validatedGoal; foundFar = true
  if not foundNear or not foundFar:
    raise newException(ValueError, "tick corpus anchors are missing")
  var rows = newJArray()
  for rosterSize in [16, 32]:
    for scenario in NavGateScenario:
      stderr.writeLine &"tick roster={rosterSize} scenario={scenario}"
      rows.add tickRow(loaded.gameMap, rosterSize, scenario, start, nearGoal, farGoal)
  %*{"maps": rows, "pass": rows.elems.allIt(it["pass"].getBool())}

proc metadata(corpus: NavCorpus, canonical: bool): JsonNode =
  let commit = getEnv("NAV_GATE_COMMIT")
  let dirty = getEnv("NAV_GATE_DIRTY")
  let imageId = getEnv("NAV_GATE_IMAGE_ID")
  let cpuLimit = getEnv("NAV_GATE_CPU_LIMIT")
  let machine = execProcess("uname -m").strip
  let platform = hostOS & "/" &
    (if machine in ["x86_64", "amd64"]: "amd64" else: machine)
  if canonical and (commit.len == 0 or dirty != "false" or
      platform != CanonicalPlatform or cpuLimit != "1" or imageId.len == 0):
    raise newException(ValueError, &"canonical run refused: commit={commit} " &
      &"dirty={dirty} platform={platform} cpu_limit={cpuLimit} image_id={imageId}")
  %*{"commit": commit, "dirty": dirty, "nim_version": NimVersion,
    "os_arch": platform, "compile_flags": CanonicalFlags,
    "image_id": imageId, "cpu_limit": cpuLimit,
    "pool_digest": corpus.poolSha256, "canonical": canonical}

proc usage() =
  echo "usage: bench_body_nav_rework --quality|--activation|--tick|--all " &
    "[--corpus PATH] [--pool-index N]"

when isMainModule:
  var runQuality, runActivation, runTick, canonical: bool
  var onlyPool = -1
  var corpusPath = "tests/fixtures/shell/nav_route_corpus.json"
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--quality": runQuality = true
    of "--activation": runActivation = true
    of "--tick": runTick = true
    of "--all":
      # Docker's linux/amd64 run is emulated on the development arm64 host.
      # Keep cross-architecture correctness, determinism, activation, and
      # memory canonical; wall-clock tick acceptance belongs to native or
      # real-hardware runs only.
      runQuality = true
      runActivation = true
      canonical = true
    of "--corpus":
      inc index
      if index > paramCount(): usage(); quit(2)
      corpusPath = paramStr(index)
    of "--pool-index":
      inc index
      if index > paramCount(): usage(); quit(2)
      onlyPool = parseInt(paramStr(index))
    of "--help", "-h": usage(); quit(0)
    else: usage(); quit(2)
    inc index
  if not runQuality and not runActivation and not runTick: usage(); quit(2)
  if canonical and onlyPool >= 0:
    raise newException(ValueError, "canonical --all does not accept --pool-index")
  let corpus = loadNavRouteCorpus(corpusPath)
  let pool = loadBrS2PoolRaw()
  var root = %*{"schema": "coworld_body_nav_gate", "v": 2,
    "metadata": metadata(corpus, canonical),
    "thresholds": {"quality_p95_inflation_pct": QualityP95Limit,
      "quality_max_inflation_pct": QualityMaxLimit,
      "retained_cap_bytes": BodyNavigationRetainedCap,
      "tick_p95_ns": TickP95LimitNs, "tick_max_ns": TickMaxLimitNs}}
  var passed = true
  if runQuality:
    root["quality"] = runRouteCorpusGate(corpus, pool, onlyPool)
    passed = passed and root["quality"]["pass"].getBool()
  if runActivation:
    root["activation"] = runActivationGate(pool, onlyPool)
    passed = passed and root["activation"]["pass"].getBool()
  if runTick:
    root["tick"] = runTickGate(corpus, pool)
    passed = passed and root["tick"]["pass"].getBool()
  root["pass"] = %passed
  echo pretty(root)
  if not passed: quit(1)
