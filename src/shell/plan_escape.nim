## Appendix R.2 bounded reflex escape planner.
##
## The candidate lattice, validator use, deduplication, integer arrival, and
## tuple ordering here are shared by every engine-native reflex. The planner
## does not build route fields; callers may supply a non-minting route-distance
## lookup, otherwise straight-line distance is used as Appendix R's estimate.

import std/options

import ../ctf/sim_types
import body_map, types

const InfiniteArrival* = high(int64) div 4
const DedupSlots = 2048

type
  ScoreDirection* = enum
    sdMaximize
    sdMinimize

  ScoreKey* = object
    direction*: ScoreDirection
    value*: int64

  ScoreKeyList* = object
    len*: int
    items*: array[8, ScoreKey]

  EscapeCandidate* = object
    requested*: BodyPoint
    resolved*: BodyPoint
    goal*: Option[ValidatedGoal]
    ordinal*: int
    arrival*: int64

  EscapeScore* = object
    hardPass*: bool
    normal*: ScoreKeyList
    fallback*: ScoreKeyList

  RouteDistanceLookup* = proc(resolved: BodyPoint): Option[int] {.closure.}

  PlanEscapeInput* = object
    map*: BodyMap
    fromPoint*: BodyPoint
    motionScale*: int
    velocity*: int
    routeDistance*: RouteDistanceLookup

  PlanEscapeResult* = object
    found*: bool
    fallbackUsed*: bool
    considered*: int
    resolvedCount*: int
    dedupedCount*: int
    goal*: Option[ValidatedGoal]
    point*: BodyPoint
    ordinal*: int
    arrival*: int64

  EscapeScorer* = proc(candidate: EscapeCandidate): EscapeScore {.closure.}

proc maxKey*(value: int64): ScoreKey =
  ScoreKey(direction: sdMaximize, value: value)

proc minKey*(value: int64): ScoreKey =
  ScoreKey(direction: sdMinimize, value: value)

proc noScoreKeys*(): ScoreKeyList =
  discard

proc scoreKeys*(items: openArray[ScoreKey]): ScoreKeyList =
  doAssert items.len <= result.items.len
  result.len = items.len
  for index, item in items:
    result.items[index] = item

