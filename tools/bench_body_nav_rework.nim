## Phase-9 qualification harness for the bounded Season 2 body navigator.
##
## Canonical rows are produced only by the repository Docker build running as
## linux/amd64 with one CPU. Development subsets remain available to make the
## expensive gate debuggable without weakening the canonical `--all` run.

import std/[algorithm, json, math, monotimes, options, os, osproc, strformat,
  sequtils, strutils, tables, times]
import crunchy/[common, sha256]
import bitworld/spriteprotocol
import ../src/ctf/[arena, br_map_pool, sim_types, zone_field]
import ../src/shell/[body, body_hazard, body_map, body_nav, body_planner,
  body_route_index, body_route_query, episode, standing_order]
import ../tests/nav_route_corpus_support

const
  CanonicalPlatform = "linux/amd64"
  CanonicalFlags =
    "-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on"
  PoolActivationLimit = 2.0
  ColossalActivationLimit = 3.0
  PoolRetainedLimit = 16'i64 * 1024 * 1024
  ColossalRetainedLimit = 32'i64 * 1024 * 1024
  QualityP95Limit = 3.0
  QualityMaxLimit = 10.0
  ActivationWarmups = 1
  ActivationSamples = 5
  ColossalActivationSamples = 3
  TickWarmups = 5
  TickSamples = 30
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
    ngsBucketDangerRollover = "bucket_danger_rollover"
    ngsStuckReplans = "stuck_replans"
    ngsWorstDegree = "worst_degree"
    ngsColdMemo = "cold_memo"

proc sha256Text(value: string): string = sha256(value).toHex()

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0:
    return Inf
  var ordered = @values
  ordered.sort()
  ordered[max(0, min(ordered.high,
    int(ceil(fraction * ordered.len.float)) - 1))]

proc medianNs(values: openArray[int64]): float64 =
  var floats = newSeq[float64](values.len)
  for index, value in values:
    floats[index] = value.float
  percentile(floats, 0.5)

proc nsArray(values: openArray[int64]): JsonNode =
  result = newJArray()
  for value in values:
    result.add %value

proc rssBytes(): int64 =
  if fileExists("/proc/self/statm"):
    let fields = readFile("/proc/self/statm").splitWhitespace()
    if fields.len >= 2:
      return parseBiggestInt(fields[1]) * 4096
  let value = execProcess("ps", args = ["-o", "rss=", "-p",
    $getCurrentProcessId()], options = {poUsePath}).strip
  if value.len > 0:
    return parseBiggestInt(value) * 1024
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

proc armedSnapshot(map: BodyMap): ZoneDamageSnapshot =
  let
    sourceW = (map.width + NavCell - 1) div NavCell
    sourceH = (map.height + NavCell - 1) div NavCell
  result = ZoneDamageSnapshot(gridW: sourceW, gridH: sourceH,
    cellPx: NavCell, fingerprint: 0x50395a4e4156'u64,
    damage: newSeq[uint16](sourceW * sourceH))
  for index in 0 ..< result.damage.len:
    result.damage[index] =
      if index mod 11 == 0: HazardNeverArrives
      else: uint16(96 + index mod 1024)

proc appendUnique(points: var seq[BodyPoint], point: BodyPoint) =
  if points.len == 0 or points[^1] != point:
    points.add point

proc routePoints(index: BodyRouteIndex,
    route: BodyRouteQueryResult): seq[BodyPoint] =
  for offset in 0 ..< route.descriptor.startLegLen.int:
    result.appendUnique(route.startLegPoint(offset))
  for edgeOffset in 0 ..< route.descriptor.edgeCount.int:
    let
      edge = route.resultEdgeAt(edgeOffset)
      segment = edge.routeEdgeSegment
      metadata = index.routeSegmentAt(segment)
      reversed = edge.routeEdgeReversed
    for pointOffset in 0 ..< metadata.cellLen.int:
      result.appendUnique(index.routePoint(
        index.segmentCellAt(segment, pointOffset, reversed)))
  for offset in 0 ..< route.descriptor.goalLegLen.int:
    result.appendUnique(route.goalLegPoint(offset))

proc executedRoutePoints(index: BodyRouteIndex,
    scratch: BodyRouteQueryScratch,
    route: BodyRouteQueryResult,
    request: var BodyRouteRequest): seq[BodyPoint] =
  ## Replay the production follower's bounded K=6 visibility smoothing. A
  ## waypoint is treated as the next polyline vertex; resampling below turns
  ## each executed chord into the oracle's 4 px scoring resolution.
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
    if waypoint.isNone:
      break
    if waypoint.get == position:
      return @[]
    position = waypoint.get
    result.appendUnique(position)
  if result.len > rawLimit or result[^1] != route.descriptor.exactGoal:
    result.setLen(0)

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

