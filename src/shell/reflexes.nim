## Engine-native Appendix R reflex observers and reflex base selection.
##
## Phase 13 reads explicit engine hazard snapshots. Lane-A hazard view rows have
## not landed yet, so the must-agree-with-view-row parity goldens are deferred:
## once those rows exist, their serializer should feed the same facts used here.
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

proc minBlastDistance(point: BodyPoint;
                      grenades: openArray[VisibleGrenade]): int64 =
  result = InfiniteArrival
  for grenade in grenades:
    result = min(result, squaredDistance(point, grenade.predictedBlastPos))

proc clearanceNumerator(point: BodyPoint; grenade: VisibleGrenade): int64 =
  boxDistanceSquared(point, grenade.predictedBlastPos)

proc clearanceDenominator(grenade: VisibleGrenade): int64 =
  let radius = grenade.blastRadius + ReflexGrenadeMarginPx
  int64(radius) * int64(radius)

proc grenadeScorer(grenades: seq[VisibleGrenade]): EscapeScorer =
  let earliest = earliestDetonation(grenades)
  result = proc(candidate: EscapeCandidate): EscapeScore =
    var safe = candidate.arrival < earliest
    for grenade in grenades:
      if candidate.resolved.grenadeCovers(grenade):
        safe = false
    var aggregation: seq[VisibleGrenade]
    for grenade in grenades:
      if int64(grenade.ticksToBlast) <= candidate.arrival:
        aggregation.add grenade
    if aggregation.len == 0:
      aggregation = grenades

    var minScaledClearance = InfiniteArrival
    var earliestInAggregation = InfiniteArrival
    for grenade in aggregation:
      # Integer ratio comparison by scaling a/b to a common positive range.
      let scaled = clearanceNumerator(candidate.resolved, grenade) *
        1_000_000'i64 div max(1'i64, clearanceDenominator(grenade))
      minScaledClearance = min(minScaledClearance, scaled)
      earliestInAggregation = min(earliestInAggregation,
        int64(grenade.ticksToBlast))

    EscapeScore(
      hardPass: safe,
      normal: scoreKeys([maxKey(minBlastDistance(candidate.resolved,
        grenades))]),
      fallback: scoreKeys([maxKey(minScaledClearance),
        maxKey(earliestInAggregation)]))

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
      normal: scoreKeys([maxKey(cover), maxKey(distance)]),
      fallback: scoreKeys([maxKey(cover), maxKey(distance)]))

proc zoneActive(input: ReflexTickInput): bool =
  input.mode == gmBr and input.zoneTicksUntilOutside != nil and
    input.zoneTicksUntilOutside(input.selfPos) <= ReflexZoneTriggerTicks

proc zoneRelease(input: ReflexTickInput): bool =
  input.mode != gmBr or input.zoneTicksUntilOutside == nil or
    input.zoneTicksUntilOutside(input.selfPos) > ReflexZoneReleaseTicks

proc zoneScorer(input: ReflexTickInput): EscapeScorer =
  result = proc(candidate: EscapeCandidate): EscapeScore =
    let
      insideNext = if candidate.resolved.pointInRect(input.nextZone): 1'i64
        else: 0'i64
      safeTicks = input.zoneTicksUntilOutside(candidate.resolved)
    EscapeScore(hardPass: true,
      normal: scoreKeys([maxKey(insideNext), maxKey(safeTicks)]),
      fallback: scoreKeys([maxKey(insideNext), maxKey(safeTicks)]))

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
    input.planInput.planEscape(grenadeScorer(input.triggeringGrenades))
  of rkClearSpray:
    input.planInput.planEscape(sprayScorer(input))
  of rkZoneEscape:
    input.planInput.planEscape(zoneScorer(input))

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
