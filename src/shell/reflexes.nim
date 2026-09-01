## Engine-native Appendix R reflex observers and reflex base selection.
##
## Phase 13 reads explicit engine hazard snapshots. The play-view hazard rows
## have since landed (view.nim); the must-agree-with-view-row parity goldens
## remain deferred — when added, their serializer should feed the same facts
## used here.
## Observers still run every tick regardless of which reflexes the current
## ladder subscribes to, so a mid-emergency call change cannot blind the newly
## selected ladder.

import std/[math, options]

import ../ctf/sim_types
import body_map, plan_escape, standing_order, types

const
  ReflexClearGrenadeName* = "reflex_clear_grenade"
  ReflexClearSprayName* = "reflex_clear_spray"
  ReflexZoneEscapeName* = "reflex_zone_escape"
  ReflexGrenadeMarginPx* = 24
  ReflexSprayImpactWindowTicks* = 48
  ReflexZoneTriggerTicks* = 72
  ReflexZoneReleaseTicks* = 96
  ReflexArriveRadiusPx* = 8.0
  ReflexRuntimeBudgetUs* = 15_000.0
    ## Local Phase-13 regression bound for the full 32-seat × 1089-candidate ×
    ## eight-hazard measured shape. This is not a retuned P0 budget ruling.

type
  ReflexKind* = enum
    rkClearGrenade
    rkClearSpray
    rkZoneEscape

  ReflexTelemetryKind* = enum
    rtTriggered
    rtReleased
    rtNoGoal

  VisibleGrenade* = object
    predictedBlastPos*: BodyPoint
    ticksToBlast*: int
    blastRadius*: int
    eventId*: int

  BlastCue* = object
    ## Post-blast evidence only. It is retained in the input model so tests
    ## prove it never triggers the grenade reflex.
    pos*: BodyPoint
    tick*: uint32
    eventId*: int

  VisibleSprayCone* = object
    origin*: BodyPoint
    aimBrads*: int
    coversSelf*: bool
    tick*: uint32
    eventId*: int

  AnonymousSprayImpact* = object
    impactPos*: BodyPoint
    incomingDir*: int
    tick*: uint32
    eventId*: int

  ZoneTicksUntilOutside* = proc(point: BodyPoint): int64 {.closure.}

  ReflexTickInput* = object
    tick*: uint32
    mode*: GameMode
    map*: BodyMap
    selfPos*: BodyPoint
    alive*: bool
    motionScale*: int
    velocity*: int
    visibleGrenades*: seq[VisibleGrenade]
    blastCues*: seq[BlastCue]
    sprayCones*: seq[VisibleSprayCone]
    sprayImpacts*: seq[AnonymousSprayImpact]
    zoneTicksUntilOutside*: ZoneTicksUntilOutside
    nextZone*: MapRect
    routeDistance*: RouteDistanceLookup

  ReflexSubscription* = object
    kind*: ReflexKind
    epoch*: uint64

  ReflexTelemetry* = object
    tick*: uint32
    kind*: ReflexTelemetryKind
    reflexName*: string

  ReflexDecision* = object
    selected*: bool
    noGoal*: bool
    fallbackUsed*: bool
    kind*: ReflexKind
    order*: ResolvedStandingOrder
    plan*: PlanEscapeResult

  ReflexSeatState* = object
    active*: array[ReflexKind, bool]
    telemetry*: seq[ReflexTelemetry]

  GrenadeScoreFact = object
    pos: BodyPoint
    ticksToBlast: int64
    blastRadiusWithMargin: int
    clearanceDenominator: int64

const ReflexDedupSlots = 2048

proc reflexName*(kind: ReflexKind): string =
  case kind
  of rkClearGrenade: ReflexClearGrenadeName
  of rkClearSpray: ReflexClearSprayName
  of rkZoneEscape: ReflexZoneEscapeName

proc reflexProvenance*(kind: ReflexKind): Provenance =
  ## The provenance name is the reserved reflex name; the replay/GameVersion
  ## pair versions the engine-native implementation.
  Provenance(base: ProvenanceBase(kind: pbReflex,
    reflexName: kind.reflexName))

proc mapPoint(point: BodyPoint): MapPoint =
  MapPoint(x: point.x, y: point.y)

proc reflexIntent(kind: ReflexKind; point: BodyPoint): Intent =
  Intent(kind: ikNavigateTo,
    point: some(point.mapPoint),
    arriveRadius: ReflexArriveRadiusPx,
    movingGoal: false,
    profile: cpDefault,
    idleAimCenterBrads: none(int),
    reason: kind.reflexName,
    combat: CombatPolicy())

