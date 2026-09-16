## Engine-side `nearest_cover` scorer over lane A's immutable cover atlas.
##
## This is the bounded host query from §6.1. The atlas stays out of
## PlayContext/View because its best answer is query-dependent on anchor,
## bearing, threats, and the seat-private duck cache.

import std/[algorithm, math, options]

import body_cache, body_map, types as shellTypes

const
  PostGunRangePx = 1300
  PostShortlistCount = 16
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

type
  CoverScoreRow* = object
    atlasIndex*: int
    point*: BodyPoint
    sightline*: float
    facing*: float
    duckContrast*: float
    phaseOneScore*: float
    finalScore*: float

  CoverScoreResult* = object
    found*: bool
    point*: BodyPoint
    examined*: int
    shortlisted*: int
    row*: CoverScoreRow

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5:
    lower
  elif fraction > 0.5:
    lower + 1
  elif (lower and 1) == 0:
    lower
  else:
    lower + 1

proc floorModulo(value, modulus: int): int =
  ((value mod modulus) + modulus) mod modulus

proc sectorForBearing(bearingBrads: int): int =
  ## Same nearest-sector quantization as the stencil brads helpers, reduced
  ## from 256 brads to lane A's 16 atlas sectors.
  floorModulo(pyRound(bearingBrads.float / 256.0 *
    AtlasSectorCount.float), AtlasSectorCount)

proc quadrantSector(adx, ady: int64): int =
  ## Nearest sector in the 0..90 degree quadrant. The thresholds are the
  ## half-sector boundaries at 11.25, 33.75, 56.25, and 78.75 degrees,
  ## scaled so threat/post classification avoids floating point work.
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

proc sightlineScore(post: BodyAtlasPost; bearingBrads: int): float =
  let sector =
    if bearingBrads < 0: post.bestReachSector
    else: sectorForBearing(bearingBrads)
  normalizedReach(post.reach[sector])

proc facingScore(post: BodyAtlasPost; threats: openArray[BodyPoint]): float =
  if threats.len == 0:
    return 0.0
  for threat in threats:
    result += normalizedReach(post.reach[sectorTo(post.pos, threat)])
  result /= threats.len.float

proc compareFinal(a, b: CoverScoreRow): int =
  result = cmp(b.finalScore, a.finalScore)
  if result == 0:
    result = cmp(a.atlasIndex, b.atlasIndex)

proc betterPhaseOne(a, b: CoverScoreRow): bool =
  a.phaseOneScore > b.phaseOneScore or
    (a.phaseOneScore == b.phaseOneScore and a.atlasIndex < b.atlasIndex)

proc worsePhaseOne(a, b: CoverScoreRow): bool =
  a.phaseOneScore < b.phaseOneScore or
    (a.phaseOneScore == b.phaseOneScore and a.atlasIndex > b.atlasIndex)

proc keepShortlisted(shortlist: var array[PostShortlistCount, CoverScoreRow];
                     count: var int; row: CoverScoreRow) =
  if count < PostShortlistCount:
    shortlist[count] = row
    inc count
    return
  var worst = 0
  for index in 1 ..< PostShortlistCount:
    if shortlist[index].worsePhaseOne(shortlist[worst]):
      worst = index
  if row.betterPhaseOne(shortlist[worst]):
    shortlist[worst] = row

proc scoreNearestCover*(cache: BodySeatCache; anchor: BodyPoint;
                        radiusPx, bearingBrads: int;
                        threats: openArray[BodyPoint]): CoverScoreResult =
  ## Scores every post in the clamped disc, then applies the lab's two-phase
  ## shape: sightline/facing shortlist first, duck-contrast only on that
  ## shortlist, final weighted score second. The radius and density cap are
  ## read from `types.nim`; callers never hardcode either value.
  if cache == nil or cache.map == nil or radiusPx <= 0:
    return
  let radius = min(radiusPx, shellTypes.MaxCoverRadiusPx)
  var
    shortlist: array[PostShortlistCount, CoverScoreRow]
    shortlistCount = 0
  for atlasIndex in cache.map.atlasNear(anchor, radius):
    let post = cache.map.atlasPostAt(atlasIndex)
    let sightline = post.sightlineScore(bearingBrads)
    let facing = post.facingScore(threats)
    shortlist.keepShortlisted(shortlistCount, CoverScoreRow(
      atlasIndex: atlasIndex,
      point: post.pos,
      sightline: sightline,
      facing: facing,
      phaseOneScore: 0.8 * sightline + 0.2 * facing))
    inc result.examined
  if shortlistCount == 0:
    return
  var rows = newSeqOfCap[CoverScoreRow](shortlistCount)
  for index in 0 ..< shortlistCount:
    rows.add(shortlist[index])
  result.shortlisted = rows.len
  for row in rows.mitems:
    let duck = cache.duckFor(row.atlasIndex)
    row.duckContrast = duck.contrast
    row.finalScore = 0.65 * row.sightline + 0.20 * row.facing +
      0.15 * row.duckContrast
  rows.sort(compareFinal)
  result.found = true
  result.row = rows[0]
  result.point = rows[0].point

proc nearestCoverPoint*(cache: BodySeatCache; anchor: BodyPoint;
                        radiusPx, bearingBrads: int;
                        threats: openArray[BodyPoint]): Option[BodyPoint] =
  let scored = cache.scoreNearestCover(anchor, radiusPx, bearingBrads, threats)
  if scored.found:
    some(scored.point)
  else:
    none(BodyPoint)
