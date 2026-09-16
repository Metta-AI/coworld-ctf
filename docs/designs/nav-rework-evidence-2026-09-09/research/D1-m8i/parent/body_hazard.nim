## Immutable episode hazard projection and its separately-owned bucket cache.
##
## The source is the zone DAMAGE surface. Render-gated paint arrival never
## crosses this boundary. Projection and segment summaries happen once during
## episode activation; live route queries only read these retained arrays.

import std/[heapqueue, math, options]
import ../ctf/zone_field
import body_map, body_route_index

const
  HazardNeverArrives* = 0xffff'u16
  HazardRiskRampTicks* = 96
  HazardRiskMaxMultiplier* = 12
  SafeHorizonTicks* = 48
  SafeBucketTicks* = 48
  HazardEtaSpeedQ4* = 33
  NoSafeSide = high(uint16)

type
  BodyHazardState* = enum
    bhsDark
    bhsReady

  BodyHazardOverlay* = ref object
    state*: BodyHazardState
    fingerprint*: uint64
    arrival*: seq[uint16]
    segmentArrivalMin*, segmentArrivalMax*: seq[uint16]
    roomMaxArrival*: seq[uint16]

  BodySafeCache* = ref object
    overlayFingerprint*: uint64
    gameGeneration*: uint64
    bucket*: int
    safeDistQ4*: seq[uint32]
    safeNext*: seq[uint16]
    roomHasDry*: seq[bool]
    lastElapsedTick: int
    revision*: uint64

  BodySafetyHints* = object
    ticksUntilPaintHere*: int32
    ticksToSafety*: int32
    safeDistPx*: int32
    retreatOctant*: int8
    sourceCell*: Option[int32]

proc mixFingerprint(value: var uint64, word: uint64) {.inline.} =
  value = (value xor word) * 1_099_511_628_211'u64

proc newDarkBodyHazardOverlay*(): BodyHazardOverlay =
  BodyHazardOverlay(state: bhsDark)

proc retainedBytes*(overlay: BodyHazardOverlay): int64 =
  ## Exact retained owner plus sequence payload bytes. The sequence headers
  ## themselves live in the fixed owner object counted by sizeof.
  if overlay == nil:
    return 0
  int64(sizeof(overlay[]) +
    overlay.arrival.len * sizeof(uint16) +
    overlay.segmentArrivalMin.len * sizeof(uint16) +
    overlay.segmentArrivalMax.len * sizeof(uint16) +
    overlay.roomMaxArrival.len * sizeof(uint16))

proc retainedBytes*(cache: BodySafeCache): int64 =
  ## Exact retained owner plus sequence payload bytes.
  if cache == nil:
    return 0
  int64(sizeof(cache[]) +
    cache.safeDistQ4.len * sizeof(uint32) +
    cache.safeNext.len * sizeof(uint16) +
    cache.roomHasDry.len * sizeof(bool))

proc projectedArrival(index: BodyRouteIndex,
    source: ZoneDamageSnapshot, navCell: int): uint16 =
  let
    navX = navCell mod index.map.gridWidth
    navY = navCell div index.map.gridWidth
    x0 = navX * NavCell
    y0 = navY * NavCell
    x1 = min(index.map.width - 1, x0 + NavCell - 1)
    y1 = min(index.map.height - 1, y0 + NavCell - 1)
  result = HazardNeverArrives
  for sourceY in y0 div source.cellPx .. y1 div source.cellPx:
    for sourceX in x0 div source.cellPx .. x1 div source.cellPx:
      result = min(result, source.damage[sourceY * source.gridW + sourceX])

proc newBodyHazardOverlay*(index: BodyRouteIndex;
    source: ZoneDamageSnapshot): BodyHazardOverlay =
  if index == nil:
    raise newException(ValueError, "body hazard overlay requires an index")
  if source.gridW <= 0 or source.gridH <= 0 or source.cellPx <= 0 or
      source.damage.len != source.gridW * source.gridH or
      source.gridW * source.cellPx < index.map.width or
      source.gridH * source.cellPx < index.map.height:
    raise newException(ValueError,
      "body hazard source does not cover the route-index map")

  let stats = index.routeIndexStats()
  new(result)
  result.state = bhsReady
  result.arrival = newSeq[uint16](stats.navCells)
  result.roomMaxArrival = newSeq[uint16](stats.rooms)

  var fingerprint = 14_695_981_039_346_656_037'u64
  fingerprint.mixFingerprint(source.fingerprint)
  fingerprint.mixFingerprint(index.routeIndexFingerprint())
  fingerprint.mixFingerprint(uint64(source.gridW))
  fingerprint.mixFingerprint(uint64(source.gridH))
  fingerprint.mixFingerprint(uint64(source.cellPx))
  for navCell in 0 ..< result.arrival.len:
    let arrival = index.projectedArrival(source, navCell)
    result.arrival[navCell] = arrival
    fingerprint.mixFingerprint(uint64(arrival))
    let room = index.roomForCell(navCell)
    if room >= 0:
      result.roomMaxArrival[room] = max(result.roomMaxArrival[room], arrival)

  let extrema = index.segmentArrivalExtrema(result.arrival,
    HazardNeverArrives)
  result.segmentArrivalMin = extrema.minimum
  result.segmentArrivalMax = extrema.maximum
  result.fingerprint = fingerprint