proc boxDistanceSquared(point, center: BodyPoint): int64 =
  let
    nearX = max(0, abs(point.x - center.x) - body_map.PlayerHalf)
    nearY = max(0, abs(point.y - center.y) - body_map.PlayerHalf)
  int64(nearX) * int64(nearX) + int64(nearY) * int64(nearY)

proc grenadeCovers*(point: BodyPoint; grenade: VisibleGrenade): bool =
  let radius = grenade.blastRadius + ReflexGrenadeMarginPx
  boxDistanceSquared(point, grenade.predictedBlastPos) <=
    int64(radius) * int64(radius)

proc triggeringGrenades(input: ReflexTickInput): seq[VisibleGrenade] =
  for grenade in input.visibleGrenades:
    if input.selfPos.grenadeCovers(grenade):
      result.add grenade

proc earliestDetonation(grenades: openArray[VisibleGrenade]): int64 =
  result = InfiniteArrival
  for grenade in grenades:
    result = min(result, int64(grenade.ticksToBlast))

proc clearanceNumerator(point: BodyPoint; fact: GrenadeScoreFact): int64 =
  let
    nearX = max(0, abs(point.x - fact.pos.x) - body_map.PlayerHalf)
    nearY = max(0, abs(point.y - fact.pos.y) - body_map.PlayerHalf)
  int64(nearX) * int64(nearX) + int64(nearY) * int64(nearY)

proc grenadeFacts(grenades: seq[VisibleGrenade]): seq[GrenadeScoreFact] =
  result.setLen(grenades.len)
  for index, grenade in grenades:
    let radius = grenade.blastRadius + ReflexGrenadeMarginPx
    result[index] = GrenadeScoreFact(
      pos: grenade.predictedBlastPos,
      ticksToBlast: int64(grenade.ticksToBlast),
      blastRadiusWithMargin: radius,
      clearanceDenominator: int64(radius) * int64(radius))

proc reflexPointKey(point: BodyPoint): uint64 =
  ((uint64(point.x) shl 32) or uint64(point.y)) + 1'u64

proc seenOrAdd(keys: var array[ReflexDedupSlots, uint64]; key: uint64): bool =
  var slot = int((key xor (key shr 33)) and uint64(ReflexDedupSlots - 1))
  while keys[slot] != 0'u64:
    if keys[slot] == key:
      return true
    slot = (slot + 1) and (ReflexDedupSlots - 1)
  keys[slot] = key
  false

proc betterHard(minDistance, arrival: int64; ordinal: int;
                bestMinDistance, bestArrival: int64; bestOrdinal: int): bool =
  if minDistance != bestMinDistance:
    return minDistance > bestMinDistance
  if arrival != bestArrival:
    return arrival < bestArrival
  ordinal < bestOrdinal

proc betterFallback(minScaledClearance, earliestInAggregation, arrival: int64;
                    ordinal: int; bestScaledClearance,
                    bestEarliestInAggregation, bestArrival: int64;
                    bestOrdinal: int): bool =
  if minScaledClearance != bestScaledClearance:
    return minScaledClearance > bestScaledClearance
  if earliestInAggregation != bestEarliestInAggregation:
    return earliestInAggregation > bestEarliestInAggregation
  if arrival != bestArrival:
    return arrival < bestArrival
  ordinal < bestOrdinal

proc latticeAllExact(map: BodyMap; fromPoint: BodyPoint; component: int): bool =
  ## A component pixel resolves to itself in the validator table: distance 0
  ## wins both EDT passes. When the whole candidate lattice is in the actor's
  ## component, the resolved stream is therefore exactly the requested stream
  ## and duplicate suppression cannot remove a candidate.
  if component == 0:
    return false
  for dy in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                   ReflexCandidateSpacingPx):
    for dx in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                     ReflexCandidateSpacingPx):
      let requested = (fromPoint.x + dx, fromPoint.y + dy)
      if not map.inBounds(requested) or map.componentOf(requested) != component:
        return false
  true

