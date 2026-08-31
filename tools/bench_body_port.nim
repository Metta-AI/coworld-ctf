## Stencil-free timing probe for the committed Season 2 body port.

when not defined(release):
  {.error: "bench_body_port must be compiled with -d:release".}

import std/[algorithm, json, math, monotimes, options, os, osproc, tables,
  strutils, times]
import ../src/ctf/arena as ctfArena
import ../src/ctf/sim_types as ctfTypes
import ../src/shell/body_cache
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
import ../src/shell/types as shellTypes
import ../src/shell/view as shellView

type
  Options = object
    selectedCase: string
    seeds: seq[int]
    warmups, samples: int
    output: string

  Scenario = object
    seed: int
    gameMap: ctfTypes.CtfMap
    map: BodyMap
    smoke: bool
    smokeWalkable: seq[bool]
    smokeSpawns: seq[BodyPoint]

  BarrierPlanPair = object
    start, requested, resolved: BodyPoint
    distancePx: float

proc parseIntList(text: string): seq[int] =
  for item in text.split(','):
    result.add(parseInt(item.strip()))

proc parseOptions(): Options =
  result = Options(selectedCase: "all", seeds: @[4242], warmups: 5,
    samples: 50)
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
    of "warmups": result.warmups = parseInt(value)
    of "samples": result.samples = parseInt(value)
    of "output", "o": result.output = value
    else: raise newException(ValueError, "unknown option --" & key)
    inc index
  if result.warmups < 0 or result.samples <= 0 or result.seeds.len == 0:
    raise newException(ValueError,
      "warmups must be >= 0; samples and seeds must be nonzero")

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc measure(warmups, samples: int,
             body: proc() {.closure.}): seq[int64] =
  for _ in 0 ..< warmups:
    body()
  for _ in 0 ..< samples:
    let started = getMonoTime()
    body()
    result.add(elapsedNs(started))

proc percentile(samples: openArray[int64], fraction: float): int64 =
  var ordered = @samples
  ordered.sort()
  ordered[clamp(int(ceil(fraction * ordered.len.float)) - 1,
    0, ordered.high)]

proc row(name: string, samples: seq[int64],
         details = newJObject()): JsonNode =
  %*{"name": name, "samples": samples.len,
    "median_ns": percentile(samples, 0.5),
    "p95_ns": percentile(samples, 0.95), "details": details}

proc generatedScenario(seed: int): Scenario =
  ## The committed BR golden-map spec, not a generated CTF giant: the
  ## season-2 target field. Generated 2-team giant maps are covered by the
  ## dedicated thinned-atlas census case; this timing scenario keeps the
  ## BR golden geometry stable and varies goals only.
  result.seed = seed
  result.gameMap = ctfArena.mapFromSpecJson(
    readFile("tests/fixtures/br-golden-map.json"))
  result.map = newBodyMap(result.gameMap)

proc smokeScenario(): Scenario =
  const Width = 384
  const Height = 160
  result.smoke = true
  result.smokeWalkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      result.smokeWalkable[y * Width + x] = true
  result.smokeSpawns = @[(16, 80), (Width - 17, 80)]
  result.map = newBodyMap(result.smokeWalkable, Width, Height, 2,
    result.smokeSpawns)

proc rebuildEpisodeMap(scenario: Scenario): BodyMap =
  if scenario.smoke:
    newBodyMap(scenario.smokeWalkable, scenario.map.width,
      scenario.map.height, 2, scenario.smokeSpawns)
  else:
    newBodyMap(scenario.gameMap)

proc mapDetails(scenario: Scenario): JsonNode =
  %*{"seed": scenario.seed, "map_width": scenario.map.width,
    "map_height": scenario.map.height,
    "grid_w": scenario.map.gridWidth,
    "grid_h": scenario.map.gridHeight,
    "groups": scenario.map.groupCount,
    "components": scenario.map.componentCount,
    "atlas_posts": scenario.map.atlasPostCount}

proc anchor(scenario: Scenario): BodyPoint =
  if scenario.smoke:
    scenario.smokeSpawns[0]
  else:
    (16, 16)  # standable on the BR golden map (the phase-2 golden's start)

proc dangerInput(scenario: Scenario): DangerInput =
  result.selfXy = scenario.anchor
  if not scenario.map.canStand(result.selfXy):
    raise newException(ValueError, "danger probe anchor is not standable")
  let towardCenter = if result.selfXy.x < scenario.map.width div 2: 1 else: -1
  let offsets = [
    (96, 0), (176, -80), (248, 112), (328, -144),
    (408, 176), (480, -208), (544, 224), (592, -32)]
  for index, offset in offsets:
    let requested: BodyPoint = (
      clamp(result.selfXy.x + towardCenter * offset[0],
        0, scenario.map.width - 1),
      clamp(result.selfXy.y + offset[1], 0, scenario.map.height - 1))
    let resolved = scenario.map.validateGoal(requested, result.selfXy)
    if resolved.isNone:
      raise newException(ValueError,
        "danger source cannot resolve in the anchor component: " & $requested)
    result.candidates.add(DangerCandidate(
      seatIndex: index + 1, pos: resolved.get.goalPoint))

