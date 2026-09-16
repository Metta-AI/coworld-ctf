## Production qualification harness for the resumable mixed-grid body route.

when not defined(navGateNoBreakdown):
  {.define: bodyNavBreakdown.}

import std/[algorithm, json, math, monotimes, options, os, osproc, strformat,
  sequtils, strutils, tables, times]
import crunchy/[common, sha256]
import bitworld/[profile, spriteprotocol]
import ../src/ctf/[arena, br_map_pool, sim_types, zone_field]
import ../src/shell/[body, body_danger, body_hazard, body_map, body_nav,
  body_route_index, body_route_query, episode, standing_order]
import ../tests/nav_route_corpus_support
import build_nav_route_corpus

const
  CanonicalPlatform = "linux/amd64"
  CanonicalFlags = "-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on"
  QualityP95Limit = 0.5
  QualityMaxLimit = 3.0
  TickWarmups = 5
  TickSamples = 120
  TickP95LimitNs = 4_000_000'i64
  TickMaxLimitNs = 5_000_000'i64
  ## --latency: ticks from a seat's first request after a life reset until a
  ## route is published for it. One warm-up wave, then measured waves that
  ## alternate far and near goals. A wave that does not publish every seat
  ## within the cap fails the row; the cap is a workload bound, not a target.
  LatencyWarmupWaves = 1
  LatencyMeasuredWaves = 10
  LatencyWaveTickCap = 2000

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
    "hazard_overlay": bytes.hazardOverlay, "safe_cache": bytes.safeCache,
    "packed_int16_weights": bytes.packedWeights,
    "packed_weight_scratch": bytes.packedWeightScratch,
    "shared_danger_geometry": bytes.sharedDangerGeometry,
    "shared_danger_source_cache": bytes.sharedDangerSourceCache,
    "trace": bytes.trace, "allocator_overhead": bytes.allocatorOverhead,
    "total": bytes.total}

proc armedSnapshot(map: BodyMap): ZoneDamageSnapshot