proc grenadeScore(candidatePoint: BodyPoint; arrival: int64;
                  facts: openArray[GrenadeScoreFact]; earliest: int64):
    tuple[safe: bool, minDistance, minScaledClearance,
      earliestInAggregation: int64] =
  result.safe = arrival < earliest
  result.minDistance = InfiniteArrival
  var
    minScaledAll = InfiniteArrival
    earliestAll = InfiniteArrival
    hasArrivedAggregation = false
  result.minScaledClearance = InfiniteArrival
  result.earliestInAggregation = InfiniteArrival
  for fact in facts:
    let
      dx = int64(candidatePoint.x) - int64(fact.pos.x)
      dy = int64(candidatePoint.y) - int64(fact.pos.y)
      distance = dx * dx + dy * dy
      clearance = candidatePoint.clearanceNumerator(fact)
    result.minDistance = min(result.minDistance, distance)
    if clearance <= int64(fact.blastRadiusWithMargin) *
        int64(fact.blastRadiusWithMargin):
      result.safe = false
    let scaled = clearance * 1_000_000'i64 div
      max(1'i64, fact.clearanceDenominator)
    minScaledAll = min(minScaledAll, scaled)
    earliestAll = min(earliestAll, fact.ticksToBlast)
    if fact.ticksToBlast <= arrival:
      hasArrivedAggregation = true
      result.minScaledClearance = min(result.minScaledClearance, scaled)
      result.earliestInAggregation = min(result.earliestInAggregation,
        fact.ticksToBlast)
  if not hasArrivedAggregation:
    result.minScaledClearance = minScaledAll
    result.earliestInAggregation = earliestAll

proc planGrenadeExactThroughStage(input: PlanEscapeInput;
                                  facts: openArray[GrenadeScoreFact];
                                  earliest: int64;
                                  stage: PlanEscapeProfileStage):
    PlanEscapeResult =
  var
    ordinal = 0
    haveHard = false
    haveFallback = false
    bestHardPoint: BodyPoint
    bestFallbackPoint: BodyPoint
    bestHardOrdinal = 0
    bestFallbackOrdinal = 0
    bestHardArrival = InfiniteArrival
    bestFallbackArrival = InfiniteArrival
    bestHardDistance = low(int64)
    bestFallbackScaled = low(int64)
    bestFallbackEarliest = low(int64)

  for dy in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                   ReflexCandidateSpacingPx):
    for dx in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                     ReflexCandidateSpacingPx):
      let resolved = (input.fromPoint.x + dx, input.fromPoint.y + dy)
      inc result.considered
      if stage == psCandidateBounds or stage == psGoalValidation:
        inc ordinal
        continue

      inc result.resolvedCount
      inc result.dedupedCount
      if stage == psOptionDedup:
        inc ordinal
        continue

      let arrival = input.arrivalFor(resolved)
      if stage == psArrival:
        inc ordinal
        continue

      let score = grenadeScore(resolved, arrival, facts, earliest)
      if stage == psScorer:
        inc ordinal
        continue

      if score.safe and (not haveHard or betterHard(score.minDistance,
          arrival, ordinal, bestHardDistance, bestHardArrival,
          bestHardOrdinal)):
        haveHard = true
        bestHardPoint = resolved
        bestHardOrdinal = ordinal
        bestHardArrival = arrival
        bestHardDistance = score.minDistance
      if not haveFallback or betterFallback(score.minScaledClearance,
          score.earliestInAggregation, arrival, ordinal, bestFallbackScaled,
          bestFallbackEarliest, bestFallbackArrival, bestFallbackOrdinal):
        haveFallback = true
        bestFallbackPoint = resolved
        bestFallbackOrdinal = ordinal
        bestFallbackArrival = arrival
        bestFallbackScaled = score.minScaledClearance
        bestFallbackEarliest = score.earliestInAggregation
      inc ordinal

  if not haveFallback:
    return
  result.found = true
  if haveHard:
    result.point = bestHardPoint
    result.ordinal = bestHardOrdinal
    result.arrival = bestHardArrival
  else:
    result.fallbackUsed = true
    result.point = bestFallbackPoint
    result.ordinal = bestFallbackOrdinal
    result.arrival = bestFallbackArrival
  result.goal = input.map.validateGoal(result.point, input.fromPoint)