proc sourceDetails(input: DangerInput): JsonNode =
  result = newJArray()
  for source in input.candidates:
    result.add(%*{"seat": source.seatIndex,
      "x": source.pos.x, "y": source.pos.y})

proc latencyMs(ticks: int): float =
  ticks.float * 1000.0 / 24.0

proc latencyRow(name: string, details: JsonNode): JsonNode =
  %*{"name": name, "samples": 1, "median_ns": 0, "p95_ns": 0,
    "details": details}

proc freezeBudgetDetails(scenario: Scenario): JsonNode =
  result = scenario.mapDetails
  result["danger_cadence_k"] = %DangerCadenceK
  result["cold_plan_budget_per_tick"] = %ColdPlanBudgetPerTick
  result["atlas_candidate_grid_px"] = %16
  result["max_cover_radius_px"] = %shellTypes.MaxCoverRadiusPx
  result["max_cover_posts_examined"] = %shellTypes.MaxCoverPostsExamined
  result["max_cover_threats"] = %shellTypes.MaxCoverThreats
  result["max_spatial_calls_per_step"] = %shellTypes.MaxSpatialCallsPerStep

proc writeBackRow(scenario: Scenario): JsonNode =
  let details = scenario.freezeBudgetDetails
  details["row"] = %"Reflex worst-case (lane C measured, 32-seat max reflex plan): 10.8 ms-class (9.9-11.1 observed) vs the 4.0 ms runtime share — over budget at freeze. Lever: the §6.1 fully-resolved validator answer table (landed in lane A) replacing per-candidate tie-scan resolution with O(1) lookup; fallback lever: reflex plan caps."
  latencyRow("freeze.write_back.reflex_worst_case", details)

proc realScorerWriteBackRow(scenario: Scenario): JsonNode =
  let details = scenario.freezeBudgetDetails
  details["row"] = %"nearest_cover real scorer (lane C measured): 19.9-20.2 us/call at cap 1,536, linear in cap — at the frozen 1,024 cap and MaxSpatialCallsPerStep=2, the adversarial spatial-call tick is ~2.6 ms of the 4.0 ms runtime share; lever if it regresses: spatial bucketing (QUEUED, lane C side)."
  latencyRow("freeze.write_back.nearest_cover_real_scorer", details)

proc dangerRow(options: Options, scenario: Scenario,
               liveRange: int): JsonNode =
  let system = newBodyNavSystem(scenario.map, 1, liveRange)
  let input = scenario.dangerInput
  let samples = measure(options.warmups, options.samples,
    proc() = system.seats[0].rebuildDanger(scenario.map, input, 0))
  let details = scenario.mapDetails
  details["source_count"] = %input.candidates.len
  details["source_positions"] = input.sourceDetails
  details["self_x"] = %input.selfXy.x
  details["self_y"] = %input.selfXy.y
  details["live_gun_range_px"] = %liveRange
  details["danger_fingerprint"] = %($system.seats[0].dangerFingerprint)
  row("port.danger_rebuild_8src_live" & $liveRange, samples, details)

proc planningGoals(scenario: Scenario): seq[BodyPoint] =
  if scenario.smoke:
    for seat in 0 ..< 32:
      result.add((scenario.map.width - 24 - (seat mod 8) * 8,
                  scenario.map.height - 24 - (seat div 8) * 8))
  else:
    for seat in 0 ..< 32:
      result.add((3194 - (seat mod 8) * 16,
                  1696 - (seat div 8) * 16))

proc representativeStarts(scenario: Scenario): seq[BodyPoint] =
  if scenario.smoke:
    for seat in 0 ..< 32:
      result.add((32 + (seat mod 8) * 40, 24 + (seat div 8) * 32))
  else:
    result = @[
      (160, 160), (480, 160), (800, 160), (1280, 160),
      (1600, 160), (1920, 160), (2240, 160), (2560, 160),
      (160, 480), (480, 480), (800, 480), (1120, 480),
      (1600, 480), (1920, 480), (2240, 480), (2560, 480),
      (160, 800), (800, 800), (1120, 800), (1440, 800),
      (1760, 800), (2080, 800), (2560, 800), (2880, 800),
      (160, 1120), (640, 1120), (960, 1120), (1440, 1120),
      (1760, 1120), (2080, 1120), (2400, 1120), (2720, 1120)]

proc straightLinePx(a, b: BodyPoint): float =
  sqrt(float((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)))