proc activationRow(gate: MapGate; gunRange = NavCorpusGunRangePx): JsonNode =
  GC_fullCollect()
  let rssBefore = rssBytes()
  let mapStarted = getMonoTime()
  let map = newBodyMap(gate.gameMap)
  let mapNs = mapStarted.elapsedNs
  let indexStarted = getMonoTime()
  let index = newBodyRouteIndex(map)
  let indexNs = indexStarted.elapsedNs
  let deleted = index.followingPayloadBytes
  let hazardStarted = getMonoTime()
  let overlay = newBodyHazardOverlay(index, map.armedSnapshot)
  let hazardNs = hazardStarted.elapsedNs
  let cacheStarted = getMonoTime()
  let cache = newBodySafeCache()
  cache.refreshSafeCache(index, overlay, 0, 1)
  let cacheNs = cacheStarted.elapsedNs
  let navStarted = getMonoTime()
  let nav = newBodyNavSystem(map, 32, gunRange, preparedRouteIndex = index)
  nav.installSafetyContext(overlay, cache)
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
  let bytes = nav.retainedNavigationBytes
  # Include all allocator overhead as a conservative bound, even the seat
  # allocations, so shared storage cannot disappear into a reporting category.
  let sharedUpperBound = bytes.systemOwner + bytes.routeIndex +
    bytes.safetyScratch + bytes.hazardOverlay + bytes.safeCache +
    bytes.mixedGraph + bytes.packedWeightScratch +
    bytes.sharedDangerGeometry + bytes.sharedDangerSourceCache +
    bytes.trace + bytes.allocatorOverhead
  const PoolSharedCap = 32'i64 * 1024 * 1024
  let totalNs = mapNs + indexNs + hazardNs + cacheNs + navNs
  let activationRatioLimit = if gate.colossal: 3 else: 2
  let activationTimePass = totalNs <= mapNs * activationRatioLimit
  let memoryPass = bytes.total <= BodyNavigationRetainedCap and
    (gate.colossal or sharedUpperBound <= PoolSharedCap)
  %*{"map": gate.label, "colossal": gate.colossal,
    "body_map_activation_ns": mapNs, "route_index_activation_ns": indexNs,
    "mixed_nav_activation_ns": navNs,
    "hazard_activation_ns": hazardNs, "safe_cache_activation_ns": cacheNs,
    "total_activation_ns": totalNs,
    "activation_ratio": totalNs.float / mapNs.float,
    "activation_ratio_limit": activationRatioLimit,
    "activation_time_pass": activationTimePass, "memory_pass": memoryPass,
    "rss_delta_bytes": max(0'i64, rssAfter - rssBefore),
    "deleted_following_portal_next_bytes": deleted.portalNext,
    "deleted_following_cells_bytes": deleted.cells,
    "deleted_following_total_bytes": deleted.total,
    "retained_cap_bytes": BodyNavigationRetainedCap,
    "retained": bytesJson(bytes),
    "shared_retained_upper_bound_bytes": sharedUpperBound,
    "pool_shared_cap_bytes": PoolSharedCap,
    "far_query_samples_ns": querySamples.nsArray, "far_query_pops": queryPops,
    "far_query_p50_ns": querySamples.percentile(0.5),
    "far_query_p95_ns": querySamples.percentile(0.95),
    "far_query_max_ns": max(querySamples),
    "far_query_p50_pops": queryPops.percentile(0.5),
    "far_query_max_pops": max(queryPops),
    "far_query_span_count": nav.seats[11].installedRoute.spanCount,
    "far_query_point_count": nav.seats[11].installedRoute.pointCount,
    "pass": memoryPass and activationTimePass}

proc activationResult(gate: MapGate; gunRange = NavCorpusGunRangePx): JsonNode =
  try:
    activationRow(gate, gunRange)
  except BodyMapError as error:
    %*{"map": gate.label, "colossal": gate.colossal,
      "activation_error": error.msg, "pass": false}

proc runActivationGate(pool: JsonNode; onlyPool: int): JsonNode =
  var rows = newJArray()
  for poolIndex in 0 ..< pool.len:
    if onlyPool >= 0 and poolIndex != onlyPool: continue
    stderr.writeLine &"activation {poolIndex + 1}/{pool.len}"
    rows.add activationResult(loadPoolMap(pool, poolIndex))
  stderr.writeLine "activation colossal"
  rows.add activationResult(colossalMap())
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
    start, nearGoal, farGoal: BodyPoint; gunRange: int): JsonNode =
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  let overlay = newBodyHazardOverlay(index, map.armedSnapshot)
  var episode = initShellEpisode(true, true, playControls(rosterSize), map,
    gunRange, hazard = overlay, preparedRouteIndex = index)
  var tick = 1
  var positions = newSeq[BodyPoint](rosterSize)
  var masksPerTick = newSeq[int16]((TickWarmups + TickSamples + 1) * rosterSize)
  for mask in masksPerTick.mitems: mask = -1
  var samples, navSamples, routeSearchSamples, requestSamples,
    weightSamples, waypointSamples, routeAdvanceSamples, steeringSamples,
    followerSamples, weaponSamples, dangerSamples, planningSamples,
    requestSubmitSamples, restartSamples, selectSamples, attachSamples,
    finishSamples, nonNavSamples, pops,
    searchNsPerPop, requestSubmissions, requestAdmissions,
    routeCompletions, weightRefreshes: seq[int64]
  for position in positions.mitems: position = start
  let initial = episode.step(tickFrames(map, positions, nearGoal, farGoal, tick),
    uint32(tick), 0)
  for mask in initial.masks:
    masksPerTick[mask.seat.int] = int16(encodeInputMask(mask.input))
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
    for mask in output.masks:
      masksPerTick[(sample + 1) * rosterSize + mask.seat.int] =
        int16(encodeInputMask(mask.input))
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
        timing = when defined(bodyNavBreakdown): episode.nav.timing
                 else: BodyNavTiming()
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
    "masks_per_tick": masksPerTick, "mask_ticks": TickWarmups + TickSamples + 1,
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

