## Phase-14 cover scorer laws. Selection goldens were re-blessed after the
## launch-map cover-density freeze.

import std/[algorithm, math, monotimes, options, times, unittest]

import ../src/ctf/arena
import ../src/shell/[body_cache, body_map, cover_scorer, types as shellTypes]

const
  PostGunRangePx = 1300
  PostShortlistCount = 16
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

proc brMap(): BodyMap =
  newBodyMap(mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json")))

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc floorModulo(value, modulus: int): int =
  ((value mod modulus) + modulus) mod modulus

proc sectorForBearing(bearingBrads: int): int =
  floorModulo(pyRound(bearingBrads.float / 256.0 *
    AtlasSectorCount.float), AtlasSectorCount)

proc quadrantSector(adx, ady: int64): int =
  if ady * SlopeScale <= adx * Tan1125:
    0
  elif ady * SlopeScale < adx * Tan3375:
    1
  elif ady * SlopeScale <= adx * Tan5625:
    2
  elif ady * SlopeScale < adx * Tan7875:
    3
  else:
    4

proc sectorTo(fromPoint, toPoint: BodyPoint): int =
  let
    dx = toPoint.x - fromPoint.x
    dy = toPoint.y - fromPoint.y
    adx = abs(dx).int64
    ady = abs(dy).int64
  if adx == 0 and ady == 0:
    return 0
  let offset = quadrantSector(adx, ady)
  if dx >= 0:
    if dy >= 0:
      offset
    else:
      (AtlasSectorCount - offset) mod AtlasSectorCount
  elif dy >= 0:
    8 - offset
  else:
    8 + offset

proc bestReachSector(post: BodyAtlasPost): int =
  for sector in 0 ..< AtlasSectorCount:
    if post.reach[sector] > post.reach[result]:
      result = sector

proc normalizedReach(reach: uint16): float =
  min(reach.int.float / PostGunRangePx.float, 1.0)

type ReferenceRow = object
  atlasIndex: int
  point: BodyPoint
  sightline, facing, duckContrast, phaseOne, final: float

proc referenceNearestCover(cache: BodySeatCache; anchor: BodyPoint;
                           radiusPx, bearingBrads: int;
                           threats: openArray[BodyPoint]): Option[ReferenceRow] =
  let radius = min(radiusPx, shellTypes.MaxCoverRadiusPx)
  var rows: seq[ReferenceRow]
  for atlasIndex in cache.map.atlasNear(anchor, radius):
    let post = cache.map.atlasPostAt(atlasIndex)
    let sightSector =
      if bearingBrads < 0: post.bestReachSector
      else: sectorForBearing(bearingBrads)
    var facing = 0.0
    if threats.len > 0:
      for threat in threats:
        facing += normalizedReach(post.reach[sectorTo(post.pos, threat)])
      facing /= threats.len.float
    let sightline = normalizedReach(post.reach[sightSector])
    rows.add ReferenceRow(atlasIndex: atlasIndex, point: post.pos,
      sightline: sightline, facing: facing,
      phaseOne: 0.8 * sightline + 0.2 * facing)
  if rows.len == 0:
    return none(ReferenceRow)
  rows.sort(proc(a, b: ReferenceRow): int =
    result = cmp(b.phaseOne, a.phaseOne)
    if result == 0: result = cmp(a.atlasIndex, b.atlasIndex))
  if rows.len > PostShortlistCount:
    rows.setLen(PostShortlistCount)
  for row in rows.mitems:
    let duck = cache.duckFor(row.atlasIndex)
    row.duckContrast = duck.contrast
    row.final = 0.65 * row.sightline + 0.20 * row.facing +
      0.15 * row.duckContrast
  rows.sort(proc(a, b: ReferenceRow): int =
    result = cmp(b.final, a.final)
    if result == 0: result = cmp(a.atlasIndex, b.atlasIndex))
  some(rows[0])

proc runCoverTick(caches: var array[32, BodySeatCache];
                  threats: openArray[BodyPoint]): tuple[calls: int, checksum: int64] =
  for step in 0 ..< shellTypes.MaxStepsPerSeatPerTick:
    for seat in 0 ..< 32:
      for spatial in 0 ..< shellTypes.MaxSpatialCallsPerStep:
        let point = caches[seat].nearestCoverPoint(
          (1800 + spatial + step, 820 + seat mod 3),
          shellTypes.MaxCoverRadiusPx, if spatial mod 2 == 0: -1 else: 64,
          threats).get
        result.checksum += (int64(point.x) shl 16) + int64(point.y) +
          int64(step * 31 + seat * 7 + spatial)
        inc result.calls

suite "shell nearest_cover scorer":
  test "cap-parameterized scorer matches the ported lab shape in both bearing forms":
    let map = brMap()
    check map.maxAtlasPostsInRadius <= shellTypes.MaxCoverPostsExamined
    let
      anchor = (1800, 820)
      threats = @[(2060, 820), (1600, 620), (1800, 1120)]

    for bearing in [-1, 64]:
      let cache = newBodySeatCache(map)
      let referenceCache = newBodySeatCache(map)
      let scored = cache.scoreNearestCover(anchor,
        shellTypes.MaxCoverRadiusPx * 3, bearing, threats)
      let reference = referenceCache.referenceNearestCover(anchor,
        shellTypes.MaxCoverRadiusPx * 3, bearing, threats).get
      check scored.found
      check scored.examined <= shellTypes.MaxCoverPostsExamined
      check scored.shortlisted <= PostShortlistCount
      check scored.point == reference.point
      check scored.row.atlasIndex == reference.atlasIndex
      check abs(scored.row.finalScore - reference.final) < 1e-12

  test "selection goldens cover no-bearing and supplied-bearing forms":
    let map = brMap()
    let threats = @[(2060, 820), (1600, 620), (1800, 1120)]
    let noneBearing = newBodySeatCache(map).scoreNearestCover((550, 300),
      shellTypes.MaxCoverRadiusPx, -1, threats)
    let suppliedBearing = newBodySeatCache(map).scoreNearestCover((550, 300),
      shellTypes.MaxCoverRadiusPx, 64, threats)
    check noneBearing.found
    check suppliedBearing.found
    check noneBearing.point == (516, 356)
    check suppliedBearing.point == (804, 180)
    check noneBearing.point != suppliedBearing.point

  test "empty atlas disc returns the true no-cover answer":
    let map = brMap()
    check newBodySeatCache(map).nearestCoverPoint((0, 0), 1, -1, []).isNone

  test "32-seat cover tick micro row prints the current 1024-cap cost":
    let map = brMap()
    var caches: array[32, BodySeatCache]
    for cache in caches.mitems:
      cache = newBodySeatCache(map)
    let threats = @[(2060, 820), (1600, 620), (1800, 1120), (1720, 760),
      (1900, 900), (1500, 500), (2200, 1100), (1200, 700)]
    let prewarm = caches.runCoverTick(threats)
    let started = getMonoTime()
    let measured = caches.runCoverTick(threats)
    let elapsedUs = (getMonoTime() - started).inNanoseconds.float / 1_000.0
    echo "SHELL_NEAREST_COVER_MICRO calls=", measured.calls,
      " posts_cap=", shellTypes.MaxCoverPostsExamined,
      " max_radius=", shellTypes.MaxCoverRadiusPx,
      " elapsed_us=", elapsedUs,
      " per_call_us=", elapsedUs / measured.calls.float,
      " checksum=", measured.checksum,
      " prewarm_checksum=", prewarm.checksum
    check measured.calls == 32 * shellTypes.MaxStepsPerSeatPerTick *
      shellTypes.MaxSpatialCallsPerStep
    check measured.calls == prewarm.calls
    check measured.checksum == prewarm.checksum
    check measured.checksum != 0