proc representativePlanPairs(scenario: Scenario): seq[BarrierPlanPair] =
  for seat, start in scenario.representativeStarts:
    if not scenario.map.canStand(start):
      raise newException(ValueError,
        "representative activation start is not standable for seat " &
        $seat & ": " & $start)
    let requested: BodyPoint =
      if scenario.smoke:
        (min(start.x + 64, scenario.map.width - 24), start.y)
      else:
        (min(start.x + shellTypes.MaxCoverRadiusPx,
          scenario.map.width - 17), start.y)
    let goal = scenario.map.validateGoal(requested, start)
    if goal.isNone:
      raise newException(ValueError,
        "representative activation goal cannot resolve for seat " &
        $seat & ": " & $requested)
    let resolved = goal.get.goalPoint
    let distance = straightLinePx(start, resolved)
    if not scenario.smoke and distance > 400.0:
      raise newException(ValueError,
        "representative activation goal exceeds cover-class distance for seat " &
        $seat & ": " & $distance)
    result.add(BarrierPlanPair(start: start, requested: requested,
      resolved: resolved, distancePx: distance))

proc distanceDistribution(pairs: openArray[BarrierPlanPair]): JsonNode =
  var distances: seq[float]
  for pair in pairs:
    distances.add(pair.distancePx)
  distances.sort()
  let median =
    if distances.len mod 2 == 0:
      (distances[distances.len div 2 - 1] + distances[distances.len div 2]) / 2
    else:
      distances[distances.len div 2]
  %*{"min": distances[0], "median": median, "max": distances[^1]}

proc pairDetails(pairs: openArray[BarrierPlanPair]): JsonNode =
  result = newJArray()
  for seat, pair in pairs:
    result.add(%*{"seat": seat,
      "start": [pair.start.x, pair.start.y],
      "requested": [pair.requested.x, pair.requested.y],
      "resolved": [pair.resolved.x, pair.resolved.y],
      "straight_line_px": pair.distancePx})

proc hasPendingPlan(system: BodyNavSystem): bool =
  for seat in system.seats:
    if seat.job.planPending:
      return true

proc planCompletionTicks(map: BodyMap, start: BodyPoint, requested: BodyPoint,
                         afterPlanOnlyBarrier: bool): JsonNode =
  let goal = map.validateGoal(requested, start)
  if goal.isNone:
    raise newException(ValueError,
      "latency goal cannot resolve: " & $requested)
  let system = newBodyNavSystem(map, 1, 331, DangerCadenceK, 100_000)
  if afterPlanOnlyBarrier:
    system.replacePlan(0, 1, start, goal.get)
    system.prewarmColdPlans()
  system.replacePlan(0, 2, start, goal.get)
  var tick = 0
  while system.seats[0].job.planPending:
    discard system.runPlanningTick(tick)
    if system.seats[0].job.planSucceeded:
      result = %*{"requested": [requested.x, requested.y],
        "resolved": [goal.get.goalPoint.x, goal.get.goalPoint.y],
        "completion_tick": tick, "ticks_elapsed": tick + 1,
        "ms_at_24hz": latencyMs(tick + 1),
        "work_units": system.seats[0].job.workUnits,
        "after_plan_only_barrier": afterPlanOnlyBarrier}
      return
    inc tick
    if tick > 100_000:
      raise newException(ValueError, "latency plan did not complete")
  raise newException(ValueError, "latency plan completed before measurement")