proc runTickGate(corpus: NavCorpus, pool: JsonNode; gunRange: int): JsonNode =
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
      rows.add tickRow(loaded.gameMap, rosterSize, scenario, start, nearGoal, farGoal, gunRange)
  %*{"maps": rows, "pass": rows.elems.allIt(it["pass"].getBool())}

proc runConfiguredTick(onlyPool: int): JsonNode =
  ## Extend coverage to the checked-in variant; keep the frozen corpus intact.
  let manifestText = readFile("coworld_manifest_paintbot.json")
  let manifest = parseJson(manifestText)
  var config: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr() == "battle-royale-s2":
      config = variant["game_config"]
  if config == nil or config["mapPath"].getStr() != BrPoolMapName16:
    raise newException(ValueError, "configured tick requires battle-royale-s2 brpool16")
  let gunRange = config["gunRange"].getInt()
  let poolText = readFile(BrS2SoloMapPoolPath)
  let pool = parseJson(poolText)
  if onlyPool >= pool.len:
    raise newException(ValueError, "configured pool index out of range")
  var rows = newJArray()
  var passed = true
  for poolIndex, spec in pool.elems:
    if onlyPool >= 0 and poolIndex != onlyPool: continue
    let gameMap = mapFromSpecJson($spec)
    let label = "configured:" & $poolIndex & ":" & spec["name"].getStr()
    stderr.writeLine label
    let pairs = block:
      let map = newBodyMap(gameMap)
      selectPairs(map)
    let start = pairs[ncrNear].start
    let nearGoal = pairs[ncrNear].goal
    let farGoal = pairs[ncrFar].goal
    let allocation = activationRow(MapGate(label: label, gameMap: gameMap), gunRange)
    var ticks = newJArray()
    for rosterSize in [16, 32]:
      for scenario in NavGateScenario:
        ticks.add tickRow(gameMap, rosterSize, scenario, start, nearGoal, farGoal, gunRange)
    let mapPassed = allocation["pass"].getBool() and
      ticks.elems.allIt(it["pass"].getBool())
    passed = passed and mapPassed
    rows.add %*{"map": label, "map_sha256": sha256Text($spec),
      "start": [start.x, start.y], "near_goal": [nearGoal.x, nearGoal.y],
      "far_goal": [farGoal.x, farGoal.y], "activation": allocation,
      "tick": ticks, "pass": mapPassed}
  %*{"variant_id": "battle-royale-s2", "map_path": config["mapPath"].getStr(),
    "manifest_sha256": sha256Text(manifestText),
    "pool_path": BrS2SoloMapPoolPath, "pool_sha256": sha256Text(poolText),
    "gun_range_px": gunRange, "maps": rows, "pass": passed}

type
  LatencySeatOutcome = object
    seat: int
    ticksToRoute: int        # 0 until a route is published in this wave
    installedRevision: uint64
    requestRevision: uint64  # seat.revision at wave end (counts requests)
    pointCount: int32
    fingerprint: int64
    replacements: uint32
    firstWaitTick: int32
    lifecycle: BodyRouteLifecycle
    lastQuerySucceeded: bool
    lastFailure: BodyRouteFailure
  LatencyWave = object
    wave: int
    far, measured: bool
    ticksUsed: int
    capHit: bool
    seats: seq[LatencySeatOutcome]
    completionOrder: seq[int]
    tickSamples: seq[int64]
    # Scheduler counters summed over the wave; measured only when the
    # breakdown clocks are compiled in, otherwise left at zero.
    restarts, admissions, completions, weightRefreshes, pops: int64

