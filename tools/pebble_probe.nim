## pebble_probe — what is the cover MADE OF?
##
## The 50-map contact sheet's honest reservation is not that the boards look
## alike, it is that a plurality of tiles read as a TEXTURE of small equal-sized
## dark squares before they read as their archetype, and `interiorFrac` misses
## its bar at both team counts (0.295 / 0.274 against >= 0.30, control 0.342).
## Those are the same finding said twice: coverage can be bought by dumping
## rocks, enclosure cannot.
##
## Every metric in this project is a property of the finished MASK, so none of
## them can say which SHAPES the cover was spent on. This one can. It buckets
## every emitted obstacle by its bounding box's long side and reports, per
## bucket, both the count share and the AREA share — because a pebble texture
## is a large count share and can still be a small area share, and only the
## second one competes with the masses for the budget.
##
## Written after the W0 lesson, which cost this epic a day: I found a flat
## series, correctly concluded a mechanism was inert, and then named the first
## inert-looking mechanism in the source instead of rendering the board and
## asking what the cover actually WAS. The answer to that question was the fix.
##
##   nim c -d:release -r tools/pebble_probe.nim [count] [teams]
import std/[os, strformat, strutils, algorithm, sequtils]
import ../src/ctf/[sim, arena, map_metrics]

const
  ## Bucket edges on the bounding box's LONG side, in px, chosen against things
  ## the game already means rather than round numbers:
  ##   34  one DRAWN cog body           — below this a shape cannot hide anyone
  ##   68  two cog bodies abreast       — RecommendedCorridorWidthPx, a corridor
  ##  120  the interiorFrac probe reach — below this a shape cannot enclose
  Edges = [34, 68, 120]
  Names = ["<34px  sub-body", "34-68  one-body", "68-120 corridor", ">=120  mass"]

proc bucketOf(longSide: int): int =
  for i, e in Edges:
    if longSide < e: return i
  Edges.len

type Row = object
  label: string
  counts: array[4, int]
  areas: array[4, int]
  shapes, coverPm: int
  interior: float

proc profile(gameMap: CtfMap, label: string): Row =
  result.label = label
  for shape in gameMap.leftObstacles:
    let
      box = shapeAsRect(shape)
      b = bucketOf(max(box.w, box.h))
    inc result.counts[b]
    ## Bounding-box area, not carved area: the point is the shape's FOOTPRINT
    ## on the board, and a disc and a rect of the same box read the same at a
    ## glance. Stated so the number is not mistaken for wall pixels.
    result.areas[b] += box.w * box.h
    inc result.shapes
  let m = evaluateMap(gameMap, label)
  result.coverPm = m.coverPermille
  result.interior = m.interiorFrac

proc emit(r: Row) =
  var areaTotal = 0
  for a in r.areas: areaTotal += a
  echo &"  {r.label:<16} {r.shapes:>4} shapes  cover {r.coverPm:>3}pm  " &
    &"interiorFrac {r.interior:>5.3f}"
  for b in 0 ..< 4:
    ## Never a count without its fraction, and never the count alone: the
    ## count share is what the EYE sees and the area share is what competes
    ## for the fill budget. They routinely disagree and that is the finding.
    let
      cShare = if r.shapes > 0: 100.0 * r.counts[b].float / r.shapes.float else: 0.0
      aShare = if areaTotal > 0: 100.0 * r.areas[b].float / areaTotal.float else: 0.0
    echo &"      {Names[b]:<18} {r.counts[b]:>4} ({cShare:>5.1f}% of shapes)" &
      &"   {aShare:>5.1f}% of footprint"

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  ## RULE 1: the hand-authored control goes in the SAME batch, always. A metric
  ## that flags the control is wrong; a metric that skips it is worse.
  echo &"CONTROL"
  emit profile(loadCtfMapMetadata("arena"), "arena")
  echo ""
  echo &"GENERATED — {teams} teams, seeds 1001..{1000 + count}"

  var
    agg: Row
    raised = 0
    interiors: seq[float]
  agg.label = "MEAN"
  for i in 0 ..< count:
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(1001 + i, teams = teams)
    except CtfError:
      inc raised
      continue
    let r = profile(gameMap, "gen:" & $(1001 + i))
    for b in 0 ..< 4:
      agg.counts[b] += r.counts[b]
      agg.areas[b] += r.areas[b]
    agg.shapes += r.shapes
    agg.coverPm += r.coverPm
    interiors.add r.interior

  let generated = count - raised
  if generated == 0:
    echo "  every seed raised — nothing to profile."
    return
  agg.coverPm = agg.coverPm div generated
  var s = 0.0
  for v in interiors: s += v
  agg.interior = s / generated.float
  echo &"  pooled over {generated}/{count} seeds " &
    &"({100 * generated div count}%), {raised} raised"
  emit agg

  ## The distribution matters more than the mean here — a pebble problem that
  ## is universal and one that is concentrated in a few seeds need opposite
  ## fixes, and a mean cannot tell them apart.
  var sorted = interiors
  sorted.sort()
  echo &"  interiorFrac  min {sorted[0]:.3f}  " &
    &"median {sorted[sorted.len div 2]:.3f}  max {sorted[^1]:.3f}   " &
    &"below 0.30: {sorted.filterIt(it < 0.30).len}/{generated}"

main()