proc latencyRows(options: Options, scenario: Scenario): seq[JsonNode] =
  discard options
  let start = scenario.anchor
  if not scenario.map.canStand(start):
    raise newException(ValueError, "latency probe start is not standable")

  block dangerLatency:
    let system = newBodyNavSystem(scenario.map, 32, 331, DangerCadenceK, 128)
    var emptyInputs = newSeq[DangerInput](32)
    var threatInputs = newSeq[DangerInput](32)
    let base = scenario.dangerInput
    for seat in 0 ..< 32:
      emptyInputs[seat].selfXy = base.selfXy
      threatInputs[seat] = base
    system.initializeDanger(emptyInputs, -1)
    var seenTick: Table[int, int]
    for tick in 0 ..< DangerCadenceK:
      system.rebuildScheduledDanger(tick, threatInputs)
      for visit in system.dangerTraceSnapshot:
        if visit.sourceCount > 0 and visit.seat notin seenTick:
          seenTick[visit.seat] = visit.tick
    var distribution = newJArray()
    var worst = 0
    for seat in 0 ..< 32:
      let latency = seenTick[seat]
      worst = max(worst, latency)
      distribution.add(%latency)
    let details = scenario.freezeBudgetDetails
    details["stimulus_tick"] = %0
    details["worst_ticks"] = %worst
    details["worst_ms_at_24hz"] = %latencyMs(worst)
    details["distribution_ticks"] = distribution
    details["note"] =
      %"measured from new threat in DangerInput to scheduled rebuild trace"
    result.add(latencyRow("latency.danger_new_threat", details))

  let goals = scenario.planningGoals
  let typicalIndices = @[7, 15, 23, 31]
  for afterPlanOnlyBarrier in [false, true]:
    var samples = newJArray()
    var worstTypical = 0
    for index in typicalIndices:
      let sample = planCompletionTicks(scenario.map, start, goals[index],
        afterPlanOnlyBarrier)
      worstTypical = max(worstTypical, sample["ticks_elapsed"].getInt)
      samples.add(sample)
    var details = scenario.freezeBudgetDetails
    details["goal_set"] = %"quartile goals"
    details["goal_indices"] = %typicalIndices
    details["after_plan_only_barrier"] = %afterPlanOnlyBarrier
    details["prewarmed_route_fields"] = %false
    details["worst_ticks_elapsed"] = %worstTypical
    details["worst_ms_at_24hz"] = %latencyMs(worstTypical)
    details["samples"] = samples
    result.add(latencyRow("latency.intent_to_movement_typical" &
      (if afterPlanOnlyBarrier: "_after_plan_only_barrier" else: ""), details))

    let worstSample = planCompletionTicks(scenario.map, start, goals[0],
      afterPlanOnlyBarrier)
    details = scenario.freezeBudgetDetails
    details["goal_set"] = %"far pair"
    details["goal_index"] = %0
    details["after_plan_only_barrier"] = %afterPlanOnlyBarrier
    details["prewarmed_route_fields"] = %false
    details["ticks_elapsed"] = %worstSample["ticks_elapsed"].getInt
    details["ms_at_24hz"] = %worstSample["ms_at_24hz"].getFloat
    details["sample"] = worstSample
    result.add(latencyRow("latency.intent_to_movement_worst" &
      (if afterPlanOnlyBarrier: "_after_plan_only_barrier" else: ""), details))

  let zoneGoal = (scenario.map.width div 2, scenario.map.height div 2)
  let zoneSample = planCompletionTicks(scenario.map, start, zoneGoal, true)
  var zoneDetails = scenario.freezeBudgetDetails
  zoneDetails["stimulus"] = %"zone-driven goal install"
  zoneDetails["body_side_split"] =
    %"measures body-side route completion only; play-side decision latency is lane C"
  zoneDetails["ticks_elapsed"] = %zoneSample["ticks_elapsed"].getInt
  zoneDetails["ms_at_24hz"] = %zoneSample["ms_at_24hz"].getFloat
  zoneDetails["sample"] = zoneSample
  result.add(latencyRow("latency.zone_shrink_to_waypoint", zoneDetails))

proc activationBarrierRow(options: Options, scenario: Scenario): JsonNode =
  let sampleCount = min(options.samples, 5)
  let goals = scenario.planningGoals
  let start = scenario.anchor
  var lastPlanVisits = 0
  var lastQueuedMints = 0
  let samples = measure(options.warmups, sampleCount,
    proc() =
      let system = newBodyNavSystem(scenario.map, 32, 331,
        DangerCadenceK, 100_000)
      for seat, requested in goals:
        let goal = scenario.map.validateGoal(requested, start)
        if goal.isNone:
          raise newException(ValueError,
            "activation-barrier goal cannot resolve: " & $requested)
        system.replacePlan(seat, uint64(seat + 1), start, goal.get)
      system.prewarmColdPlans()
      lastPlanVisits = system.planningTraceSnapshot.len
      lastQueuedMints = 0
      for seat in system.seats:
        if seat.mintQueuedOrPending:
          inc lastQueuedMints)
  let p95Ms = percentile(samples, 0.95).float / 1_000_000.0
  let details = scenario.freezeBudgetDetails
  details["seat_count"] = %32
  details["goal_count"] = %goals.len
  details["sample_cap"] = %5
  details["samples_requested"] = %options.samples
  details["p95_ms"] = %p95Ms
  details["baseline_note"] =
    %"absolute p95 only; the previously reported 434.0 ms value was episode_build, not a pre-change prewarm measurement"
  details["includes_plan_drain"] = %true
  details["includes_route_field_mint_drain"] = %false
  details["last_plan_trace_visits"] = %lastPlanVisits
  details["last_queued_mints"] = %lastQueuedMints
  row("latency.activation_barrier_prewarm32_plans_only", samples, details)