proc pointKey(point: BodyPoint): int64 =
  (int64(point.x) shl 32) xor (int64(point.y) and 0xffff_ffff'i64)

proc seenOrAdd(keys: var array[DedupSlots, int64];
               used: var array[DedupSlots, bool]; key: int64): bool =
  var slot = int((uint64(key) xor (uint64(key) shr 33)) and
    uint64(DedupSlots - 1))
  while used[slot]:
    if keys[slot] == key:
      return true
    slot = (slot + 1) and (DedupSlots - 1)
  used[slot] = true
  keys[slot] = key
  false

proc pointInRect*(point: BodyPoint, rect: MapRect): bool =
  point.x >= rect.x and point.x < rect.x + rect.w and
    point.y >= rect.y and point.y < rect.y + rect.h

proc isqrtFloor*(value: int64): int =
  doAssert value >= 0
  if value == 0:
    return 0
  var
    lo = 0'i64
    hi = min(value, int64(high(int32)))
  while lo <= hi:
    let mid = (lo + hi) div 2
    let sq = mid * mid
    if sq <= value:
      result = mid.int
      lo = mid + 1
    else:
      hi = mid - 1

proc squaredDistance*(a, b: BodyPoint): int64 =
  let
    dx = int64(a.x) - int64(b.x)
    dy = int64(a.y) - int64(b.y)
  dx * dx + dy * dy

proc straightLineDistance*(a, b: BodyPoint): int =
  isqrtFloor(squaredDistance(a, b))

proc arrivalTicksForDistance*(distancePx, motionScale, velocity: int): int64 =
  ## Appendix R.2 integer arrival:
  ##   arrival = (d * motionScale + v - 1) div v
  ## with int64 products. Non-positive velocity is infinite arrival.
  if velocity <= 0:
    return InfiniteArrival
  let numerator = int64(distancePx) * int64(motionScale) + int64(velocity) - 1
  numerator div int64(velocity)

proc effectiveMaxVelocity*(config: GameConfig; team: Team; perks: PerkSet;
                           carryingFlag: bool; paintSpeedPct: int): int =
  ## Mirrors the sim's live max-speed derivation for arrival estimates,
  ## intentionally excluding the directional trench-exit divisor.
  let speedScale = if carryingFlag: config.carrierSpeedPct else: 100
  (config.maxSpeedFor(team, perks) * speedScale div 100) *
    paintSpeedPct div 100

proc arrivalFor*(input: PlanEscapeInput; resolved: BodyPoint): int64 =
  var distancePx = straightLineDistance(input.fromPoint, resolved)
  if input.routeDistance != nil:
    let routed = input.routeDistance(resolved)
    if routed.isSome:
      distancePx = routed.get
  arrivalTicksForDistance(distancePx, input.motionScale, input.velocity)

proc betterKeys(a, b: ScoreKeyList): bool =
  doAssert a.len == b.len
  for index in 0 ..< a.len:
    doAssert a.items[index].direction == b.items[index].direction
    if a.items[index].value == b.items[index].value:
      continue
    case a.items[index].direction
    of sdMaximize:
      return a.items[index].value > b.items[index].value
    of sdMinimize:
      return a.items[index].value < b.items[index].value
  false

proc withUniversal(score: ScoreKeyList; candidate: EscapeCandidate):
    ScoreKeyList =
  result = score
  doAssert result.len + 2 <= result.items.len
  result.items[result.len] = minKey(candidate.arrival)
  inc result.len
  result.items[result.len] = minKey(candidate.ordinal.int64)
  inc result.len

proc planEscape*(input: PlanEscapeInput; scorer: EscapeScorer):
    PlanEscapeResult =
  doAssert input.map != nil
  doAssert ReflexCandidateRadiusPx mod ReflexCandidateSpacingPx == 0

  var
    seenKeys: array[DedupSlots, int64]
    seenUsed: array[DedupSlots, bool]
    ordinal = 0
    haveHard = false
    haveFallback = false
    bestHard: EscapeCandidate
    bestFallback: EscapeCandidate
    hardKeys: ScoreKeyList
    fallbackKeys: ScoreKeyList

  for dy in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                   ReflexCandidateSpacingPx):
    for dx in countup(-ReflexCandidateRadiusPx, ReflexCandidateRadiusPx,
                     ReflexCandidateSpacingPx):
      let requested = (input.fromPoint.x + dx, input.fromPoint.y + dy)
      inc result.considered
      if not input.map.inBounds(requested):
        inc ordinal
        continue
      let goal = input.map.validateGoal(requested, input.fromPoint)
      if goal.isNone:
        inc ordinal
        continue
      inc result.resolvedCount
      let resolved = goal.get.goalPoint
      let key = pointKey(resolved)
      if seenKeys.seenOrAdd(seenUsed, key):
        inc ordinal
        continue
      inc result.dedupedCount
      let candidate = EscapeCandidate(requested: requested,
        resolved: resolved, goal: goal, ordinal: ordinal,
        arrival: input.arrivalFor(resolved))
      let score = scorer(candidate)
      if score.hardPass:
        let keys = score.normal.withUniversal(candidate)
        if not haveHard or keys.betterKeys(hardKeys):
          haveHard = true
          bestHard = candidate
          hardKeys = keys
      let keys = score.fallback.withUniversal(candidate)
      if not haveFallback or keys.betterKeys(fallbackKeys):
        haveFallback = true
        bestFallback = candidate
        fallbackKeys = keys
      inc ordinal

  if not haveFallback:
    return

  let chosen =
    if haveHard:
      bestHard
    else:
      result.fallbackUsed = true
      bestFallback
  result.found = true
  result.goal = chosen.goal
  result.point = chosen.resolved
  result.ordinal = chosen.ordinal
  result.arrival = chosen.arrival

proc isCoverPost*(map: BodyMap; point: BodyPoint): bool =
  ## Appendix R.2 spray scoring uses engine-side atlas posts. The atlas is
  ## cell-centered, so this accepts only the exact resolved post center.
  let cell = map.cellOf(point)
  cellCenter(cell) == point and map.coverDirections(cell) != 0'u16
