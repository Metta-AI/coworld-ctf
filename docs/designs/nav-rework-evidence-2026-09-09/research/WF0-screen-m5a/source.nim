## Isolated exact-danger screen. This is not a whole-body acceptance gate.
import std/[algorithm, json, math, monotimes, random, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]

type
  RayRange = tuple[first, last: int]
  RayCell = object
    point: BodyPoint
    firstRange, afterRange: int
  Geometry = object
    radius, rayCount: int
    cells: seq[RayCell]
    ranges: seq[RayRange]
    shells: seq[int]
    kernel: seq[float32]
    blocked: seq[bool]

proc evenRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  lower + ord(fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0))

iterator rayCells(target: BodyPoint): BodyPoint =
  let nx = abs(target.x)
  let ny = abs(target.y)
  let sx = cmp(target.x, 0)
  let sy = cmp(target.y, 0)
  var x, y, ix, iy: int
  var decision = ny - nx
  while ix < nx or iy < ny:
    if decision == 0:
      yield (x + sx, y)
      yield (x, y + sy)
      x += sx
      y += sy
      inc ix
      inc iy
      decision += 2 * ny - 2 * nx
    elif decision < 0:
      x += sx
      inc ix
      decision += 2 * ny
    else:
      y += sy
      inc iy
      decision -= 2 * nx
    yield (x, y)