proc runLatencyWaves(gameMap: CtfMap, rosterSize: int,
    start, nearGoal, farGoal: BodyPoint): seq[LatencyWave] =
  ## Completion is the publication marker `installedRoute.revision`, which
  ## `resetNavigationLife` zeroes and `installMixedRoute` writes last with the
  ## request generation it satisfied. `seat.revision` counts requests (it is
  ## bumped on submission and also zeroed by the reset), so it cannot mark
  ## completion; it is recorded so a superseded first request is visible.
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  let overlay = newBodyHazardOverlay(index, map.armedSnapshot)
  var episode = initShellEpisode(true, true, playControls(rosterSize), map,
    331, hazard = overlay, preparedRouteIndex = index)
  var tick = 1
  var positions = newSeq[BodyPoint](rosterSize)
  for position in positions.mitems: position = start
  discard episode.step(tickFrames(map, positions, farGoal, farGoal, tick),
    uint32(tick), 0)
  for wave in 0 ..< LatencyWarmupWaves + LatencyMeasuredWaves:
    let measuredIndex = wave - LatencyWarmupWaves
    var row = LatencyWave(wave: wave, measured: wave >= LatencyWarmupWaves,
      far: wave < LatencyWarmupWaves or measuredIndex mod 2 == 0)
    let target = if row.far: farGoal else: nearGoal
    for position in positions.mitems: position = start
    for seat in 0 ..< rosterSize: episode.nav.resetNavigationLife(seat)
    row.seats = newSeq[LatencySeatOutcome](rosterSize)
    for seat in 0 ..< rosterSize: row.seats[seat].seat = seat
    var completed = 0
    var waveTick = 0
    while completed < rosterSize and waveTick < LatencyWaveTickCap:
      inc waveTick
      inc tick
      let output = episode.step(tickFrames(map, positions, target, farGoal,
        tick), uint32(tick), waveTick)
      row.tickSamples.add output.bodySliceNanoseconds
      row.pops += int64(episode.nav.routePopsLastTick)
      when defined(bodyNavBreakdown):
        row.restarts += int64(episode.nav.timing.schedulerRestarts)
        row.admissions += int64(episode.nav.timing.requestAdmissions)
        row.completions += int64(episode.nav.timing.routeCompletions)
        row.weightRefreshes += int64(episode.nav.timing.weightRefreshes)
      for mask in output.masks:
        let bits = encodeInputMask(mask.input)
        var next = positions[mask.seat.int]
        if (bits and ButtonLeft) != 0: next.x -= 4
        if (bits and ButtonRight) != 0: next.x += 4
        if (bits and ButtonUp) != 0: next.y -= 4
        if (bits and ButtonDown) != 0: next.y += 4
        if map.canStand(next): positions[mask.seat.int] = next
      for seat in 0 ..< rosterSize:
        if row.seats[seat].ticksToRoute != 0: continue
        let nav = episode.nav.seats[seat]
        if nav.installedRoute.revision != 0:
          row.seats[seat].ticksToRoute = waveTick
          row.seats[seat].installedRevision = nav.installedRoute.revision
          row.seats[seat].pointCount = nav.installedRoute.pointCount
          row.seats[seat].fingerprint = int64(nav.installedRouteFingerprint)
          row.completionOrder.add seat
          inc completed
    row.ticksUsed = waveTick
    row.capHit = completed < rosterSize
    for seat in 0 ..< rosterSize:
      let nav = episode.nav.seats[seat]
      row.seats[seat].requestRevision = nav.revision
      row.seats[seat].replacements = nav.pendingRoute.replacements
      row.seats[seat].firstWaitTick = nav.pendingRoute.firstWaitTick
      row.seats[seat].lifecycle = nav.pendingRoute.lifecycle
      row.seats[seat].lastQuerySucceeded = nav.lastQuerySucceeded
      row.seats[seat].lastFailure = nav.lastQueryFailure
    result.add row
  episode.closeShellEpisode()