proc representativeActivationBarrierRow(options: Options,
                                        scenario: Scenario): JsonNode =
  let sampleCount = min(options.samples, 5)
  let pairs = scenario.representativePlanPairs
  var lastPlanVisits = 0
  var lastQueuedMints = 0
  let samples = measure(options.warmups, sampleCount,
    proc() =
      let system = newBodyNavSystem(scenario.map, 32, 331,
        DangerCadenceK, 100_000)
      for seat in 0 ..< pairs.len:
        let pair = pairs[seat]
        let goal = scenario.map.validateGoal(pair.requested, pair.start)
        if goal.isNone or goal.get.goalPoint != pair.resolved:
          raise newException(ValueError,
            "representative activation goal changed for seat " & $seat)
        system.replacePlan(seat, uint64(seat + 1), pair.start, goal.get)
      system.prewarmColdPlans()
      lastPlanVisits = system.planningTraceSnapshot.len
      lastQueuedMints = 0
      for seat in system.seats:
        if seat.mintQueuedOrPending:
          inc lastQueuedMints)
  let p95Ms = percentile(samples, 0.95).float / 1_000_000.0
  let details = scenario.freezeBudgetDetails
  details["seat_count"] = %32
  details["goal_count"] = %pairs.len
  details["sample_cap"] = %5
  details["samples_requested"] = %options.samples
  details["p95_ms"] = %p95Ms
  details["scenario"] =
    %"every seat plans a cover-class goal from its own scattered start"
  details["includes_plan_drain"] = %true
  details["includes_route_field_mint_drain"] = %false
  details["distance_px"] = pairs.distanceDistribution
  details["pairs"] = pairs.pairDetails
  details["last_plan_trace_visits"] = %lastPlanVisits
  details["last_queued_mints"] = %lastQueuedMints
  row("latency.activation_barrier_prewarm32_representative", samples, details)