proc arrivalAt*(overlay: BodyHazardOverlay; cellIndex: int): uint16 =
  if overlay == nil or overlay.state == bhsDark:
    return HazardNeverArrives
  if cellIndex < 0 or cellIndex >= overlay.arrival.len:
    raise newException(IndexDefect, "body hazard cell is out of bounds")
  overlay.arrival[cellIndex]

proc divideRoundTiesEven(numerator, denominator: int64): int64 {.inline.} =
  let
    quotient = numerator div denominator
    remainder = numerator mod denominator
    doubled = remainder * 2
  if doubled > denominator or
      (doubled == denominator and (quotient and 1) != 0):
    quotient + 1
  else:
    quotient

proc hazardStepCostQ4*(overlay: BodyHazardOverlay; cellIndex: int;
    etaTick: int; physicalStepQ4: uint32): int64 =
  let arrival = overlay.arrivalAt(cellIndex)
  if arrival == HazardNeverArrives:
    return 0
  let
    length = physicalStepQ4.int64
    slack = arrival.int64 - etaTick.int64
  if slack >= HazardRiskRampTicks:
    return 0
  if slack <= 0:
    return HazardRiskMaxMultiplier.int64 * length
  divideRoundTiesEven(
    HazardRiskMaxMultiplier.int64 * length *
      (HazardRiskRampTicks.int64 - slack),
    HazardRiskRampTicks.int64)

proc hazardSegmentCostQ4*(overlay: BodyHazardOverlay; index: BodyRouteIndex;
    segment: int; reversed: bool; elapsedTick: int;
    entryPhysicalQ4: int64): int64 =
  if overlay == nil or overlay.state == bhsDark:
    return 0
  let metadata = index.routeSegmentAt(segment)
  let latestEta = elapsedTick + int(
    (entryPhysicalQ4 + metadata.staticLengthQ4.int64 +
     HazardEtaSpeedQ4 - 1) div HazardEtaSpeedQ4)
  if overlay.segmentArrivalMin[segment].int >=
      latestEta + HazardRiskRampTicks:
    return 0
  let entryEta = elapsedTick + int(
    (entryPhysicalQ4 + HazardEtaSpeedQ4 - 1) div HazardEtaSpeedQ4)
  if overlay.segmentArrivalMax[segment].int <= entryEta:
    return HazardRiskMaxMultiplier.int64 * metadata.staticLengthQ4.int64
  var physical = entryPhysicalQ4
  for offset in 1 ..< metadata.cellLen.int:
    let
      previous = index.segmentCellAt(segment, offset - 1, reversed)
      current = index.segmentCellAt(segment, offset, reversed)
      a = index.routePoint(previous)
      b = index.routePoint(current)
      dx = a.x - b.x
      dy = a.y - b.y
      step = uint32(round(sqrt(float(dx * dx + dy * dy)) * 16.0))
      eta = elapsedTick + int(
        (physical + step.int64 + HazardEtaSpeedQ4 - 1) div
          HazardEtaSpeedQ4)
    result += overlay.hazardStepCostQ4(index.routeNavCell(current).int,
      eta, step)
    physical += step.int64

proc newBodySafeCache*(): BodySafeCache =
  new(result)
  result.bucket = -1
  result.lastElapsedTick = -1