proc sameLatencyOutcome(a, b: seq[LatencyWave]): bool =
  if a.len != b.len: return false
  for wave in 0 ..< a.len:
    if a[wave].ticksUsed != b[wave].ticksUsed or
        a[wave].capHit != b[wave].capHit or
        a[wave].completionOrder != b[wave].completionOrder or
        a[wave].seats.len != b[wave].seats.len:
      return false
    for seat in 0 ..< a[wave].seats.len:
      let x = a[wave].seats[seat]
      let y = b[wave].seats[seat]
      if x.ticksToRoute != y.ticksToRoute or
          x.installedRevision != y.installedRevision or
          x.requestRevision != y.requestRevision or
          x.pointCount != y.pointCount or x.fingerprint != y.fingerprint or
          x.replacements != y.replacements or x.lifecycle != y.lifecycle or
          x.lastFailure != y.lastFailure:
        return false
  true

proc latencyRow(gameMap: CtfMap, rosterSize: int,
    start, nearGoal, farGoal: BodyPoint): JsonNode =
  let first = runLatencyWaves(gameMap, rosterSize, start, nearGoal, farGoal)
  let second = runLatencyWaves(gameMap, rosterSize, start, nearGoal, farGoal)
  let deterministic = sameLatencyOutcome(first, second)
  var farSamples, nearSamples: seq[int]
  var tickSamples: seq[int64]
  var capHits, unpublished, superseded, failed = 0
  var waves = newJArray()
  for wave in first:
    var seats = newJArray()
    for outcome in wave.seats:
      let published = outcome.ticksToRoute != 0 and outcome.pointCount > 0
      if wave.measured:
        if published:
          if wave.far: farSamples.add outcome.ticksToRoute
          else: nearSamples.add outcome.ticksToRoute
        else:
          inc unpublished
        # Revision 1 is the first request after the wave's reset; a published
        # route with a higher revision means that first request was replaced.
        if published and outcome.installedRevision != 1:
          inc superseded
        if not published and outcome.lastFailure != brfNone:
          inc failed
      seats.add %*{"seat": outcome.seat, "published": published,
        "ticks_to_route": outcome.ticksToRoute,
        "installed_revision": outcome.installedRevision,
        "request_revision": outcome.requestRevision,
        "point_count": outcome.pointCount, "fingerprint": outcome.fingerprint,
        "replacements": outcome.replacements,
        "first_wait_tick": outcome.firstWaitTick,
        "lifecycle_at_end": $outcome.lifecycle,
        "last_query_succeeded": outcome.lastQuerySucceeded,
        "last_failure": $outcome.lastFailure}
    if wave.measured:
      inc capHits, ord(wave.capHit)
      for sample in wave.tickSamples: tickSamples.add sample
    waves.add %*{"wave": wave.wave, "goal": (if wave.far: "far" else: "near"),
      "measured": wave.measured, "ticks_used": wave.ticksUsed,
      "cap_hit": wave.capHit, "completion_order": wave.completionOrder,
      "pops": wave.pops, "scheduler_restarts": wave.restarts,
      "request_admissions": wave.admissions,
      "route_completions": wave.completions,
      "weight_refreshes": wave.weightRefreshes,
      "counters_measured": defined(bodyNavBreakdown), "seats": seats}
  let pass = deterministic and capHits == 0 and unpublished == 0
  %*{"roster_size": rosterSize, "warmup_waves": LatencyWarmupWaves,
    "measured_waves": LatencyMeasuredWaves, "wave_tick_cap": LatencyWaveTickCap,
    "pop_budget_per_tick": BodyRoutePopBudgetPerTick,
    "far_ticks_to_route_samples": farSamples,
    "far_ticks_to_route_p50": farSamples.percentile(0.5),
    "far_ticks_to_route_p95": farSamples.percentile(0.95),
    "far_ticks_to_route_max": (if farSamples.len > 0: max(farSamples) else: 0),
    "near_ticks_to_route_samples": nearSamples,
    "near_ticks_to_route_p50": nearSamples.percentile(0.5),
    "near_ticks_to_route_p95": nearSamples.percentile(0.95),
    "near_ticks_to_route_max": (if nearSamples.len > 0: max(nearSamples) else: 0),
    "cap_hits": capHits, "unpublished_seat_waves": unpublished,
    "superseded_before_install": superseded,
    "failed_unpublished": failed, "deterministic": deterministic,
    "wave_tick_samples_ns": tickSamples.nsArray,
    "wave_tick_p50_ns": tickSamples.percentile(0.5),
    "wave_tick_p95_ns": tickSamples.percentile(0.95),
    "wave_tick_max_ns": (if tickSamples.len > 0: max(tickSamples) else: 0'i64),
    "tick_timing_gated": false, "waves": waves, "pass": pass}

proc runLatencyGate(corpus: NavCorpus, pool: JsonNode): JsonNode =
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
    raise newException(ValueError, "latency corpus anchors are missing")
  var rows = newJArray()
  for rosterSize in [16, 32]:
    stderr.writeLine &"latency roster={rosterSize}"
    rows.add latencyRow(loaded.gameMap, rosterSize, start, nearGoal, farGoal)
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
    "body_nav_breakdown": defined(bodyNavBreakdown),
    "os_arch": platform, "compile_flags": CanonicalFlags,
    "image_id": imageId, "cpu_limit": cpuLimit,
    "pool_digest": corpus.poolSha256, "canonical": canonical}