proc requestBlockedCell(item: NavCorpusCase): Option[BodyPoint] =
  ## The corpus stores the dense oracle's 8 px cell coordinate; the live
  ## request carries a pixel position whose containing cell is penalized.
  if item.blockedCell.isSome:
    some(cellCenter(item.blockedCell.get))
  else:
    none(BodyPoint)

proc qualityRow(name: string, values: openArray[float64], missing,
    illegal: int): JsonNode =
  let
    p95 = percentile(values, 0.95)
    maximum = if values.len == 0: Inf else: max(values)
    passed = values.len > 0 and missing == 0 and illegal == 0 and
      p95 <= QualityP95Limit and maximum <= QualityMaxLimit
  %*{
    "stratum": name,
    "count": values.len,
    "missing": missing,
    "illegal": illegal,
    "p95_inflation_pct": p95,
    "max_inflation_pct": maximum,
    "p95_limit_pct": QualityP95Limit,
    "max_limit_pct": QualityMaxLimit,
    "pass": passed
  }

proc runRouteCorpusGate(corpus: NavCorpus, pool: JsonNode,
    onlyPool = -1): JsonNode =
  var
    allInflation: seq[float64]
    strata = initTable[string, seq[float64]]()
    missingByStratum = initCountTable[string]()
    illegalByStratum = initCountTable[string]()
    missing = 0
    illegal = 0
    routeIdentities = newStringOfCap(corpus.cases.len * 96)
    cases = newJArray()
  for poolIndex in 0 ..< pool.len:
    if onlyPool >= 0 and poolIndex != onlyPool:
      continue
    stderr.writeLine &"quality {poolIndex + 1}/{pool.len}"
    let
      loaded = loadPoolMap(pool, poolIndex)
      map = newBodyMap(loaded.gameMap)
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
    var dangerByHash = initTable[string, BodyDangerField]()
    for item in corpus.cases:
      if item.poolIndex != poolIndex:
        continue
      let key = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      var danger = dangerByHash[item.dangerHash]
      if dangerRasterHash(danger) != item.dangerHash:
        raise newException(ValueError,
          "danger raster drifted for corpus case " & item.id)
      let validated = map.validateGoal(item.requestedGoal, item.start)
      if validated.isNone or validated.get.goalPoint != item.validatedGoal or
          validated.get.goalComponent != item.component:
        inc missing
        missingByStratum.inc key
        routeIdentities.add item.id & ":missing;"
        cases.add %*{"id": item.id, "status": "goal-validation"}
        continue
      let request = BodyRouteRequest(
        start: item.start,
        goal: validated.get,
        profile: item.profile.corpusProfile,
        danger: if item.dynamic in {ncdDanger, ncdBoth}: addr danger else: nil,
        blockedCell: item.requestBlockedCell,
        hazard: newDarkBodyHazardOverlay())
      let candidate = index.queryBodyRoute(scratch, request)
      if not candidate.ok:
        inc missing
        missingByStratum.inc key
        routeIdentities.add item.id & ":" & $candidate.failure & ";"
        cases.add %*{"id": item.id, "status": $candidate.failure}
        continue
      let raw = index.routePoints(candidate)
      if not map.routeLegal(item, raw):
        inc illegal
        illegalByStratum.inc key
        routeIdentities.add item.id & ":illegal;"
        cases.add %*{"id": item.id, "status": "illegal"}
        continue
      var executionRequest = request
      let executed = index.executedRoutePoints(scratch, candidate,
        executionRequest)
      if not map.routeLegal(item, executed):
        inc illegal
        illegalByStratum.inc key
        routeIdentities.add item.id & ":executed-illegal;"
        cases.add %*{"id": item.id, "status": "executed-illegal"}
        continue
      let sampled = resampleRoute4px(executed)
      let inflation = routeInflationPct(
        oracleFloatCost(sampled, map, danger, item.profile.corpusProfile,
          item.blockedCell),
        item.oracleCost)
      allInflation.add inflation
      strata.mgetOrPut(key, @[]).add inflation
      let candidateHash = routeHash(sampled)
      routeIdentities.add item.id & ":" & candidateHash & ";"
      cases.add %*{
        "id": item.id,
        "status": "ok",
        "inflation_pct": inflation,
        "route_hash": candidateHash,
        "local_cap_hits": candidate.stats.localCapHits,
        "local_pops": candidate.stats.localPops,
        "side_cap_hits": candidate.stats.sideCapHits,
        "side_pops": candidate.stats.sidePops
      }

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
  result = %*{
    "case_count": if onlyPool < 0: corpus.cases.len else: cases.len,
    "scored_count": allInflation.len,
    "missing": missing,
    "illegal": illegal,
    "route_hash": sha256Text(routeIdentities),
    "cases": cases,
    "strata": rows
  }
  result["pass"] = %rows.elems.allIt(it["pass"].getBool())