proc viewSource(seat: int): PlayViewSource =
  result = PlayViewSource(
    tick: 12345'u32,
    mode: gmBr,
    epoch: uint64(seat + 1),
    self: PlaySelf(pos: (1605 + seat, 856), hp: 9, hpFrac: 0.9,
      aimBrads: (seat * 17) mod 256, alive: true),
    aliveTeams: 16,
    zone: some(PlayZone(phase: 3,
      current: PlayRect(x: 100, y: 100, w: 3000, h: 1500),
      next: some(PlayRect(x: 200, y: 200, w: 2800, h: 1300)),
      ticksToShrink: 240, dps: 2)),
    intent: some(shellTypes.Intent(kind: ikNavigateTo,
      point: some(MapPoint(x: 3000, y: 850)),
      arriveRadius: 24.0,
      movingGoal: true,
      profile: cpCarrier,
      micro: {mfFormationBias, mfPeekDuck},
      idleAimCenterBrads: some(128),
      clampToEndzone: true,
      suppressFireFreeze: true,
      reason: "benchmark")))
  for index in 0 ..< 32:
    result.tracks.add(PlayTrack(seat: index, team: Team(index div 2),
      pos: (100 + index * 31, 200 + index * 13),
      aimBrads: some((index * 17) mod 256),
      hp: some(10 - (index mod 4)), freshTick: 12345'u32 - uint32(index),
      bounty: index mod 7 == 0))
    result.items.add(PlayItem(eventId: uint64(index), kind: pikMedkit,
      pos: (40 + index * 23, 60 + index * 11),
      present: some(index mod 3 != 0),
      freshTick: 12300'u32 + uint32(index)))
    result.killFeed.add(PlayKillFeedRow(eventId: uint64(index),
      tick: 12000'u32 + uint32(index), killerTeam: Team(index div 2),
      victimSeat: (index + 1) mod 32))
    result.shouts.add(PlayShout(eventId: uint64(index),
      team: Team(index div 2), slotLetter: $char(ord('A') + index mod 26),
      text: "contact", pos: (500 + index, 700 - index),
      tick: 12345'u32 - uint32(index)))
  for index in 0 ..< 16:
    result.aggressors.add(PlayAggressor(eventId: uint64(index),
      tick: 12340'u32 - uint32(index), dirBrads: (index * 19) mod 256,
      seat: some(index)))
  for index in 0 ..< 8:
    result.hazards.grenades.add(PlayGrenadeHazard(eventId: uint64(index),
      coversSelf: index == 0, pos: (900 + index, 800 + index),
      predictedBlastPos: (920 + index, 810 + index),
      ticksToBlast: 20 - index))
    if index mod 2 == 0:
      result.hazards.sprays.add(PlaySprayHazard(kind: pshVisibleCone,
        eventId: uint64(index), coversSelf: index == 0,
        tick: 12340'u32 - uint32(index), attackerSeat: index,
        origin: (700 + index, 600 + index), aimBrads: index * 8,
        reachPx: 331, maxWidthPx: 96))
    else:
      result.hazards.sprays.add(PlaySprayHazard(kind: pshAnonymousImpact,
        eventId: uint64(index), coversSelf: false,
        tick: 12340'u32 - uint32(index),
        impactPos: (700 + index, 600 + index),
        incomingDirBrads: index * 8))
  for index in 0 ..< 4:
    result.hazards.blastCues.add(PlayBlastCue(eventId: uint64(index),
      coversSelf: index == 0, pos: (1000 + index, 500 + index),
      tick: 12340'u32 + uint32(index)))
  result.hazards.ownThrow = some(PlayOwnThrow(
    target: (1700, 900), releaseTick: 12360, blastRadius: 96))

proc viewRows(options: Options): seq[JsonNode] =
  var sources: seq[PlayViewSource]
  for seat in 0 ..< 32:
    sources.add(viewSource(seat))
  var producer = newPlayViewProducer()
  var maxBytes = 0
  var selectedRows = newJArray()
  let sampleModel = selectPlayView(sources[0], shellTypes.MaxViewFrameBytes)
  selectedRows.add(%*{"tracks": sampleModel.tracks.len,
    "items": sampleModel.items.len, "aggressors": sampleModel.aggressors.len,
    "kill_feed": sampleModel.killFeed.len, "shouts": sampleModel.shouts.len,
    "grenades": sampleModel.hazards.grenades.len,
    "blast_cues": sampleModel.hazards.blastCues.len,
    "sprays": sampleModel.hazards.sprays.len,
    "own_throw": sampleModel.hazards.ownThrow.isSome})
  let samples = measure(options.warmups, options.samples,
    proc() =
      for source in sources:
        let bytes = producer.buildPlayView(source, shellTypes.MaxViewFrameBytes)
        maxBytes = max(maxBytes, bytes.len))
  let details = %*{"seat_count": 32,
    "max_view_frame_bytes": shellTypes.MaxViewFrameBytes,
    "max_observed_frame_bytes": maxBytes,
    "acceptance_p95_ms": 2.5,
    "acceptance": "32-seat canonical JSON build+encode for socket/replay path",
    "json_guest_reader_fuel_acceptance":
      "fixed-layout binary play copy uses its own 8192-byte cap after 28-57 fuel/byte JSON measurement",
    "selected_rows_sample": selectedRows}
  result.add(row("view.json_batch32_build_encode", samples, details))

proc stageBucket(stage: PlanStage): string =
  case stage
  of pjsAstarSearch:
    "astar"
  else:
    "mixed"

proc classifyPlanningTick(system: BodyNavSystem, traceStart: int,
                          stagesBefore: openArray[PlanStage]): string =
  result = ""
  let trace = system.planningTraceSnapshot
  for index in traceStart ..< trace.len:
    let visit = trace[index]
    if visit.units == 0:
      continue
    let before = stagesBefore[visit.seat]
    let after = system.seats[visit.seat].job.stage
    var bucket = before.stageBucket
    if before != after:
      bucket = "mixed"
    if result.len == 0:
      result = bucket
    elif result != bucket:
      result = "mixed"
  if result.len == 0:
    result = "mixed"

proc planningRows(options: Options, scenario: Scenario): seq[JsonNode] =
  let system = newBodyNavSystem(scenario.map, 32, 331)
  let start = scenario.anchor
  if not scenario.map.canStand(start):
    raise newException(ValueError, "planning probe start is not standable")
  let requestedGoals = scenario.planningGoals
  var resolvedGoals = newJArray()
  for seat, requested in requestedGoals:
    let goal = scenario.map.validateGoal(requested, start)
    if goal.isNone:
      raise newException(ValueError,
        "planning goal cannot resolve: " & $requested)
    system.replacePlan(seat, uint64(seat + 1), start, goal.get)
    resolvedGoals.add(%*{"seat": seat, "requested": [requested.x, requested.y],
      "resolved": [goal.get.goalPoint.x, goal.get.goalPoint.y]})

  var tick = 0
  for _ in 0 ..< options.warmups:
    if not system.hasPendingPlan:
      raise newException(ValueError, "planning jobs ended during warmup")
    let spent = system.runPlanningTick(tick)
    if spent != ColdPlanBudgetPerTick:
      raise newException(ValueError,
        "planning warmup did not spend the full budget: " & $spent)
    inc tick

  var earlySamples: seq[int64]
  var earlyUnits: seq[int]
  var stageSamples = newJObject()
  var stageUnits = newJObject()
  var stageTicks = newJObject()
  for name in ["clear", "dijkstra", "astar", "mixed"]:
    stageSamples[name] = newJArray()
    stageUnits[name] = newJArray()
    stageTicks[name] = newJArray()

  while system.hasPendingPlan:
    let measuringEarly = earlySamples.len < options.samples
    var stagesBefore = newSeq[PlanStage](system.seats.len)
    for index, seat in system.seats:
      stagesBefore[index] = seat.job.stage
    let traceStart = system.planningTraceSnapshot.len
    if not system.hasPendingPlan:
      raise newException(ValueError, "planning jobs ended before all samples")
    let started = getMonoTime()
    let spent = system.runPlanningTick(tick)
    let ns = elapsedNs(started)
    if not scenario.smoke and spent != ColdPlanBudgetPerTick:
      raise newException(ValueError,
        "planning sample did not spend the full budget: " & $spent)
    let bucket = system.classifyPlanningTick(traceStart, stagesBefore)
    if measuringEarly:
      earlySamples.add(ns)
      earlyUnits.add(spent)
    if stageSamples[bucket].len < options.samples:
      stageSamples[bucket].add(%ns)
      stageUnits[bucket].add(%spent)
      stageTicks[bucket].add(%tick)
    inc tick
    if earlySamples.len == options.samples and
        stageSamples["clear"].len >= options.samples and
        stageSamples["dijkstra"].len >= options.samples and
        stageSamples["astar"].len >= options.samples and
        stageSamples["mixed"].len > 0:
      break

  if earlySamples.len < options.samples:
    raise newException(ValueError, "planning jobs ended before all early samples")

  proc baseDetails(): JsonNode =
    result = scenario.mapDetails
    result["seat_count"] = %32
    result["start"] = %*[start.x, start.y]
    result["goals"] = resolvedGoals
    result["budget_per_tick"] = %ColdPlanBudgetPerTick
    result["first_measured_tick"] = %options.warmups

  let earlyDetails = baseDetails()
  earlyDetails["units_spent"] = %earlyUnits
  earlyDetails["units_min"] = %earlyUnits.min
  earlyDetails["units_max"] = %earlyUnits.max
  earlyDetails["compatibility_note"] =
    %"same early drain window formerly reported as port.planning_tick_saturated"
  result.add(row("port.planning_tick_early_drain", earlySamples,
    earlyDetails))

  for bucket in ["clear", "dijkstra", "astar", "mixed"]:
    if stageSamples[bucket].len == 0:
      continue
    var samples: seq[int64]
    var units: seq[int]
    for node in stageSamples[bucket]:
      samples.add(node.getInt.int64)
    for node in stageUnits[bucket]:
      units.add(node.getInt)
    let details = baseDetails()
    details["stage_bucket"] = %bucket
    details["units_spent"] = %units
    details["units_min"] = %units.min
    details["units_max"] = %units.max
    details["ticks"] = stageTicks[bucket]
    if bucket == "mixed":
      details["mixed_tick_count"] = %samples.len
    result.add(row("port.planning_tick_" & bucket, samples, details))

proc episodeRow(options: Options, scenario: Scenario): JsonNode =
  let sampleCount = min(options.samples, 5)
  var built: BodyMap
  let samples = measure(options.warmups, sampleCount,
    proc() = built = scenario.rebuildEpisodeMap)
  let details = scenario.mapDetails
  details["validator_tables"] = %built.validatorTableCount
  details["validator_logical_bytes"] = %built.validatorLogicalBytes
  details["home_fields"] = %built.homeFieldCount
  details["rooms"] = %built.roomCount
  details["chokes"] = %built.chokeCount
  details["sample_cap"] = %5
  row("port.episode_build", samples, details)

proc duckRow(options: Options, scenario: Scenario): JsonNode =
  if scenario.map.atlasPostCount == 0:
    raise newException(ValueError, "map has no atlas post for duck probe")
  let cache = newBodySeatCache(scenario.map)
  var duck: BodyDuckResult
  let coldStarted = getMonoTime()
  duck = cache.duckFor(0)
  let coldNs = elapsedNs(coldStarted)
  let warm = measure(options.warmups, options.samples,
    proc() = duck = cache.duckFor(0))
  let details = scenario.mapDetails
  details["atlas_index"] = %0
  details["cold_ns"] = %coldNs
  details["warm_samples"] = %warm.len
  details["duck_x"] = %duck.pos.x
  details["duck_y"] = %duck.pos.y
  details["duck_contrast"] = %duck.contrast
  row("port.duck_cold_warm", warm, details)

proc validatorScanProbeMap(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc validatorBuildRow(options: Options, scenario: Scenario): JsonNode =
  let sampleCount = min(options.samples, 5)
  var built: BodyMap
  let samples = measure(options.warmups, sampleCount,
    proc() = built = scenario.rebuildEpisodeMap)
  let details = scenario.mapDetails
  details["framing"] =
    %"representative activation barrier: rebuild the episode body map before seats plan"
  details["validator_tables"] = %built.validatorTableCount
  details["validator_logical_bytes"] = %built.validatorLogicalBytes
  details["validator_bytes_per_component"] = %validatorBytesFor(
    built.width, built.height, 1)
  details["p0_giant_single_component_bytes"] = %validatorBytesFor(
    3211, 1713, 1)
  details["max_validator_table_bytes"] = %shellTypes.MaxValidatorTableBytes
  details["memory_choice"] =
    %"winner-only uint32 raster; distance is recomputed from winner coordinates"
  details["sample_cap"] = %5
  row("validator.table_build_representative_barrier", samples, details)

proc validatorLookupRows(options: Options): seq[JsonNode] =
  let map = validatorScanProbeMap()
  let start: BodyPoint = (30, 30)
  let requested: BodyPoint = (350, 30)
  let component = map.componentOf(start)
  let resolved = map.validateGoal(requested, start)
  if resolved.isNone or resolved.get.goalPoint != (94, 30):
    raise newException(ValueError,
      "validator lookup probe no longer resolves to the radius-256 golden")
  let scanSamples = measure(options.warmups, options.samples,
    proc() = discard map.resolveNearestByRowMajorScan(component, requested,
      shellTypes.ValidatorRadiusPx))
  let tableSamples = measure(options.warmups, options.samples,
    proc() = discard map.validateGoal(requested, start))
  let details = %*{"map_width": map.width, "map_height": map.height,
    "component": component, "requested": [requested.x, requested.y],
    "resolved": [resolved.get.goalPoint.x, resolved.get.goalPoint.y],
    "distance_squared": 256 * 256,
    "validator_radius_px": shellTypes.ValidatorRadiusPx,
    "case": "deep-in-wall request at the exact validator radius"}
  result.add(row("validator.lookup_deep_wall_row_major_scan",
    scanSamples, details))
  result.add(row("validator.lookup_deep_wall_table",
    tableSamples, details))

proc censusSeeds(): seq[int] =
  for index in 0 .. 32:
    result.add(4242 + index * 1009)

proc censusRow(): JsonNode =
  var perSeed = newJArray()
  var maxCount = 0
  var maxSeed = 0
  let overrides = ctfTypes.MapGenOverrides(size: "giant",
    windows: -1, pits: -1, pitDensity: -1)
  for seed in censusSeeds():
    let gameMap = ctfArena.generateCtfMap(seed, overrides, 2)
    let map = newBodyMap(gameMap)
    let count = map.maxAtlasPostsInRadius
    if count > maxCount:
      maxCount = count
      maxSeed = seed
    perSeed.add(%*{"seed": seed, "width": map.width, "height": map.height,
      "atlas_posts": map.atlasPostCount, "densest_disc_posts": count})
  let details = %*{"seed_formula": "4242 + k*1009, k=0..32",
    "map_size": "giant", "teams": 2, "atlas_candidate_grid_px": 16,
    "max_cover_radius_px": shellTypes.MaxCoverRadiusPx,
    "max_cover_posts_examined": shellTypes.MaxCoverPostsExamined,
    "max_densest_disc_posts": maxCount, "max_seed": maxSeed,
    "headroom_posts": shellTypes.MaxCoverPostsExamined - maxCount,
    "per_seed": perSeed}
  latencyRow("census.thinned_atlas_giant_33", details)

proc addRows(target: JsonNode, rows: openArray[JsonNode]) =
  for item in rows:
    target.add(item)

proc addRows(target: var seq[JsonNode], rows: openArray[JsonNode]) =
  for item in rows:
    target.add(item)

proc runCase(options: Options, scenario: Scenario): seq[JsonNode] =
  case options.selectedCase
  of "smoke", "all":
    result.add(options.dangerRow(scenario, 331))
    result.add(options.dangerRow(scenario, 1050))
    result.addRows(options.planningRows(scenario))
    result.addRows(options.latencyRows(scenario))
    result.add(options.activationBarrierRow(scenario))
    result.add(options.representativeActivationBarrierRow(scenario))
    result.addRows(options.viewRows())
    result.add(options.episodeRow(scenario))
    result.add(options.duckRow(scenario))
    result.add(scenario.writeBackRow)
    result.add(scenario.realScorerWriteBackRow)
  of "danger":
    result.add(options.dangerRow(scenario, 331))
    result.add(options.dangerRow(scenario, 1050))
  of "planning": result.addRows(options.planningRows(scenario))
  of "latency":
    result.addRows(options.latencyRows(scenario))
    result.add(options.activationBarrierRow(scenario))
    result.add(options.representativeActivationBarrierRow(scenario))
    result.add(scenario.writeBackRow)
    result.add(scenario.realScorerWriteBackRow)
  of "view": result.addRows(options.viewRows())
  of "episode": result.add(options.episodeRow(scenario))
  of "validator":
    result.add(options.validatorBuildRow(scenario))
    result.addRows(options.validatorLookupRows())
  of "duck": result.add(options.duckRow(scenario))
  else:
    raise newException(ValueError,
      "cases are smoke, all, danger, planning, latency, view, episode, validator, duck, census")

proc gitHead(): string =
  try:
    execProcess("git", args = ["rev-parse", "HEAD"],
      options = {poUsePath}).strip()
  except OSError:
    "unknown"

proc main() =
  var options = parseOptions()
  let smoke = options.selectedCase == "smoke"
  if smoke:
    options.warmups = 0
    options.samples = 1
  var rows = newJArray()
  if options.selectedCase == "census":
    rows.add(censusRow())
  elif smoke:
    rows.addRows(options.runCase(smokeScenario()))
  else:
    for seed in options.seeds:
      rows.addRows(options.runCase(generatedScenario(seed)))
  let output = %*{"harness": "body-port-probe", "release": true,
    "repo_commit": gitHead(), "case": options.selectedCase,
    "seeds": options.seeds, "warmups": options.warmups,
    "samples": options.samples, "rows": rows}
  let encoded = pretty(output)
  if options.output.len > 0:
    let destination = absolutePath(options.output)
    if destination.startsWith(getCurrentDir() & DirSep):
      raise newException(ValueError,
        "benchmark output must stay outside the repository")
    writeFile(destination, encoded & "\n")
  echo encoded

when isMainModule:
  main()