proc planGrenadeEscapeThroughStage(input: PlanEscapeInput;
                                   grenades: seq[VisibleGrenade];
                                   stage: PlanEscapeProfileStage):
    PlanEscapeResult =
  doAssert input.map != nil
  doAssert ReflexCandidateRadiusPx mod ReflexCandidateSpacingPx == 0
  let
    facts = grenadeFacts(grenades)
    earliest = earliestDetonation(grenades)
    component = input.map.componentOf(input.fromPoint)
  if input.map.latticeAllExact(input.fromPoint, component):
    return planGrenadeExactThroughStage(input, facts, earliest, stage)

  var
    seenKeys: array[ReflexDedupSlots, uint64]
    ordinal = 0
    haveHard = false
    haveFallback = false
    bestHardGoal = none(ValidatedGoal)
    bestFallbackGoal = none(ValidatedGoal)
    bestHardPoint: BodyPoint
    bestFallbackPoint: BodyPoint
    bestHardOrdinal = 0
    bestFallbackOrdinal = 0
    bestHardArrival = InfiniteArrival
    bestFallbackArrival = InfiniteArrival
    bestHardDistance = low(int64)
    bestFallbackScaled = low(int64)
    bestFallbackEarliest = low(int64)

  for dy in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                   ReflexCandidateSpacingPx):
    for dx in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                     ReflexCandidateSpacingPx):
      let requested = (input.fromPoint.x + dx, input.fromPoint.y + dy)
      inc result.considered
      if not input.map.inBounds(requested):
        inc ordinal
        continue
      if stage == psCandidateBounds:
        inc ordinal
        continue

      let goal = input.map.validateGoal(requested, input.fromPoint)
      if goal.isNone:
        inc ordinal
        continue
      if stage == psGoalValidation:
        inc ordinal
        continue

      inc result.resolvedCount
      let
        resolved = goal.get.goalPoint
        key = reflexPointKey(resolved)
      if seenKeys.seenOrAdd(key):
        inc ordinal
        continue
      inc result.dedupedCount
      if stage == psOptionDedup:
        inc ordinal
        continue

      let arrival = input.arrivalFor(resolved)
      if stage == psArrival:
        inc ordinal
        continue

      let score = grenadeScore(resolved, arrival, facts, earliest)
      if stage == psScorer:
        inc ordinal
        continue

      if score.safe and (not haveHard or betterHard(score.minDistance,
          arrival, ordinal, bestHardDistance, bestHardArrival,
          bestHardOrdinal)):
        haveHard = true
        bestHardGoal = goal
        bestHardPoint = resolved
        bestHardOrdinal = ordinal
        bestHardArrival = arrival
        bestHardDistance = score.minDistance
      if not haveFallback or betterFallback(score.minScaledClearance,
          score.earliestInAggregation, arrival, ordinal, bestFallbackScaled,
          bestFallbackEarliest, bestFallbackArrival, bestFallbackOrdinal):
        haveFallback = true
        bestFallbackGoal = goal
        bestFallbackPoint = resolved
        bestFallbackOrdinal = ordinal
        bestFallbackArrival = arrival
        bestFallbackScaled = score.minScaledClearance
        bestFallbackEarliest = score.earliestInAggregation
      inc ordinal

  if not haveFallback:
    return
  result.found = true
  if haveHard:
    result.goal = bestHardGoal
    result.point = bestHardPoint
    result.ordinal = bestHardOrdinal
    result.arrival = bestHardArrival
  else:
    result.fallbackUsed = true
    result.goal = bestFallbackGoal
    result.point = bestFallbackPoint
    result.ordinal = bestFallbackOrdinal
    result.arrival = bestFallbackArrival

proc planGrenadeEscape(input: PlanEscapeInput;
                       grenades: seq[VisibleGrenade]): PlanEscapeResult =
  input.planGrenadeEscapeThroughStage(grenades, psTupleComparison)

proc betterZone(insideNext, safeTicks, arrival: int64; ordinal: int;
                bestInsideNext, bestSafeTicks, bestArrival: int64;
                bestOrdinal: int): bool =
  if insideNext != bestInsideNext:
    return insideNext > bestInsideNext
  if safeTicks != bestSafeTicks:
    return safeTicks > bestSafeTicks
  if arrival != bestArrival:
    return arrival < bestArrival
  ordinal < bestOrdinal