proc refreshSafeCache*(cache: BodySafeCache; index: BodyRouteIndex;
    overlay: BodyHazardOverlay; elapsedTick: int; gameGeneration: uint64) =
  if cache == nil or index == nil or overlay == nil:
    raise newException(ValueError,
      "body safe cache requires an index and hazard overlay")
  let
    effectiveTick = max(0, elapsedTick)
    bucket = effectiveTick div SafeBucketTicks
    movedBackward = cache.lastElapsedTick >= 0 and
      effectiveTick < cache.lastElapsedTick
  if not movedBackward and cache.overlayFingerprint == overlay.fingerprint and
      cache.gameGeneration == gameGeneration and cache.bucket == bucket:
    cache.lastElapsedTick = effectiveTick
    return

  let stats = index.routeIndexStats()
  cache.overlayFingerprint = overlay.fingerprint
  cache.gameGeneration = gameGeneration
  cache.bucket = bucket
  cache.lastElapsedTick = effectiveTick
  inc cache.revision
  cache.safeDistQ4 = newSeq[uint32](stats.sides)
  cache.safeNext = newSeq[uint16](stats.sides)
  cache.roomHasDry = newSeq[bool](stats.rooms)
  for distance in cache.safeDistQ4.mitems:
    distance = high(uint32)
  for next in cache.safeNext.mitems:
    next = NoSafeSide
  if overlay.state == bhsDark:
    return

  let dryAfter = (bucket + 1) * SafeBucketTicks - 1 + SafeHorizonTicks
  for room in 0 ..< cache.roomHasDry.len:
    let arrival = overlay.roomMaxArrival[room]
    cache.roomHasDry[room] = arrival == HazardNeverArrives or
      arrival.int > dryAfter

  var heap = initHeapQueue[(uint32, int)]()
  for side in 0 ..< stats.sides:
    let
      point = index.sideAnchor(side)
      cell = index.map.cellOf(point)
      cellIndex = cell.y * index.map.gridWidth + cell.x
    let arrival = overlay.arrivalAt(cellIndex)
    if arrival == HazardNeverArrives or arrival.int > dryAfter:
      cache.safeDistQ4[side] = 0
      cache.safeNext[side] = uint16(side)
      heap.push((0'u32, side))

  while heap.len > 0:
    let (distance, side) = heap.pop()
    if distance != cache.safeDistQ4[side]:
      continue
    for arcOffset in index.arcRangeForSide(side):
      let
        arc = index.routeArcAt(arcOffset)
        next = arc.toSide.int
        edge = index.routeSegmentAt(arc.segment.int).staticLengthQ4
      if distance > high(uint32) - edge:
        continue
      let candidate = distance + edge
      if candidate < cache.safeDistQ4[next] or
          (candidate == cache.safeDistQ4[next] and
           uint16(side) < cache.safeNext[next]):
        cache.safeDistQ4[next] = candidate
        cache.safeNext[next] = uint16(side)
        heap.push((candidate, next))

proc roomHasDryAt*(cache: BodySafeCache; overlay: BodyHazardOverlay;
    room: int): bool =
  doAssert cache != nil and overlay != nil and
    cache.overlayFingerprint == overlay.fingerprint,
    "body safe cache does not match the hazard overlay"
  if room < 0 or room >= cache.roomHasDry.len:
    raise newException(IndexDefect, "body hazard room is out of bounds")
  cache.roomHasDry[room]

proc cellDryAt*(cache: BodySafeCache; overlay: BodyHazardOverlay;
    cellIndex: int): bool =
  doAssert cache != nil and overlay != nil and
    cache.overlayFingerprint == overlay.fingerprint,
    "body safe cache does not match the hazard overlay"
  let arrival = overlay.arrivalAt(cellIndex)
  arrival == HazardNeverArrives or
    arrival.int > (cache.bucket + 1) * SafeBucketTicks - 1 + SafeHorizonTicks

proc safeDistanceQ4At*(cache: BodySafeCache; overlay: BodyHazardOverlay;
    side: int): uint32 =
  doAssert cache != nil and overlay != nil and
    cache.overlayFingerprint == overlay.fingerprint,
    "body safe cache does not match the hazard overlay"
  if side < 0 or side >= cache.safeDistQ4.len:
    raise newException(IndexDefect, "body safe-cache side is out of bounds")
  cache.safeDistQ4[side]

proc nextSafeSideAt*(cache: BodySafeCache; overlay: BodyHazardOverlay;
    side: int): Option[int] =
  doAssert cache != nil and overlay != nil and
    cache.overlayFingerprint == overlay.fingerprint,
    "body safe cache does not match the hazard overlay"
  if side < 0 or side >= cache.safeNext.len:
    raise newException(IndexDefect, "body safe-cache side is out of bounds")
  if cache.safeNext[side] == NoSafeSide:
    none(int)
  else:
    some(cache.safeNext[side].int)