proc usage() =
  echo "usage: bench_body_nav_rework --quality|--activation|--tick|--configured-tick|--latency|" &
    "--all [--corpus PATH] [--pool-index N] [--tick-gun-range PX]"
  echo "--pool-index selects the configured pool under --configured-tick, " &
    "otherwise the frozen corpus pool; --tick-gun-range only affects --tick."

when isMainModule:
  var runQuality, runActivation, runTick, runLatency, runConfigured, canonical: bool
  var onlyPool = -1
  var tickGunRange = NavCorpusGunRangePx
  var corpusPath = "tests/fixtures/shell/nav_route_corpus.json"
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--quality": runQuality = true
    of "--activation": runActivation = true
    of "--tick": runTick = true
    of "--configured-tick": runConfigured = true
    of "--latency": runLatency = true
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
    of "--tick-gun-range":
      inc index
      if index > paramCount(): usage(); quit(2)
      tickGunRange = parseInt(paramStr(index))
      if tickGunRange <= 0:
        raise newException(ValueError, "tick gun range must be positive")
    of "--pool-index":
      inc index
      if index > paramCount(): usage(); quit(2)
      onlyPool = parseInt(paramStr(index))
    of "--help", "-h": usage(); quit(0)
    else: usage(); quit(2)
    inc index
  if not runQuality and not runActivation and not runTick and
      not runLatency and not runConfigured: usage(); quit(2)
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
  if runConfigured:
    root["configured_tick"] = runConfiguredTick(onlyPool)
    passed = passed and root["configured_tick"]["pass"].getBool()
  if runQuality:
    root["quality"] = runRouteCorpusGate(corpus, pool, onlyPool)
    passed = passed and root["quality"]["pass"].getBool()
  if runActivation:
    root["activation"] = runActivationGate(pool, onlyPool)
    passed = passed and root["activation"]["pass"].getBool()
  if runTick:
    startProfileTrace()
    root["tick"] = runTickGate(corpus, pool, tickGunRange)
    root["tick"]["gun_range_px"] = %tickGunRange
    finishProfileTrace()
    passed = passed and root["tick"]["pass"].getBool()
  if runLatency:
    root["latency"] = runLatencyGate(corpus, pool)
    passed = passed and root["latency"]["pass"].getBool()
  root["pass"] = %passed
  echo pretty(root)
  if not passed: quit(1)