proc planZoneExactThroughStage(input: PlanEscapeInput;
                               nextZone: MapRect;
                               zoneTicksUntilOutside: ZoneTicksUntilOutside;
                               stage: PlanEscapeProfileStage):
    PlanEscapeResult =
  var
    ordinal = 0
    haveBest = false
    bestPoint: BodyPoint
    bestOrdinal = 0
    bestArrival = InfiniteArrival
    bestInsideNext = low(int64)
    bestSafeTicks = low(int64)

  for dy in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                   ReflexCandidateSpacingPx):
    for dx in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                     ReflexCandidateSpacingPx):
      let resolved = (input.fromPoint.x + dx, input.fromPoint.y + dy)
      inc result.considered
      if stage == psCandidateBounds or stage == psGoalValidation:
        inc ordinal
        continue

      inc result.resolvedCount
      inc result.dedupedCount
      if stage == psOptionDedup:
        inc ordinal
        continue

      let arrival = input.arrivalFor(resolved)
      if stage == psArrival:
        inc ordinal
        continue

      let
        insideNext = if resolved.pointInRect(nextZone): 1'i64 else: 0'i64
        safeTicks = zoneTicksUntilOutside(resolved)
      if stage == psScorer:
        inc ordinal
        continue

      if not haveBest or betterZone(insideNext, safeTicks, arrival, ordinal,
          bestInsideNext, bestSafeTicks, bestArrival, bestOrdinal):
        haveBest = true
        bestPoint = resolved
        bestOrdinal = ordinal
        bestArrival = arrival
        bestInsideNext = insideNext
        bestSafeTicks = safeTicks
      inc ordinal

  if not haveBest:
    return
  result.found = true
  result.point = bestPoint
  result.ordinal = bestOrdinal
  result.arrival = bestArrival
  result.goal = input.map.validateGoal(result.point, input.fromPoint)

proc planZoneEscapeThroughStage(input: PlanEscapeInput;
                                nextZone: MapRect;
                                zoneTicksUntilOutside: ZoneTicksUntilOutside;
                                stage: PlanEscapeProfileStage):
    PlanEscapeResult =
  doAssert input.map != nil
  doAssert ReflexCandidateRadiusPx mod ReflexCandidateSpacingPx == 0
  if zoneTicksUntilOutside == nil:
    return
  let component = input.map.componentOf(input.fromPoint)
  if input.map.latticeAllExact(input.fromPoint, component):
    return input.planZoneExactThroughStage(nextZone, zoneTicksUntilOutside,
      stage)
  input.planEscapeThroughStage(
    proc(candidate: EscapeCandidate): EscapeScore =
      let
        insideNext = if candidate.resolved.pointInRect(nextZone): 1'i64
          else: 0'i64
        safeTicks = zoneTicksUntilOutside(candidate.resolved)
      EscapeScore(hardPass: true,
        normal: scoreKey2(maxKey(insideNext), maxKey(safeTicks)),
        fallback: scoreKey2(maxKey(insideNext), maxKey(safeTicks))),
    stage)

proc planZoneEscape(input: PlanEscapeInput; source: ReflexTickInput):
    PlanEscapeResult =
  input.planZoneEscapeThroughStage(source.nextZone,
    source.zoneTicksUntilOutside, psTupleComparison)

proc activeImpactCount(input: ReflexTickInput): int =
  for impact in input.sprayImpacts:
    if input.tick >= impact.tick and
        input.tick - impact.tick <= ReflexSprayImpactWindowTicks.uint32:
      inc result

proc triggeringSpray(input: ReflexTickInput): bool =
  for cone in input.sprayCones:
    if cone.coversSelf:
      return true
  input.activeImpactCount >= 2

proc axisDistanceSquared(point, origin: BodyPoint; aimBrads: int): int64 =
  let
    angle = aimBrads.float * 2.0 * PI / AimBradsTurn.float
    ux = cos(angle)
    uy = sin(angle)
    dx = (point.x - origin.x).float
    dy = (point.y - origin.y).float
    cross = dx * uy - dy * ux
  int64(round(cross * cross))

proc activeImpactCentroid(input: ReflexTickInput): BodyPoint =
  var
    count = 0
    sx = 0
    sy = 0
  for impact in input.sprayImpacts:
    if input.tick >= impact.tick and
        input.tick - impact.tick <= ReflexSprayImpactWindowTicks.uint32:
      inc count
      sx += impact.impactPos.x
      sy += impact.impactPos.y
  if count == 0:
    input.selfPos
  else:
    (sx div count, sy div count)

proc sprayScorer(input: ReflexTickInput): EscapeScorer =
  let
    useCone = input.sprayCones.len > 0
    firstCone = if useCone: input.sprayCones[0] else: VisibleSprayCone()
    centroid = input.activeImpactCentroid
  result = proc(candidate: EscapeCandidate): EscapeScore =
    let cover = if input.map.isCoverPost(candidate.resolved): 1'i64 else: 0'i64
    let distance =
      if useCone:
        axisDistanceSquared(candidate.resolved, firstCone.origin,
          firstCone.aimBrads)
      else:
        squaredDistance(candidate.resolved, centroid)
    EscapeScore(hardPass: true,
      normal: scoreKey2(maxKey(cover), maxKey(distance)),
      fallback: scoreKey2(maxKey(cover), maxKey(distance)))