proc angleOrder(a, b: BodyPoint): int =
  let ah = ord(a.y < 0 or (a.y == 0 and a.x < 0))
  let bh = ord(b.y < 0 or (b.y == 0 and b.x < 0))
  if ah != bh: return cmp(ah, bh)
  let cross = a.x.int64 * b.y.int64 - a.y.int64 * b.x.int64
  if cross != 0: return -cmp(cross, 0'i64)
  result = cmp(a.x, b.x)
  if result == 0: result = cmp(a.y, b.y)

proc geometry(map: BodyMap; gunRange: int): Geometry =
  result.radius = max(1, (gunRange + NavCell - 1) div NavCell)
  let r = result.radius
  let diameter = 2 * r + 1
  let count = diameter * diameter
  var perimeter: seq[BodyPoint]
  var included = newSeq[bool](count)
  template includePoint(px, py: int) =
    let index = (py + r) * diameter + px + r
    if not included[index]:
      included[index] = true
      perimeter.add((px, py))
  for x in -r .. r:
    let y = evenRound(sqrt(max(0, r * r - x * x).float))
    includePoint(x, y)
    includePoint(x, -y)
  for y in -r .. r:
    let x = evenRound(sqrt(max(0, r * r - y * y).float))
    includePoint(x, y)
    includePoint(-x, y)
  perimeter.sort(angleOrder)
  result.rayCount = perimeter.len
  var counts = newSeq[int](count)
  for target in perimeter:
    for point in rayCells(target):
      inc counts[(point.y + r) * diameter + point.x + r]
  var offsets = newSeq[int](count + 1)
  for i, value in counts: offsets[i + 1] = offsets[i] + value
  var members = newSeq[int](offsets[^1])
  var cursor = newSeq[int](count)
  for i in 0 ..< count: cursor[i] = offsets[i]
  for ray, target in perimeter:
    for point in rayCells(target):
      let index = (point.y + r) * diameter + point.x + r
      members[cursor[index]] = ray
      inc cursor[index]
  var cellCount, rangeCount: int
  for index, value in counts:
    if value == 0: continue
    inc cellCount
    var previous = -2
    for i in offsets[index] ..< offsets[index + 1]:
      if members[i] > previous + 1: inc rangeCount
      previous = members[i]
  result.cells = newSeqOfCap[RayCell](cellCount)
  result.ranges = newSeqOfCap[RayRange](rangeCount)
  result.shells = newSeq[int](2 * r + 2)
  for shell in 1 .. 2 * r:
    result.shells[shell] = result.cells.len
    for x in max(-r, -shell) .. min(r, shell):
      let ay = shell - abs(x)
      if ay > r: continue
      for sign in [-1, 1]:
        if ay == 0 and sign == 1: continue
        let y = sign * ay
        let index = (y + r) * diameter + x + r
        if counts[index] == 0: continue
        let firstRange = result.ranges.len
        var i = offsets[index]
        while i < offsets[index + 1]:
          let first = members[i]
          var last = first
          inc i
          while i < offsets[index + 1] and members[i] <= last + 1:
            last = members[i]
            inc i
          result.ranges.add((first, last))
        result.cells.add RayCell(point: (x, y), firstRange: firstRange,
          afterRange: result.ranges.len)
  result.shells[^1] = result.cells.len
  result.kernel = newSeq[float32](count)
  # Literal reference contract from body_nav.attenuation; raster equality below
  # detects drift. The live radius and the 1050px attenuation cutoff differ.
  for y in -r .. r:
    for x in -r .. r:
      let distance = hypot(x.float, y.float) * NavCell.float
      let value = if distance > min(1050, gunRange).float: 0'f32
        elif distance <= 400.0: 1'f32
        else: (1.0 - ((distance - 400.0) / (1050.0 - 400.0)) * (1.0 - 0.6)).float32
      result.kernel[(y + r) * diameter + x + r] = value
  result.blocked = newSeq[bool](map.gridWidth * map.gridHeight)
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      result.blocked[y * map.gridWidth + x] = map.isWall(cellCenter((x, y)))

proc wordMask(span: RayRange; word: int): uint64 {.inline.} =
  result = high(uint64)
  if word == span.first div 64: result = result shl (span.first mod 64)
  if word == span.last div 64:
    result = result and (high(uint64) shr (63 - span.last mod 64))

proc activeCell(g: Geometry; cell: RayCell; active: seq[uint64]): bool {.inline.} =
  for i in cell.firstRange ..< cell.afterRange:
    let span = g.ranges[i]
    for word in span.first div 64 .. span.last div 64:
      if (active[word] and wordMask(span, word)) != 0: return true

proc rebuild(g: Geometry; map: BodyMap; gunRange: int;
             sources: seq[DangerCandidate]; active: var seq[uint64];
             values: var seq[float32]): float32 =
  for value in values.mitems: value = 0
  let width = map.gridWidth
  let height = map.gridHeight
  let diameter = 2 * g.radius + 1
  for source in sources:
    let origin = map.cellOf(source.pos)
    for word in active.mitems: word = high(uint64)
    if g.rayCount mod 64 != 0:
      active[^1] = (1'u64 shl (g.rayCount mod 64)) - 1
    values[origin.y * width + origin.x] += g.kernel[g.radius * diameter + g.radius]
    for shell in 1 ..< g.shells.len - 1:
      for i in g.shells[shell] ..< g.shells[shell + 1]:
        let cell = g.cells[i]
        let x = origin.x + cell.point.x
        let y = origin.y + cell.point.y
        if x < 0 or x >= width or y < 0 or y >= height or g.blocked[y * width + x]:
          for j in cell.firstRange ..< cell.afterRange:
            let span = g.ranges[j]
            for word in span.first div 64 .. span.last div 64:
              active[word] = active[word] and not wordMask(span, word)
      var anyActive = false
      for word in active:
        if word != 0: anyActive = true; break
      if not anyActive: break
      for i in g.shells[shell] ..< g.shells[shell + 1]:
        let cell = g.cells[i]
        if g.activeCell(cell, active):
          let x = origin.x + cell.point.x
          let y = origin.y + cell.point.y
          values[y * width + x] += g.kernel[(cell.point.y + g.radius) * diameter +
            cell.point.x + g.radius]
    let closeRange = min(190, gunRange)
    let closeCells = (closeRange + NavCell - 1) div NavCell
    for y in max(0, origin.y - closeCells) .. min(height - 1, origin.y + closeCells):
      for x in max(0, origin.x - closeCells) .. min(width - 1, origin.x + closeCells):
        let center = cellCenter((x, y))
        let dx = center.x - source.pos.x
        let dy = center.y - source.pos.y
        if dx * dx + dy * dy <= closeRange * closeRange:
          values[y * width + x] += 0.5'f32
  for value in values: result = max(result, value)

proc screen(label: string; gameMap: CtfMap; gunRange: int): JsonNode =
  let map = newBodyMap(gameMap)
  var points: seq[BodyPoint]
  for y in countup(0, map.height - 1, 32):
    for x in countup(0, map.width - 1, 32):
      if map.canStand((x, y)): points.add((x, y))
  var rng = initRand(401)
  var input = DangerInput(selfXy: points[rng.rand(points.high)])
  for i in 0 ..< 16:
    input.candidates.add DangerCandidate(seatIndex: i, pos: points[rng.rand(points.high)])
  let nav = newBodyNavSystem(map, 1, gunRange, prepareRouteQueries = false)
  let started = getMonoTime()
  let g = geometry(map, gunRange)
  let constructionNs = (getMonoTime() - started).inNanoseconds
  nav.seats[0].rebuildDanger(map, input, 0)
  let sources = nav.seats[0].selectedDangerSources()
  var active = newSeq[uint64]((g.rayCount + 63) div 64)
  var values = newSeq[float32](map.gridWidth * map.gridHeight)
  let maximum = g.rebuild(map, gunRange, sources, active, values)
  doAssert maximum == nav.seats[0].danger.maximum
  for i, value in values:
    doAssert cast[uint32](value) == cast[uint32](nav.seats[0].danger.values[i])
  var parentTimes, candidateTimes: seq[int64]
  for sample in 0 ..< 30:
    let parentStarted = getMonoTime()
    nav.seats[0].rebuildDanger(map, input, sample)
    parentTimes.add (getMonoTime() - parentStarted).inNanoseconds
    let candidateStarted = getMonoTime()
    discard g.rebuild(map, gunRange, sources, active, values)
    candidateTimes.add (getMonoTime() - candidateStarted).inNanoseconds
  result = %*{"map": label, "gun_range": gunRange, "equal": true,
    "parent_samples_ns": parentTimes, "candidate_samples_ns": candidateTimes,
    "construction_ns": constructionNs, "rays": g.rayCount, "cells": g.cells.len,
    "extra_geometry_bytes": g.cells.capacity * sizeof(RayCell) +
      g.ranges.capacity * sizeof(RayRange) + g.shells.capacity * sizeof(int),
    "active_bytes": active.capacity * sizeof(uint64)}
  parentTimes.sort()
  candidateTimes.sort()
  result["parent_p95_ns"] = %parentTimes[28]
  result["candidate_p95_ns"] = %candidateTimes[28]

var rows = newJArray()
let pool = loadBrS2PoolRaw()
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for gunRange in [331, 1300]:
  for index in [0, 29, 48]:
    stderr.writeLine "pool:", index, " range:", gunRange
    rows.add screen("pool:" & $index, mapFromSpecJson($pool[index]["spec"]), gunRange)
  for index in [0, 5, 10]:
    stderr.writeLine "configured:", index, " range:", gunRange
    rows.add screen("configured:" & $index, mapFromSpecJson($configured[index]), gunRange)
  stderr.writeLine "colossal range:", gunRange
  rows.add screen("colossal", generateCtfMap(4242,
    MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4), gunRange)
echo %*{"rows": rows, "whole_body_acceptance": false}