proc activationRow(gate: MapGate, sampleCount: int): JsonNode =
  var baselineSamples, candidateSamples: seq[int64]
  var ratioSamples: seq[float64]
  var rssDeltaSamples: seq[int64]
  var retained = 0'i64
  var transient = 0'i64
  var perSeatDanger = 0'i64
  var components = newJObject()
  for sample in 0 .. ActivationWarmups + sampleCount - 1:
    GC_fullCollect()
    let rssBefore = rssBytes()
    let baselineStarted = getMonoTime()
    discard newBodyMap(gate.gameMap)
    let baselineNs = baselineStarted.elapsedNs

    let candidateStarted = getMonoTime()
    let
      map = newBodyMap(gate.gameMap)
      index = newBodyRouteIndex(map)
      scratch = newBodyRouteQueryScratch(index)
      overlay = newBodyHazardOverlay(index, map.armedSnapshot)
      safeCache = newBodySafeCache()
    safeCache.refreshSafeCache(index, overlay, 0, 1)
    let candidateNs = candidateStarted.elapsedNs
    GC_fullCollect()
    let rssAfter = rssBytes()
    let
      indexBytes = index.retainedIndexBytes
      scratchBytes = scratch.retainedBytes
      overlayBytes = overlay.retainedBytes
      safeCacheBytes = safeCache.retainedBytes
    retained = indexBytes + scratchBytes + overlayBytes + safeCacheBytes
    perSeatDanger = int64(map.gridWidth * map.gridHeight) *
      int64(sizeof(float32) + sizeof(uint32))
    transient = index.routeIndexStats.transientPeakBytes
    components = %*{
      "index_bytes": indexBytes,
      "query_scratch_bytes": scratchBytes,
      "hazard_overlay_bytes": overlayBytes,
      "safe_cache_bytes": safeCacheBytes
    }
    if sample >= ActivationWarmups:
      baselineSamples.add baselineNs
      candidateSamples.add candidateNs
      ratioSamples.add candidateNs.float / baselineNs.float
      rssDeltaSamples.add(max(0'i64, rssAfter - rssBefore))
  let
    ratio = percentile(ratioSamples, 1.0)
    ratioLimit = if gate.colossal: ColossalActivationLimit
      else: PoolActivationLimit
    retainedLimit = if gate.colossal: ColossalRetainedLimit
      else: PoolRetainedLimit
  result = %*{
    "map": gate.label,
    "colossal": gate.colossal,
    "baseline_body_map_samples_ns": baselineSamples.nsArray,
    "candidate_body_map_index_overlay_cache_samples_ns": candidateSamples.nsArray,
    "baseline_median_ns": baselineSamples.medianNs,
    "candidate_median_ns": candidateSamples.medianNs,
    "sample_ratios": ratioSamples,
    "max_ratio": ratio,
    "ratio_limit": ratioLimit,
    "retained_bytes": retained,
    "retained_limit_bytes": retainedLimit,
    "transient_peak_bytes": transient,
    "steady_state_rss_delta_samples_bytes": rssDeltaSamples,
    "per_seat_danger_and_visited_bytes": perSeatDanger,
    "retained_components": components,
    "pass": ratio <= ratioLimit and retained <= retainedLimit
  }

proc runActivationGate(pool: JsonNode): JsonNode =
  var rows = newJArray()
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"activation {poolIndex + 1}/{pool.len}"
    rows.add activationRow(loadPoolMap(pool, poolIndex), ActivationSamples)
  stderr.writeLine "activation colossal"
  rows.add activationRow(colossalMap(), ColossalActivationSamples)
  result = %*{"maps": rows}
  result["pass"] = %rows.elems.allIt(it["pass"].getBool())

proc playControls(count: int): seq[SlotControl] =
  result = newSeq[SlotControl](count)
  for control in result.mitems:
    control = scPlay

proc tickFrames(map: BodyMap, positions: openArray[BodyPoint], target: BodyPoint,
    tick: int): seq[ShellSeatFrame] =
  for seat in 0 ..< positions.len:
    var tracks: seq[BodyTrackUpdate]
    for threat in 0 ..< 8:
      tracks.add BodyTrackUpdate(
        seat: (seat + threat + 1) mod positions.len,
        pos: (target.x + (threat mod 3 - 1) * 16,
          target.y + (threat div 3 - 1) * 16),
        team: Blue, aimBrads: some(0), hpKnown: some(3),
        weapon: some(bwGun), tick: uint32(tick))
    result.add ShellSeatFrame(
      seat: uint8(seat), playerIndex: seat, present: true, playing: true,
      alive: true, aliveTeams: 16, motionScale: 1, velocity: 1,
      bodyInputs: BodyTickInputs(
        self: BodySelfState(pos: positions[seat], hp: 4, hpFrac: 1.0,
          lives: some(1), aimBrads: seat mod 256, alive: true),
        visibleTracks: tracks),
      defaultFallbacks: BrDefaultFallbacks(
        currentZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        nextZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        ticksToNextShrink: BrRotateLeadTicks,
        zonePhase: 1, zoneDps: 2, rotateTarget: some(target)))

proc tickRow(map: BodyMap, index: BodyRouteIndex, rosterSize: int,
    scenario: NavGateScenario, start, nearGoal, farGoal: BodyPoint,
    worstRoom, worstDegree: int): JsonNode =
  let overlay = newBodyHazardOverlay(index, map.armedSnapshot)
  var episode = initShellEpisode(true, true, playControls(rosterSize), map,
    331, hazard = overlay, preparedRouteIndex = index)
  var
    tick = 1
    positions = newSeq[BodyPoint](rosterSize)
  for position in positions.mitems:
    position = start
  discard episode.step(tickFrames(map, positions, nearGoal, tick),
    uint32(tick), 0)
  var samples: seq[int64]
  for sample in 0 ..< TickWarmups + TickSamples:
    inc tick
    let target =
      if scenario == ngsMovingGoals and (sample and 1) != 0: nearGoal
      else: farGoal
    case scenario
    of ngsFirstGoals:
      for seat in 0 ..< rosterSize:
        episode.nav.resetNavigationLife(seat)
    of ngsStuckReplans:
      for seat in episode.nav.seats:
        seat.stuckTicks = 8
    of ngsColdMemo:
      episode.nav.routeScratch.invalidateArcMemo()
      for seat in 0 ..< rosterSize:
        episode.nav.resetNavigationLife(seat)
    else:
      discard
    let elapsed =
      if scenario == ngsBucketDangerRollover:
        (sample + 2) * SafeBucketTicks
      else: sample
    let output = episode.step(
      tickFrames(map, positions, target, tick), uint32(tick), elapsed)
    if scenario != ngsStuckReplans:
      for mask in output.masks:
        let bits = encodeInputMask(mask.input)
        var next = positions[mask.seat.int]
        if (bits and ButtonLeft) != 0: next.x -= 4
        if (bits and ButtonRight) != 0: next.x += 4
        if (bits and ButtonUp) != 0: next.y -= 4
        if (bits and ButtonDown) != 0: next.y += 4
        if map.canStand(next):
          positions[mask.seat.int] = next
    if sample >= TickWarmups:
      samples.add output.bodySliceNanoseconds
  episode.closeShellEpisode()
  var floating = newSeq[float64](samples.len)
  for offset, sample in samples:
    floating[offset] = sample.float
  let
    p95 = int64(percentile(floating, 0.95))
    maximum = max(samples)
  result = %*{
    "roster_size": rosterSize,
    "scenario": $scenario,
    "warmups": TickWarmups,
    "sample_count": TickSamples,
    "samples_ns": samples.nsArray,
    "p95_ns": p95,
    "max_ns": maximum,
    "p95_limit_ns": TickP95LimitNs,
    "max_limit_ns": TickMaxLimitNs,
    "worst_degree_map": map.name,
    "worst_degree_room": worstRoom,
    "worst_degree": worstDegree,
    "pass": p95 <= TickP95LimitNs and maximum <= TickMaxLimitNs
  }

proc runTickGate(corpus: NavCorpus, pool: JsonNode): JsonNode =
  let
    loaded = loadPoolMap(pool, 15)
    map = newBodyMap(loaded.gameMap)
    index = newBodyRouteIndex(map)
  var
    start, nearGoal, farGoal: BodyPoint
    foundNear = false
    foundFar = false
    worstRoom = -1
    worstDegree = -1
  for room in 0 ..< map.roomCount:
    let degree = index.roomSideRange(room).len
    if degree > worstDegree:
      worstDegree = degree
      worstRoom = room
  for item in corpus.cases:
    if item.poolIndex == 15 and item.rosterSize == 16 and
        item.profile == ncpDefault and item.dynamic == ncdNone:
      start = item.start
      if item.distance == ncrNear:
        nearGoal = item.validatedGoal
        foundNear = true
      else:
        farGoal = item.validatedGoal
        foundFar = true
  if not foundNear or not foundFar:
    raise newException(ValueError, "tick corpus anchors are missing")
  var rows = newJArray()
  for rosterSize in [16, 32]:
    for scenario in NavGateScenario:
      stderr.writeLine &"tick roster={rosterSize} scenario={scenario}"
      rows.add tickRow(map, index, rosterSize, scenario, start, nearGoal,
        farGoal, worstRoom, worstDegree)
  result = %*{"maps": rows}
  result["pass"] = %rows.elems.allIt(it["pass"].getBool())

proc metadata(corpus: NavCorpus, canonical: bool): JsonNode =
  let
    commit = getEnv("NAV_GATE_COMMIT")
    dirty = getEnv("NAV_GATE_DIRTY")
    imageId = getEnv("NAV_GATE_IMAGE_ID")
    cpuLimit = getEnv("NAV_GATE_CPU_LIMIT")
    machine = execProcess("uname -m").strip
    platform = hostOS & "/" &
      (if machine in ["x86_64", "amd64"]: "amd64" else: machine)
  if canonical and (commit.len == 0 or dirty != "false" or
      platform != CanonicalPlatform or cpuLimit != "1" or imageId.len == 0):
    raise newException(ValueError,
      &"canonical run refused: commit={commit} dirty={dirty} " &
      &"platform={platform} cpu_limit={cpuLimit} image_id={imageId}")
  %*{
    "commit": commit,
    "dirty": dirty,
    "nim_version": NimVersion,
    "os_arch": platform,
    "compile_flags": CanonicalFlags,
    "image_id": imageId,
    "cpu_limit": cpuLimit,
    "pool_digest": corpus.poolSha256,
    "canonical": canonical
  }

proc usage() =
  echo "usage: bench_body_nav_rework --quality|--activation|--tick|--all " &
    "[--corpus PATH] [--pool-index N]"

when isMainModule:
  var
    runQuality = false
    runActivation = false
    runTick = false
    canonical = false
    onlyPool = -1
    corpusPath = "tests/fixtures/shell/nav_route_corpus.json"
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--quality": runQuality = true
    of "--activation": runActivation = true
    of "--tick": runTick = true
    of "--all":
      runQuality = true
      runActivation = true
      runTick = true
      canonical = true
    of "--corpus":
      inc index
      if index > paramCount():
        usage()
        quit(2)
      corpusPath = paramStr(index)
    of "--pool-index":
      inc index
      if index > paramCount():
        usage()
        quit(2)
      onlyPool = parseInt(paramStr(index))
    of "--help", "-h":
      usage()
      quit(0)
    else:
      usage()
      quit(2)
    inc index
  if not runQuality and not runActivation and not runTick:
    usage()
    quit(2)
  if canonical and onlyPool >= 0:
    raise newException(ValueError,
      "canonical --all run does not accept --pool-index")

  let
    corpus = loadNavRouteCorpus(corpusPath)
    pool = loadBrS2PoolRaw()
  var root = %*{
    "schema": "coworld_body_nav_gate",
    "v": 1,
    "metadata": metadata(corpus, canonical),
    "thresholds": {
      "quality_p95_inflation_pct": QualityP95Limit,
      "quality_max_inflation_pct": QualityMaxLimit,
      "pool_activation_ratio": PoolActivationLimit,
      "colossal_activation_ratio": ColossalActivationLimit,
      "pool_retained_bytes": PoolRetainedLimit,
      "colossal_retained_bytes": ColossalRetainedLimit,
      "tick_p95_ns": TickP95LimitNs,
      "tick_max_ns": TickMaxLimitNs
    }
  }
  var passed = true
  if runQuality:
    root["quality"] = runRouteCorpusGate(corpus, pool, onlyPool)
    passed = passed and root["quality"]["pass"].getBool()
  if runActivation:
    root["activation"] = runActivationGate(pool)
    passed = passed and root["activation"]["pass"].getBool()
  if runTick:
    root["tick"] = runTickGate(corpus, pool)
    passed = passed and root["tick"]["pass"].getBool()
  root["pass"] = %passed
  echo pretty(root)
  if not passed:
    quit(1)