proc zoneActive(input: ReflexTickInput): bool =
  input.mode == gmBr and input.zoneTicksUntilOutside != nil and
    input.zoneTicksUntilOutside(input.selfPos) <= ReflexZoneTriggerTicks

proc zoneRelease(input: ReflexTickInput): bool =
  input.mode != gmBr or input.zoneTicksUntilOutside == nil or
    input.zoneTicksUntilOutside(input.selfPos) > ReflexZoneReleaseTicks

proc note(state: var ReflexSeatState; tick: uint32;
          kind: ReflexTelemetryKind; reflex: ReflexKind) =
  state.telemetry.add ReflexTelemetry(tick: tick, kind: kind,
    reflexName: reflex.reflexName)

proc setActive(state: var ReflexSeatState; input: ReflexTickInput;
               kind: ReflexKind; activeNow: bool) =
  if activeNow and not state.active[kind]:
    state.note(input.tick, rtTriggered, kind)
  elif not activeNow and state.active[kind]:
    state.note(input.tick, rtReleased, kind)
  state.active[kind] = activeNow

proc observeReflexes*(state: var ReflexSeatState; input: ReflexTickInput) =
  ## Updates every observer regardless of current ladder subscription.
  if not input.alive:
    for kind in ReflexKind:
      state.setActive(input, kind, false)
    return

  state.setActive(input, rkClearGrenade,
    input.triggeringGrenades.len > 0)
  state.setActive(input, rkClearSpray, input.triggeringSpray)

  if state.active[rkZoneEscape]:
    state.setActive(input, rkZoneEscape, not input.zoneRelease)
  else:
    state.setActive(input, rkZoneEscape, input.zoneActive)

proc planInput(input: ReflexTickInput): PlanEscapeInput =
  PlanEscapeInput(map: input.map, fromPoint: input.selfPos,
    motionScale: input.motionScale, velocity: input.velocity,
    routeDistance: input.routeDistance)

proc planFor(input: ReflexTickInput; kind: ReflexKind): PlanEscapeResult =
  case kind
  of rkClearGrenade:
    input.planInput.planGrenadeEscape(input.triggeringGrenades)
  of rkClearSpray:
    input.planInput.planEscape(sprayScorer(input))
  of rkZoneEscape:
    input.planInput.planZoneEscape(input)

proc profilePlanFor*(input: ReflexTickInput; kind: ReflexKind;
                     stage: PlanEscapeProfileStage): PlanEscapeResult =
  ## Measurement-only entry point used by the reflex budget tests. Production
  ## callers stay on `planFor`/`selectReflex` so profiling timers do not affect
  ## the runtime row.
  case kind
  of rkClearGrenade:
    input.planInput.planGrenadeEscapeThroughStage(input.triggeringGrenades,
      stage)
  of rkClearSpray:
    input.planInput.planEscapeThroughStage(sprayScorer(input), stage)
  of rkZoneEscape:
    input.planInput.planZoneEscapeThroughStage(input.nextZone,
      input.zoneTicksUntilOutside, stage)

proc selectReflex*(state: var ReflexSeatState; input: ReflexTickInput;
                   subscriptions: openArray[ReflexSubscription]):
    ReflexDecision =
  ## Runs observers first, then returns the first subscribed active reflex in
  ## ladder order. If that reflex has no resolved candidate, it contributes no
  ## standing order and records reflexNoGoal telemetry.
  state.observeReflexes(input)
  for subscription in subscriptions:
    if not state.active[subscription.kind]:
      continue
    let planned = input.planFor(subscription.kind)
    result.kind = subscription.kind
    result.plan = planned
    result.fallbackUsed = planned.fallbackUsed
    if not planned.found:
      result.noGoal = true
      state.note(input.tick, rtNoGoal, subscription.kind)
      return
    result.selected = true
    result.order = ResolvedStandingOrder(
      intent: reflexIntent(subscription.kind, planned.point),
      goal: planned.goal,
      provenance: subscription.kind.reflexProvenance,
      contributingEpoch: subscription.epoch)
    return
